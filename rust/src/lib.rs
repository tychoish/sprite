//! Client library for the sprite-direct Emacs server wire protocol.
//!
//! This crate implements the client side of the `sprite-direct.el`
//! wire protocol described in `fixtures/CONTRACT.md`: wire-protocol
//! quoting ([`protocol::encode`]/[`protocol::decode`]), an s-expression
//! builder and printer ([`sexp`]), and a blocking
//! connect-send-receive-parse call ([`eval_blocking`]) over either a
//! Unix domain socket or a TCP `HOST:PORT:KEY` target.
//!
//! Per the CONTRACT's async policy for Rust, only a sync/std-only
//! `eval_blocking` ships in this crate; no `tokio`/async feature is
//! provided.
//!
//! # Connection targets
//!
//! `target` is one of:
//!
//! - A Unix domain socket path (any string that does not parse as
//!   `HOST:PORT` or `HOST:PORT:KEY`). No auth key is required in the
//!   common case (Emacs 29+ authenticates local connections via peer
//!   UID), but the `key` argument to [`eval_blocking`] is still sent as
//!   `-auth KEY` when given.
//! - A TCP target string `HOST:PORT` or `HOST:PORT:KEY`. When the
//!   target embeds a key (three colon-separated segments, with the
//!   middle one parsing as a `u16` port), that key is used. When it
//!   does not (two segments), the `key` argument to [`eval_blocking`]
//!   is used instead. If neither is present, [`SpriteError::MissingAuthKey`]
//!   is returned before a connection is attempted.
//!
//! # Live-daemon integration tests
//!
//! No `emacs --daemon` is assumed available in this sandbox, so this
//! crate ships only fixture-driven unit tests (see `tests/protocol.rs`).
//! Live-daemon integration tests are a follow-up; the socket-opening
//! step is isolated behind [`Target::connect`] specifically so that
//! seam is easy to substitute or exercise separately later.

pub mod protocol;
pub mod sexp;

use std::error::Error;
use std::fmt;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::os::unix::net::UnixStream;
use std::time::Duration;

use sexp::Sexp;

/// Errors that can occur while evaluating a form in a sprite.
#[derive(Debug)]
pub enum SpriteError {
    /// An I/O error occurred while connecting, sending, or reading.
    Io(io::Error),
    /// The server responded with `-error PAYLOAD`; the string is the
    /// decoded error message.
    Eval(String),
    /// The response contained only the `-emacs-pid` preamble and no
    /// `-print`/`-print-nonl`/`-error` line at all.
    Empty,
    /// A TCP target was given with no auth key, either embedded in the
    /// target string or passed explicitly.
    MissingAuthKey,
}

impl fmt::Display for SpriteError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            SpriteError::Io(e) => write!(f, "i/o error: {e}"),
            SpriteError::Eval(msg) => write!(f, "eval error: {msg}"),
            SpriteError::Empty => write!(f, "empty response (no print/error line found)"),
            SpriteError::MissingAuthKey => write!(f, "missing auth key for TCP target"),
        }
    }
}

impl Error for SpriteError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            SpriteError::Io(e) => Some(e),
            _ => None,
        }
    }
}

impl From<io::Error> for SpriteError {
    fn from(e: io::Error) -> Self {
        SpriteError::Io(e)
    }
}

/// A parsed connection target.
#[derive(Debug, Clone, PartialEq)]
enum Target {
    Unix { path: String },
    Tcp {
        host: String,
        port: u16,
        key: Option<String>,
    },
}

impl Target {
    /// Parse `target` per the rules documented on the crate root: a
    /// `HOST:PORT` or `HOST:PORT:KEY` string is TCP, anything else is a
    /// Unix socket path.
    fn parse(target: &str) -> Target {
        let parts: Vec<&str> = target.split(':').collect();
        if parts.len() == 3 {
            if let Ok(port) = parts[1].parse::<u16>() {
                return Target::Tcp {
                    host: parts[0].to_string(),
                    port,
                    key: Some(parts[2].to_string()),
                };
            }
        } else if parts.len() == 2 {
            if let Ok(port) = parts[1].parse::<u16>() {
                return Target::Tcp {
                    host: parts[0].to_string(),
                    port,
                    key: None,
                };
            }
        }
        Target::Unix {
            path: target.to_string(),
        }
    }

    /// Open a fresh connection for this target. This is the seam
    /// referenced in the crate-level docs for later live-daemon
    /// integration testing: it is the only place that touches the
    /// network.
    fn connect(&self, timeout: Option<Duration>) -> Result<Box<dyn ReadWrite>, SpriteError> {
        match self {
            Target::Unix { path } => {
                let stream = UnixStream::connect(path)?;
                stream.set_read_timeout(timeout)?;
                Ok(Box::new(stream))
            }
            Target::Tcp { host, port, .. } => {
                let stream = TcpStream::connect((host.as_str(), *port))?;
                stream.set_read_timeout(timeout)?;
                Ok(Box::new(stream))
            }
        }
    }
}

trait ReadWrite: Read + Write {}
impl<T: Read + Write> ReadWrite for T {}

