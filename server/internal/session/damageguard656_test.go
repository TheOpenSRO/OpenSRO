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
// off the monster in between. A path that calls combat.Hub.ApplyDamage itself
// announces to the after-watchers only and leaves ghosts. This fails on any
// call of the monster hub's ApplyDamage -- the two-argument (id, amount) one;
// the character stores' take a context first -- outside aoi.go and the GM's
// /kill (internal/gm/gm.go, whose announcement in session/gm.go reads the
// before-watchers itself). Rounds 659 (status-effect ticks) and 660 add
// monster damage: call damageMonsterWatched (docs/protocol/monster_ai.md).
func TestMonsterDamageGoesThroughDamageMonsterWatched(t *testing.T) {
	allowed := map[string]bool{
		filepath.Join("internal", "session", "aoi.go"): true,
		filepath.Join("internal", "gm", "gm.go"):       true,
	}
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
		ast.Inspect(f, func(n ast.Node) bool {
			call, ok := n.(*ast.CallExpr)
			if !ok {
				return true
			}
			sel, ok := call.Fun.(*ast.SelectorExpr)
			if !ok || sel.Sel.Name != "ApplyDamage" || len(call.Args) != 2 {
				return true
			}
			found++
			if !allowed[rel] {
				t.Errorf("%s: a monster hub ApplyDamage outside damageMonsterWatched -- call damageMonsterWatched so the death reaches the watchers before the blow too",
					fset.Position(call.Pos()))
			}
			return true
		})
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if found < 2 {
		t.Fatalf("the guard found %d monster ApplyDamage calls, want at least aoi.go's and gm.go's: the probe is broken", found)
	}
}
