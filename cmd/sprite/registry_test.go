package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestIsFullName(t *testing.T) {
	cases := []struct {
		name string
		want bool
	}{
		{"work.0.worker", true},
		{"x.0.y", true},
		{"x.12.y", true},
		{"", false},
		{"work.worker", false},         // only two segments
		{"work.0.worker.extra", false}, // four segments
		{"work.x.worker", false},       // idx not numeric
		{".0.worker", false},           // empty parent segment
		{"work..worker", false},        // empty idx segment
		{"work.0.", false},             // empty unique segment
		{"work.0.wor.ker", false},      // unique segment contains a dot
	}
	for _, c := range cases {
		if got := IsFullName(c.name); got != c.want {
			t.Errorf("IsFullName(%q) = %v, want %v", c.name, got, c.want)
		}
	}
}

func TestListSpritesEmptyDir(t *testing.T) {
	dir := t.TempDir()
	entries, err := ListSprites(dir)
	if err != nil {
		t.Fatalf("ListSprites: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected no entries, got %v", entries)
	}
}

func TestListSpritesMissingDir(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "does-not-exist")
	entries, err := ListSprites(dir)
	if err != nil {
		t.Fatalf("ListSprites on missing dir should not error, got: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected no entries, got %v", entries)
	}
}

func TestListSpritesFiltersAndFlagsDecommissioned(t *testing.T) {
	dir := t.TempDir()
	mustMkdir(t, filepath.Join(dir, "x.0.y"))
	mustMkdir(t, filepath.Join(dir, "not-a-full-name"))
	mustMkdir(t, filepath.Join(dir, "x.1.z"))
	if err := os.WriteFile(filepath.Join(dir, "x.1.z", "DECOMMISSIONED"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	entries, err := ListSprites(dir)
	if err != nil {
		t.Fatalf("ListSprites: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries (non-full-name filtered out), got %d: %v", len(entries), entries)
	}

	byName := map[string]ListEntry{}
	for _, e := range entries {
		byName[e.Name] = e
	}
	if byName["x.0.y"].Decommissioned {
		t.Errorf("x.0.y should not be decommissioned")
	}
	if !byName["x.1.z"].Decommissioned {
		t.Errorf("x.1.z should be decommissioned")
	}
}

func TestEnsureStateDirAndWriteDecommissioned(t *testing.T) {
	dir := t.TempDir()
	full := "x.0.y"

	stateDir, err := EnsureStateDir(dir, full)
	if err != nil {
		t.Fatalf("EnsureStateDir: %v", err)
	}
	if _, err := os.Stat(stateDir); err != nil {
		t.Fatalf("state dir not created: %v", err)
	}
	if IsDecommissioned(dir, full) {
		t.Errorf("should not be decommissioned before writing the marker")
	}

	if err := WriteDecommissioned(dir, full); err != nil {
		t.Fatalf("WriteDecommissioned: %v", err)
	}
	if !IsDecommissioned(dir, full) {
		t.Errorf("should be decommissioned after writing the marker")
	}
}

func TestStateDirRequiresEnv(t *testing.T) {
	t.Setenv("SPRITE_STATE_DIR", "")
	if _, err := StateDir(); err == nil {
		t.Fatalf("expected an error when SPRITE_STATE_DIR is unset")
	}

	t.Setenv("SPRITE_STATE_DIR", "/some/path")
	dir, err := StateDir()
	if err != nil {
		t.Fatalf("StateDir: %v", err)
	}
	if dir != "/some/path" {
		t.Fatalf("StateDir() = %q, want /some/path", dir)
	}
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatal(err)
	}
}
