package main

import (
	"encoding/json"
	"fmt"
	"io"
	"text/tabwriter"
)

// writeJSONLine marshals v to a single JSON object and writes it to w
// followed by a newline, per fixtures/CLI-CONTRACT.md's "--json global
// flag ... newline-delimited JSON objects" requirement.
func writeJSONLine(w io.Writer, v interface{}) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintln(w, string(b))
	return err
}

// statusResult is the JSON shape for lifecycle commands (start, stop,
// restart, decommission, fleet start).
type statusResult struct {
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
	Name    string `json:"name,omitempty"`
}

// printLifecycleResult writes the outcome of a lifecycle command (one
// that either succeeds or fails with a message, no other payload) in
// either human or --json form.
func printLifecycleResult(w io.Writer, jsonMode bool, name string, err error) {
	if jsonMode {
		res := statusResult{Status: "ok", Name: name}
		if err != nil {
			res.Status = "error"
			res.Message = err.Error()
		}
		_ = writeJSONLine(w, res)
		return
	}
	if err != nil {
		fmt.Fprintf(w, "%s: error: %s\n", name, err.Error())
		return
	}
	fmt.Fprintf(w, "%s: ok\n", name)
}

// evalResult is the JSON shape for call/eval.
type evalResult struct {
	Result string `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

// printEvalResult writes the outcome of a call/eval command in either
// human or --json form.
func printEvalResult(w io.Writer, jsonMode bool, result string, err error) {
	if jsonMode {
		if err != nil {
			_ = writeJSONLine(w, evalResult{Error: err.Error()})
			return
		}
		_ = writeJSONLine(w, evalResult{Result: result})
		return
	}
	if err != nil {
		fmt.Fprintln(w, err.Error())
		return
	}
	fmt.Fprintln(w, result)
}

// printListEntries writes the sprite registry listing in either human
// (aligned columns) or --json (newline-delimited) form.
func printListEntries(w io.Writer, jsonMode bool, entries []ListEntry) {
	if jsonMode {
		for _, e := range entries {
			_ = writeJSONLine(w, e)
		}
		return
	}
	tw := tabwriter.NewWriter(w, 0, 2, 2, ' ', 0)
	for _, e := range entries {
		fmt.Fprintf(tw, "%s\t%v\n", e.Name, e.Decommissioned)
	}
	_ = tw.Flush()
}
