package efp

import (
	"math"
	"testing"
)

// Header variants (round 619), on synthetic buffers only. The client's loader
// FUN_00cb8d70 reads an f32 after the magic when the version is >= "0012" and
// three u32 more when it is >= "0013"; then the root node's u32 id and name.

func appendF32(b []byte, v float32) []byte { return appendU32(b, math.Float32bits(v)) }

// headerFor builds magic + version + the version's header + root id + name +
// controller count 1 + one "NormalTimeLife" controller (which carries no
// data), the smallest root the flat walk accepts.
func headerFor(version, name string) []byte {
	var buf []byte
	buf = append(buf, []byte(magic+" "+version)...)
	switch version {
	case "0012":
		buf = appendF32(buf, 0.4)
	case "0013":
		buf = appendF32(buf, 0.5)
		buf = appendU32(buf, 0)
		buf = appendU32(buf, 0)
		buf = appendU32(buf, 0)
	}
	buf = appendU32(buf, 101) // root node id
	buf = appendLenPrefixed(buf, name)
	buf = appendU32(buf, 1)
	buf = appendLenPrefixed(buf, "NormalTimeLife")
	buf = appendLenPrefixed(buf, "StaticEmit")
	buf = append(buf, make([]byte, 20)...)
	return buf
}

func TestParseHeaderVariants(t *testing.T) {
	for _, v := range []string{"0010", "0011", "0012", "0013"} {
		e, err := Parse(headerFor(v, "fx"))
		if err != nil {
			t.Errorf("version %s: Parse: %v", v, err)
			continue
		}
		if e.Version != v || e.Name != "fx" || e.Count != 1 {
			t.Errorf("version %s: got version %q name %q count %d", v, e.Version, e.Name, e.Count)
		}
		if len(e.Entries) == 0 || e.Entries[0].Name != "NormalTimeLife" {
			t.Errorf("version %s: entries %+v", v, e.Entries)
		}
	}
}

// Retail root names include "11111", "-..." and names with spaces; the header
// name rule is any printable length-prefixed string.
func TestParseRelaxedEffectName(t *testing.T) {
	// The last is EUC-KR bytes, as system_levelup.efp's root name is.
	for _, name := range []string{"11111", "-fire", "big wave,2", "\xb7\xb9\xba\xa7\xbe\xf7"} {
		e, err := Parse(headerFor("0011", name))
		if err != nil {
			t.Errorf("name %q: Parse: %v", name, err)
			continue
		}
		if e.Name != name {
			t.Errorf("name %q: got %q", name, e.Name)
		}
	}
}

func TestParseRejectsVersion0000(t *testing.T) {
	if _, err := Parse(headerFor("0000", "fx")); err == nil {
		t.Fatal("version 0000 is not the node format; want an error")
	}
}
