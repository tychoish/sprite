//! Wire-protocol quoting and response reassembly.
//!
//! See `fixtures/CONTRACT.md` for the authoritative spec this module
//! implements. Quoting table: `&` -> `&&`, `-` -> `&-`, space -> `&_`,
//! newline -> `&n`. Both encode and decode are single-pass, one special
//! character at a time (not sequential global replaces, which would
//! double-encode).

use crate::SpriteError;

/// Encode `s` for the wire protocol.
pub fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&&"),
            '-' => out.push_str("&-"),
            ' ' => out.push_str("&_"),
            '\n' => out.push_str("&n"),
            _ => out.push(c),
        }
    }
    out
}

/// Decode `s` from the wire protocol.
pub fn decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '&' {
            match chars.next() {
                Some('&') => out.push('&'),
                Some('-') => out.push('-'),
                Some('_') => out.push(' '),
                Some('n') => out.push('\n'),
                Some(other) => {
                    // Not part of the documented quoting table; pass
                    // both characters through unchanged rather than
                    // silently dropping the `&`.
                    out.push('&');
                    out.push(other);
                }
                None => out.push('&'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Parse a raw server response buffered to EOF into the reassembled
/// decoded result string, per the CONTRACT's reassembly algorithm:
///
/// 1. Split on newlines.
/// 2. `-print`/`-print-nonl` payloads are decoded and concatenated in
///    line order, with no assumption about which line is last.
/// 3. `-error` payload makes the whole response an error.
/// 4. `-emacs-pid` lines are ignored (preamble only, never part of the
///    result).
/// 5. If no `-print`/`-print-nonl`/`-error` line is found at all (only
///    the preamble), the result is [`SpriteError::Empty`].
pub fn parse_response(raw: &str) -> Result<String, SpriteError> {
    let mut chunks = String::new();
    let mut found = false;

    for line in raw.split('\n') {
        if let Some(payload) = line.strip_prefix("-print-nonl ") {
            chunks.push_str(&decode(payload));
            found = true;
        } else if let Some(payload) = line.strip_prefix("-print ") {
            chunks.push_str(&decode(payload));
            found = true;
        } else if let Some(payload) = line.strip_prefix("-error ") {
            return Err(SpriteError::Eval(decode(payload)));
        } else if line.starts_with("-emacs-pid") {
            // Preamble, sent on connect before any result; ignore.
            continue;
        }
        // Any other line (blank trailing line from a trailing
        // newline, unrecognised chatter, etc.) is ignored rather than
        // treated as an error, matching the reference implementation.
    }

    if !found {
        return Err(SpriteError::Empty);
    }

    // Emacs's real server.el builds every reply with (pp v), not
    // prin1/%S -- pp always appends a trailing newline (verified
    // against a live `emacs --daemon`; see fixtures/CONTRACT.md).
    // Strip exactly one, matching what a Lisp `read` of the text
    // would discard as insignificant trailing whitespace.
    if let Some(stripped) = chunks.strip_suffix('\n') {
        return Ok(stripped.to_string());
    }
    Ok(chunks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trips_special_chars() {
        let decoded = "&-& \n";
        let encoded = encode(decoded);
        assert_eq!(decode(&encoded), decoded);
    }

    #[test]
    fn reassembles_print_and_print_nonl() {
        let raw = "-emacs-pid 111\n-print-nonl abc&_def\n-print ghi";
        assert_eq!(parse_response(raw).unwrap(), "abc defghi");
    }

    #[test]
    fn error_response() {
        let raw = "-emacs-pid 5\n-error Symbol's&_function&_definition&_is&_void:&_foo";
        match parse_response(raw) {
            Err(SpriteError::Eval(msg)) => {
                assert_eq!(msg, "Symbol's function definition is void: foo");
            }
            other => panic!("expected Eval error, got {other:?}"),
        }
    }

    #[test]
    fn preamble_only_is_empty() {
        let raw = "-emacs-pid 999";
        match parse_response(raw) {
            Err(SpriteError::Empty) => {}
            other => panic!("expected Empty error, got {other:?}"),
        }
    }
}
