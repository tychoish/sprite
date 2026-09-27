package main

import (
	"testing"

	"github.com/tychoish/sprite/go/lisp"
)

func TestTranslateArgsJSON(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string // printed form of lisp.NewList(result...)
	}{
		{"empty", "", "()"},
		{"string", `["hello"]`, `("hello")`},
		{"int", `[3]`, "(3)"},
		{"negative int", `[-7]`, "(-7)"},
		{"float", `[3.5]`, "(3.5)"},
		{"float via exponent", `[1e3]`, "(1000.0)"},
		{"true", `[true]`, "(t)"},
		{"false", `[false]`, "(nil)"},
		{"null", `[null]`, "(nil)"},
		{"array", `[[1,2]]`, "((quote (1 2)))"},
		{"mixed", `["a",1,2.5,true,false,null,[1,2]]`,
			`("a" 1 2.5 t nil nil (quote (1 2)))`},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, err := TranslateArgsJSON(c.raw)
			if err != nil {
				t.Fatalf("TranslateArgsJSON(%q): %v", c.raw, err)
			}
			printed := lisp.Print(lisp.NewList(got...))
			if printed != c.want {
				t.Errorf("TranslateArgsJSON(%q) printed = %q, want %q", c.raw, printed, c.want)
			}
		})
	}
}

func TestTranslateArgsJSONErrors(t *testing.T) {
	cases := []string{
		`not json`,
		`{"a":1}`,   // top level must be an array
		`[{"a":1}]`, // object elements are unsupported
	}
	for _, raw := range cases {
		if _, err := TranslateArgsJSON(raw); err == nil {
			t.Errorf("TranslateArgsJSON(%q): expected an error, got none", raw)
		}
	}
}
