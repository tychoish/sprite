// Command sprite-example is a minimal demonstration of the sprite
// client library: it is illustrative only, not the production `sprite`
// CLI (a separate, larger tool that will depend on this library).
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

	form := lisp.NewList(lisp.Sym("+"), lisp.Int(1), lisp.Int(2))

	result, err := client.Eval(form)
	if err != nil {
		fmt.Fprintf(os.Stderr, "eval error: %v\n", err)
		os.Exit(1)
	}

	fmt.Println(result)
}
