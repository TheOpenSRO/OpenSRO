// Command opcodegen writes internal/metrics/opcodes_gen.go, the table of
// every opcode the server's code names (round 858; opcodescan). Run it from
// internal/metrics with `go generate`; TestOpcodeTableIsCurrent fails when a
// new opcode constant is not in the table yet.
package main

import (
	"fmt"
	"os"

	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics/opcodescan"
)

func main() {
	root := "../.."
	if len(os.Args) > 1 {
		root = os.Args[1]
	}
	entries, err := opcodescan.Scan(root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "opcodegen:", err)
		os.Exit(1)
	}
	if err := os.WriteFile("opcodes_gen.go", opcodescan.Render(entries), 0o644); err != nil {
		fmt.Fprintln(os.Stderr, "opcodegen:", err)
		os.Exit(1)
	}
}
