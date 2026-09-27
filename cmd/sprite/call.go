package main

import (
	"fmt"
	"io"

	"github.com/tychoish/sprite"
	"github.com/tychoish/sprite/go/lisp"
)

var _ lisp.Sexp = rawForm("")

// runCall implements `sprite call NAME FUNC [--args JSON]`: builds
// `(FUNC arg1 arg2 ...)` via the go/lisp builder from FUNC and the
// --args JSON array, connects to NAME's resolved socket, evaluates the
// form, and prints the raw result string.
func runCall(w io.Writer, args []string, jsonMode bool) int {
	argsJSON, rest := extractStringFlag(args, "--args")
	if len(rest) != 2 {
		fmt.Fprintln(w, "usage: sprite call NAME FUNC [--args JSON]")
		return 2
	}
	name, fn := rest[0], rest[1]

	if !IsFullName(name) {
		printEvalResult(w, jsonMode, "", fmt.Errorf("not a valid sprite full name: %s", name))
		return 1
	}

	argSexps, err := TranslateArgsJSON(argsJSON)
	if err != nil {
		printEvalResult(w, jsonMode, "", err)
		return 1
	}

	items := make([]lisp.Sexp, 0, len(argSexps)+1)
	items = append(items, lisp.Sym(fn))
	items = append(items, argSexps...)
	form := lisp.NewList(items...)

	target := ResolveSocketPath(name)
	result, err := sprite.New(target).Eval(form)
	printEvalResult(w, jsonMode, result, err)
	if err != nil {
		return 1
	}
	return 0
}

// runEval implements `sprite eval NAME FORM`: FORM is literal Lisp text
// supplied by the caller and is sent as-is, skipping the sexp builder
// entirely -- the one command that does so, per
// fixtures/CLI-CONTRACT.md.
func runEval(w io.Writer, args []string, jsonMode bool) int {
	if len(args) != 2 {
		fmt.Fprintln(w, "usage: sprite eval NAME '(form)'")
		return 2
	}
	name, form := args[0], args[1]

	if !IsFullName(name) {
		printEvalResult(w, jsonMode, "", fmt.Errorf("not a valid sprite full name: %s", name))
		return 1
	}

	target := ResolveSocketPath(name)
	result, err := sprite.New(target).Eval(rawForm(form))
	printEvalResult(w, jsonMode, result, err)
	if err != nil {
		return 1
	}
	return 0
}

// rawForm is a lisp.Sexp that writes text verbatim, with no printing/
// escaping applied -- the wire-encoding step (protocol.Encode) still
// runs on it downstream, exactly as it would for any other form, but
// the text itself is passed through unparsed and unbuilt.
type rawForm string

func (r rawForm) WriteTo(w io.Writer) (int64, error) {
	n, err := io.WriteString(w, string(r))
	return int64(n), err
}

func (r rawForm) Format(f fmt.State, verb rune) {
	switch verb {
	case 's', 'v':
		_, _ = io.WriteString(f, string(r))
	default:
		_, _ = fmt.Fprintf(f, "%%!%c(rawForm=%s)", verb, string(r))
	}
}
