// Package lisp implements a small Lisp s-expression builder and printer,
// matching the printed (reader) syntax expected by the sprite-direct wire
// protocol (see fixtures/CONTRACT.md at the repo root). It intentionally
// does not implement a Lisp *reader*: only construction and printing of
// forms are supported, per the MVP scope in the contract.
package lisp

import (
	"fmt"
	"io"
	"strconv"
	"strings"
)

// Sexp is satisfied by every printable s-expression variant: Sym, Str,
// Int, Float, and ListForm. It supports direct streaming via io.WriterTo
// and integrates with the fmt package via fmt.Formatter, so %s/%v also
// print the Lisp form correctly.
type Sexp interface {
	io.WriterTo
	fmt.Formatter
}

// Sym is a bare Lisp symbol, printed without quoting (e.g. `+`, `foo`).
type Sym string

// WriteTo writes the symbol's printed form.
func (s Sym) WriteTo(w io.Writer) (int64, error) {
	n, err := io.WriteString(w, string(s))
	return int64(n), err
}

// Format implements fmt.Formatter by delegating to WriteTo.
func (s Sym) Format(f fmt.State, verb rune) { formatVia(s, f, verb) }

// Str is a Lisp string, printed with double quotes and prin1-style
// escaping of `\` and `"`.
type Str string

// WriteTo writes the string's printed (quoted, escaped) form.
func (s Str) WriteTo(w io.Writer) (int64, error) {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range string(s) {
		switch r {
		case '\\', '"':
			b.WriteByte('\\')
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	n, err := io.WriteString(w, b.String())
	return int64(n), err
}

// Format implements fmt.Formatter by delegating to WriteTo.
func (s Str) Format(f fmt.State, verb rune) { formatVia(s, f, verb) }

// Int is a Lisp integer.
type Int int64

// WriteTo writes the integer's printed form.
func (i Int) WriteTo(w io.Writer) (int64, error) {
	n, err := io.WriteString(w, strconv.FormatInt(int64(i), 10))
	return int64(n), err
}

// Format implements fmt.Formatter by delegating to WriteTo.
func (i Int) Format(f fmt.State, verb rune) { formatVia(i, f, verb) }

// Float is a Lisp floating point number.
type Float float64

// WriteTo writes the float's printed form. Whole-number floats always
// print with a trailing ".0" (e.g. "2.0", not "2") so the Emacs Lisp
// reader reads them back as a float, not an integer.
func (fl Float) WriteTo(w io.Writer) (int64, error) {
	s := strconv.FormatFloat(float64(fl), 'g', -1, 64)
	if !strings.ContainsAny(s, ".eE") {
		s += ".0"
	}
	n, err := io.WriteString(w, s)
	return int64(n), err
}

// Format implements fmt.Formatter by delegating to WriteTo.
func (fl Float) Format(f fmt.State, verb rune) { formatVia(fl, f, verb) }

// ListForm is a Lisp list, printed as `(a b c)` with single-space
// separators between elements.
type ListForm []Sexp

// WriteTo writes the list's printed form.
func (l ListForm) WriteTo(w io.Writer) (int64, error) {
	var total int64
	n, err := io.WriteString(w, "(")
	total += int64(n)
	if err != nil {
		return total, err
	}
	for i, item := range l {
		if i > 0 {
			n, err = io.WriteString(w, " ")
			total += int64(n)
			if err != nil {
				return total, err
			}
		}
		var m int64
		m, err = item.WriteTo(w)
		total += m
		if err != nil {
			return total, err
		}
	}
	n, err = io.WriteString(w, ")")
	total += int64(n)
	return total, err
}

// Format implements fmt.Formatter by delegating to WriteTo.
func (l ListForm) Format(f fmt.State, verb rune) { formatVia(l, f, verb) }

// formatVia implements fmt.Formatter for any Sexp by writing its printed
// form to the fmt.State, for both %s and %v verbs.
func formatVia(s Sexp, f fmt.State, verb rune) {
	switch verb {
	case 's', 'v':
		_, _ = s.WriteTo(f)
	default:
		_, _ = fmt.Fprintf(f, "%%!%c(lisp.Sexp=%s)", verb, Print(s))
	}
}

// List builds a ListForm from a typed slice of items, so callers with a
// single-typed list (e.g. all Str, or all Int) don't need to box each
// element into the Sexp interface by hand.
func List[T Sexp](items ...T) ListForm {
	out := make(ListForm, len(items))
	for i, item := range items {
		out[i] = item
	}
	return out
}

// NewList builds a ListForm from a mixed-type slice of Sexp values.
func NewList(items ...Sexp) ListForm {
	out := make(ListForm, len(items))
	copy(out, items)
	return out
}

// Quote wraps form as `(quote form)`.
func Quote(form Sexp) Sexp {
	return NewList(Sym("quote"), form)
}

// Print renders any Sexp to its printed string via WriteTo.
func Print(form Sexp) string {
	var b strings.Builder
	_, _ = form.WriteTo(&b)
	return b.String()
}
