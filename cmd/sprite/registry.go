package main

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
)

// fullNameRE mirrors sprite--full-name-p (sprite.el:152-166): three
// dot-separated segments, none empty, none containing a dot, with the
// middle (idx) segment numeric.
var fullNameRE = regexp.MustCompile(`^[^.]+\.[0-9]+\.[^.]+$`)

// IsFullName reports whether name matches the sprite full-name grammar
// <parent>.<idx>.<unique>.
func IsFullName(name string) bool {
	return fullNameRE.MatchString(name)
}

// decommissionedMarker is the marker file's name inside a sprite's state
// directory (mirrors sprite--decommissioned-p, sprite.el:292-295).
const decommissionedMarker = "DECOMMISSIONED"

// StateDir resolves the sprite registry's root directory from the
// SPRITE_STATE_DIR environment variable. It is a required variable in
// this CLI (see fixtures/CLI-CONTRACT.md's "Registry / state directory"
// section) since the CLI has no running-Emacs identity to derive it
// from.
func StateDir() (string, error) {
	dir := os.Getenv("SPRITE_STATE_DIR")
	if dir == "" {
		return "", fmt.Errorf("SPRITE_STATE_DIR is not set; it must point at the resolved sprite state directory")
	}
	return dir, nil
}

// ListEntry describes one sprite registered on disk.
type ListEntry struct {
	Name           string `json:"name"`
	Decommissioned bool   `json:"decommissioned"`
}

// ListSprites enumerates every entry directly under stateDir whose name
// matches the full-name grammar. Registry reads are a directory listing
// + regex filter -- no daemon communication is performed.
func ListSprites(stateDir string) ([]ListEntry, error) {
	entries, err := os.ReadDir(stateDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading state directory %s: %w", stateDir, err)
	}

	out := make([]ListEntry, 0, len(entries))
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if !IsFullName(e.Name()) {
			continue
		}
		out = append(out, ListEntry{
			Name:           e.Name(),
			Decommissioned: IsDecommissioned(stateDir, e.Name()),
		})
	}
	return out, nil
}

// IsDecommissioned reports whether the DECOMMISSIONED marker file
// exists inside stateDir/fullName (mirrors sprite--decommissioned-p,
// sprite.el:292-295).
func IsDecommissioned(stateDir, fullName string) bool {
	_, err := os.Stat(filepath.Join(stateDir, fullName, decommissionedMarker))
	return err == nil
}

// EnsureStateDir creates stateDir/fullName if it does not already
// exist, returning its path (mirrors sprite--ensure-state-dir,
// sprite.el).
func EnsureStateDir(stateDir, fullName string) (string, error) {
	dir := filepath.Join(stateDir, fullName)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("creating state directory %s: %w", dir, err)
	}
	return dir, nil
}

// WriteDecommissioned writes the empty DECOMMISSIONED marker file inside
// stateDir/fullName (mirrors sprite--write-decommissioned-file,
// sprite.el:297-303). The state directory must already exist.
func WriteDecommissioned(stateDir, fullName string) error {
	path := filepath.Join(stateDir, fullName, decommissionedMarker)
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		return fmt.Errorf("writing DECOMMISSIONED marker %s: %w", path, err)
	}
	return nil
}
