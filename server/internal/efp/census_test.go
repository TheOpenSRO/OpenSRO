package efp

import (
	"os"
	"strings"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/pk2"
)

// TestRetailCensus runs the coverage census over the player's own
// Particles.pk2 when SRREVAMP_PARTICLES_PK2 points at it, and is skipped
// otherwise (CI has no game data). The targets are round 619's: at least 98%
// of files parse their header, and every file whose header parses decodes to
// the end of its root node. Run it with -v to see the report.
func TestRetailCensus(t *testing.T) {
	path := os.Getenv("SRREVAMP_PARTICLES_PK2")
	if path == "" {
		t.Skip("SRREVAMP_PARTICLES_PK2 not set; the census needs the player's Particles.pk2")
	}
	a, err := pk2.Open(path)
	if err != nil {
		t.Fatalf("opening %s: %v", path, err)
	}
	defer a.Close()
	root, err := a.ReadDir()
	if err != nil {
		t.Fatal(err)
	}
	c := NewCensus()
	var walk func([]pk2.Entry, string)
	walk = func(es []pk2.Entry, prefix string) {
		for _, e := range es {
			if e.Name == "." || e.Name == ".." {
				continue
			}
			p := e.Name
			if prefix != "" {
				p = prefix + "\\" + e.Name
			}
			if e.IsDir {
				kids, err := a.ReadDirAt(e)
				if err != nil {
					t.Fatalf("reading %s: %v", p, err)
				}
				walk(kids, p)
				continue
			}
			if strings.HasSuffix(strings.ToLower(p), ".efp") {
				data, err := a.ReadFile(e)
				if err != nil {
					t.Fatalf("reading %s: %v", p, err)
				}
				c.Add(p, data)
			}
		}
	}
	walk(root, "")
	var sb strings.Builder
	c.Report(&sb)
	t.Log("\n" + sb.String())
	if c.Files == 0 {
		t.Fatal("no .efp files found; is this Particles.pk2?")
	}
	if pct(c.HeaderOK, c.Files) < 98 {
		t.Errorf("headers parsed %d of %d (%.1f%%), want >= 98%%", c.HeaderOK, c.Files, pct(c.HeaderOK, c.Files))
	}
	if c.Decoded() != c.HeaderOK {
		t.Errorf("%d files parse their header but only %d decode", c.HeaderOK, c.Decoded())
	}
}
