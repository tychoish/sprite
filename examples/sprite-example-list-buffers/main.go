// Command sprite-example-list-buffers evaluates
// `(mapcar #'buffer-name (buffer-list))` in a running sprite daemon and
// prints each buffer name on its own line.
//
// This is illustrative only, not the production `sprite` CLI.
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/tychoish/sprite"
	"github.com/tychoish/sprite/go/lisp"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <socket-path|host:port:key>\n", os.Args[0])
		os.Exit(2)
	}
	target := os.Args[1]

	client := sprite.New(target)

	form := lisp.NewList(
		lisp.Sym("mapcar"),
		lisp.NewList(lisp.Sym("function"), lisp.Sym("buffer-name")),
		lisp.NewList(lisp.Sym("buffer-list")),
	)

	result, err := client.Eval(form)
	if err != nil {
		fmt.Fprintf(os.Stderr, "eval error: %v\n", err)
		os.Exit(1)
	}

	for _, name := range parseBufferNameList(result) {
		fmt.Println(name)
	}
}

// parseBufferNameList does a minimal, best-effort split of a printed
// Lisp list of strings, e.g. `("*scratch*" "foo.txt")`, into its
// elements. It is NOT a general Lisp reader (v1 of sprite-direct has
// none, per fixtures/CONTRACT.md) -- it just strips the outer parens
// and splits on `" "` between quoted strings. It will mis-parse buffer
// names that themselves contain a `" ` sequence; that's an accepted
// limitation of this quick-and-dirty approach.
func parseBufferNameList(raw string) []string {
	s := strings.TrimSpace(raw)
	s = strings.TrimPrefix(s, "(")
	s = strings.TrimSuffix(s, ")")
	if s == "" {
		return nil
	}
	// Emacs's printer may wrap a long list's printed representation
	// across embedded newlines (observed against a live daemon);
	// collapse any run of whitespace between elements down to a
	// single space before the best-effort split below.
	s = strings.Join(strings.Fields(s), " ")
	parts := strings.Split(s, `" "`)
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimPrefix(p, `"`)
		p = strings.TrimSuffix(p, `"`)
		out = append(out, p)
	}
	return out
}
