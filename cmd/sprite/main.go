// Command sprite is a standalone command-line client for managing
// sprite Emacs daemons: starting/stopping/restarting/decommissioning
// individual daemons and small fleets of them, opening graphical frames
// against a running daemon, and evaluating Lisp forms against one over
// its sprite-direct socket. See fixtures/CLI-CONTRACT.md at the repo
// root for the full contract this implements.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

const usage = `sprite: manage sprite Emacs daemons

Usage:
  sprite [--json] start NAME
  sprite [--json] fleet start --count N --prefix PREFIX
  sprite [--json] frame open NAME
  sprite [--json] call NAME FUNC [--args JSON]
  sprite [--json] eval NAME '(form)'
  sprite [--json] stop NAME
  sprite [--json] restart NAME
  sprite [--json] decommission NAME
  sprite [--json] list

NAME is always a sprite full name: <parent>.<idx>.<unique>, e.g.
work.0.worker (this CLI has no running-Emacs identity to resolve a
parent/index from, unlike sprite.el).

"fleet start" synthesizes full names as PREFIX.<idx>.PREFIX for
idx in [0, N).

--json switches every subcommand's output to newline-delimited JSON.

Environment:
  SPRITE_STATE_DIR   required; root of the sprite state-directory registry.
  SPRITE_SOCKET_DIR  optional; overrides socket-path resolution (see below).

Socket resolution for call/eval/stop/restart/decommission targets, in
order: $SPRITE_SOCKET_DIR/NAME, else $XDG_RUNTIME_DIR/emacs/NAME, else
${TMPDIR:-/tmp}/emacs<uid>/NAME. v1 supports Unix-domain sockets only;
TCP targets (server-use-tcp) are not supported (documented follow-up).
`

// run implements the whole CLI, parameterized over output streams for
// testability.
func run(args []string, stdout, stderr io.Writer) int {
	jsonMode, args := extractJSONFlag(args)

	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return 2
	}

	cmd, rest := args[0], args[1:]

	switch cmd {
	case "start":
		return runStart(stdout, rest, jsonMode)
	case "fleet":
		return runFleet(stdout, rest, jsonMode)
	case "frame":
		return runFrame(stdout, rest, jsonMode)
	case "call":
		return runCall(stdout, rest, jsonMode)
	case "eval":
		return runEval(stdout, rest, jsonMode)
	case "stop":
		return runStop(stdout, rest, jsonMode)
	case "restart":
		return runRestart(stdout, rest, jsonMode)
	case "decommission":
		return runDecommission(stdout, rest, jsonMode)
	case "list":
		return runList(stdout, rest, jsonMode)
	case "help", "-h", "--help":
		fmt.Fprint(stdout, usage)
		return 0
	default:
		fmt.Fprintf(stderr, "unknown command: %s\n\n%s", cmd, usage)
		return 2
	}
}

// extractJSONFlag scans args for a "--json" token anywhere in the
// argument list and removes it, since --json is a global flag that
// applies uniformly to every subcommand (per
// fixtures/CLI-CONTRACT.md's Output modes section) rather than being
// tied to a single flag.FlagSet's position in the argument list.
func extractJSONFlag(args []string) (bool, []string) {
	out := make([]string, 0, len(args))
	found := false
	for _, a := range args {
		if a == "--json" {
			found = true
			continue
		}
		out = append(out, a)
	}
	return found, out
}

// extractStringFlag scans args for a "--name value" pair (in either
// "--name value" or "--name=value" form) anywhere in the argument list,
// removes it, and returns its value alongside the remaining args. This
// mirrors extractJSONFlag's approach of tolerating a flag interspersed
// among positional arguments, which stdlib flag.FlagSet does not
// support (it stops parsing flags at the first positional argument).
func extractStringFlag(args []string, name string) (string, []string) {
	out := make([]string, 0, len(args))
	value := ""
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == name && i+1 < len(args):
			value = args[i+1]
			i++
		case len(a) > len(name)+1 && a[:len(name)+1] == name+"=":
			value = a[len(name)+1:]
		default:
			out = append(out, a)
		}
	}
	return value, out
}

func requireFullName(w io.Writer, jsonMode bool, name string) bool {
	if !IsFullName(name) {
		printLifecycleResult(w, jsonMode, name, fmt.Errorf("not a valid sprite full name: %s", name))
		return false
	}
	return true
}

