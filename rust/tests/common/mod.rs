//! Shared disposable-daemon helpers for the live-daemon test suites
//! (`integration.rs`, `timeout.rs`). Each of those files brings this
//! module in via `mod common;`; since they're separate test binaries,
//! whichever one doesn't use every helper here will otherwise warn on
//! unused pub items, hence the blanket allow below.
#![allow(dead_code)]

use std::fs;
use std::io;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

static NAME_COUNTER: AtomicU64 = AtomicU64::new(0);

/// Resolves the `emacs` binary via PATH, or `None` if it isn't found.
pub fn emacs_path() -> Option<String> {
    let output = Command::new("which").arg("emacs").output().ok()?;
    if !output.status.success() {
        return None;
    }
    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(path)
    }
}

/// Short, unique disposable-daemon name (`<prefix><pid><counter>`) --
/// AF_UNIX `sun_path` has a ~108-byte limit, so this stays short rather
/// than using a UUID or timestamp.
pub fn unique_name(prefix: &str) -> String {
    let n = NAME_COUNTER.fetch_add(1, Ordering::SeqCst);
    format!("{prefix}{}{n}", std::process::id() % 100_000)
}

/// Polls until `path` exists or `timeout` elapses.
pub fn wait_for_path(path: &PathBuf, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if path.exists() {
            return true;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    false
}

/// A disposable `emacs --fg-daemon` listening on a Unix socket, in its
/// own private `XDG_RUNTIME_DIR`. `--fg-daemon` (not `--daemon`) is
/// required so `child` really is the daemon process and can be killed
/// directly; see fixtures/CONTRACT.md-adjacent findings in integration.rs
/// and timeout.rs for why. Kills the daemon and removes its temp dir on
/// drop.
pub struct UnixDaemon {
    pub child: Child,
    xdg: PathBuf,
    pub sock: PathBuf,
}

impl UnixDaemon {
    /// Spawns a fresh, uniquely-named `emacs --fg-daemon` and waits for
    /// its Unix socket to appear.
    pub fn spawn(emacs: &str, name: &str) -> io::Result<Self> {
        let xdg = std::env::temp_dir().join(format!("x{name}"));
        fs::create_dir_all(&xdg)?;

        let child = Command::new(emacs)
            .arg(format!("--fg-daemon={name}"))
            .arg("--no-init-file")
            .arg("--no-site-file")
            .env("XDG_RUNTIME_DIR", &xdg)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;

        let sock = xdg.join("emacs").join(name);
        let mut daemon = UnixDaemon { child, xdg, sock };
        if !wait_for_path(&daemon.sock, Duration::from_secs(10)) {
            daemon.kill();
            return Err(io::Error::other(format!(
                "disposable daemon socket {:?} never appeared",
                daemon.sock
            )));
        }
        Ok(daemon)
    }

    pub fn sock_str(&self) -> &str {
        self.sock.to_str().expect("socket path is valid UTF-8")
    }

    /// Unconditionally kills the daemon process and removes its temp
    /// dir, regardless of whether the daemon is wedged.
    pub fn kill(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.xdg);
    }
}

impl Drop for UnixDaemon {
    fn drop(&mut self) {
        self.kill();
    }
}

/// A disposable `emacs --fg-daemon` with `server-use-tcp` enabled and a
/// private `server-auth-dir` (so it never touches the caller's real
/// `~/.emacs.d/server`). Kills the daemon and removes its temp dirs on
/// drop.
pub struct TcpDaemon {
    pub host: String,
    pub port: String,
    pub key: String,
    pub child: Child,
    xdg: PathBuf,
    auth_dir: PathBuf,
}

impl TcpDaemon {
    /// Spawns a fresh, uniquely-named TCP daemon, waits for its auth
    /// file to appear, and parses out host/port/key. server.el writes:
    /// line 1 `HOST:PORT PID`, line 2 the raw auth key (verified
    /// against a live `server-use-tcp` daemon).
    pub fn spawn(emacs: &str, name: &str) -> io::Result<Self> {
        let xdg = std::env::temp_dir().join(format!("x{name}"));
        fs::create_dir_all(&xdg)?;
        let auth_dir = std::env::temp_dir().join(format!("a{name}"));
        fs::create_dir_all(&auth_dir)?;
        let auth_dir_str = format!("{}/", auth_dir.display());

        let eval_expr = format!(r#"(setq server-use-tcp t server-auth-dir "{auth_dir_str}")"#);
        let child = Command::new(emacs)
            .arg(format!("--fg-daemon={name}"))
            .arg("--no-init-file")
            .arg("--no-site-file")
            .arg("--eval")
            .arg(&eval_expr)
            .env("XDG_RUNTIME_DIR", &xdg)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()?;

        let auth_file = auth_dir.join(name);
        if !wait_for_path(&auth_file, Duration::from_secs(10)) {
            let mut child = child;
            let _ = child.kill();
            let _ = child.wait();
            let _ = fs::remove_dir_all(&xdg);
            let _ = fs::remove_dir_all(&auth_dir);
            return Err(io::Error::other(format!(
                "disposable TCP daemon auth file {auth_file:?} never appeared"
            )));
        }

        let contents = fs::read_to_string(&auth_file)?;
        let mut lines = contents.lines();
        let host_port = lines
            .next()
            .unwrap_or_default()
            .split_whitespace()
            .next()
            .unwrap_or_default();
        let key = lines.next().unwrap_or_default().to_string();
        let (host, port) = host_port.rsplit_once(':').unwrap_or(("127.0.0.1", "0"));

        Ok(TcpDaemon {
            host: host.to_string(),
            port: port.to_string(),
            key,
            child,
            xdg,
            auth_dir,
        })
    }

    /// Unconditionally kills the daemon process and removes its temp
    /// dirs.
    pub fn kill(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.xdg);
        let _ = fs::remove_dir_all(&self.auth_dir);
    }
}

impl Drop for TcpDaemon {
    fn drop(&mut self) {
        self.kill();
    }
}
