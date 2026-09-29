package gm

import (
	"context"
	"strings"
	"testing"
)

type fakeSpeed struct {
	factor float64
	calls  int
}

func (f *fakeSpeed) SetGMSpeed(_ int64, x float64) uint32 {
	f.calls++
	f.factor = x
	return uint32(50*x + 0.5)
}

func (f *fakeSpeed) GMSpeed(int64) (float64, uint32) { return f.factor, uint32(50*f.factor + 0.5) }

// /speed (OURS, round 636): the multiplier's bounds and words, and the
// refusals that change nothing.
func TestSpeedCommand(t *testing.T) {
	sp := &fakeSpeed{factor: 1}
	d := &Deps{Speed: sp}
	in := Actor{CharacterID: 7, Zone: "jangan"}
	for _, c := range []struct {
		line    string
		refused bool
		factor  float64
		text    string
	}{
		{"/speed 2.5", false, 2.5, "run speed 125 (x2.5)"},
		{"/speed x4", false, 4, "run speed 200 (x4)"},
		{"/speed", false, 4, "run speed 200 (x4)"},
		{"/speed off", false, 1, "speed multiplier off: run speed 50"},
		{"/speed 11", true, 1, ""},
		{"/speed 0.05", true, 1, ""},
		{"/speed fast", true, 1, ""},
		{"/speed 2 3", true, 1, ""},
	} {
		res := d.Run(context.Background(), in, c.line)
		if res.Refused != c.refused || sp.factor != c.factor || (c.text != "" && res.Text != c.text) {
			t.Errorf("%s: %+v, factor %v; want refused %v factor %v %q", c.line, res, sp.factor, c.refused, c.factor, c.text)
		}
	}
	if res := d.Run(context.Background(), Actor{CharacterID: 7}, "/speed 2"); !res.Refused {
		t.Error("/speed outside the world accepted")
	}
	if res := (&Deps{}).Run(context.Background(), in, "/speed 2"); !res.Refused {
		t.Error("/speed with no control accepted")
	}
	if !strings.Contains(Help, "/speed") {
		t.Error("Help does not list /speed")
	}
}
