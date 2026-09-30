package main

import (
	"go/ast"
	"go/parser"
	"go/token"
	"strings"
	"testing"
)

// Round 665: nothing revives a dead player unasked. Retail has no timed
// revive in the open world -- the PC's one-second tick
// (CGObjPC::PeriodicUpdate, 0x52aa90) calls GObjPC::Revive nowhere, and of
// Revive's ten call sites only the fortress war's countdown
// (CGObjPC::PeriodicUpdateInSiege) counts a dead player down
// (session/deadstate.go, "THE CHOICES") -- so round 549's 30 s in-place
// auto-revive, which revived players among the monsters that had killed them,
// is gone. The boot wiring is the one place such a pass would be started:
// this reads main.go and fails on any goroutine or call that starts a
// session auto-revive.
func TestServerStartsNoAutoRevive(t *testing.T) {
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "main.go", nil, 0)
	if err != nil {
		t.Fatalf("parsing main.go: %v", err)
	}
	ast.Inspect(f, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		if pkg, ok := sel.X.(*ast.Ident); ok && pkg.Name == "session" && strings.Contains(strings.ToLower(sel.Sel.Name), "autorevive") {
			t.Errorf("%s: main.go uses session.%s: a dead player must stay dead until it chooses retail's return point or present point", fset.Position(sel.Pos()), sel.Sel.Name)
		}
		return true
	})
}
