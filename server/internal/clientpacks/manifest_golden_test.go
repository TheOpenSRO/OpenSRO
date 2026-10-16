package clientpacks

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// The vector file client/scripts/update/pack_manifest_test.gd reads too:
// both sides encode the same fields to the same bytes and decode the same
// bytes to the same fields (round 789, lane U).
func goldenPath() string {
	return filepath.Join("..", "..", "..", "client", "scripts", "net", "testdata", "client_packs_golden.json")
}

type goldenPack struct {
	Name   string `json:"name"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
	URL    string `json:"url"`
}

type goldenVector struct {
	Name   string `json:"name"`
	Error  bool   `json:"error"`
	Hex    string `json:"hex"`
	Fields struct {
		Required    bool         `json:"required"`
		LocalExtras bool         `json:"local_extras"`
		HTTPPort    uint16       `json:"http_port"`
		Packs       []goldenPack `json:"packs"`
	} `json:"fields"`
}

func goldenBytes(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(strings.NewReplacer(" ", "", "|", "").Replace(s))
	if err != nil {
		t.Fatalf("bad hex %q: %v", s, err)
	}
	return b
}

func TestManifestGolden(t *testing.T) {
	raw, err := os.ReadFile(goldenPath())
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Opcodes   map[string]uint16 `json:"opcodes"`
		Manifests []goldenVector    `json:"manifests"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		t.Fatal(err)
	}
	if file.Opcodes["client_packs_request"] != 0x0009 || file.Opcodes["client_packs"] != 0x000A {
		t.Fatalf("opcodes %v", file.Opcodes)
	}
	good, bad := 0, 0
	for _, v := range file.Manifests {
		data := goldenBytes(t, v.Hex)
		got, err := Decode(data)
		if v.Error {
			bad++
			if err == nil {
				t.Errorf("%s: decoded, want an error", v.Name)
			}
			continue
		}
		good++
		if err != nil {
			t.Errorf("%s: %v", v.Name, err)
			continue
		}
		want := Manifest{Required: v.Fields.Required, LocalExtras: v.Fields.LocalExtras, HTTPPort: v.Fields.HTTPPort}
		for _, p := range v.Fields.Packs {
			gp := Pack{Name: p.Name, Size: p.Size, URL: p.URL}
			h, err := hex.DecodeString(p.SHA256)
			if err != nil || len(h) != 32 {
				t.Fatalf("%s: sha256 %q", v.Name, p.SHA256)
			}
			copy(gp.SHA256[:], h)
			want.Packs = append(want.Packs, gp)
		}
		if !reflect.DeepEqual(got, want) {
			t.Errorf("%s: decoded %+v, want %+v", v.Name, got, want)
		}
		enc, err := want.Encode()
		if err != nil {
			t.Errorf("%s: encode: %v", v.Name, err)
			continue
		}
		if hex.EncodeToString(enc) != hex.EncodeToString(data) {
			t.Errorf("%s: encoded %x, want %x", v.Name, enc, data)
		}
	}
	if good < 5 || bad < 20 {
		t.Fatalf("only %d good and %d bad vectors read", good, bad)
	}
}

func TestValidName(t *testing.T) {
	for _, ok := range []string{"z_akatsuki.pk3", "A.ZIP", "pack-1.0.pk3", "0.pk3", "_.zip"} {
		if why := ValidName(ok); why != "" {
			t.Errorf("%q refused: %s", ok, why)
		}
	}
	for _, bad := range []string{"", "a", ".pk3", "a.pk2", "a.pk3x", "a/b.pk3", `a\b.pk3`, "../a.pk3", "a..b.pk3",
		"c:a.pk3", "a b.pk3", "Data.pk3", "PARTICLES.zip", "-" + strings.Repeat("x", 61) + ".pk3", "a\x00.pk3", "ä.pk3"} {
		if ValidName(bad) == "" {
			t.Errorf("%q accepted", bad)
		}
	}
}

func TestValidURL(t *testing.T) {
	for _, ok := range []string{"https://cdn.example.com/a.pk3", "http://10.0.0.1:15780/packs/a.pk3", "https://x/a.pk3?sig=1"} {
		if why := ValidURL(ok); why != "" {
			t.Errorf("%q refused: %s", ok, why)
		}
	}
	for _, bad := range []string{"", "ftp://x/a", "https://", "https://u@x/a", "https://x/a#f", "file:///etc/passwd",
		"https://x/a b", "https://x/\x7f", "//x/a", "https://x/" + strings.Repeat("a", MaxURLLen)} {
		if ValidURL(bad) == "" {
			t.Errorf("%q accepted", bad)
		}
	}
}
