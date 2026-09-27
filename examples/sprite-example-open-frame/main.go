// Command sprite-example-open-frame reproduces sprite.el's
// `sprite-open-frame` (sprite.el:687): it does NOT use the sprite-direct
// socket protocol at all -- it shells out to a real `emacsclient
// --no-wait --create-frame`, setting DISPLAY (defaulting to ":0" when
// unset) and unsetting TERM in the child's environment, exactly
// mirroring sprite.el's `with-environment-variables` block. This is the
// one example that is a documented exception to the direct-socket
// protocol, matching sprite.el's own approach.
//
// This is illustrative only, not the production `sprite` CLI.
package main

import (
	"fmt"
	"os"
	"os/exec"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <socket-name>\n", os.Args[0])
		os.Exit(2)
	}
	name := os.Args[1]

	// Simplification: sprite.el resolves the address args via
	// `sprite--emacsclient-address-args', which picks `--server-file'
	// for TCP-registered daemons and `--socket-name' for Unix-socket
	// ones. These examples don't have access to that infrastructure
	// (or to `server-use-tcp''s value), so a bare
	// `--socket-name=<name>' is used unconditionally; a real caller
	// against a TCP-registered daemon would need `--server-file'
	// instead.
	addressArg := fmt.Sprintf("--socket-name=%s", name)

	cmd := exec.Command("emacsclient", "--no-wait", "--create-frame", addressArg)

	env := os.Environ()
	filtered := env[:0]
	for _, kv := range env {
		if len(kv) >= 5 && kv[:5] == "TERM=" {
			continue
		}
		if len(kv) >= 8 && kv[:8] == "DISPLAY=" {
			continue
		}
		filtered = append(filtered, kv)
	}
	display := os.Getenv("DISPLAY")
	if display == "" {
		display = ":0"
	}
	filtered = append(filtered, "DISPLAY="+display)
	cmd.Env = filtered

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "emacsclient error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("frame requested")
}
