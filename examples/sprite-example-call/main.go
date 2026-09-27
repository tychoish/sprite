// Command sprite-example-call evaluates `(FUNC arg1 arg2 ...)` in a
// running sprite daemon, mirroring cmd/sprite/call.go's runCall: the
// function name and a JSON array of arguments are given as CLI args,
// translated to lisp.Sexp values by go/lisp's builder, and the raw
// eval result is printed.
//
// This is illustrative only, not the production `sprite` CLI.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/tychoish/sprite"
	"github.com/tychoish/sprite/go/lisp"
)

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintf(os.Stderr, "usage: %s <socket-path|host:port:key> <func-name> <json-args-array>\n", os.Args[0])
		os.Exit(2)
	}
	target := os.Args[1]
	fn := os.Args[2]
	argsJSON := os.Args[3]

	client := sprite.New(target)

	argSexps, err := translateArgsJSON(argsJSON)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	items := make([]lisp.Sexp, 0, len(argSexps)+1)
	items = append(items, lisp.Sym(fn))
	items = append(items, argSexps...)
	form := lisp.NewList(items...)

	result, err := client.Eval(form)
	if err != nil {
		fmt.Fprintf(os.Stderr, "eval error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println(result)
}

// translateArgsJSON mirrors cmd/sprite/args.go's TranslateArgsJSON:
// parses a JSON array and translates each top-level element to a
// lisp.Sexp (string -> Str, int -> Int, float -> Float, true/false/null
// -> Sym("t")/Sym("nil"), array -> a quoted list). Kept as a small
// standalone copy here since these examples don't import cmd/sprite.
func translateArgsJSON(raw string) ([]lisp.Sexp, error) {
	if strings.TrimSpace(raw) == "" {
		return []lisp.Sexp{}, nil
	}

	dec := json.NewDecoder(bytes.NewReader([]byte(raw)))
	dec.UseNumber()

	var values []interface{}
	if err := dec.Decode(&values); err != nil {
		return nil, fmt.Errorf("parsing args JSON (expected a JSON array): %w", err)
	}

	out := make([]lisp.Sexp, 0, len(values))
	for _, v := range values {
		sexp, err := jsonToSexp(v)
		if err != nil {
			return nil, err
		}
		out = append(out, sexp)
	}
	return out, nil
}

func jsonToSexp(v interface{}) (lisp.Sexp, error) {
	switch val := v.(type) {
	case nil:
		return lisp.Sym("nil"), nil
	case bool:
		if val {
			return lisp.Sym("t"), nil
		}
		return lisp.Sym("nil"), nil
	case string:
		return lisp.Str(val), nil
	case json.Number:
		return jsonNumberToSexp(val)
	case []interface{}:
		items := make([]lisp.Sexp, 0, len(val))
		for _, elem := range val {
			sexp, err := jsonToSexp(elem)
			if err != nil {
				return nil, err
			}
			items = append(items, sexp)
		}
		return lisp.Quote(lisp.NewList(items...)), nil
	default:
		return nil, fmt.Errorf("unsupported JSON value in args: %T (%v); only strings, numbers, booleans, null, and arrays are supported", v, v)
	}
}

func jsonNumberToSexp(n json.Number) (lisp.Sexp, error) {
	s := n.String()
	if strings.ContainsAny(s, ".eE") {
		f, err := n.Float64()
		if err != nil {
			return nil, fmt.Errorf("parsing JSON number %q as float: %w", s, err)
		}
		return lisp.Float(f), nil
	}
	i, err := n.Int64()
	if err != nil {
		return nil, fmt.Errorf("parsing JSON number %q as int: %w", s, err)
	}
	return lisp.Int(i), nil
}
