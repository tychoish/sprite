# sprite (Go client)

A Go client for the `sprite-direct` Emacs server wire protocol. See
`../fixtures/CONTRACT.md` for the protocol spec this implementation
conforms to.

Layout: `go/lisp` (the sexp builder/printer), `go/protocol` (wire
encode/decode, response reassembly, blocking connect-send-receive), and
the root `sprite.go`, which re-exports both behind a small `sprite.New`
/ `sprite.List` API for the common case.

Only a blocking API is provided (`EvalBlocking`, wrapped as
`(*Client).Eval`). There is no async/non-blocking variant — dispatch
concurrently by calling `Eval` from your own goroutine.

## Usage

```go
import "github.com/tychoish/sprite"

func main() {
	client := sprite.New("/run/user/1000/emacs/server") // or "host:port:key" for TCP

	form := sprite.NewList(sprite.Sym("+"), sprite.Int(1), sprite.Int(2))

	result, err := client.Eval(form)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(result) // "3"
}
```

For a single-typed list of arguments, `sprite.List(items...)` avoids
boxing each element by hand: `sprite.List(sprite.Int(1), sprite.Int(2))`.
Use `sprite.Quote(form)` for `(quote form)`.

A minimal runnable example lives in `examples/sprite-example`.

## Examples

- `examples/sprite-example`: evaluate `(+ 1 2)` and print the result — `go run ./examples/sprite-example <target>`
- `examples/sprite-example-list-buffers`: list all buffer names, one per line — `go run ./examples/sprite-example-list-buffers <target>`
- `examples/sprite-example-save-buffers`: save all buffers, confirming with `buffers saved` — `go run ./examples/sprite-example-save-buffers <target>`
- `examples/sprite-example-open-frame`: reproduce `sprite-open-frame` by invoking `emacsclient --no-wait --create-frame` directly (not the socket protocol) — `go run ./examples/sprite-example-open-frame <socket-name>`
- `examples/sprite-example-call`: build `(FUNC arg1 arg2 ...)` from a function name and a JSON args array and print the raw result — `go run ./examples/sprite-example-call <target> <func-name> <json-args-array>`

## Testing

Unit tests in `go/lisp` and `go/protocol` load
`../../fixtures/protocol.json` and iterate its `encode_decode`,
`sexp_print`, and `response_reassembly` cases directly, rather than
hand-copying them, so a protocol fixture fix is picked up automatically.

No live-daemon integration test is included in this pass (no `emacs
--daemon` is assumed available). The "open a connection" step in
`go/protocol` is factored behind the `Dial` field of `protocol.Config`
(settable via `protocol.WithDialer`) specifically so a future
integration-test pass can substitute a dialer that talks to a real
daemon without touching the request/response logic. That's a TODO
noted in `go/protocol/protocol.go`.
