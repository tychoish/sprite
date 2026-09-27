package protocol_test

// Live-daemon integration test: exercises EvalBlocking against a real
// `emacs --daemon`, not a fake dialer. Gated on SPRITE_TEST_SOCKET
// (the resolved Unix-socket path of an already-running daemon) so it
// is skipped by default in any environment without one -- CI sets
// this env var after spawning a dedicated test daemon; see
// .github/workflows/test.yml.

import (
	"os"
	"testing"

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
