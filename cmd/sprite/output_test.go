package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestPrintListEntriesJSONValid(t *testing.T) {
	var buf bytes.Buffer
	entries := []ListEntry{
		{Name: "x.0.y", Decommissioned: false},
		{Name: "x.1.z", Decommissioned: true},
	}
	printListEntries(&buf, true, entries)
	requireValidNDJSON(t, buf.String(), 2)
}

func TestPrintListEntriesEmptyJSON(t *testing.T) {
	var buf bytes.Buffer
	printListEntries(&buf, true, nil)
	if buf.Len() != 0 {
		t.Errorf("expected no output for an empty list, got %q", buf.String())
	}
}

func TestPrintEvalResultJSONValid(t *testing.T) {
	var buf bytes.Buffer
	printEvalResult(&buf, true, "42", nil)
	requireValidNDJSON(t, buf.String(), 1)
	if !strings.Contains(buf.String(), `"result":"42"`) {
		t.Errorf("expected result field, got %q", buf.String())
	}

	buf.Reset()
	printEvalResult(&buf, true, "", errors.New("boom"))
	requireValidNDJSON(t, buf.String(), 1)
	if !strings.Contains(buf.String(), `"error":"boom"`) {
		t.Errorf("expected error field, got %q", buf.String())
	}
}

func TestPrintLifecycleResultJSONValid(t *testing.T) {
	var buf bytes.Buffer
	printLifecycleResult(&buf, true, "x.0.y", nil)
	requireValidNDJSON(t, buf.String(), 1)
	if !strings.Contains(buf.String(), `"status":"ok"`) {
		t.Errorf("expected ok status, got %q", buf.String())
	}

	buf.Reset()
	printLifecycleResult(&buf, true, "x.0.y", errors.New("boom"))
	requireValidNDJSON(t, buf.String(), 1)
	if !strings.Contains(buf.String(), `"status":"error"`) {
		t.Errorf("expected error status, got %q", buf.String())
	}
}

// requireValidNDJSON asserts that s is newline-delimited JSON with
// exactly wantLines non-empty lines, each independently valid per
// encoding/json.Valid.
func requireValidNDJSON(t *testing.T, s string, wantLines int) {
	t.Helper()
	scanner := bufio.NewScanner(strings.NewReader(s))
	n := 0
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			continue
		}
		n++
		if !json.Valid([]byte(line)) {
			t.Errorf("line %q is not valid JSON", line)
		}
	}
	if n != wantLines {
		t.Errorf("got %d JSON lines, want %d (output: %q)", n, wantLines, s)
	}
}