/// Evaluate `form` in the sprite at `target`; return the raw decoded
/// result string.
///
/// Opens a single fresh connection, sends one `-auth KEY -eval
/// ENCODED_FORM \n` request line, reads to EOF, and reassembles the
/// response per the CONTRACT's algorithm (see [`protocol::parse_response`]).
/// The connection is never pooled or reused.
///
/// `key` is used as the `-auth` key. For a TCP target that already
/// embeds a key (`HOST:PORT:KEY`), the embedded key takes precedence
/// over `key`; otherwise `key` is used. A TCP target with no key from
/// either source is rejected with [`SpriteError::MissingAuthKey`]
/// before any connection is attempted. A missing key on a Unix socket
/// target is fine: the `-auth` segment is simply omitted, matching
/// Emacs 29+'s peer-UID authentication for local sockets.
///
/// `timeout` bounds each individual read from the socket (via
/// `set_read_timeout`); pass `None` to block indefinitely.
pub fn eval_blocking(
    target: &str,
    form: &Sexp,
    key: Option<&str>,
    timeout: Option<Duration>,
) -> Result<String, SpriteError> {
    let parsed = Target::parse(target);

    let auth_key: Option<String> = match &parsed {
        // Per the CONTRACT, the -auth segment is omitted entirely for
        // local Unix-socket targets (Emacs 29+ authenticates those via
        // peer UID, not a key) -- a caller-supplied key is ignored here
        // rather than sent, matching the Python client's behavior.
        Target::Unix { .. } => None,
        Target::Tcp { key: embedded, .. } => match embedded {
            Some(k) => Some(k.clone()),
            None => match key {
                Some(k) => Some(k.to_string()),
                None => return Err(SpriteError::MissingAuthKey),
            },
        },
    };

    let mut stream = parsed.connect(timeout)?;

    let printed = sexp::print_sexp(form);
    let encoded = protocol::encode(&printed);
    let mut request = String::new();
    if let Some(k) = &auth_key {
        request.push_str("-auth ");
        request.push_str(k);
        request.push(' ');
    }
    request.push_str("-eval ");
    request.push_str(&encoded);
    request.push_str(" \n");

    stream.write_all(request.as_bytes())?;

    let raw = read_response(stream.as_mut())?;
    let raw = String::from_utf8_lossy(&raw);

    protocol::parse_response(&raw)
}

/// Reads the response, stopping at EOF (the success-reply case: the
/// server closes the connection once a -print/-print-nonl reply is
/// fully sent) or as soon as a complete `-error PAYLOAD` line has been
/// seen.
///
/// The latter is not an optimization, it is a correctness requirement:
/// verified against a live `emacs --daemon` that after sending an
/// -error reply, the server does NOT promptly close the connection
/// the way it does after a successful reply -- an internal cleanup
/// eventually closes it, but only after a multi-second, unspecified
/// delay (on top of Emacs's own ~1-2s delay generating the error
/// reply in the first place, which is inherent server-side latency,
/// not a client bug). Waiting unconditionally for EOF would add that
/// delay to every real eval error. -print/-print-nonl still requires
/// waiting for EOF, since a large value's continuation lines carry no
/// marker for which one is last (see fixtures/CONTRACT.md).
fn read_response(stream: &mut dyn Read) -> std::io::Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk)?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if has_complete_error_line(&buf) {
            break;
        }
    }
    Ok(buf)
}

/// Returns true when buf contains a full, newline-terminated
/// `-error ...` line. Only bytes up to the last `\n` are considered
/// "complete" -- a trailing, not-yet-terminated fragment is still in
/// flight.
fn has_complete_error_line(buf: &[u8]) -> bool {
    match buf.iter().rposition(|&b| b == b'\n') {
        None => false,
        Some(last) => buf[..last]
            .split(|&b| b == b'\n')
            .any(|line| line.starts_with(b"-error ")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_unix_target() {
        assert_eq!(
            Target::parse("work.0.render"),
            Target::Unix {
                path: "work.0.render".to_string()
            }
        );
    }

    #[test]
    fn parses_tcp_target_with_key() {
        assert_eq!(
            Target::parse("localhost:9999:secret"),
            Target::Tcp {
                host: "localhost".to_string(),
                port: 9999,
                key: Some("secret".to_string()),
            }
        );
    }

    #[test]
    fn parses_tcp_target_without_key() {
        assert_eq!(
            Target::parse("localhost:9999"),
            Target::Tcp {
                host: "localhost".to_string(),
                port: 9999,
                key: None,
            }
        );
    }

    #[test]
    fn missing_auth_key_before_connect() {
        let form = Sexp::Sym("t".to_string());
        let result = eval_blocking("localhost:9999", &form, None, None);
        assert!(matches!(result, Err(SpriteError::MissingAuthKey)));
    }

    #[test]
    fn bogus_unix_target_returns_io_error() {
        let form = Sexp::Sym("t".to_string());
        let result = eval_blocking(
            "/nonexistent/path/that/does/not/exist.sock",
            &form,
            None,
            None,
        );
        assert!(matches!(result, Err(SpriteError::Io(_))));
    }
}
