package protocol_test

// Timeout / hung-daemon test suite: exercises protocol.WithTimeout
// against daemons that either never reply (a genuine infinite Elisp
// loop) or never accept a connection at all, plus a fast daemon with
// no timeout configured at all. Every disposable daemon this file
// spawns is uniquely named (via integration_test.go's
// uniqueDaemonName) and unconditionally killed via its cleanup func
// (deferred, regardless of pass/fail), independent of
// SPRITE_TEST_SOCKET's shared daemon (see integration_test.go's
// liveDaemonSocket and CONTRACT.md).
//
// IMPORTANT finding, recorded here because it shapes every sub-case
// below: a single hung eval (a genuine (while t ...) busy loop) DOES
// block every other connection to the same daemon, not just the
// connection that issued it. Emacs's Lisp evaluator is single
// threaded; server.el's accept loop cannot service (or even accept())
// any other connection while one Lisp form is running forever. This
// was verified directly against a live `emacs --daemon` before writing
// these tests: a second, independent connection issuing a trivial (+ 1
// 2) sat unserviced (no reply, connect() itself succeeds into the
// kernel backlog but the daemon never accepts/replies) for as long as
// the hung eval kept running. So, per this suite's own instructions,
// the hung-eval daemon in case 1 is spawned fresh, used for nothing
// else, and killed immediately after -- it is never reused for the
// "fast daemon, no timeout" case (that case either uses
// SPRITE_TEST_SOCKET's shared daemon, gated the same way existing
// tests gate on it, or is skipped).
//
// A second finding: cleanup for a daemon wedged by a hung eval cannot
// go through emacsclient (or any -eval RPC) -- that RPC would itself
// queue behind the very form that's hanging, hanging the *test's own
// teardown*. Cleanup here always kills the daemon's OS process
// directly (SIGKILL).
//
// A third finding, important enough to repeat here since it silently
// breaks the "kill $PID" cleanup pattern CONTRACT.md itself
// recommends: plain `emacs --daemon=NAME` double-forks and detaches --
// the process os/exec (or Python's subprocess.Popen, etc.) actually
// launches exits almost immediately once the real, detached daemon is
// up, so tracking *that* PID and killing it later kills nothing (the
// tracked PID is long gone; the actual daemon process has a different,
// untracked PID). `emacs --fg-daemon=NAME` avoids the double-fork --
// the launched process *is* the daemon process, so Kill() on it
// actually works. This file reuses integration_test.go's
// spawnDisposableUnixDaemon/uniqueDaemonName helpers (see
// helpers_test.go), which already do this correctly.

