// Package sprite is a thin entrypoint over github.com/tychoish/sprite/go/lisp
// and github.com/tychoish/sprite/go/protocol, implementing a client for
// the sprite-direct Emacs server wire protocol (see
// fixtures/CONTRACT.md at the repo root for the protocol spec).
//
// EvalBlocking (via (*Client).Eval) blocks for the duration of one
// connect-send-receive round trip. Callers who want a non-blocking
// handle instead of hand-rolling their own goroutine can use
// protocol.EvalAsync/Resume (see go/protocol/async.go), which return a
// *protocol.Handle backed by the daemon-side sprite-async-start/
// sprite-async-poll token registry.
//
// Build forms with go/lisp (Sym, Str, Int, Float, List, NewList,
// Quote, Print) and configure calls with go/protocol's Option
// constructors (WithKey, WithTimeout, WithDialer) directly -- this
// package does not re-export either, to avoid two names for the same
// thing.
package sprite

import (
	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

// Client evaluates Lisp forms against a single sprite-direct target
// (a Unix-domain socket path, or a TCP "HOST:PORT"/"HOST:PORT:KEY"
// string).
type Client struct {
	target string
	opts   []protocol.Option
}

// New constructs a Client for target. target is either a Unix-domain
// socket path, or a TCP target string "HOST:PORT" / "HOST:PORT:KEY"
// (see protocol.WithKey to supply the key separately). opts are
// applied to every call to Eval.
func New(target string, opts ...protocol.Option) *Client {
	return &Client{target: target, opts: opts}
}

// Eval evaluates form against the client's target and returns the raw
// decoded result string. A fresh connection is opened and closed for
// this single call. See protocol.EvalBlocking for full semantics,
// including the empty-result case.
func (c *Client) Eval(form lisp.Sexp, opts ...protocol.Option) (string, error) {
	all := make([]protocol.Option, 0, len(c.opts)+len(opts))
	all = append(all, c.opts...)
	all = append(all, opts...)
	return protocol.EvalBlocking(c.target, form, all...)
}
