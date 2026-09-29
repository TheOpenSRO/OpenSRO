package session

import (
	"context"
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/character"
)

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
	// Keep the length-prefixed error + the first 24 body bytes only.
	old := full[:len(full)-(len(full)-2-24)]
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
	// Keep only the 48 body bytes before the mana pair: the rest must still decode.
	short := encoded[:2+48]
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

// The character rows -- Str/Int, the stat-point pool, both attack ranges and
// the magical defence -- are the third appended tail: they must round-trip,
// and a 56-byte result from an older server must still decode with them 0.
func TestCharacterStatsResultCarriesCharacterRows(t *testing.T) {
	in := &CharacterStatsResult{
		Gold: 1267, HP: 185, MaxHP: 214, PhysAttack: 14, PhysDefense: 6,
		Level: 2, Exp: 3, ExpToNext: 470, SkillPoints: 9, MP: 214, MaxMP: 214,
		Str: 21, Int: 21, StatPoints: 3,
		PhysAttackMin: 12, MagAttackMin: 0, MagAttackMax: 0, MagDefense: 4,
	}
	encoded := in.Encode()
	if got := len(encoded) - 2; got != 88 {
		t.Fatalf("body is %d bytes, want 88", got)
	}
	out, err := DecodeCharacterStatsResult(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if *out != *in {
		t.Fatalf("round trip changed the result:\n got %+v\nwant %+v", out, in)
	}
	old, err := DecodeCharacterStatsResult(encoded[:2+56])
	if err != nil {
		t.Fatalf("decoding a 56-byte result: %v", err)
	}
	if old.MaxMP != 214 || old.Level != 2 {
		t.Errorf("older result lost its head: %+v", old)
	}
	if old.Str != 0 || old.StatPoints != 0 || old.PhysAttackMin != 0 || old.MagDefense != 0 {
		t.Errorf("older result should leave the character rows at 0: %+v", old)
	}
}

// The berserk orb count is the fourth tail (round 629): it round-trips, an
// 84-byte result from an older server decodes with it 0, and the builder takes
// it from the character's persisted _CHAR.RemainHwanCount -- so the player
// block's orbs are right at world entry, before any blow.
func TestCharacterStatsResultCarriesHwanCount(t *testing.T) {
	in := &CharacterStatsResult{HP: 10, MaxHP: 10, Level: 3, Str: 22, Int: 21, HwanCount: 4}
	encoded := in.Encode()
	out, err := DecodeCharacterStatsResult(encoded)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.HwanCount != 4 {
		t.Fatalf("HwanCount did not survive: got %d, want 4", out.HwanCount)
	}
	old, err := DecodeCharacterStatsResult(encoded[:2+84])
	if err != nil {
		t.Fatalf("decoding an 84-byte result: %v", err)
	}
	if old.HwanCount != 0 || old.Str != 22 {
		t.Fatalf("an 84-byte result should keep the rows and leave HwanCount 0: %+v", old)
	}
	built, err := buildCharacterStats(context.Background(), &character.Character{ID: 7, Level: 3, HP: 10, Str: 22, Int: 21, HwanCount: 5}, 7, nil, nil, nil, nil)
	if err != nil {
		t.Fatalf("buildCharacterStats: %v", err)
	}
	if built.HwanCount != 5 {
		t.Fatalf("buildCharacterStats: HwanCount %d, want the character's 5", built.HwanCount)
	}
}

func TestSpendStatPointsRequestRoundTrip(t *testing.T) {
	in := &SpendStatPointsRequest{Name: "Aria", Str: 2, Int: 1}
	out, err := DecodeSpendStatPointsRequest(in.Encode())
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	if *out != *in {
		t.Fatalf("round trip changed the request: got %+v want %+v", out, in)
	}
}
