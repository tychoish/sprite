# sprite-direct (JavaScript)

Node.js client library for the `sprite-direct` Emacs server wire
protocol. ESM-only, zero runtime dependencies (uses Node's built-in
`net` module).

```js
import { evalBlocking, sym, quote } from "sprite-direct";

// Unix domain socket target (no auth key needed; Emacs 29+
// authenticates local connections via peer UID).
const result = await evalBlocking("/run/user/1000/emacs/server", "(+ 1 2)");

// TCP target: "HOST:PORT:KEY" — key is mandatory and sent in the clear
// on every request; trusted-network-only, no TLS layer.
const remote = await evalBlocking("example.com:9999:mykey", [
  sym("buffer-name"),
]);

// Or pass the key separately instead of embedding it in the target.
const remote2 = await evalBlocking("example.com:9999", "(current-buffer)", {
  key: "mykey",
});
```

Build forms with the tagged sexp constructors (`sym`, `quote`, plain
JS strings/numbers/arrays) and pass either a form or an already-printed
string to `evalBlocking`. `evalBlocking` resolves to the raw decoded
response string, or `null` if the server returned no result at all; it
rejects with a `SpriteEvalError` on a `-error` response or a missing
TCP auth key.

For concurrent fan-out, call `evalBlocking` multiple times and await
the results together with `Promise.all`:

```js
import { evalBlocking } from "sprite-direct";

const targets = ["worker-a.socket", "worker-b.socket", "worker-c.socket"];
const results = await Promise.all(
  targets.map((target) => evalBlocking(target, "(+ 1 2)")),
);
```

Unlike the Python, Go, and Rust `sprite-direct` client libraries, this
one has no separate non-blocking/future-style entry point and won't
gain one: `evalBlocking` is already Promise-based end-to-end, since
Node's `net` module is async-native, so it already is the non-blocking
API rather than a wrapper around a synchronous call underneath. To run
evaluations concurrently, just issue several `evalBlocking` calls at
once and await them together, as above, instead of looking for a
distinct async entry point.

Run tests with `npm test` (from this directory) or `node --test test/`.

Live-daemon integration tests against a real `emacs --daemon` are a
follow-up — no Emacs daemon is assumed available in this sandbox. The
socket-opening step in `src/conn.js` (`openSocket`) is kept as a small
seam for that future work.
