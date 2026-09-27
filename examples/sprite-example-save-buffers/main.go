// Command sprite-example-save-buffers evaluates `(save-some-buffers t)`
// in a running sprite daemon and prints a one-line confirmation.
//
// This is illustrative only, not the production `sprite` CLI.
package main

import (
	"fmt"
	"os"

	"github.com/tychoish/sprite"
	"github.com/tychoish/sprite/go/lisp"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintf(os.Stderr, "usage: %s <socket-path|host:port:key>\n", os.Args[0])
		os.Exit(2)
	}
	target := os.Args[1]

	client := sprite.New(target)

	form := lisp.NewList(lisp.Sym("save-some-buffers"), lisp.Sym("t"))

	_, err := client.Eval(form)
	if err != nil {
		fmt.Fprintf(os.Stderr, "eval error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println("buffers saved")
}
