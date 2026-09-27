package sprite_test

import (
	"io"
	"net"
	"testing"
	"time"

	"github.com/tychoish/sprite"
	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

// fakeConn is a minimal net.Conn double: it records what was written
// and serves a canned response on Read, so Client.Eval can be tested
// without a real socket.
type fakeConn struct {
	net.Conn
	written  []byte
	response []byte
	pos      int
}

func (f *fakeConn) Write(p []byte) (int, error) {
	f.written = append(f.written, p...)
	return len(p), nil
}

func (f *fakeConn) Read(p []byte) (int, error) {
	if f.pos >= len(f.response) {
		return 0, io.EOF
	}
	n := copy(p, f.response[f.pos:])
	f.pos += n
	return n, nil
}

func (f *fakeConn) Close() error                    { return nil }
func (f *fakeConn) SetDeadline(time.Time) error     { return nil }
func (f *fakeConn) SetReadDeadline(time.Time) error { return nil }

func TestClientEvalRoundTrip(t *testing.T) {
	conn := &fakeConn{response: []byte("-print 3\n")}
	dialer := func(network, address string) (net.Conn, error) { return conn, nil }

	client := sprite.New("/tmp/some.sock", protocol.WithDialer(dialer))
	got, err := client.Eval(lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2)))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "3" {
		t.Errorf("got %q, want %q", got, "3")
	}
	if want := "-eval (+&_1&_2) \n"; string(conn.written) != want {
		t.Errorf("written request = %q, want %q", conn.written, want)
	}
}

func TestClientEvalReturnsErrorResponse(t *testing.T) {
	conn := &fakeConn{response: []byte("-error boom\n")}
	dialer := func(network, address string) (net.Conn, error) { return conn, nil }

	client := sprite.New("/tmp/some.sock", protocol.WithDialer(dialer))
	_, err := client.Eval(lisp.Sym("t"))
	var evalErr *protocol.EvalError
	if err == nil {
		t.Fatal("expected an error")
	}
	if !asEvalError(err, &evalErr) || evalErr.Message != "boom" {
		t.Errorf("got %v, want an *protocol.EvalError{Message: \"boom\"}", err)
	}
}

func TestClientEvalPerCallOptionsAppendToClientOptions(t *testing.T) {
	conn := &fakeConn{response: []byte("-print ok\n")}
	dialer := func(network, address string) (net.Conn, error) { return conn, nil }

	// WithDialer supplied per-call, not at construction, exercises the
	// append-not-replace behavior of Client.Eval's opts parameter.
	client := sprite.New("localhost:9999:secretkey")
	got, err := client.Eval(lisp.Sym("t"), protocol.WithDialer(dialer))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "ok" {
		t.Errorf("got %q, want %q", got, "ok")
	}
	if want := "-auth secretkey -eval t \n"; string(conn.written) != want {
		t.Errorf("written request = %q, want %q", conn.written, want)
	}
}

func asEvalError(err error, target **protocol.EvalError) bool {
	e, ok := err.(*protocol.EvalError)
	if !ok {
		return false
	}
	*target = e
	return true
}
