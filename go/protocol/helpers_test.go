package protocol_test

// Shared disposable-daemon spawn/teardown helpers used by both
// integration_test.go and timeout_test.go, consolidated here to avoid
// two near-identical copies (see CONTRACT.md / plan notes on the
// sun_path length limit and --fg-daemon vs --daemon for why these look
// the way they do).

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/tychoish/sprite/go/protocol"
)

var daemonNameCounter int64

// uniqueDaemonName returns a short, unique disposable-daemon name (short prefix + pid + counter, never a full test name or UUID -- see sun_path length note).
func uniqueDaemonName(prefix string) string {
	n := atomic.AddInt64(&daemonNameCounter, 1)
	return fmt.Sprintf("%s-%d-%d", prefix, os.Getpid()%100000, n)
}

// requireEmacsBinary skips the calling test if no `emacs` binary is on PATH.
func requireEmacsBinary(t *testing.T) string {
	t.Helper()
	path, err := exec.LookPath("emacs")
	if err != nil {
		t.Skip("emacs binary not found on PATH; skipping live-daemon integration test")
	}
	return path
}

// liveDaemonSocket returns the SPRITE_TEST_SOCKET path, or skips the calling test if it isn't set.
func liveDaemonSocket(t *testing.T) string {
	t.Helper()
	sock := os.Getenv("SPRITE_TEST_SOCKET")
	if sock == "" {
		t.Skip("SPRITE_TEST_SOCKET not set; skipping live-daemon integration test")
	}
	return sock
}

// isEvalError reports whether err is a *protocol.EvalError, assigning it into target if so.
func isEvalError(err error, target **protocol.EvalError) bool {
	e, ok := err.(*protocol.EvalError)
	if !ok {
		return false
	}
	*target = e
	return true
}

// onceCleanup returns an idempotent kill+wait cleanup func for cmd (callers may invoke it both mid-test and again via defer/t.Cleanup).
func onceCleanup(cmd *exec.Cmd) func() {
	var once sync.Once
	return func() {
		once.Do(func() {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		})
	}
}

// waitForPath polls until path exists or timeout elapses, reporting which happened first.
func waitForPath(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		time.Sleep(100 * time.Millisecond)
	}
	return false
}

// newRuntimeDir creates a short-lived, short-path temp dir suitable for a disposable daemon's XDG_RUNTIME_DIR (deliberately not t.TempDir(), whose embedded full test name can push a socket path over the ~104-108 byte sun_path limit).
func newRuntimeDir(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "sprite")
	if err != nil {
		t.Fatalf("creating disposable daemon runtime dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

// spawnDisposableUnixDaemon starts a fresh, uniquely-named `emacs --fg-daemon`, waits for its Unix socket to appear, and returns the resolved socket path along with an idempotent cleanup func that unconditionally kills the process.
func spawnDisposableUnixDaemon(t *testing.T, name string) (string, *exec.Cmd, func()) {
	t.Helper()
	emacsPath := requireEmacsBinary(t)

	runtimeDir := newRuntimeDir(t)
	sockPath := filepath.Join(runtimeDir, "emacs", name)

	cmd := exec.Command(emacsPath, "--fg-daemon="+name, "--no-init-file", "--no-site-file")
	cmd.Env = append(os.Environ(), "XDG_RUNTIME_DIR="+runtimeDir)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	if err := cmd.Start(); err != nil {
		t.Fatalf("failed to start disposable daemon: %v", err)
	}

	cleanup := onceCleanup(cmd)

	if !waitForPath(sockPath, 10*time.Second) {
		cleanup()
		t.Fatalf("disposable daemon socket %s never appeared (daemon output: %s)", sockPath, out.String())
	}
	return sockPath, cmd, cleanup
}

// tcpDaemon describes a disposable server-use-tcp daemon.
type tcpDaemon struct {
	host, port, key string
}

// spawnDisposableTCPDaemon starts a fresh, uniquely-named `emacs --fg-daemon` with server-use-tcp enabled and a private server-auth-dir, waits for its auth file, parses it, and returns the host/port/key along with a cleanup func.
func spawnDisposableTCPDaemon(t *testing.T, name string) (tcpDaemon, func()) {
	t.Helper()
	emacsPath := requireEmacsBinary(t)

	runtimeDir := newRuntimeDir(t)
	authDir := filepath.Join(newRuntimeDir(t), "authdir")
	if err := os.MkdirAll(authDir, 0o700); err != nil {
		t.Fatalf("failed to create auth dir: %v", err)
	}
	authFile := filepath.Join(authDir, name)

	// Trailing slash on server-auth-dir is required by Emacs.
	evalExpr := fmt.Sprintf(`(setq server-use-tcp t server-auth-dir %q)`, authDir+string(os.PathSeparator))
	cmd := exec.Command(emacsPath, "--fg-daemon="+name, "--no-init-file", "--no-site-file", "--eval", evalExpr)
	cmd.Env = append(os.Environ(), "XDG_RUNTIME_DIR="+runtimeDir)
	if err := cmd.Start(); err != nil {
		t.Fatalf("failed to start disposable TCP daemon: %v", err)
	}

	cleanup := onceCleanup(cmd)

	if !waitForPath(authFile, 10*time.Second) {
		cleanup()
		t.Fatalf("disposable TCP daemon auth file %s never appeared", authFile)
	}

	contents, err := os.ReadFile(authFile)
	if err != nil {
		cleanup()
		t.Fatalf("failed to read auth file: %v", err)
	}
	// Emacs's server.el writes: line 1 "HOST:PORT PID", line 2 the raw
	// auth key (no further quoting/escaping applied to the key itself).
	lines := strings.SplitN(string(contents), "\n", 3)
	if len(lines) < 2 {
		cleanup()
		t.Fatalf("unexpected auth file format: %q", string(contents))
	}
	hostPort := strings.Fields(lines[0])[0]
	host, port, ok := strings.Cut(hostPort, ":")
	if !ok {
		cleanup()
		t.Fatalf("unexpected host:port in auth file: %q", hostPort)
	}
	key := strings.TrimRight(lines[1], "\n")

	return tcpDaemon{host: host, port: port, key: key}, cleanup
}
