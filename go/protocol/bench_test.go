package protocol_test

// Native Go micro-benchmarks for EvalBlocking against a real
// `emacs --daemon`, using the standard `go test -bench` toolchain
// rather than a shared cross-language driver -- these numbers are for
// tracking this language's own per-call cost over time (encode/decode,
// connect, roundtrip), not for a cross-language latency comparison.
//
// Gated on SPRITE_TEST_SOCKET, same convention as the live-daemon
// integration/timeout suites. Run with:
//
//	SPRITE_TEST_SOCKET=/path/to/socket go test ./go/protocol/... -run '^$' -bench . -benchmem
//
// Each benchmark has sub-benchmarks for a small and a large payload
// (see the `forms` map) so a payload-size regression (e.g. an
// accidental per-byte allocation in the multi-chunk -print-nonl
// reassembly path) shows up distinctly from a fixed per-call
// connect/roundtrip cost regression.

import (
	"os"
	"os/exec"
	"testing"

	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

func benchSocket(b *testing.B) string {
	b.Helper()
	sock := os.Getenv("SPRITE_TEST_SOCKET")
	if sock == "" {
		b.Skip("SPRITE_TEST_SOCKET not set; skipping benchmark")
	}
	return sock
}

func benchForms() map[string]lisp.Sexp {
	return map[string]lisp.Sexp{
		"small-int":    lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2)),
		"large-string": lisp.NewList(lisp.Sym("make-string"), lisp.Int(5000), lisp.Int(120)),
	}
}

// BenchmarkEvalBlocking measures this library's own per-call cost:
// connect, encode, send, read/reassemble, decode.
func BenchmarkEvalBlocking(b *testing.B) {
	sock := benchSocket(b)
	for name, form := range benchForms() {
		b.Run(name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				if _, err := protocol.EvalBlocking(sock, form); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

// BenchmarkEmacsclientSubprocess measures the baseline this library
// exists to beat: forking a real `emacsclient --eval` per call. Useful
// to run alongside BenchmarkEvalBlocking (e.g. via `benchstat`) to see
// the current relative speedup, not just this language's own trend.
func BenchmarkEmacsclientSubprocess(b *testing.B) {
	sock := benchSocket(b)
	if _, err := exec.LookPath("emacsclient"); err != nil {
		b.Skip("emacsclient binary not found on PATH; skipping benchmark")
	}

	forms := map[string]string{
		"small-int":    "(+ 1 2)",
		"large-string": "(make-string 5000 120)",
	}
	for name, form := range forms {
		b.Run(name, func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				cmd := exec.Command("emacsclient", "--socket-name="+sock, "--eval", form)
				if err := cmd.Run(); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}
