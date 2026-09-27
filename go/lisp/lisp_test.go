package lisp_test

import (
	"fmt"
	"testing"

	"github.com/tychoish/sprite/go/lisp"
)

func TestListGenericConstructor(t *testing.T) {
	l := lisp.List(lisp.Int(1), lisp.Int(2), lisp.Int(3))
	if got, want := lisp.Print(l), "(1 2 3)"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestNewListMixedTypes(t *testing.T) {
	l := lisp.NewList(lisp.Sym("list"), lisp.Str("a"), lisp.Int(2))
	if got, want := lisp.Print(l), `(list "a" 2)`; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestFormatVerbs(t *testing.T) {
	form := lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2))
	if got, want := fmt.Sprintf("%s", form), "(+ 1 2)"; got != want {
		t.Errorf("%%s: got %q, want %q", got, want)
	}
	if got, want := fmt.Sprintf("%v", form), "(+ 1 2)"; got != want {
		t.Errorf("%%v: got %q, want %q", got, want)
	}
}

// TestFormatEachVariant exercises Format (not just WriteTo/Print)
// directly on every Sexp variant, since ListForm.WriteTo calls each
// element's WriteTo, not its Format method -- a bug in a variant's
// Format implementation specifically wouldn't be caught by
// TestFormatVerbs above.
func TestFormatEachVariant(t *testing.T) {
	cases := []struct {
		name string
		form lisp.Sexp
		want string
	}{
		{"Sym", lisp.Sym("foo"), "foo"},
		{"Str", lisp.Str(`a"b`), `"a\"b"`},
		{"Int", lisp.Int(-3), "-3"},
		{"Float", lisp.Float(2), "2.0"},
		{"ListForm", lisp.NewList(lisp.Sym("a"), lisp.Sym("b")), "(a b)"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := fmt.Sprintf("%s", c.form); got != c.want {
				t.Errorf("%%s: got %q, want %q", got, c.want)
			}
			if got := fmt.Sprintf("%v", c.form); got != c.want {
				t.Errorf("%%v: got %q, want %q", got, c.want)
			}
		})
	}
}

// TestFormatUnsupportedVerb exercises formatVia's fallback branch for
// a verb other than %s/%v.
func TestFormatUnsupportedVerb(t *testing.T) {
	got := fmt.Sprintf("%d", lisp.Int(1))
	want := "%!d(lisp.Sexp=1)"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestQuote(t *testing.T) {
	if got, want := lisp.Print(lisp.Quote(lisp.Sym("foo"))), "(quote foo)"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}
