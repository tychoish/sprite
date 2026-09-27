package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestResolveSocketPathFallbackChain(t *testing.T) {
	const full = "x.0.y"

	t.Run("prefers SPRITE_SOCKET_DIR", func(t *testing.T) {
		t.Setenv("SPRITE_SOCKET_DIR", "/custom/sockets")
		t.Setenv("XDG_RUNTIME_DIR", "/run/user/1000")
		t.Setenv("TMPDIR", "/tmp")
		got := ResolveSocketPath(full)
		want := filepath.Join("/custom/sockets", full)
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	})

	t.Run("falls back to XDG_RUNTIME_DIR/emacs", func(t *testing.T) {
		t.Setenv("SPRITE_SOCKET_DIR", "")
		t.Setenv("XDG_RUNTIME_DIR", "/run/user/1000")
		t.Setenv("TMPDIR", "/tmp")
		got := ResolveSocketPath(full)
		want := filepath.Join("/run/user/1000", "emacs", full)
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	})

	t.Run("falls back to TMPDIR/emacs<uid>", func(t *testing.T) {
		t.Setenv("SPRITE_SOCKET_DIR", "")
		t.Setenv("XDG_RUNTIME_DIR", "")
		t.Setenv("TMPDIR", "/my/tmp")
		got := ResolveSocketPath(full)
		want := filepath.Join("/my/tmp", "emacs"+strconv.Itoa(os.Getuid()), full)
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	})

	t.Run("falls back to /tmp/emacs<uid> when TMPDIR is also unset", func(t *testing.T) {
		t.Setenv("SPRITE_SOCKET_DIR", "")
		t.Setenv("XDG_RUNTIME_DIR", "")
		t.Setenv("TMPDIR", "")
		got := ResolveSocketPath(full)
		want := filepath.Join("/tmp", "emacs"+strconv.Itoa(os.Getuid()), full)
		if got != want {
			t.Errorf("got %q, want %q", got, want)
		}
	})
}
