package protocol_test

import (
	"errors"
	"fmt"
	"io"
	"net"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

// asyncState describes how a fakeAsyncDaemon should reply to polls for a
// single token: pendingLeft controls how many ":pending" replies are
// served before the final reply, and finalTag/finalBody describe that
// final reply (finalBody is the already-Lisp-printed payload, e.g. "42"
// or `"boom"` including the quotes; unused for ":unknown").
type asyncState struct {
	pendingLeft int
	finalTag    string
	finalBody   string
}

// fakeAsyncDaemon is an in-memory double for the daemon-side
// sprite-async-start/sprite-async-poll registry (see sprite-async.el at
// the repo root). EvalAsync/Resume open a fresh connection per call (one
// eval, one connection, per the wire contract), so a single canned
// fakeConn response (protocol_test.go's pattern) can't serve the
// sequence of start/poll calls a Handle's background poll loop makes.
// Instead, this fake decides its reply per connection by decoding the
// outgoing "-eval ..." request text and matching on whether it names
// sprite-async-start or sprite-async-poll.
type fakeAsyncDaemon struct {
	mu      sync.Mutex
	seq     int
	tokens  map[string]*asyncState
	onStart func(decodedForm string) asyncState
}

func newFakeAsyncDaemon(onStart func(decodedForm string) asyncState) *fakeAsyncDaemon {
	return &fakeAsyncDaemon{tokens: map[string]*asyncState{}, onStart: onStart}
}

// dialer returns a WithDialer-compatible function that hands out a fresh
// fakeAsyncConn (backed by this daemon) per connection.
func (d *fakeAsyncDaemon) dialer() func(network, address string) (net.Conn, error) {
	return func(network, address string) (net.Conn, error) {
		return &fakeAsyncConn{daemon: d}, nil
	}
}

var pollTokenRE = regexp.MustCompile(`sprite-async-poll\s+"([^"]*)"`)

// respond decides the wire-format reply for one request, given the raw
// bytes written for it (the full "-eval ENCODED \n" request line).
func (d *fakeAsyncDaemon) respond(written []byte) []byte {
	decoded := decodeEvalRequest(written)

	switch {
	case strings.Contains(decoded, "sprite-async-start"):
		d.mu.Lock()
		d.seq++
		token := fmt.Sprintf("tok-%d", d.seq)
		st := d.onStart(decoded)
		d.tokens[token] = &st
		d.mu.Unlock()
		return printReply(fmt.Sprintf("%q", token))

	case strings.Contains(decoded, "sprite-async-poll"):
		m := pollTokenRE.FindStringSubmatch(decoded)
		if m == nil {
			return printReply("(:unknown)")
		}
		token := m[1]

		d.mu.Lock()
		st, ok := d.tokens[token]
		var body string
		switch {
		case !ok:
			body = "(:unknown)"
		case st.pendingLeft > 0:
			st.pendingLeft--
			body = "(:pending)"
		default:
			body = pollBody(*st)
		}
		d.mu.Unlock()
		return printReply(body)

	default:
		return []byte("-error " + protocol.Encode("fakeAsyncDaemon: unrecognized request") + "\n")
	}
}

func pollBody(st asyncState) string {
	switch st.finalTag {
	case ":resolved":
		return fmt.Sprintf("(:resolved %s)", st.finalBody)
	case ":rejected":
		return fmt.Sprintf("(:rejected %s)", st.finalBody)
	default:
		return "(:unknown)"
	}
}

func printReply(body string) []byte {
	return []byte("-print " + protocol.Encode(body) + "\n")
}

// decodeEvalRequest strips the "-eval " prefix and " \n" suffix from a
// written request line and decodes the wire-quoted payload back to the
// original printed Lisp text (e.g. `(sprite-async-poll "tok-1")`).
func decodeEvalRequest(written []byte) string {
	s := string(written)
	s = strings.TrimPrefix(s, "-eval ")
	s = strings.TrimSuffix(s, " \n")
	return protocol.Decode(s)
}

var intRE = regexp.MustCompile(`-?\d+`)

// extractLastInt returns the last integer literal appearing in s, or 0
// if there isn't one. Used by the concurrency test to derive a
// per-token expected result directly from the form embedded in a
// sprite-async-start request, without needing a side channel.
func extractLastInt(s string) int {
	matches := intRE.FindAllString(s, -1)
	if len(matches) == 0 {
		return 0
	}
	n, _ := strconv.Atoi(matches[len(matches)-1])
	return n
}

// fakeAsyncConn is a minimal net.Conn double, mirroring protocol_test.go's
// fakeConn, except its Read response is computed lazily -- once the full
// request has been Written -- by asking the daemon to decide a reply
// based on that request's decoded text.
type fakeAsyncConn struct {
	net.Conn
	daemon   *fakeAsyncDaemon
	written  []byte
	response []byte
	computed bool
	pos      int
}

func (f *fakeAsyncConn) Write(p []byte) (int, error) {
	f.written = append(f.written, p...)
	return len(p), nil
}

func (f *fakeAsyncConn) Read(p []byte) (int, error) {
	if !f.computed {
		f.response = f.daemon.respond(f.written)
		f.computed = true
	}
	if f.pos >= len(f.response) {
		return 0, io.EOF
	}
	n := copy(p, f.response[f.pos:])
	f.pos += n
	return n, nil
}

func (f *fakeAsyncConn) Close() error                     { return nil }
func (f *fakeAsyncConn) SetDeadline(time.Time) error      { return nil }
func (f *fakeAsyncConn) SetReadDeadline(time.Time) error  { return nil }
func (f *fakeAsyncConn) SetWriteDeadline(time.Time) error { return nil }

func TestEvalAsyncHappyPath(t *testing.T) {
	d := newFakeAsyncDaemon(func(string) asyncState {
		return asyncState{pendingLeft: 2, finalTag: ":resolved", finalBody: "42"}
	})

	h, err := protocol.EvalAsync(
		"/tmp/fake-async.sock",
		lisp.NewList(lisp.Sym("+"), lisp.Int(40), lisp.Int(2)),
		protocol.WithDialer(d.dialer()),
		protocol.WithPollInterval(time.Millisecond),
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if h.Token() == "" {
		t.Error("expected a non-empty token before settlement")
	}

	got, err := h.Wait()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "42" {
		t.Errorf("got %q, want %q", got, "42")
	}
}

func TestEvalAsyncRejected(t *testing.T) {
	d := newFakeAsyncDaemon(func(string) asyncState {
		return asyncState{finalTag: ":rejected", finalBody: `"boom"`}
	})

	h, err := protocol.EvalAsync(
		"/tmp/fake-async.sock",
		lisp.Sym("t"),
		protocol.WithDialer(d.dialer()),
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	_, err = h.Wait()
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "boom") {
		t.Errorf("error = %q, want it to mention %q", err, "boom")
	}
}

func TestEvalAsyncUnknownToken(t *testing.T) {
	d := newFakeAsyncDaemon(func(string) asyncState {
		return asyncState{finalTag: ":unknown"}
	})

	h, err := protocol.EvalAsync(
		"/tmp/fake-async.sock",
		lisp.Sym("t"),
		protocol.WithDialer(d.dialer()),
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	_, err = h.Wait()
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), h.Token()) {
		t.Errorf("error = %q, want it to mention token %q", err, h.Token())
	}
}

func TestEvalAsyncDialErrorReturnsDirectly(t *testing.T) {
	dialer := func(network, address string) (net.Conn, error) {
		return nil, errors.New("boom-dial")
	}

	h, err := protocol.EvalAsync("/tmp/fake-async.sock", lisp.Sym("t"), protocol.WithDialer(dialer))
	if err == nil {
		t.Fatal("expected an error")
	}
	if h != nil {
		t.Fatal("expected a nil Handle when sprite-async-start itself fails")
	}
}

func TestEvalAsyncConcurrency(t *testing.T) {
	d := newFakeAsyncDaemon(func(decodedForm string) asyncState {
		want := extractLastInt(decodedForm)
		return asyncState{finalTag: ":resolved", finalBody: strconv.Itoa(want)}
	})

	const n = 20
	var wg sync.WaitGroup
	errs := make([]error, n)
	got := make([]string, n)
	want := make([]string, n)

	for i := 0; i < n; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			v := i*1000 + 7
			want[i] = strconv.Itoa(v)

			h, err := protocol.EvalAsync(
				"/tmp/fake-async.sock",
				lisp.NewList(lisp.Sym("identity"), lisp.Int(int64(v))),
				protocol.WithDialer(d.dialer()),
			)
			if err != nil {
				errs[i] = err
				return
			}
			val, err := h.Wait()
			if err != nil {
				errs[i] = err
				return
			}
			got[i] = val
		}()
	}
	wg.Wait()

	for i := 0; i < n; i++ {
		if errs[i] != nil {
			t.Errorf("goroutine %d: unexpected error: %v", i, errs[i])
			continue
		}
		if got[i] != want[i] {
			t.Errorf("goroutine %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

func TestEvalAsyncNoGoroutineLeak(t *testing.T) {
	d := newFakeAsyncDaemon(func(string) asyncState {
		return asyncState{finalTag: ":resolved", finalBody: "1"}
	})

	runtime.GC()
	base := runtime.NumGoroutine()

	const n = 50
	for i := 0; i < n; i++ {
		h, err := protocol.EvalAsync("/tmp/fake-async.sock", lisp.Sym("t"), protocol.WithDialer(d.dialer()))
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		// Deliberately do not call Wait/Poll: the point of this test is
		// that the background poll goroutine exits on its own once
		// settled, regardless of whether anything ever reads the Handle
		// again.
		_ = h
	}

	const tolerance = 10
	deadline := time.Now().Add(2 * time.Second)
	last := runtime.NumGoroutine()
	for time.Now().Before(deadline) {
		runtime.GC()
		time.Sleep(20 * time.Millisecond)
		last = runtime.NumGoroutine()
		if last <= base+tolerance {
			break
		}
	}

	if last > base+tolerance {
		t.Errorf("goroutines did not settle back to baseline: base=%d, got=%d (tolerance=%d)", base, last, tolerance)
	}
}
