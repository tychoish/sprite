package main

import (
	"io"
	"sort"
)

// runList implements `sprite list`: enumerates $SPRITE_STATE_DIR
// entries matching the full-name grammar, reporting each one's name and
// whether it is decommissioned. Filesystem-only and fast -- no live
// socket connection is attempted per entry (see
// fixtures/CLI-CONTRACT.md: "running" status is a follow-up, not a
// guess made here).
func runList(w io.Writer, args []string, jsonMode bool) int {
	stateDir, err := StateDir()
	if err != nil {
		printLifecycleResult(w, jsonMode, "list", err)
		return 1
	}

	entries, err := ListSprites(stateDir)
	if err != nil {
		printLifecycleResult(w, jsonMode, "list", err)
		return 1
	}

	sort.Slice(entries, func(i, j int) bool { return entries[i].Name < entries[j].Name })

	printListEntries(w, jsonMode, entries)
	return 0
}
