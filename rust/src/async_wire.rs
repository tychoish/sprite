//! Hand-parsing helpers for the `sprite-async-start`/`sprite-async-poll`
//! reply text, matching the style of [`crate::protocol::parse_response`]:
//! no full Lisp reader exists in this library, so these replies are
//! parsed by hand per the documented wire-level contract.

/// The parsed result of a `(sprite-async-poll TOKEN)` reply.
#[derive(Debug, Clone, PartialEq)]
pub(crate) enum PollReply {
    Pending,
    Resolved(String),
    Rejected(String),
    Unknown,
}

/// Strip exactly one leading and one trailing `"` from `s` and unescape
/// `\"` -> `"` and `\\` -> `\` within. Returns `s` verbatim (unstripped)
/// if it does not look like a quoted string.
pub(crate) fn unquote_lisp_string(s: &str) -> String {
    let inner = match s.strip_prefix('"').and_then(|s| s.strip_suffix('"')) {
        Some(inner) => inner,
        None => return s.to_string(),
    };

    let mut out = String::with_capacity(inner.len());
    let mut chars = inner.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('"') => out.push('"'),
                Some('\\') => out.push('\\'),
                Some(other) => {
                    out.push('\\');
                    out.push(other);
                }
                None => out.push('\\'),
            }
        } else {
            out.push(c);
        }
    }
    out
}

/// Parse the reply to `(sprite-async-start ...)`: a `prin1`-quoted Lisp
/// string. Returns the bare token.
pub(crate) fn parse_start_reply(raw: &str) -> String {
    unquote_lisp_string(raw.trim())
}

/// Parse the reply to `(sprite-async-poll TOKEN)`: text like
/// `(:pending)`, `(:resolved 3)`, `(:rejected "boom")`, or `(:unknown)`.
pub(crate) fn parse_poll_reply(raw: &str) -> PollReply {
    let trimmed = raw.trim();
    let inner = trimmed
        .strip_prefix('(')
        .and_then(|s| s.strip_suffix(')'))
        .unwrap_or(trimmed);

    let (tag, rest) = match inner.find(char::is_whitespace) {
        Some(idx) => (&inner[..idx], inner[idx..].trim_start()),
        None => (inner, ""),
    };

    match tag {
        ":pending" => PollReply::Pending,
        ":resolved" => PollReply::Resolved(rest.to_string()),
        ":rejected" => PollReply::Rejected(unquote_lisp_string(rest)),
        ":unknown" => PollReply::Unknown,
        _ => PollReply::Unknown,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_start_reply() {
        assert_eq!(
            parse_start_reply("\"sprite-async-172-455-g123\""),
            "sprite-async-172-455-g123"
        );
    }

    #[test]
    fn parses_start_reply_with_escapes() {
        assert_eq!(parse_start_reply("\"a\\\"b\\\\c\""), "a\"b\\c");
    }

    #[test]
    fn parses_pending() {
        assert_eq!(parse_poll_reply("(:pending)"), PollReply::Pending);
    }

    #[test]
    fn parses_resolved() {
        assert_eq!(
            parse_poll_reply("(:resolved 3)"),
            PollReply::Resolved("3".to_string())
        );
    }

    #[test]
    fn parses_rejected() {
        assert_eq!(
            parse_poll_reply("(:rejected \"boom\")"),
            PollReply::Rejected("boom".to_string())
        );
    }

    #[test]
    fn parses_unknown() {
        assert_eq!(parse_poll_reply("(:unknown)"), PollReply::Unknown);
    }
}
