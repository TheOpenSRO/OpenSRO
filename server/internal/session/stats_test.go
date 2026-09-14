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

// The mana pair is appended to the wire format, so it must survive a round
// trip and an older 48-byte result must still decode with mana left at 0.
func TestCharacterStatsResultCarriesMana(t *testing.T) {
	r := &CharacterStatsResult{HP: 100, MaxHP: 100, Level: 1, MP: 119, MaxMP: 120}
	encoded := r.Encode()
	back, err := DecodeCharacterStatsResult(encoded)
	if err != nil {
		t.Fatalf("decoding: %v", err)
	}
	if back.MP != 119 || back.MaxMP != 120 {
		t.Errorf("mana did not survive: got MP=%d MaxMP=%d, want 119/120", back.MP, back.MaxMP)
	}
	// Truncate the mana pair off the end: the rest must still decode.
	short := encoded[:len(encoded)-8]
	back, err = DecodeCharacterStatsResult(short)
	if err != nil {
		t.Fatalf("decoding a mana-less result: %v", err)
	}
	if back.MaxHP != 100 || back.Level != 1 {
		t.Errorf("older result lost its head: %+v", back)
	}
	if back.MP != 0 || back.MaxMP != 0 {
		t.Errorf("older result should leave mana at 0, got %d/%d", back.MP, back.MaxMP)
	}
}
