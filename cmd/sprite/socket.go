package main

import (
	"os"
	"path/filepath"
	"strconv"
)

// ResolveSocketPath resolves the Unix-domain socket path for fullName,
// mirroring the fallback chain Emacs's server.el uses (per
// sprite--direct-target, sprite.el:663-671, which this v1 CLI does not
// reproduce in full -- TCP/server-use-tcp targets are a documented
// follow-up, not supported here):
//
//  1. $SPRITE_SOCKET_DIR/<full-name>, if SPRITE_SOCKET_DIR is set.
//  2. $XDG_RUNTIME_DIR/emacs/<full-name>, if XDG_RUNTIME_DIR is set.
//  3. $TMPDIR-or-/tmp/emacs<uid>/<full-name>, otherwise.
//
// Kept behind this one small function so the resolution strategy is
// easy to correct later (e.g. to add TCP target support).
func ResolveSocketPath(fullName string) string {
	if dir := os.Getenv("SPRITE_SOCKET_DIR"); dir != "" {
		return filepath.Join(dir, fullName)
	}
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, "emacs", fullName)
	}
	tmp := os.Getenv("TMPDIR")
	if tmp == "" {
		tmp = "/tmp"
	}
	dir := filepath.Join(tmp, "emacs"+strconv.Itoa(os.Getuid()))
	return filepath.Join(dir, fullName)
}
