package main

import (
	"bytes"
	"net"
	"os"
	"path/filepath"
	"testing"

	"github.com/tychoish/sprite/go/protocol"
)

// startFakeSprite listens on a Unix-domain socket at socketPath and, for
// each incoming connection, reads the request line and writes back a
// single canned response line (already wire-encoded by the caller),
// mimicking just enough of the sprite-direct wire protocol (see
// fixtures/CONTRACT.md) to exercise the CLI's call/eval paths without a
// live `emacs --daemon`.
//
// TODO(live-daemon-integration): exercise the real daemon path once one
// is available in the test environment, same follow-up noted in
// go/protocol's Config.Dial doc comment.
func startFakeSprite(t *testing.T, socketPath, response string) {
	t.Helper()
	ln, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listening on fake socket: %v", err)
	}
	t.Cleanup(func() { _ = ln.Close() })

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		_, _ = conn.Read(buf) // drain the request line; content unused by this fake
		_, _ = conn.Write([]byte(response))
	}()
}

func TestRunCallAgainstFakeTarget(t *testing.T) {
	dir := t.TempDir()
	socketDir := filepath.Join(dir, "sockets")
	if err := os.MkdirAll(socketDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPRITE_SOCKET_DIR", socketDir)

	full := "x.0.y"
	response := "-print " + protocol.Encode("3") + "\n"
	startFakeSprite(t, filepath.Join(socketDir, full), response)

	var buf bytes.Buffer
	code := runCall(&buf, []string{full, "+", "--args", "[1,2]"}, false)
	if code != 0 {
		t.Fatalf("runCall exit = %d, output: %s", code, buf.String())
	}
	if got := buf.String(); got != "3\n" {
		t.Errorf("runCall output = %q, want %q", got, "3\n")
	}
}

func TestRunCallJSONOutputValid(t *testing.T) {
	dir := t.TempDir()
	socketDir := filepath.Join(dir, "sockets")
	if err := os.MkdirAll(socketDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPRITE_SOCKET_DIR", socketDir)

	full := "x.0.y"
	response := "-print " + protocol.Encode("3") + "\n"
	startFakeSprite(t, filepath.Join(socketDir, full), response)

	var buf bytes.Buffer
	code := runCall(&buf, []string{full, "+", "--args", "[1,2]"}, true)
	if code != 0 {
		t.Fatalf("runCall exit = %d, output: %s", code, buf.String())
	}
	requireValidNDJSON(t, buf.String(), 1)
}

func TestRunEvalAgainstFakeTarget(t *testing.T) {
	dir := t.TempDir()
	socketDir := filepath.Join(dir, "sockets")
	if err := os.MkdirAll(socketDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPRITE_SOCKET_DIR", socketDir)

	full := "x.0.y"
	response := "-print " + protocol.Encode("hello") + "\n"
	startFakeSprite(t, filepath.Join(socketDir, full), response)

	var buf bytes.Buffer
	code := runEval(&buf, []string{full, `(greeting)`}, false)
	if code != 0 {
		t.Fatalf("runEval exit = %d, output: %s", code, buf.String())
	}
	if got := buf.String(); got != "hello\n" {
		t.Errorf("runEval output = %q, want %q", got, "hello\n")
	}
}

func TestRunEvalJSONOutputValid(t *testing.T) {
	dir := t.TempDir()
	socketDir := filepath.Join(dir, "sockets")
	if err := os.MkdirAll(socketDir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SPRITE_SOCKET_DIR", socketDir)

	full := "x.0.y"
	response := "-print " + protocol.Encode("hello") + "\n"
	startFakeSprite(t, filepath.Join(socketDir, full), response)

	var buf bytes.Buffer
	code := runEval(&buf, []string{full, `(greeting)`}, true)
	if code != 0 {
		t.Fatalf("runEval exit = %d, output: %s", code, buf.String())
	}
	requireValidNDJSON(t, buf.String(), 1)
}

func TestRunCallAgainstNonexistentTargetFailsCleanly(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("SPRITE_SOCKET_DIR", filepath.Join(dir, "sockets"))

	var buf bytes.Buffer
	code := runCall(&buf, []string{"x.0.y", "+", "--args", "[1,2]"}, false)
	if code == 0 {
		t.Fatalf("expected a non-zero exit code against a nonexistent target")
	}
	requireCleanFailureMessage(t, buf.String())
}

func requireCleanFailureMessage(t *testing.T, s string) {
	t.Helper()
	if s == "" {
		t.Errorf("expected a non-empty error message")
	}
}
