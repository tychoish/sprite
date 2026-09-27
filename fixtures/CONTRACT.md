# sprite-direct wire protocol — shared contract for all four client libraries

Reference implementation: `/home/tychoish/src/sprite/sprite-direct.el`.
Conformance fixtures (must be consumed verbatim by every language's unit
tests): `/home/tychoish/src/sprite/fixtures/protocol.json`.

## Wire-protocol quoting (encode/decode)

Applied to the *entire* printed Lisp form before it goes out after
`-eval`, and to each `-print`/`-print-nonl`/`-error` payload before it's
read back. Single-pass, one special character at a time (not sequential
global replaces, which would double-encode):

| Character | Encoded as |
|---|---|
| `&` | `&&` |
| `-` | `&-` |
| space | `&_` |
| newline | `&n` |

## Request line

`-auth KEY -eval ENCODED_FORM \n`

- `-auth KEY` segment is omitted entirely for local Unix-socket targets
  (Emacs 29+ authenticates via peer UID, not a cookie). For TCP targets,
  a missing key is an error — return/raise before attempting to connect.
- `ENCODED_FORM` is the wire-encoded printed representation of the Lisp
  form (see "S-expression printer" below), not raw text.

## Response reassembly algorithm (must match exactly)

1. Open a fresh socket per call. Never pool/reuse connections — one
   eval is one connection, one request, one response, then close.
2. Send the request line, and **do not half-close the write side**
   afterward (no `shutdown(SHUT_WR)` / `CloseWrite()` / socket
   `.end()`). Verified against a live `emacs --daemon`: a client that
   signals its own EOF right after sending can cause the server to
   treat the connection as abandoned and skip flushing a genuine
   `-error` reply entirely — the response is silently lost, not just
   delayed. Just write the request and move on to reading.
3. Read incrementally (not one bulk read-to-EOF), stopping at
   whichever of these happens first:
   - **EOF** (the server closes the connection on its own once a
     successful `-print`/`-print-nonl` reply is fully sent — this is
     the normal, fast path for a non-error result), or
   - **a complete, newline-terminated `-error PAYLOAD` line has been
     seen** in the buffered bytes so far.

   The second condition is not an optimization, it is a correctness
   requirement, verified against live `emacs --daemon` instances
   (Emacs 28.2 and 31.1): after sending a genuine `-error` reply, the
   server does *not* promptly close the connection the way it does
   after a successful reply — some internal cleanup eventually closes
   it, but only after a multi-second, unspecified delay, on top of
   Emacs's own roughly 1-2 second delay in generating the error reply
   in the first place (this generation delay is inherent server-side
   latency for the error path specifically; it is not something a
   client can avoid, only avoid compounding). A client that
   unconditionally waits for EOF pays that full compounded delay, or
   times out and discards a reply that had, in fact, already fully
   arrived. Determining "complete" requires only bytes up to the last
   `\n` in the buffer so far — a trailing fragment with no newline yet
   is still in flight and must not be inspected. `-print`/`-print-nonl`
   still requires waiting for EOF regardless. since a large value's
   continuation lines carry no marker for which one is last (step 5).
4. Split buffered response on newlines. For each line:
   - `-print PAYLOAD` or `-print-nonl PAYLOAD`: decode PAYLOAD, append
     to an accumulator in line order.
   - `-error PAYLOAD`: decode PAYLOAD, whole response is an error with
     PAYLOAD as the message.
   - `-emacs-pid PID`: ignore — sent immediately on connect, before any
     result, never part of the eval value.
