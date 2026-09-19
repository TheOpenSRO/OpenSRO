package systems

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

// The in-client Help window renders copies of docs/*.md that
// client/tools/bundle_docs.sh writes under client/docs/. The release build
// regenerates them, but a local Godot run shows the committed copies -- so a
// doc edited in docs/ without re-running the bundler would read differently
// in the client than in the repo. Keep the two identical.
func TestBundledClientDocsMatchSource(t *testing.T) {
	repoRoot := filepath.Join("..", "..", "..")
	for _, name := range []string{"DEBUG_TOOLS.md", "HELP_PLAYING.md"} {
		src, err := os.ReadFile(filepath.Join(repoRoot, "docs", name))
		if err != nil {
			t.Fatalf("reading docs/%s: %v", name, err)
		}
		bundled, err := os.ReadFile(filepath.Join(repoRoot, "client", "docs", name))
		if err != nil {
			t.Fatalf("reading client/docs/%s (run client/tools/bundle_docs.sh): %v", name, err)
		}
		if !bytes.Equal(src, bundled) {
			t.Errorf("client/docs/%s differs from docs/%s -- run client/tools/bundle_docs.sh and commit the result", name, name)
		}
	}
}
