package protocol

import (
	"fmt"
	"strings"
	"sync"
	"time"
	"unicode"

	"github.com/tychoish/fun/ers"
	"github.com/tychoish/fun/opt"

	"github.com/tychoish/sprite/go/lisp"
)

// Status reports the settlement state of a Handle.
type Status int

const (
	// StatusPending means the background eval has not yet settled.
	StatusPending Status = iota
	// StatusResolved means the background eval completed successfully.
	StatusResolved
	// StatusRejected means the background eval failed, or the polling
	// loop itself failed (a network error, a malformed reply, or the
	// daemon reporting the token as unknown/expired).
	StatusRejected
)

// Handle represents an in-flight or resumed asynchronous eval, started
// via sprite-async-start and tracked via sprite-async-poll on the
// Emacs daemon (see sprite-async.el at the repo root). The
// channel/goroutine driving it is an unexported implementation
// detail; callers interact with Handle's methods only.
type Handle struct {
	token string

	mu     sync.Mutex
	status Status
	value  string
	err    error

	done chan struct{}
}

// Token returns the opaque token identifying this async eval on the
// daemon, suitable for later passing to Resume (e.g. across process
// restarts, once persisted somewhere by the caller).
func (h *Handle) Token() string { return h.token }

// Poll reports the Handle's current cached state. It never blocks and
// never performs a network round trip: the actual polling happens on
// a background goroutine started by EvalAsync/Resume, and Poll simply
// reads its last-known result.
func (h *Handle) Poll() (Status, string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.status, h.value, h.err
}

// Wait blocks until the Handle settles (resolved or rejected), then
// returns the settled value or error.
func (h *Handle) Wait() (string, error) {
	<-h.done
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.value, h.err
}

// settle records the Handle's final state and wakes any Wait callers.
// Must be called at most once per Handle.
func (h *Handle) settle(status Status, value string, err error) {
	h.mu.Lock()
	h.status = status
	h.value = value
	h.err = err
	h.mu.Unlock()
	close(h.done)
}

// WithTTL sets the TTL-SECONDS argument passed to sprite-async-start.
// When not supplied, EvalAsync omits that argument from the sexp
// entirely rather than sending a zero/default sentinel.
func WithTTL(d time.Duration) Option {
	return func(c *Config) error { c.TTL = &d; return nil }
}

// WithPollInterval sets a fixed delay between polls, overriding the
// default exponential backoff.
func WithPollInterval(d time.Duration) Option {
	return func(c *Config) error {
		c.PollIntervalFunc = func(time.Duration) time.Duration { return d }
		return nil
	}
}

// WithPollIntervalFunc sets a custom poll-interval function, called
// before each poll after the first with the elapsed time since
// EvalAsync/Resume started, returning the delay before the next poll.
func WithPollIntervalFunc(f func(elapsed time.Duration) time.Duration) Option {
	return func(c *Config) error { c.PollIntervalFunc = f; return nil }
}

// newDefaultPollIntervalFunc returns a fresh, stateful poll-interval
// function implementing exponential backoff: 50ms, doubling each
// poll, capped at 2s. A new instance is created per Handle so that
// concurrent Handles don't share backoff state.
func newDefaultPollIntervalFunc() func(time.Duration) time.Duration {
	const (
		initial = 50 * time.Millisecond
		capped  = 2 * time.Second
	)
	next := initial
	return func(time.Duration) time.Duration {
		d := next
		next *= 2
		if next > capped {
			next = capped
		}
		return d
	}
}

// applyAsyncOptions resolves opts into a Config, the same way
// EvalBlocking does internally, so EvalAsync/Resume can inspect the
// TTL/poll-interval fields without needing EvalBlocking to expose
// them.
func applyAsyncOptions(opts ...Option) (Config, error) {
	var cfg Config
	if err := opt.Join(opts...).Apply(&cfg); err != nil {
		return Config{}, ers.Wrap(err, "applying options")
	}
	return cfg, nil
}

// EvalAsync registers form for background evaluation on the daemon
// reachable at target (via sprite-async-start) and returns a Handle
// immediately, without waiting for form to finish evaluating. A
// background goroutine polls the daemon (via sprite-async-poll) on an
// exponential backoff (or a caller-supplied interval, see
// WithPollInterval/WithPollIntervalFunc) until the eval settles,
// updating the Handle's cached state; the goroutine exits once
// settled.
//
// If the initial sprite-async-start call itself fails (e.g. a bad
// target or missing auth key), EvalAsync returns (nil, error)
// directly -- this is the one case where the error is not delivered
// through a Handle, since no Handle can be constructed without a
// token. Once a Handle is returned, every subsequent failure (a poll
// erroring, the form itself erroring inside Emacs, or the token
// expiring before it's collected) settles through the Handle
// (Wait/Poll), never as a panic or a background goroutine crash.
func EvalAsync(target string, form lisp.Sexp, opts ...Option) (*Handle, error) {
	cfg, err := applyAsyncOptions(opts...)
	if err != nil {
		return nil, err
	}

	args := []lisp.Sexp{lisp.Sym("sprite-async-start"), lisp.Quote(form)}
	if cfg.TTL != nil {
		args = append(args, lisp.Int(int64(*cfg.TTL/time.Second)))
	}

	raw, err := EvalBlocking(target, lisp.NewList(args...), opts...)
	if err != nil {
		return nil, ers.Wrap(err, "sprite-async: starting async eval")
	}

	token, err := parseAsyncStartReply(raw)
	if err != nil {
		return nil, ers.Wrap(err, "sprite-async: parsing sprite-async-start reply")
	}

	return startHandle(target, token, opts, cfg), nil
}

