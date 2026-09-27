// Package protocol implements the sprite-direct wire protocol: the
// character-quoting table used to encode/decode request and response
// payloads, response reassembly, and a blocking connect-send-receive
// client over Unix domain sockets and TCP. See fixtures/CONTRACT.md at
// the repo root for the authoritative specification.
package protocol

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"strings"
	"time"

	"github.com/tychoish/fun/ers"
	"github.com/tychoish/fun/opt"

	"github.com/tychoish/sprite/go/lisp"
)

// Encode quotes str for the wire protocol: & -> &&, - -> &-, space ->
// &_, newline -> &n. Encoding is single-pass (one special character at
// a time), never a sequence of global replaces, to avoid double
// encoding.
// Encode scans for the next special byte with strings.IndexAny rather
// than decoding str rune-by-rune: all four special characters (&, -,
// space, newline) are single-byte ASCII, and no byte of a multi-byte
// UTF-8 sequence can ever equal one of them, so operating on raw bytes
// and bulk-copying the untouched runs between special bytes is both
// correct for arbitrary UTF-8 input and avoids the per-rune decode/
// switch overhead of a range loop.
func Encode(str string) string {
	var b strings.Builder
	b.Grow(len(str))
	for {
		i := strings.IndexAny(str, "&- \n")
		if i < 0 {
			b.WriteString(str)
			break
		}
		b.WriteString(str[:i])
		switch str[i] {
		case '&':
			b.WriteString("&&")
		case '-':
			b.WriteString("&-")
		case ' ':
			b.WriteString("&_")
		case '\n':
			b.WriteString("&n")
		}
		str = str[i+1:]
	}
	return b.String()
}

// Decode reverses Encode: && -> &, &- -> -, &_ -> space, &n -> newline.
// Only '&' can begin an escape, so strings.IndexByte finds the next
// candidate directly instead of scanning every byte/rune by hand.
func Decode(str string) string {
	var b strings.Builder
	b.Grow(len(str))
	for {
		i := strings.IndexByte(str, '&')
		if i < 0 {
			b.WriteString(str)
			break
		}
		b.WriteString(str[:i])
		if i+1 >= len(str) {
			// Trailing lone '&' with no following byte: emit literally,
			// matching the original rune-loop's behavior.
			b.WriteByte('&')
			break
		}
		switch str[i+1] {
		case '&':
			b.WriteByte('&')
		case '-':
			b.WriteByte('-')
		case 'n':
			b.WriteByte('\n')
		default:
			b.WriteByte(' ')
		}
		str = str[i+2:]
	}
	return b.String()
}

// EvalError is returned when the server responds with an -error line.
// Message is the decoded error payload.
type EvalError struct {
	Message string
}

func (e *EvalError) Error() string { return fmt.Sprintf("sprite eval error: %s", e.Message) }

// ParseResponse reassembles a raw response buffer (the full byte stream
// read from a connection until EOF) per the sprite-direct algorithm:
//
//  1. Split the buffer on newlines.
//  2. `-print PAYLOAD` / `-print-nonl PAYLOAD` lines: decode PAYLOAD and
//     append to an accumulator, in line order.
//  3. `-error PAYLOAD`: decode PAYLOAD; the whole response is an error.
//  4. `-emacs-pid PID`: ignored, sent immediately on connect, never part
//     of the result.
//  5. No -print/-print-nonl/-error line at all (only the -emacs-pid
//     preamble, or nothing): the result is empty. ParseResponse reports
//     this by returning (nil, nil) -- a nil *string with a nil error --
//     distinct from a successful empty-string result, which cannot
//     otherwise occur (there is no case here that produces one), and
//     distinct from the error case, which is reported via *EvalError.
func ParseResponse(raw []byte) (*string, error) {
	lines := strings.Split(string(raw), "\n")

	var (
		acc   strings.Builder
		found bool
	)

	for _, line := range lines {
		if line == "" {
			continue
		}
		switch {
		case strings.HasPrefix(line, "-print-nonl "):
			found = true
			acc.WriteString(Decode(strings.TrimPrefix(line, "-print-nonl ")))
		case strings.HasPrefix(line, "-print "):
			found = true
			acc.WriteString(Decode(strings.TrimPrefix(line, "-print ")))
		case strings.HasPrefix(line, "-error "):
			msg := Decode(strings.TrimPrefix(line, "-error "))
			return nil, &EvalError{Message: msg}
		case strings.HasPrefix(line, "-emacs-pid "):
			// Preamble, sent on connect, never part of the result.
			continue
		default:
			// Unrecognized line: ignore, per a permissive reading of the
			// contract (only the three tagged forms above, plus the pid
			// preamble, are defined).
			continue
		}
	}

	if !found {
		return nil, nil
	}
	// Emacs's real server.el builds every reply with (pp v), not
	// prin1/(format "%S" v) -- pp always appends a trailing newline
	// (verified against a live `emacs --daemon`; see server-eval-and
	// -print in server.el). Strip exactly one, mirroring what a Lisp
	// `read' of the text would discard as insignificant trailing
	// whitespace, so callers get the same value sprite-direct.el's own
	// (read ...)-based parsing would produce.
	result := strings.TrimSuffix(acc.String(), "\n")
	return &result, nil
}

