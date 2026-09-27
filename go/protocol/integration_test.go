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
	"strings"
	"sync"
	"syscall"
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

// isEvalError, liveDaemonSocket, requireEmacsBinary, onceCleanup,
// waitForPath, spawnDisposableUnixDaemon, tcpDaemon, and
// spawnDisposableTCPDaemon are shared with timeout_test.go and defined
// in helpers_test.go.

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

// --- Extended error-handling / transmission-fidelity case matrix ---
//
// The three cases below (wrong-type-argument, user-error, large value)
// exercise the *existing* SPRITE_TEST_SOCKET daemon, same as the tests
// above: none of them are destructive to the daemon. TCP and
// kill-mid-response cases need their own disposable daemons (see
// requireEmacsBinary/spawnDisposableUnixDaemon/spawnDisposableTCPDaemon
// below) and are gated on the emacs binary being on PATH, independent of
// whether SPRITE_TEST_SOCKET is set.

func TestWrongTypeArgumentEvalLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	// (+ 1 "a") is a genuine wrong-type-argument error, distinct in
	// message shape from the unbound-variable case above -- this
	// confirms the error path decodes whatever message text Emacs
	// actually sends, rather than being hardcoded to one string.
	form := lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Str("a"))
	_, err := protocol.EvalBlocking(sock, form)
	if err == nil {
		t.Fatal("expected a wrong-type-argument eval error")
	}
	var evalErr *protocol.EvalError
	if !isEvalError(err, &evalErr) {
		t.Fatalf("expected *protocol.EvalError, got %T: %v", err, err)
	}
	if evalErr.Message == "" {
		t.Fatal("expected a non-empty decoded error message")
	}
}

func TestUserErrorEvalLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	// (user-error "boom") is a genuine user-error, which must surface
	// via the same -error/EvalError path as any other eval error, not
	// be silently swallowed or routed differently.
	form := lisp.NewList(lisp.Sym("user-error"), lisp.Str("boom"))
	_, err := protocol.EvalBlocking(sock, form)
	if err == nil {
		t.Fatal("expected a user-error eval error")
	}
	var evalErr *protocol.EvalError
	if !isEvalError(err, &evalErr) {
		t.Fatalf("expected *protocol.EvalError, got %T: %v", err, err)
	}
	if evalErr.Message == "" || !strings.Contains(evalErr.Message, "boom") {
		t.Errorf("got message %q, want it to contain %q", evalErr.Message, "boom")
	}
}

func TestLargeValueEvalLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	// A 5000-byte string is well beyond Emacs's server-msg-size
	// (1024), forcing the server to split the -print-nonl reply across
	// multiple continuation lines. 120 is the char code for ?x.
	form := lisp.NewList(lisp.Sym("make-string"), lisp.Int(5000), lisp.Int(120))
	got, err := protocol.EvalBlocking(sock, form)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// pp/prin1-quotes the string, so assert on length and content
	// rather than an exact literal (see task notes on quoting).
	xCount := strings.Count(got, "x")
	if xCount != 5000 {
		t.Errorf("got %d 'x' characters in result, want 5000 (result length %d)", xCount, len(got))
	}
	if !strings.HasPrefix(got, `"x`) || !strings.HasSuffix(got, `x"`) {
		t.Errorf("got %q (truncated), want a quoted string of 5000 x's", truncateForLog(got))
	}
}

func truncateForLog(s string) string {
	if len(s) > 80 {
		return s[:80] + "...(truncated)"
	}
	return s
}

