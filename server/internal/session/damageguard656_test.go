package session

import (
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
	"path/filepath"
	"strings"
	"testing"
)

// Round 656's second review: every blow on a monster goes through
// damageMonsterWatched (aoi.go), which reads the players watching the monster
// before the blow as well as after it, so a death reaches a view that moved
// off the monster in between. A path that calls the monster hub itself
// announces to the after-watchers only and leaves ghosts. This fails on any
// call of combat.Hub.ApplyDamage (id, amount) or ApplyDamageFrom (id,
// attacker, amount; round 657's damage list) -- the character stores'
// ApplyDamage takes a context first, three arguments, and is told apart by
// its first argument being `ctx` -- anywhere but inside damageMonsterWatched
// in aoi.go and the GM's /kill and /damage (internal/gm/gm.go, whose
// announcement in session/gm.go reads the before-watchers itself). Rounds 659
// (status-effect ticks) and 660 add monster damage: call damageMonsterWatched
// (docs/protocol/monster_ai.md).
func TestMonsterDamageGoesThroughDamageMonsterWatched(t *testing.T) {
	aoiFile := filepath.Join("internal", "session", "aoi.go")
	gmFile := filepath.Join("internal", "gm", "gm.go")
	root := filepath.Join("..", "..")
	fset := token.NewFileSet()
	found := 0
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		if strings.HasPrefix(rel, filepath.Join("internal", "combat")+string(filepath.Separator)) {
			return nil // the hub's own package
		}
		f, err := parser.ParseFile(fset, path, nil, 0)
		if err != nil {
			return err
		}
		for _, decl := range f.Decls {
			fn, _ := decl.(*ast.FuncDecl)
			ast.Inspect(decl, func(n ast.Node) bool {
				call, ok := n.(*ast.CallExpr)
				if !ok {
					return true
				}
				sel, ok := call.Fun.(*ast.SelectorExpr)
				if !ok {
					return true
				}
				monsterHub := (sel.Sel.Name == "ApplyDamage" && len(call.Args) == 2) ||
					(sel.Sel.Name == "ApplyDamageFrom" && len(call.Args) == 3)
				if id, isIdent := firstArg(call).(*ast.Ident); isIdent && id.Name == "ctx" {
					monsterHub = false // a character store's
				}
				if !monsterHub {
					return true
				}
				found++
				inWatched := rel == aoiFile && fn != nil && fn.Name.Name == "damageMonsterWatched"
				if !inWatched && rel != gmFile {
					t.Errorf("%s: the monster hub's %s outside damageMonsterWatched -- call damageMonsterWatched so the death reaches the watchers before the blow too",
						fset.Position(call.Pos()), sel.Sel.Name)
				}
				return true
			})
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if found < 2 {
		t.Fatalf("the guard found %d monster ApplyDamage calls, want at least aoi.go's and gm.go's: the probe is broken", found)
	}
}

func firstArg(call *ast.CallExpr) ast.Expr {
	if len(call.Args) == 0 {
		return nil
	}
	return call.Args[0]
}