// Config holds the resolved options for EvalBlocking.
type Config struct {
	// Key is the TCP auth key. Ignored for Unix-socket targets. Required
	// for TCP targets (either embedded in the target string as
	// HOST:PORT:KEY, or supplied here).
	Key string

	// Timeout, if non-zero, bounds the dial and the full round trip.
	Timeout time.Duration

	// Dial, if set, overrides the default connection strategy: this is
	// the seam unit tests use to substitute a fake net.Conn without
	// touching the request/response logic (see fixtures/CONTRACT.md's
	// Testing section, and go/protocol/async_test.go's
	// fakeAsyncDaemon). Live-daemon integration tests (see
	// integration_test.go) leave it unset, dialing a real `emacs
	// --daemon` instead.
	Dial func(network, address string) (net.Conn, error)

	// TTL, if non-nil, is passed as the TTL-SECONDS argument to
	// sprite-async-start (see async.go). Left unset, no TTL argument is
	// sent at all -- the daemon applies its own default.
	TTL *time.Duration

	// PollIntervalFunc, if non-nil, is called by a Handle's background
	// poll loop (see async.go) before each poll after the first, given
	// the elapsed time since the loop started, to compute the delay
	// before the next poll. Left nil, the loop falls back to an
	// exponential backoff starting at 50ms, doubling each poll, capped
	// at 2s.
	PollIntervalFunc func(elapsed time.Duration) time.Duration
}

// Option configures a Config for EvalBlocking.
type Option = opt.Provider[*Config]

// WithKey sets the TCP auth key explicitly (used when the target string
// does not already embed one as HOST:PORT:KEY).
func WithKey(key string) Option {
	return func(c *Config) error { c.Key = key; return nil }
}

// WithTimeout bounds the dial and round trip.
func WithTimeout(d time.Duration) Option {
	return func(c *Config) error { c.Timeout = d; return nil }
}

// WithDialer overrides the connection strategy (dependency injection
// seam for tests).
func WithDialer(dial func(network, address string) (net.Conn, error)) Option {
	return func(c *Config) error { c.Dial = dial; return nil }
}

// target describes a parsed connection target.
type target struct {
	network string // "unix" or "tcp"
	address string
	key     string // TCP only
}

// parseTarget parses a target string into a connection target. Unix
// socket targets are any string that isn't recognized as HOST:PORT or
// HOST:PORT:KEY; TCP targets are HOST:PORT or HOST:PORT:KEY, where the
// port component must be all-digits.
func parseTarget(raw string, key string) (target, error) {
	parts := strings.SplitN(raw, ":", 3)
	if len(parts) >= 2 && isAllDigits(parts[1]) {
		host := parts[0]
		port := parts[1]
		tcpKey := key
		if len(parts) == 3 && parts[2] != "" {
			tcpKey = parts[2]
		}
		if tcpKey == "" {
			return target{}, ers.New("TCP target requires a key: pass HOST:PORT:KEY or use WithKey")
		}
		return target{network: "tcp", address: host + ":" + port, key: tcpKey}, nil
	}
	return target{network: "unix", address: raw}, nil
}