func TestTCPTargetNoKeyRejectedBeforeDialingLiveDaemon(t *testing.T) {
	daemon, cleanup := spawnDisposableTCPDaemon(t, uniqueDaemonName("sprite-tcp-nokey"))
	defer cleanup()

	// Deliberately omit the key: a TCP target the daemon requires a
	// real auth key for must be rejected client-side before any dial
	// is attempted -- confirmed here against a live, key-configured TCP
	// daemon rather than only a fake dialer.
	target := daemon.host + ":" + daemon.port
	_, err := protocol.EvalBlocking(target, lisp.Sym("t"))
	if err == nil {
		t.Fatal("expected an error for a TCP target with no key")
	}
	if !strings.Contains(err.Error(), "key") {
		t.Errorf("got error %v, want it to mention the missing key", err)
	}
}

func TestTCPTargetWithKeyLiveDaemon(t *testing.T) {
	daemon, cleanup := spawnDisposableTCPDaemon(t, uniqueDaemonName("sprite-tcp-key"))
	defer cleanup()

	target := daemon.host + ":" + daemon.port
	got, err := protocol.EvalBlocking(target, lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2)), protocol.WithKey(daemon.key))
	if err != nil {
		t.Fatalf("unexpected error evaluating over TCP: %v", err)
	}
	if got != "3" {
		t.Errorf("got %q, want %q", got, "3")
	}
}

// stopThenKillAfterWriteConn wraps a real net.Conn. Before the first
// Write, it SIGSTOPs the daemon process (pid); after that Write
// returns, it SIGKILLs it (via killFn, called exactly once).
//
// SIGSTOP-ing before the write, rather than merely killing immediately
// after it, removes what would otherwise be a timing race: a plain
// kill immediately after Write can still lose (verified empirically) if
// Emacs's own event loop happens to get scheduled first and read the
// bytes before the kill syscall runs, in which case the kernel sees an
// empty receive buffer at process-death time and delivers an ordinary
// clean EOF -- indistinguishable from the server successfully
// finishing and closing the connection (see ParseResponse/readResponse:
// no -print/-error line found plus a clean EOF is treated as a
// legitimate empty result, not an error). A process that is SIGSTOPed
// *cannot* read no matter how much wall-clock time elapses, so the
// request bytes are guaranteed to still be sitting unread in the
// kernel's receive buffer once SIGKILL is delivered -- and an unread
// receive buffer at close time is what causes the kernel to send RST
// instead of FIN, which is what actually produces a detectable
// connection-reset error client-side. SIGKILL still terminates a
// stopped process immediately (the kernel treats SIGKILL specially,
// waking a stopped process just to kill it).
type stopThenKillAfterWriteConn struct {
	net.Conn
	pid    int
	once   sync.Once
	killFn func()
}

func (c *stopThenKillAfterWriteConn) Write(p []byte) (int, error) {
	_ = syscall.Kill(c.pid, syscall.SIGSTOP)
	n, err := c.Conn.Write(p)
	c.once.Do(c.killFn)
	return n, err
}

func TestDaemonKilledMidResponseLiveDaemon(t *testing.T) {
	sockPath, cmd, cleanup := spawnDisposableUnixDaemon(t, uniqueDaemonName("sprite-kill"))
	defer cleanup()

	dial := func(network, address string) (net.Conn, error) {
		conn, err := net.Dial(network, address)
		if err != nil {
			return nil, err
		}
		return &stopThenKillAfterWriteConn{Conn: conn, pid: cmd.Process.Pid, killFn: cleanup}, nil
	}

	type result struct {
		val string
		err error
	}
	resultCh := make(chan result, 1)
	go func() {
		form := lisp.NewList(lisp.Sym("progn"),
			lisp.NewList(lisp.Sym("sleep-for"), lisp.Int(2)),
			lisp.Int(1),
		)
		val, err := protocol.EvalBlocking(sockPath, form, protocol.WithDialer(dial), protocol.WithTimeout(10*time.Second))
		resultCh <- result{val, err}
	}()

	select {
	case r := <-resultCh:
		if r.err == nil {
			t.Fatalf("expected a connection/IO error after killing the daemon mid-response, got value %q", r.val)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for EvalBlocking to return after the daemon was killed (hang)")
	}
}
