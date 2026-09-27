package protocol_test

import (
	"errors"
	"io"
	"net"
	"testing"
	"time"

	"github.com/tychoish/sprite/go/lisp"
	"github.com/tychoish/sprite/go/protocol"
)

// fakeConn is a minimal net.Conn double for testing EvalBlocking without
// a real socket. It records what was written and serves a canned
// response on Read.
type fakeConn struct {
	net.Conn
	written     []byte
	response    []byte
	pos         int
	deadlineSet bool
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

func (f *fakeConn) Close() error { return nil }
func (f *fakeConn) SetDeadline(time.Time) error {
	f.deadlineSet = true
	return nil
}
func (f *fakeConn) SetReadDeadline(time.Time) error  { return nil }
func (f *fakeConn) SetWriteDeadline(time.Time) error { return nil }

func TestEvalBlockingUnixTargetViaFakeDialer(t *testing.T) {
	conn := &fakeConn{response: []byte("-emacs-pid 1\n-print 3\n")}
	dialer := func(network, address string) (net.Conn, error) {
		if network != "unix" {
			t.Errorf("network = %q, want unix", network)
		}
		return conn, nil
	}

	got, err := protocol.EvalBlocking("/tmp/some.sock", lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2)), protocol.WithDialer(dialer))
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

func TestEvalBlockingTCPTargetSendsAuth(t *testing.T) {
	conn := &fakeConn{response: []byte("-print ok\n")}
	dialer := func(network, address string) (net.Conn, error) {
		if network != "tcp" {
			t.Errorf("network = %q, want tcp", network)
		}
		if address != "localhost:9999" {
			t.Errorf("address = %q, want localhost:9999", address)
		}
		return conn, nil
	}

	got, err := protocol.EvalBlocking("localhost:9999:secretkey", lisp.Sym("t"), protocol.WithDialer(dialer))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got != "ok" {
		t.Errorf("got %q, want ok", got)
	}
	if want := "-auth secretkey -eval t \n"; string(conn.written) != want {
		t.Errorf("written request = %q, want %q", conn.written, want)
	}
}

func TestEvalBlockingTCPTargetNoKeyIsErrorBeforeDialing(t *testing.T) {
	dialed := false
	dialer := func(network, address string) (net.Conn, error) {
		dialed = true
		return nil, errors.New("should not be called")
	}

	_, err := protocol.EvalBlocking("localhost:9999", lisp.Sym("t"), protocol.WithDialer(dialer))
	if err == nil {
		t.Fatal("expected an error for a TCP target with no key")
	}
	if dialed {
		t.Fatal("dialer should not have been called before the key check")
	}
}

func TestEvalBlockingErrorResponse(t *testing.T) {
	conn := &fakeConn{response: []byte("-error boom")}
	dialer := func(network, address string) (net.Conn, error) { return conn, nil }

	_, err := protocol.EvalBlocking("/tmp/some.sock", lisp.Sym("t"), protocol.WithDialer(dialer))
	if err == nil {
		t.Fatal("expected an error")
	}
	var evalErr *protocol.EvalError
	if !errors.As(err, &evalErr) {
		t.Fatalf("expected *protocol.EvalError, got %T: %v", err, err)
	}
	if evalErr.Message != "boom" {
		t.Errorf("message = %q, want boom", evalErr.Message)
	}
}

func TestEvalErrorMessage(t *testing.T) {
	err := &protocol.EvalError{Message: "boom"}
	if got, want := err.Error(), "sprite eval error: boom"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestWithKeySuppliesTCPAuth(t *testing.T) {
	conn := &fakeConn{response: []byte("-print ok\n")}
	dialer := func(network, address string) (net.Conn, error) { return conn, nil }

	// Target has no embedded key; WithKey supplies it out of band.
	_, err := protocol.EvalBlocking("localhost:9999", lisp.Sym("t"), protocol.WithDialer(dialer), protocol.WithKey("k"))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if want := "-auth k -eval t \n"; string(conn.written) != want {
		t.Errorf("written request = %q, want %q", conn.written, want)
	}
}

func TestWithTimeoutAppliesReadDeadline(t *testing.T) {
	conn := &fakeConn{response: []byte("-print ok\n")}
	dialer := func(network, address string) (net.Conn, error) { return conn, nil }

	_, err := protocol.EvalBlocking("/tmp/some.sock", lisp.Sym("t"), protocol.WithDialer(dialer), protocol.WithTimeout(time.Second))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !conn.deadlineSet {
		t.Error("expected SetDeadline to have been called")
	}
}

func TestEvalBlockingDialTimeout(t *testing.T) {
	// A dialer that never returns before the configured timeout must
	// surface a timeout error, not hang forever.
	release := make(chan struct{})
	dialed := make(chan struct{})
	dialer := func(network, address string) (net.Conn, error) {
		close(dialed)
		<-release
		return &fakeConn{response: []byte("-print ok\n")}, nil
	}

	_, err := protocol.EvalBlocking("/tmp/some.sock", lisp.Sym("t"), protocol.WithDialer(dialer), protocol.WithTimeout(20*time.Millisecond))
	if err == nil {
		t.Fatal("expected a dial-timeout error")
	}
	<-dialed
	// Let the slow dial complete after EvalBlocking has already
	// returned, exercising the leaked-connection cleanup path in
	// dialWithTimeout.
	close(release)
}

func TestDefaultDialSurfacesConnectionError(t *testing.T) {
	// No WithDialer supplied: exercises defaultDial against a socket
	// path that cannot possibly exist.
	_, err := protocol.EvalBlocking("/nonexistent/sprite-direct-test.sock", lisp.Sym("t"))
	if err == nil {
		t.Fatal("expected a connection error")
	}
}
