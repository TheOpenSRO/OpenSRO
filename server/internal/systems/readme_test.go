package systems

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// TestServerReadmeIsCurrent keeps server/README.md honest the way
// TestSystems keeps docs/SYSTEMS.md honest: every tool under cmd/ and every
// flag cmd/server registers must be mentioned in it. A tool or flag added
// without a README line fails the build rather than rotting quietly.
func TestServerReadmeIsCurrent(t *testing.T) {
	serverDir := filepath.Join("..", "..")
	readmeBytes, err := os.ReadFile(filepath.Join(serverDir, "README.md"))
	if err != nil {
		t.Fatalf("server/README.md must exist: %v", err)
	}
	readme := string(readmeBytes)

	entries, err := os.ReadDir(filepath.Join(serverDir, "cmd"))
	if err != nil {
		t.Fatalf("listing cmd/: %v", err)
	}
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		if !strings.Contains(readme, "`"+e.Name()+"`") {
			t.Errorf("server/README.md does not mention cmd/%s (add it to the tools table)", e.Name())
		}
	}

	mainSrc, err := os.ReadFile(filepath.Join(serverDir, "cmd", "server", "main.go"))
	if err != nil {
		t.Fatalf("reading cmd/server/main.go: %v", err)
	}
	flagRe := regexp.MustCompile(`flag\.(?:String|Bool|Int|Int64|Float64|Duration)\("([a-z][a-z0-9-]*)"`)
	for _, m := range flagRe.FindAllStringSubmatch(string(mainSrc), -1) {
		if !strings.Contains(readme, "-"+m[1]) {
			t.Errorf("server/README.md does not mention the -%s flag", m[1])
		}
	}
}
