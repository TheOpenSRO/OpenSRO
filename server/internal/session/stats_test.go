package session

import "testing"

func TestCharacterStatsResultRoundTrip(t *testing.T) {
	in := &CharacterStatsResult{
		Gold: 5000, HP: 94, MaxHP: 140, PhysAttack: 16, PhysDefense: 3,
		Level: 2, Exp: 130, ExpToNext: 470, SkillPoints: 14,
	}
	out, err := DecodeCharacterStatsResult(in.Encode())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if *out != *in {
		t.Fatalf("round trip changed the result:\n got %+v\nwant %+v", out, in)
	}
}

// An older 24-byte result (before the level/exp/SP tail) must still decode,
// leaving the new fields zero rather than erroring.
func TestCharacterStatsResultBackCompat(t *testing.T) {
	full := (&CharacterStatsResult{Gold: 1, HP: 2, MaxHP: 3, PhysAttack: 4, PhysDefense: 5,
		Level: 9, Exp: 9, ExpToNext: 9, SkillPoints: 9}).Encode()
	// Trim the 24-byte tail (keep the length-prefixed error + the first 24).
	old := full[:len(full)-24]
	out, err := DecodeCharacterStatsResult(old)
	if err != nil {
		t.Fatalf("decode of 24-byte result: %v", err)
	}
	if out.Gold != 1 || out.MaxHP != 3 || out.PhysDefense != 5 {
		t.Fatalf("core fields wrong after trim: %+v", out)
	}
	if out.Level != 0 || out.Exp != 0 || out.SkillPoints != 0 {
		t.Fatalf("appended fields should be zero on an old result: %+v", out)
	}
}
