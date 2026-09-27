package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/tychoish/sprite/go/lisp"
)

// TranslateArgsJSON parses raw (a JSON array, e.g. `[1, "a", true]`) and
// translates each top-level element to a lisp.Sexp per the rules in
// fixtures/CLI-CONTRACT.md's command table:
//
//   - JSON string       -> lisp.Str
//   - JSON number, int   -> lisp.Int
//   - JSON number, float -> lisp.Float
//   - JSON true/false   -> lisp.Sym("t") / lisp.Sym("nil")
//   - JSON null         -> lisp.Sym("nil")
//   - JSON array        -> a quoted list (lisp.Quote(lisp.NewList(...)))
//
// An empty raw string is treated as "no arguments" (returns an empty,
// non-nil slice).
func TranslateArgsJSON(raw string) ([]lisp.Sexp, error) {
	if strings.TrimSpace(raw) == "" {
		return []lisp.Sexp{}, nil
	}

	dec := json.NewDecoder(bytes.NewReader([]byte(raw)))
	dec.UseNumber()

	var values []interface{}
	if err := dec.Decode(&values); err != nil {
		return nil, fmt.Errorf("parsing --args JSON (expected a JSON array): %w", err)
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

// jsonToSexp translates a single decoded JSON value (as produced by a
// json.Decoder with UseNumber() set) into a lisp.Sexp.
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
		return nil, fmt.Errorf("unsupported JSON value in --args: %T (%v); only strings, numbers, booleans, null, and arrays are supported", v, v)
	}
}

// jsonNumberToSexp classifies a json.Number as an Int or a Float based
// on whether its literal text contains a fractional or exponent part.
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