import (
	"net"
	"runtime"
	"testing"
	"time"

	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

// Case 1 + case 4: a genuinely hung eval (an infinite Elisp loop, not
// merely a slow one) against a configured timeout must fire the
// timeout within a generous (~2x) tolerance of the configured
// duration, must not return a success value, and must not leak a
// goroutine (regression coverage for dialWithTimeout's
// goroutine-cleanup path in protocol.go, though that path isn't
// actually exercised on the *read* timeout side here -- see the
// separate slow-dial test below for the dial-timeout goroutine path
// specifically).
func TestHungEvalTimeoutFiresLiveDaemon(t *testing.T) {
	sock, _, cleanup := spawnDisposableUnixDaemon(t, uniqueDaemonName("sprite-timeout"))
	defer cleanup()

	// Allow any goroutines from prior subtests/GC bookkeeping to settle
	// before taking the "before" count.
	runtime.GC()
	time.Sleep(50 * time.Millisecond)
	before := runtime.NumGoroutine()

	form := lisp.NewList(lisp.Sym("while"), lisp.Sym("t"),
		lisp.NewList(lisp.Sym("sleep-for"), lisp.Int(1)))

	const configured = 2 * time.Second
	start := time.Now()
	got, err := protocol.EvalBlocking(sock, form, protocol.WithTimeout(configured))
	elapsed := time.Since(start)

	if err == nil {
		t.Fatalf("expected a timeout error evaluating a genuinely hung form, got success value %q", got)
	}
	if elapsed > 2*configured {
		t.Errorf("timeout took %v, want at most ~2x the configured %v", elapsed, configured)
	}

	runtime.GC()
	time.Sleep(200 * time.Millisecond)
	after := runtime.NumGoroutine()
	// Allow a small amount of scheduler/GC noise rather than requiring
	// an exact match.
	if after > before+2 {
		t.Errorf("goroutine count grew from %d to %d after a timed-out eval against a hung daemon; possible leak", before, after)
	}
}

// Case 2: with no timeout configured at all, a normal fast-replying
// daemon (the shared SPRITE_TEST_SOCKET one, gated exactly like the
// existing integration tests) must still succeed promptly -- omitting
// WithTimeout must not impose some implicit ceiling of its own.
func TestNoTimeoutConfiguredFastDaemonUnaffectedLiveDaemon(t *testing.T) {
	sock := liveDaemonSocket(t)

	start := time.Now()
	got, err := protocol.EvalBlocking(sock, lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2)))
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("unexpected error with no timeout configured: %v", err)
	}
	if got != "3" {
		t.Errorf("got %q, want %q", got, "3")
	}
	if elapsed > 2*time.Second {
		t.Errorf("expected a prompt reply with no timeout configured, took %v", elapsed)
	}
}

// Case 3: a slow DIAL specifically, distinct from a slow read. Go is
// the one client library in this repo with a real dial-injection seam
// (protocol.WithDialer), so unlike the Python/JS/Rust suites (which
// fall back to "connect to a nonexistent path fails promptly" because
// they have no such seam), Go can construct a genuinely slow dial
// directly: a custom Dial function that sleeps past the configured
// timeout before ever attempting the real connection. This exercises
// dialWithTimeout's own timeout-races-the-dial-goroutine logic
// directly, and distinguishes a dial timeout (fires at ~the configured
// duration, not the full artificial dial delay) from a read timeout
// (case 1, above).
func TestSlowDialTimesOutDistinctlyFromReadTimeoutLiveDaemon(t *testing.T) {
	const dialDelay = 5 * time.Second
	const configured = 500 * time.Millisecond

	slowDial := func(network, address string) (net.Conn, error) {
		time.Sleep(dialDelay)
		return net.Dial(network, address)
	}

	start := time.Now()
	_, err := protocol.EvalBlocking(
		"/does-not-matter-dialer-is-overridden.sock",
		lisp.Sym("t"),
		protocol.WithTimeout(configured),
		protocol.WithDialer(slowDial),
	)
	elapsed := time.Since(start)

	if err == nil {
		t.Fatal("expected a dial-timeout error, got success")
	}
	if elapsed >= dialDelay {
		t.Errorf("dial timeout took %v, waited out the full %v artificial dial delay instead of firing at ~%v", elapsed, dialDelay, configured)
	}
	if elapsed > 2*configured {
		t.Errorf("dial timeout took %v, want at most ~2x the configured %v", elapsed, configured)
	}
}

// Case 3 fallback, run unconditionally (no live daemon or emacs
// binary required): a connection attempt to a socket path that simply
// doesn't exist must fail promptly, not hang, even without the
// WithDialer seam used above. This mirrors what the other three
// language suites in this round rely on as their *only* slow-dial
// coverage, since they have no dial-injection seam of their own.
func TestConnectToNonexistentSocketFailsPromptly(t *testing.T) {
	start := time.Now()
	_, err := protocol.EvalBlocking(
		"/tmp/sprite-timeout-test-nonexistent-socket-path.sock",
		lisp.Sym("t"),
		protocol.WithTimeout(2*time.Second),
	)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("expected an error connecting to a nonexistent socket path")
	}
	if elapsed > 2*time.Second {
		t.Errorf("connecting to a nonexistent socket path took %v, want a prompt failure", elapsed)
	}
}
