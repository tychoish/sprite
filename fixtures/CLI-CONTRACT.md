# sprite CLI — implementation contract

Builds on the Go client library already implemented at the repo root
(`github.com/tychoish/sprite`, packages `go/lisp` and `go/protocol`).
Read `sprite.go` first to see the exact public API (`sprite.New`,
`(*Client).Eval`, `sprite.Sym`/`Str`/`Int`/`Float`/`List`/`NewList`/
`Quote`/`Print`) — use it, don't reach around it.

Also read `/home/tychoish/src/sprite/fixtures/CONTRACT.md` for the wire
protocol shape (already implemented; you're consuming it, not
reimplementing it).

## Scope note: no running-Emacs identity assumed

Unlike `sprite.el` (which resolves "the current instance" to compute a
sprite's full name from a parent + auto-incremented index), this CLI
runs standalone with no parent Emacs process. **Simplification for v1
(deliberate, not an oversight):** every CLI command that names a sprite
takes the full three-segment name directly as its argument — e.g.
`sprite start work.0.worker` — rather than inferring parent/index. Full
name grammar: `<parent>.<idx>.<unique>`, three dot-separated segments,
none empty, none containing a dot, `idx` numeric (mirrors
`sprite--parse-full-name`/`sprite--full-name-p` in `sprite.el:152-166`).

## Registry / state directory

`sprite.el`'s `sprite-state-directory` resolves to
`<user-emacs-directory>/state/<hostname>-<instance-name>[-<user>]/sprite/`
— a path this CLI cannot replicate exactly (it doesn't know "the
current instance"). Instead: the CLI reads the **already-resolved**
`sprite` subdirectory path from an environment variable,
`SPRITE_STATE_DIR` (required; error out with a clear message if unset).
Each entry directly under `$SPRITE_STATE_DIR` whose name matches the
full-name grammar above is one sprite's state directory. A
`DECOMMISSIONED` file inside `$SPRITE_STATE_DIR/<full-name>/` marks that
sprite decommissioned (mirrors `sprite--decommissioned-p`,
`sprite.el:292-295`).

Registry reads are a directory listing + regex filter — no daemon
communication needed to enumerate sprites.

## Socket target resolution

For `call`/`eval`/`stop`, the CLI needs a target string to pass to
`sprite.New`. v1 supports Unix-domain sockets only (document TCP/
`server-use-tcp` support as a follow-up, per `sprite--direct-target`,
`sprite.el:663-671`, which this CLI does not reproduce). Resolve the
socket path the same way Emacs's `server.el` does: `$SPRITE_SOCKET_DIR/
<full-name>` if `SPRITE_SOCKET_DIR` is set, else fall back to
`$XDG_RUNTIME_DIR/emacs/<full-name>`, else
`$TMPDIR-or-/tmp/emacs<uid>/<full-name>`. Keep this resolution behind
one small function so it's easy to correct later.

## Commands

| Command | Behavior |
|---|---|
| `sprite start NAME` | `mkdir -p $SPRITE_STATE_DIR/NAME`, then spawn `emacs --daemon=NAME` as a detached background subprocess (mirrors `sprite--spawn`, `sprite.el:518-528` — start the daemon, do not wait for it inline beyond a short poll). Poll the resolved socket path (up to e.g. 10s, matching `sprite--wait-for-server`'s default, `sprite.el:543-552`) until it exists, then print success; time out with a non-zero exit and clear message otherwise. |
| `sprite fleet start --count N --prefix PREFIX` | Loop `sprite start` N times over synthesized full names — no existing Elisp fleet-spawn helper exists (per the plan, "CLI loops"); you decide a reasonable naming scheme (e.g. `PREFIX.0.PREFIX`, `PREFIX.1.PREFIX`, ... using an incrementing idx segment) since the CLI doesn't have a parent context to model "children of X" the way sprite.el does — just be consistent and document the scheme in `--help`. |
| `sprite frame open NAME` | Reproduce `sprite-open-frame` (`sprite.el:676-703`) exactly: set `DISPLAY` to its existing value or `:0` if unset, unset `TERM`, then run `emacsclient --no-wait --create-frame --socket-name NAME` as a detached subprocess (inherit the modified env for that subprocess only, don't mutate the CLI's own env permanently). This is the one command that legitimately shells out to `emacsclient` — that's expected, not a shortcut to avoid. |
| `sprite call NAME FUNC [--args JSON]` | Build `(FUNC arg1 arg2 ...)` via the `go/lisp` builder: JSON string -> `lisp.Str`, JSON number with no fractional part -> `lisp.Int`, JSON number with a fractional part -> `lisp.Float`, JSON `true`/`false` -> `lisp.Sym("t")`/`lisp.Sym("nil")`, JSON `null` -> `lisp.Sym("nil")`, JSON array -> a quoted list (`lisp.Quote(lisp.NewList(...))`) since a bare list would otherwise be read as a nested function call. Connect via `sprite.New(target).Eval(form)` and print the raw result string. |
| `sprite eval NAME '(form)'` | Raw escape hatch: the argument is already literal Lisp text supplied by the caller — do NOT run it through the sexp builder/printer, just wire-encode the text as-is and send it (this is the one command that skips the builder, exactly as the plan's table specifies). |
| `sprite stop NAME` | `sprite.New(target).Eval(lisp.List(lisp.Sym("kill-emacs")))`. The daemon closing the connection as it exits is expected and must be treated as success, not an error — a "connection reset"/EOF-with-no-print-line right after sending `(kill-emacs)` is the normal shutdown path, not a failure (mirrors `sprite-stop`'s own fire-and-forget shape, `sprite.el:601-603`); do not surface this as a CLI error. |
| `sprite restart NAME` | `stop` (ignore/log any error, matching `sprite-restart`'s `condition-case`-free-but-forgiving intent... actually mirror `sprite-decommission`'s explicit `condition-case _ (sprite-stop ...) (error nil)` pattern, `sprite.el:625`, i.e. swallow stop errors here too), then re-run the `start` logic for the same NAME. |
| `sprite decommission NAME` | Best-effort stop (swallow errors, same pattern as above, mirrors `sprite.el:625`), `mkdir -p` the state dir if missing, write an empty `DECOMMISSIONED` file inside it (mirrors `sprite--write-decommissioned-file`, `sprite.el:297-303`). |
| `sprite list` | Enumerate `$SPRITE_STATE_DIR` entries matching the full-name grammar; for each, report the name and whether `DECOMMISSIONED` exists. Do not attempt a live socket connection per entry in v1 (keep `list` filesystem-only and fast); note "running" status as a follow-up rather than guessing. |

## Output modes

Default: human-readable — aligned columns for `list` (name, decommissioned y/n), plain result/error text for `call`/`eval`. `--json` global flag switches every subcommand to newline-delimited JSON objects, e.g. `{"name":"...","decommissioned":false}` per line for `list`, `{"result":"..."}` or `{"error":"..."}` for `call`/`eval`, `{"status":"ok"}`/`{"status":"error","message":"..."}` for the lifecycle commands. Validate with `jq` or Go's own `json.Valid` in your tests that every subcommand's `--json` output is parseable.

## Dependencies

Stdlib + `github.com/tychoish/sprite` (already a go.mod dependency of
this module) + `github.com/tychoish/fun` (already a dependency; reuse
its option/error helpers where they reduce boilerplate, consistent with
the Go library). No other third-party module, and no new `go.mod`
dependency lines beyond what's already there — this CLI lives in the
same module, so `import "github.com/tychoish/sprite"` is a same-module
import.

## Layout

`cmd/sprite/main.go` (+ additional files in `cmd/sprite/` as needed —
e.g. split subcommand parsing/dispatch across a few files rather than
one giant `main.go`). Use stdlib `flag`/manual arg parsing for the
subcommand tree (no third-party CLI framework, per the dependency
constraint above).

## Testing

Unit tests for: full-name grammar validation, JSON-args-to-sexp-form
translation (a handful of cases: string/int/float/bool/null/array),
`--json` output validity for `list` and `call`/`eval` (using a fake/mock
target — do not require a live daemon), and the socket-path resolution
fallback chain. Do not attempt a live `emacs --daemon` integration test
in this pass (no daemon assumed available) — leave a `// TODO` noting
it as a follow-up, same as the four client libraries did.

Build (`go build ./...` from repo root) and smoke-test the binary by
hand: `./sprite list` with `SPRITE_STATE_DIR` pointed at an empty temp
dir (expect empty output, exit 0), then create a fake
`$SPRITE_STATE_DIR/x.0.y/` dir and re-run `list` (expect it to appear),
then create `$SPRITE_STATE_DIR/x.0.y/DECOMMISSIONED` and re-run (expect
decommissioned=true). Also smoke-test `sprite call x.0.y '+' --args
'[1,2]'` against a target that doesn't exist and confirm it fails
cleanly (connection error, not a panic) — no live daemon needed for
that negative case.

## Do not touch

Do not modify `sprite-direct.el`, `sprite.el`, any file under `go/`,
`sprite.go`, `python/`, `js/`, `rust/`, `fixtures/protocol.json`, or
`fixtures/CONTRACT.md`. Do not run repo-wide linters/formatters beyond
`gofmt`/`go vet` scoped to your own new files.
