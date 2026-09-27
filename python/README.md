# sprite-direct (Python)

Blocking client for the `sprite-direct` Emacs server wire protocol.
See `../fixtures/CONTRACT.md` for the authoritative protocol spec.

```python
from sprite_direct import eval_blocking, sym

# Unix domain socket target: pass the resolved socket path directly.
# No key is required (Emacs 29+ authenticates via peer UID).
result = eval_blocking("/run/user/1000/emacs/server", [sym("+"), 1, 2])
print(result)  # "3"

# TCP target: "HOST:PORT:KEY" — key is mandatory and sent in the
# clear on every request. Trusted-network-only, no TLS layer.
result = eval_blocking("127.0.0.1:9999:mysecretkey", [sym("+"), 1, 2])
```

Live-daemon integration tests against a real `emacs --daemon` are a
follow-up; no Emacs daemon is assumed available in this sandbox. Unit
tests instead consume the shared `fixtures/protocol.json` conformance
fixtures.

Run tests with `pytest` from this directory.
