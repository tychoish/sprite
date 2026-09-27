package protocol_test

// Live-daemon integration test: exercises EvalBlocking against a real
// `emacs --daemon`, not a fake dialer. Gated on SPRITE_TEST_SOCKET
// (the resolved Unix-socket path of an already-running daemon) so it
// is skipped by default in any environment without one -- CI sets
// this env var after spawning a dedicated test daemon; see
// .github/workflows/test.yml.

import (
	"net"
	"os"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

func TestEvalBlockingAgainstLiveDaemon(t *testing.T) {
	sock := os.Getenv("SPRITE_TEST_SOCKET")
	if sock == "" {
		t.Skip("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test")
	}

	got, err := protocol.EvalBlocking(sock, lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "3" {
		t.Errorf("got %q, want %q", got, "3")
	}

	// A string result and a list result, to cover more than one Lisp
	// reader syntax shape than the previous case, and to confirm the
	// real server's (pp v)-appended trailing newline is stripped for
	// every result shape, not just bare integers.
	got, err = protocol.EvalBlocking(sock, lisp.NewList(lisp.Sym("concat"), lisp.Str("hello"), lisp.Str(" world")))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := `"hello world"`; got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	got, err = protocol.EvalBlocking(sock, lisp.NewList(lisp.Sym("list"), lisp.Int(1), lisp.Int(2), lisp.Int(3)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := "(1 2 3)"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}

	// A genuine evaluation error (an unbound variable): verified
	// against a live emacs --daemon that the server DOES send a real
	// -error line for this (server-eval-and-print's un-caught eval
	// error propagates out, but server.el still reports it via
	// -error), so long as the client doesn't half-close its write
	// side after sending -- see readResponse's doc comment and
	// CONTRACT.md for why this must not wait for EOF to detect it.
	_, err = protocol.EvalBlocking(sock, lisp.Sym("this-variable-does-not-exist-anywhere"))
	if err == nil {
		t.Fatal("expected an error evaluating an unbound variable")
	}
	var evalErr *protocol.EvalError
	if !isEvalError(err, &evalErr) {
		t.Fatalf("expected *protocol.EvalError, got %T: %v", err, err)
	}
}

func isEvalError(err error, target **protocol.EvalError) bool {
	e, ok := err.(*protocol.EvalError)
	if !ok {
		return false
	}
	*target = e
	return true
}

// liveDaemonSocket returns the SPRITE_TEST_SOCKET path, or skips the
// calling test if it isn't set. See CI's .github/workflows/test.yml,
// which loads sprite-async.el into the test daemon before running
// -run LiveDaemon tests.
func liveDaemonSocket(t *testing.T) string {
	t.Helper()
	sock := os.Getenv("SPRITE_TEST_SOCKET")
	if sock == "" {
		t.Skip("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test")
	}
	return sock
}

func TestEvalAsyncHappyPathLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	h, err := protocol.EvalAsync(sock, lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	got, err := h.Wait()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "3" {
		t.Errorf("got %q, want %q", got, "3")
	}
}

func TestEvalAsyncErrorPathLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	h, err := protocol.EvalAsync(sock, lisp.Sym("this-variable-does-not-exist-anywhere"))
	if err != nil {
		t.Fatalf("unexpected error starting async eval: %v", err)
	}

	_, err = h.Wait()
	if err == nil {
		t.Fatal("expected an error evaluating an unbound variable")
	}
}

// dialWithRetry wraps net.Dial with a handful of short retries on a
// transient connect error. A live Emacs server's Unix-domain socket has
// a small accept backlog; a burst of near-simultaneous connections (as
// in TestEvalAsyncConcurrencyLiveDaemon) can trip EAGAIN on connect(2)
// when the backlog is briefly full -- a real, if simple, retry-on-
// transient-failure situation any client of this daemon should expect
// under concurrent load, not a defect in EvalAsync/EvalBlocking
// themselves (which always open one fresh connection per call, per the
// wire contract, and have no seam of their own for a connect retry).
func dialWithRetry(network, address string) (net.Conn, error) {
	const attempts = 20
	var lastErr error
	for i := 0; i < attempts; i++ {
		conn, err := net.Dial(network, address)
		if err == nil {
			return conn, nil
		}
		lastErr = err
		time.Sleep(10 * time.Millisecond)
	}
	return nil, lastErr
}

func TestEvalAsyncConcurrencyLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	const n = 10
	var wg sync.WaitGroup
	errs := make([]error, n)
	got := make([]string, n)
	want := make([]string, n)

	for i := 0; i < n; i++ {
		i := i
		wg.Add(1)
		go func() {
			defer wg.Done()
			want[i] = strconv.Itoa(1 + i)

			h, err := protocol.EvalAsync(
				sock,
				lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(int64(i))),
				protocol.WithDialer(dialWithRetry),
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

func TestResumeAfterDisconnectLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	// A form whose evaluation takes a moment to settle on the daemon
	// side, so the token is still pending when we abandon the original
	// Handle below -- sprite-async-start evaluates arbitrary Elisp, so
	// the sleep happens inside the form itself.
	form := lisp.NewList(lisp.Sym("progn"),
		lisp.NewList(lisp.Sym("sleep-for"), lisp.Int(1)),
		lisp.Int(99),
	)

	h, err := protocol.EvalAsync(sock, form)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	token := h.Token()
	if token == "" {
		t.Fatal("expected a non-empty token")
	}
	// Deliberately do not call Wait/Poll on h: this simulates the
	// original connection/process going away before the eval settles.

	resumed := protocol.Resume(sock, token)
	got, err := resumed.Wait()
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "99" {
		t.Errorf("got %q, want %q", got, "99")
	}
}
