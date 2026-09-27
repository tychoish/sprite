package protocol_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

// fixturesPath resolves fixtures/protocol.json relative to the repo
// root, regardless of the package's own directory depth.
func fixturesPath(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return filepath.Join(wd, "..", "..", "fixtures", "protocol.json")
}

type encodeDecodeCase struct {
	Decoded string `json:"decoded"`
	Encoded string `json:"encoded"`
}

// formNode mirrors the tagged {type, value} nodes in protocol.json's
// sexp_print section.
type formNode struct {
	Type  string          `json:"type"`
	Value json.RawMessage `json:"value"`
}

type sexpPrintCase struct {
	Form    formNode `json:"form"`
	Printed string   `json:"printed"`
}

type responseReassemblyCase struct {
	Name     string   `json:"name"`
	RawLines []string `json:"raw_lines"`
	Expected struct {
		Status  string `json:"status"`
		Value   string `json:"value"`
		Message string `json:"message"`
	} `json:"expected"`
}

type fixtures struct {
	EncodeDecode struct {
		Cases []encodeDecodeCase `json:"cases"`
	} `json:"encode_decode"`

	SexpPrint struct {
		Cases []sexpPrintCase `json:"cases"`
	} `json:"sexp_print"`

	ResponseReassembly struct {
		Cases []responseReassemblyCase `json:"cases"`
	} `json:"response_reassembly"`
}

func (f formNode) toSexp(t *testing.T) lisp.Sexp {
	t.Helper()
	switch f.Type {
	case "sym":
		var s string
		mustUnmarshal(t, f.Value, &s)
		return lisp.Sym(s)
	case "str":
		var s string
		mustUnmarshal(t, f.Value, &s)
		return lisp.Str(s)
	case "int":
		var i int64
		mustUnmarshal(t, f.Value, &i)
		return lisp.Int(i)
	case "float":
		var v float64
		mustUnmarshal(t, f.Value, &v)
		return lisp.Float(v)
	case "list":
		var items []formNode
		mustUnmarshal(t, f.Value, &items)
		out := make([]lisp.Sexp, len(items))
		for i, it := range items {
			out[i] = it.toSexp(t)
		}
		return lisp.NewList(out...)
	case "quote":
		var inner formNode
		mustUnmarshal(t, f.Value, &inner)
		return lisp.Quote(inner.toSexp(t))
	default:
		t.Fatalf("unknown form type %q", f.Type)
		return nil
	}
}

func mustUnmarshal(t *testing.T, raw json.RawMessage, out any) {
	t.Helper()
	if err := json.Unmarshal(raw, out); err != nil {
		t.Fatalf("unmarshal %s: %v", raw, err)
	}
}

func loadFixtures(t *testing.T) fixtures {
	t.Helper()
	data, err := os.ReadFile(fixturesPath(t))
	if err != nil {
		t.Fatalf("reading fixtures/protocol.json: %v", err)
	}
	var f fixtures
	if err := json.Unmarshal(data, &f); err != nil {
		t.Fatalf("parsing fixtures/protocol.json: %v", err)
	}
	return f
}

func TestEncodeDecodeFixtures(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.EncodeDecode.Cases {
		c := c
		t.Run(c.Decoded, func(t *testing.T) {
			if got := protocol.Encode(c.Decoded); got != c.Encoded {
				t.Errorf("Encode(%q) = %q, want %q", c.Decoded, got, c.Encoded)
			}
			if got := protocol.Decode(c.Encoded); got != c.Decoded {
				t.Errorf("Decode(%q) = %q, want %q", c.Encoded, got, c.Decoded)
			}
		})
	}
}

func TestSexpPrintFixtures(t *testing.T) {
	f := loadFixtures(t)
	for i, c := range f.SexpPrint.Cases {
		c := c
		t.Run("case_"+strconv.Itoa(i), func(t *testing.T) {
			form := c.Form.toSexp(t)
			if got := lisp.Print(form); got != c.Printed {
				t.Errorf("Print(...) = %q, want %q", got, c.Printed)
			}
		})
	}
}

func TestResponseReassemblyFixtures(t *testing.T) {
	f := loadFixtures(t)
	for _, c := range f.ResponseReassembly.Cases {
		c := c
		t.Run(c.Name, func(t *testing.T) {
			raw := []byte(strings.Join(c.RawLines, "\n"))
			value, err := protocol.ParseResponse(raw)
			switch c.Expected.Status {
			case "ok":
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if value == nil {
					t.Fatalf("expected value %q, got nil", c.Expected.Value)
				}
				if *value != c.Expected.Value {
					t.Errorf("value = %q, want %q", *value, c.Expected.Value)
				}
			case "error":
				if err == nil {
					t.Fatalf("expected an error, got value %v", value)
				}
				evalErr, ok := err.(*protocol.EvalError)
				if !ok {
					t.Fatalf("expected *protocol.EvalError, got %T: %v", err, err)
				}
				if evalErr.Message != c.Expected.Message {
					t.Errorf("message = %q, want %q", evalErr.Message, c.Expected.Message)
				}
			case "empty":
				if err != nil {
					t.Fatalf("unexpected error: %v", err)
				}
				if value != nil {
					t.Errorf("expected nil value, got %q", *value)
				}
			default:
				t.Fatalf("unknown expected status %q", c.Expected.Status)
			}
		})
	}
}