func runStart(w io.Writer, args []string, jsonMode bool) int {
	fs := flag.NewFlagSet("start", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(w, "usage: sprite start NAME")
		return 2
	}
	name := rest[0]
	if !requireFullName(w, jsonMode, name) {
		return 1
	}

	stateDir, err := StateDir()
	if err != nil {
		printLifecycleResult(w, jsonMode, name, err)
		return 1
	}

	err = StartDaemon(stateDir, name, defaultStartTimeout)
	printLifecycleResult(w, jsonMode, name, err)
	if err != nil {
		return 1
	}
	return 0
}

func runFleet(w io.Writer, args []string, jsonMode bool) int {
	if len(args) == 0 || args[0] != "start" {
		fmt.Fprintln(w, "usage: sprite fleet start --count N --prefix PREFIX")
		return 2
	}
	fs := flag.NewFlagSet("fleet start", flag.ContinueOnError)
	count := fs.Int("count", 0, "number of sprites to start")
	prefix := fs.String("prefix", "", "name prefix; full names are synthesized as PREFIX.<idx>.PREFIX")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}
	if *count <= 0 || *prefix == "" {
		fmt.Fprintln(w, "usage: sprite fleet start --count N --prefix PREFIX (both required, count > 0)")
		return 2
	}

	stateDir, err := StateDir()
	if err != nil {
		printLifecycleResult(w, jsonMode, "fleet start", err)
		return 1
	}

	exit := 0
	for idx := 0; idx < *count; idx++ {
		name := FleetName(*prefix, idx)
		err := StartDaemon(stateDir, name, defaultStartTimeout)
		printLifecycleResult(w, jsonMode, name, err)
		if err != nil {
			exit = 1
		}
	}
	return exit
}

func runFrame(w io.Writer, args []string, jsonMode bool) int {
	if len(args) == 0 || args[0] != "open" {
		fmt.Fprintln(w, "usage: sprite frame open NAME")
		return 2
	}
	rest := args[1:]
	if len(rest) != 1 {
		fmt.Fprintln(w, "usage: sprite frame open NAME")
		return 2
	}
	name := rest[0]
	if !requireFullName(w, jsonMode, name) {
		return 1
	}

	err := OpenFrame(name)
	printLifecycleResult(w, jsonMode, name, err)
	if err != nil {
		return 1
	}
	return 0
}

func runStop(w io.Writer, args []string, jsonMode bool) int {
	fs := flag.NewFlagSet("stop", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(w, "usage: sprite stop NAME")
		return 2
	}
	name := rest[0]
	if !requireFullName(w, jsonMode, name) {
		return 1
	}

	err := StopDaemon(ResolveSocketPath(name))
	printLifecycleResult(w, jsonMode, name, err)
	if err != nil {
		return 1
	}
	return 0
}

func runRestart(w io.Writer, args []string, jsonMode bool) int {
	fs := flag.NewFlagSet("restart", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(w, "usage: sprite restart NAME")
		return 2
	}
	name := rest[0]
	if !requireFullName(w, jsonMode, name) {
		return 1
	}

	stateDir, err := StateDir()
	if err != nil {
		printLifecycleResult(w, jsonMode, name, err)
		return 1
	}

	err = RestartDaemon(stateDir, name, defaultStartTimeout)
	printLifecycleResult(w, jsonMode, name, err)
	if err != nil {
		return 1
	}
	return 0
}

func runDecommission(w io.Writer, args []string, jsonMode bool) int {
	fs := flag.NewFlagSet("decommission", flag.ContinueOnError)
	if err := fs.Parse(args); err != nil {
		return 2
	}
	rest := fs.Args()
	if len(rest) != 1 {
		fmt.Fprintln(w, "usage: sprite decommission NAME")
		return 2
	}
	name := rest[0]
	if !requireFullName(w, jsonMode, name) {
		return 1
	}

	stateDir, err := StateDir()
	if err != nil {
		printLifecycleResult(w, jsonMode, name, err)
		return 1
	}

	err = DecommissionDaemon(stateDir, name)
	printLifecycleResult(w, jsonMode, name, err)
	if err != nil {
		return 1
	}
	return 0
}
