package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"

	"github.com/tychoish/sprite"
	"github.com/tychoish/sprite/go/lisp"
)

// defaultStartTimeout mirrors sprite--wait-for-server's default
// (sprite.el:543-552).
const defaultStartTimeout = 10 * time.Second

// StartDaemon mkdir -p's the sprite's state directory, spawns
// `emacs --daemon=fullName` as a detached background subprocess
// (mirrors sprite--spawn, sprite.el:518-528), then polls the resolved
// socket path until it exists or timeout elapses (mirrors
// sprite--wait-for-server, sprite.el:543-552).
func StartDaemon(stateDir, fullName string, timeout time.Duration) error {
	if _, err := EnsureStateDir(stateDir, fullName); err != nil {
		return err
	}

	if timeout <= 0 {
		timeout = defaultStartTimeout
	}

	cmd := exec.Command("emacs", "--daemon="+fullName)
	// Detach fully: new session, and don't hold onto the parent's
	// stdio (the daemon logs to its own files/syslog once running).
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("spawning emacs --daemon=%s: %w", fullName, err)
	}
	// Fire-and-forget: release the process so it isn't reaped as a
	// zombie by this short-lived CLI process exiting before the
	// daemon does.
	_ = cmd.Process.Release()

	socketPath := ResolveSocketPath(fullName)
	deadline := time.Now().Add(timeout)
	for {
		if _, err := os.Stat(socketPath); err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("timed out after %s waiting for %s's socket at %s", timeout, fullName, socketPath)
		}
		time.Sleep(200 * time.Millisecond)
	}
}

// stopReadDropSubstring is the substring EvalBlocking's wrapped error
// carries when the failure occurred while reading the response --
// i.e. after the request (here, "(kill-emacs)") was already sent. A
// daemon closing the connection mid-shutdown, right after processing
// kill-emacs, surfaces this way; it is the expected shutdown path, not
// a failure (mirrors sprite-stop's fire-and-forget shape,
// sprite.el:601-603).
const stopReadDropSubstring = "reading response"

// StopDaemon sends (kill-emacs) to the sprite reachable at target. A
// connection failure that happens while sending the request or dialing
// is a real error; a failure while reading the (necessarily absent)
// response is the expected result of the daemon exiting and is treated
// as success -- UNLESS the read failure was a timeout, since a stalled
// read means the daemon may never have received or processed the
// request at all, not that it shut down.
func StopDaemon(target string) error {
	_, err := sprite.New(target).Eval(lisp.NewList(lisp.Sym("kill-emacs")))
	if err == nil {
		return nil
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return err
	}
	if strings.Contains(err.Error(), stopReadDropSubstring) {
		return nil
	}
	return err
}

// bestEffortStop swallows any error from StopDaemon, matching
// sprite-decommission's `(condition-case _ (sprite-stop ...) (error
// nil))` pattern (sprite.el:625), reused here for both restart and
// decommission.
func bestEffortStop(target string) {
	_ = StopDaemon(target)
}

// RestartDaemon stops fullName (best-effort, swallowing errors) then
// re-spawns it, mirroring sprite-restart.
func RestartDaemon(stateDir, fullName string, timeout time.Duration) error {
	bestEffortStop(ResolveSocketPath(fullName))
	return StartDaemon(stateDir, fullName, timeout)
}

// DecommissionDaemon stops fullName (best-effort), ensures its state
// directory exists, and writes the DECOMMISSIONED marker file (mirrors
// sprite-decommission, sprite.el).
func DecommissionDaemon(stateDir, fullName string) error {
	bestEffortStop(ResolveSocketPath(fullName))
	if _, err := EnsureStateDir(stateDir, fullName); err != nil {
		return err
	}
	return WriteDecommissioned(stateDir, fullName)
}

// FleetName synthesizes the full name for the idx'th member of a fleet
// started under prefix. Scheme: PREFIX.<idx>.PREFIX -- parent and
// unique-name segments both set to prefix, since the CLI has no parent
// context to model "children of X" the way sprite.el does. Documented
// in --help; consistency matters more than the specific scheme, per
// fixtures/CLI-CONTRACT.md.
func FleetName(prefix string, idx int) string {
	return fmt.Sprintf("%s.%d.%s", prefix, idx, prefix)
}

// OpenFrame reproduces sprite-open-frame (sprite.el:676-703): set
// DISPLAY to its existing value or ":0" if unset, unset TERM, then run
// `emacsclient --no-wait --create-frame --socket-name fullName` as a
// detached subprocess, inheriting the modified environment for that
// subprocess only (the CLI's own environment is never mutated).
func OpenFrame(fullName string) error {
	env := os.Environ()
	env = setEnvVar(env, "DISPLAY", displayOrDefault())
	env = unsetEnvVar(env, "TERM")

	cmd := exec.Command("emacsclient", "--no-wait", "--create-frame", "--socket-name", fullName)
	cmd.Env = env
	cmd.Stdin = nil
	cmd.Stdout = nil
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("spawning emacsclient for %s: %w", fullName, err)
	}
	return cmd.Process.Release()
}

func displayOrDefault() string {
	if d := os.Getenv("DISPLAY"); d != "" {
		return d
	}
	return ":0"
}

// setEnvVar returns env with key set to value, replacing any existing
// entry for key.
func setEnvVar(env []string, key, value string) []string {
	out := unsetEnvVar(env, key)
	return append(out, key+"="+value)
}

// unsetEnvVar returns env with any entry for key removed.
func unsetEnvVar(env []string, key string) []string {
	prefix := key + "="
	out := make([]string, 0, len(env))
	for _, e := range env {
		if strings.HasPrefix(e, prefix) {
			continue
		}
		out = append(out, e)
	}
	return out
}