// Resume reattaches to a previously started async eval identified by
// token (e.g. one obtained from an earlier Handle.Token and persisted
// across a process restart), launching the same background polling
// goroutine EvalAsync would, without repeating the initial
// sprite-async-start call.
func Resume(target string, token string, opts ...Option) *Handle {
	// Option providers defined in this package never return an error;
	// a non-nil err here would only come from a caller-supplied Option,
	// which is not expected to fail either. Fall back to a zero Config
	// (default backoff, no TTL) rather than surfacing an error Resume
	// has no return value to carry.
	cfg, _ := applyAsyncOptions(opts...)
	return startHandle(target, token, opts, cfg)
}

// startHandle constructs a Handle for token and launches its
// background polling goroutine.
func startHandle(target string, token string, opts []Option, cfg Config) *Handle {
	h := &Handle{token: token, done: make(chan struct{})}

	pollFn := cfg.PollIntervalFunc
	if pollFn == nil {
		pollFn = newDefaultPollIntervalFunc()
	}

	go pollLoop(target, h, opts, pollFn)

	return h
}

// pollLoop repeatedly polls the daemon for token's status until it
// settles, updating h and closing h.done exactly once before
// returning.
func pollLoop(target string, h *Handle, opts []Option, pollFn func(elapsed time.Duration) time.Duration) {
	start := time.Now()
	first := true
	for {
		if !first {
			time.Sleep(pollFn(time.Since(start)))
		}
		first = false

		raw, err := EvalBlocking(target, lisp.NewList(lisp.Sym("sprite-async-poll"), lisp.Str(h.token)), opts...)
		if err != nil {
			h.settle(StatusRejected, "", ers.Wrap(err, "sprite-async: poll failed"))
			return
		}

		tag, rest, err := parseAsyncPollReply(raw)
		if err != nil {
			h.settle(StatusRejected, "", err)
			return
		}

		switch tag {
		case ":pending":
			continue
		case ":resolved":
			h.settle(StatusResolved, rest, nil)
			return
		case ":rejected":
			msg, uerr := unquoteLispString(rest)
			if uerr != nil {
				msg = rest
			}
			h.settle(StatusRejected, "", fmt.Errorf("sprite-async: rejected: %s", msg))
			return
		case ":unknown":
			h.settle(StatusRejected, "", fmt.Errorf("sprite-async: token %s unknown or expired", h.token))
			return
		default:
			h.settle(StatusRejected, "", fmt.Errorf("sprite-async: unrecognized poll reply tag %q", tag))
			return
		}
	}
}

// parseAsyncStartReply parses the raw reply to a (sprite-async-start
// ...) call: a prin1-quoted Lisp string, e.g. the text
// `"sprite-async-172-455-g123"` (quote characters included). Returns
// the bare, unescaped token.
func parseAsyncStartReply(raw string) (string, error) {
	return unquoteLispString(strings.TrimSpace(raw))
}

// parseAsyncPollReply parses the raw reply to a (sprite-async-poll
// ...) call: text like "(:pending)", "(:resolved 3)",
// "(:rejected \"boom\")", or "(:unknown)". Returns the tag
// (":pending"/":resolved"/":rejected"/":unknown") and the remaining
// text verbatim (empty when there is none) -- callers that need the
// :rejected message unescaped should pass rest to unquoteLispString.
func parseAsyncPollReply(raw string) (tag string, rest string, err error) {
	s := strings.TrimSpace(raw)
	if len(s) < 2 || s[0] != '(' || s[len(s)-1] != ')' {
		return "", "", fmt.Errorf("sprite-async: malformed poll reply %q", raw)
	}
	inner := s[1 : len(s)-1]

	idx := strings.IndexFunc(inner, unicode.IsSpace)
	if idx < 0 {
		return inner, "", nil
	}
	tag = inner[:idx]
	rest = strings.TrimLeftFunc(inner[idx:], unicode.IsSpace)
	return tag, rest, nil
}

// unquoteLispString strips exactly one leading and trailing `"` from
// s and unescapes `\"` -> `"` and `\\` -> `\` within, per this
// library's hand-rolled wire parsing (no Lisp reader; see
// ParseResponse).
func unquoteLispString(s string) (string, error) {
	if len(s) < 2 || s[0] != '"' || s[len(s)-1] != '"' {
		return "", fmt.Errorf("sprite-async: expected a quoted Lisp string, got %q", s)
	}
	inner := s[1 : len(s)-1]

	var b strings.Builder
	b.Grow(len(inner))
	for i := 0; i < len(inner); i++ {
		c := inner[i]
		if c == '\\' && i+1 < len(inner) && (inner[i+1] == '"' || inner[i+1] == '\\') {
			b.WriteByte(inner[i+1])
			i++
			continue
		}
		b.WriteByte(c)
	}
	return b.String(), nil
}
