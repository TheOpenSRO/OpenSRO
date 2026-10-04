package charmsg

import "testing"

func TestExpGainRoundTrip(t *testing.T) {
	for _, g := range []ExpGain{
		{Source: 4321, Exp: 1170, SkillExp: 249},
		{Source: 4321, Exp: 5000, SkillExp: 10, LevelUp: true, StatPoints: 3},
		{Exp: -2000},
	} {
		b := g.Encode()
		want := 21
		if g.LevelUp {
			want = 23
		}
		if len(b) != want {
			t.Errorf("%+v encodes to %d bytes, want %d", g, len(b), want)
		}
		got, err := DecodeExpGain(b)
		if err != nil || got != g {
			t.Errorf("round trip %+v -> %+v (%v)", g, got, err)
		}
	}
	if _, err := DecodeExpGain(make([]byte, 20)); err == nil {
		t.Error("a 20-byte 0x3056 decoded")
	}
	if _, err := DecodeExpGain(ExpGain{Flags: 0x10}.Encode()); err == nil {
		t.Error("training-camp flags decoded without their fields")
	}
}

func TestGoldRoundTrip(t *testing.T) {
	total, show, err := DecodeGold(EncodeGold(1234567, true))
	if err != nil || total != 1234567 || !show {
		t.Fatalf("%d %v %v", total, show, err)
	}
	if _, _, err := DecodeGold([]byte{2, 0, 0, 0, 0, 0, 0, 0, 0, 0}); err == nil {
		t.Fatal("kind 2 read as gold")
	}
}