5. No `-print`/`-print-nonl`/`-error` line found at all (only the
   `-emacs-pid` preamble, EOF with nothing else): treat as failed/empty
   (e.g. return None/null/nil, per the language's idiom). This
   genuinely happens (e.g. evaluating a form whose value is itself
   `nil`... no — even `nil` prints as the text `"nil"` via `pp`, so in
   practice this case is rare) but is not the same thing as an eval
   error: a real eval error (unbound symbol/function,
   wrong-type-argument, etc.) reliably produces an actual `-error` line
   per step 3 above, given a correct (non-half-closing, early-exit-on
   -error) client implementation.
6. Concatenate the accumulated decoded payload, then **strip exactly
   one trailing newline if present**, and return the result as a raw
   string. No Lisp *reader* is needed in v1 — callers parse the
   returned string themselves if they need structured data.

   The trailing-newline strip is not optional and is not a stylistic
   choice: Emacs's real `server.el` builds every reply with `(pp v)`
   (`server-eval-and-print` in server.el), not `prin1`/`(format "%S"
   v)` as the request-encoding side uses — `pp` always appends a
   trailing newline. This was verified against a live `emacs --daemon`
   (not discoverable from `sprite-direct.el` alone, since it reads the
   decoded text back through the Emacs Lisp reader via `read`, and a
   reader silently discards trailing whitespace — so the newline never
   surfaces as a bug on the Elisp side). A client library that skips
   this step returns `"3\n"` instead of `"3"` for every eval, which
   then re-surfaces as an extra blank line or an embedded `\n` inside
   `--json` output wherever the result is printed. `pp` may also insert
   *internal* line breaks when pretty-printing a large/deeply nested
   value; that case is out of v1 scope (no Lisp reader), same as the
   rest of the MVP's structured-value handling.

## S-expression builder + printer

Tagged variants: symbol, string, int, float, list (variadic), quote
(wraps a form as `(quote form)`). String printing escapes `\` and `"`
Lisp-`prin1`-style; this is independent of, and applied *before*, the
wire-protocol encode above (build form -> print to text -> wire-encode
text). Function-call forms are just lists whose head is a symbol — no
separate "call" constructor.

## Connection targets

- Unix domain socket: connect to a path resolved by the caller (this
  library takes the resolved socket path directly, or a base directory
  + name — implementer's choice, document it). No key required in the
  common case.
- TCP: `HOST:PORT:KEY` string, key mandatory, sent in the clear in
  every request's `-auth` segment. Document as trusted-network-only,
  no TLS layer — matches the Elisp implementation's own assumption.

## MVP scope (exactly this, nothing more)

1. Wire-protocol encode/decode.
2. Sexp builder + printer (symbol, string, int/float, list, quote).
3. Blocking connect-send-receive-parse over both Unix socket and TCP.
4. Response reassembly per the algorithm above, returning a raw decoded
   string (no Lisp reader).

Do NOT build: a full Lisp reader, fleet-level dispatch, non-blocking
APIs beyond what the language gives for free (see below), or a shared
subprocess helper.

## Async policy (per language)

*Superseded by the cross-language async/future client API plan
(denote `7a4d2`): this MVP-era policy no longer holds for Python, Go,
and Rust. It is kept here, corrected in place, rather than deleted,
since it is still the authoritative statement of each language's async
surface.*

- Python: ships blocking `eval_blocking` (unchanged) plus a
  thread-pool-backed `eval_non_blocking`/`resume_future`
  (`sprite_direct.async_`) returning a `concurrent.futures.Future`,
  and a thin `asyncio` wrapper (`sprite_direct.aio`).
- JavaScript: still the natural Promise-based `evalBlocking` as the
  one and only API (Node's `net` is already async-native) — do not fake
  a synchronous variant, and do not add a second "async" entry point;
  see `js/README.md`'s fan-out example.
- Go: `EvalBlocking` is unchanged; `protocol.EvalAsync`/`Resume`
  (`go/protocol/async.go`) add a `*Handle` (`Token`/`Poll`/`Wait`) for
  callers who want a non-blocking handle instead of hand-rolling their
  own goroutine.
- Rust: sync/std-only `eval_blocking` remains the default-feature API;
  a new optional `async` Cargo feature (`dep:tokio`, minimal features)
  adds `eval_non_blocking`/`resume_future`/`AsyncHandle`
  (`rust/src/async_eval.rs`), built on `eval_blocking` via
  `tokio::task::spawn_blocking` rather than a parallel async-native
  socket implementation.

All four languages' non-blocking APIs are start/poll wrappers around
the daemon-side `sprite-async-start`/`sprite-async-poll` token
registry (`sprite-async.el`, repo root) — reached entirely through the
existing `-eval` wire command, no new wire-protocol message type.

## Testing

Unit tests must load and iterate `fixtures/protocol.json`'s three
sections (`encode_decode`, `sexp_print`, `response_reassembly`) — not
hand-copy the cases. Do not attempt live-daemon integration tests
against a real `emacs --daemon` in this pass (no Emacs daemon is
assumed available in this sandbox); note in a code comment or README
that integration tests against a real daemon are a follow-up, and
structure the response-parsing/connection code so it's easy to add
later (e.g. keep the "open socket" step behind a small seam).

## Do not touch

Do not modify `sprite-direct.el`, `sprite.el`, or any other existing
`.el` file in this repo. Do not modify `fixtures/protocol.json` or
`fixtures/CONTRACT.md`. Do not run project-wide linters/formatters
across the whole repo — scope any build/test commands to your own new
directory.