func isAllDigits(s string) bool {
	if s == "" {
		return false
	}
	for _, r := range s {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// defaultDial is the default connection-opening seam: a fresh
// net.Dial per call, matching the contract's "one eval, one
// connection" requirement.
func defaultDial(network, address string) (net.Conn, error) {
	return net.Dial(network, address)
}

// EvalBlocking evaluates form against a running Emacs daemon reachable
// at target, and returns the raw decoded result string.
//
// target is either a Unix-domain socket path, or a TCP target string
// "HOST:PORT" / "HOST:PORT:KEY" (see WithKey to supply the key
// separately). A TCP target with no key is an error, returned before
// any connection is attempted.
//
// A fresh connection is opened for this single call and closed before
// returning, per the contract: never pool or reuse connections.
//
// The returned string is empty with a nil error when the server
// produced no -print/-print-nonl/-error line at all (only the
// -emacs-pid preamble) -- Go has no natural analog of Python's
// Optional[str] here without complicating the common-case call site, so
// this is the one place where an "empty" result and a genuinely
// empty-string result are indistinguishable at this layer; callers who
// need to distinguish them can use ParseResponse directly.
//
// EvalAsync (see async.go) is available for callers who want a
// non-blocking handle instead of a synchronous call; EvalBlocking
// itself is unchanged.
func EvalBlocking(rawTarget string, form lisp.Sexp, opts ...Option) (string, error) {
	var cfg Config
	if err := opt.Join(opts...).Apply(&cfg); err != nil {
		return "", ers.Wrap(err, "applying options")
	}

	tgt, err := parseTarget(rawTarget, cfg.Key)
	if err != nil {
		return "", err
	}

	printed := lisp.Print(form)
	encoded := Encode(printed)

	var requestLine string
	if tgt.network == "tcp" {
		requestLine = fmt.Sprintf("-auth %s -eval %s \n", tgt.key, encoded)
	} else {
		requestLine = fmt.Sprintf("-eval %s \n", encoded)
	}

	dial := cfg.Dial
	if dial == nil {
		dial = defaultDial
	}

	conn, err := dialWithTimeout(dial, tgt.network, tgt.address, cfg.Timeout)
	if err != nil {
		return "", ers.Wrapf(err, "connecting to %s target %s", tgt.network, tgt.address)
	}
	defer conn.Close()

	if cfg.Timeout > 0 {
		_ = conn.SetDeadline(time.Now().Add(cfg.Timeout))
	}

	if _, err := io.WriteString(conn, requestLine); err != nil {
		return "", ers.Wrap(err, "sending request")
	}
	// Deliberately do NOT half-close the write side here (no
	// CloseWrite): verified against a live emacs --daemon that doing
	// so races with the server sending a genuine -error reply for an
	// evaluation error -- the server can treat the client's EOF as an
	// abandoned connection and skip flushing the reply entirely,
	// silently turning a real error into an empty result.

	raw, err := readResponse(conn)
	if err != nil {
		return "", ers.Wrap(err, "reading response")
	}

	value, err := ParseResponse(bytes.TrimRight(raw, "\x00"))
	if err != nil {
		return "", err
	}
	if value == nil {
		return "", nil
	}
	return *value, nil
}

// readResponse reads the response a byte at a time... no: it reads in
// chunks, stopping either at EOF (the success-reply case: the server
// closes the connection once a -print/-print-nonl reply is fully
// sent) or as soon as a complete `-error PAYLOAD` line has been seen.
//
// The latter is not an optimization, it is a correctness requirement:
// verified against a live emacs --daemon that after sending an -error
// reply, the server does NOT promptly close the connection the way it
// does after a successful reply -- an internal cleanup timer
// eventually closes it, but only after a multi-second, unspecified
// delay. Waiting for EOF unconditionally would mean every real eval
// error costs several seconds of latency (or a timeout, discarding a
// reply that had, in fact, already fully arrived). -print/-print-nonl
// still requires waiting for EOF, since a large value's continuation
// lines carry no marker for which one is last (see CONTRACT.md).
func readResponse(conn net.Conn) ([]byte, error) {
	var buf bytes.Buffer
	chunk := make([]byte, 4096)
	for {
		n, rerr := conn.Read(chunk)
		if n > 0 {
			buf.Write(chunk[:n])
			if hasCompleteErrorLine(buf.Bytes()) {
				return buf.Bytes(), nil
			}
		}
		if rerr != nil {
			if rerr == io.EOF {
				return buf.Bytes(), nil
			}
			return buf.Bytes(), rerr
		}
	}
}

// hasCompleteErrorLine reports whether buf contains a full, newline
// -terminated "-error ..." line. Only bytes up to the last '\n' are
// considered "complete" -- a trailing, not-yet-newline-terminated
// fragment is still in flight and not checked, since it could still
// turn out to be something other than an -error line once fully
// received.
func hasCompleteErrorLine(buf []byte) bool {
	last := bytes.LastIndexByte(buf, '\n')
	if last < 0 {
		return false
	}
	for _, line := range bytes.Split(buf[:last], []byte("\n")) {
		if bytes.HasPrefix(line, []byte("-error ")) {
			return true
		}
	}
	return false
}

func dialWithTimeout(dial func(network, address string) (net.Conn, error), network, address string, timeout time.Duration) (net.Conn, error) {
	if timeout <= 0 {
		return dial(network, address)
	}
	type result struct {
		conn net.Conn
		err  error
	}
	ch := make(chan result, 1)
	go func() {
		c, e := dial(network, address)
		ch <- result{c, e}
	}()
	select {
	case r := <-ch:
		return r.conn, r.err
	case <-time.After(timeout):
		// The dial goroutine may still be in flight and later succeed;
		// close whatever connection it eventually produces so it isn't
		// leaked (nobody else will ever read from ch again).
		go func() {
			if r := <-ch; r.conn != nil {
				_ = r.conn.Close()
			}
		}()
		return nil, ers.New("dial timed out")
	}
}
