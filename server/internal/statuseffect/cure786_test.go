package statuseffect

import "testing"

// Round 786: the cure pills' runs through FUN_004a56c0 (READ, asm
// 0x4a56c0..0x4a59cb). The item path passes a third kind of rule the skills
// never pass: CGItemExpendable slot 308 (0x49b7bd..0x49b7d8) hands the
// universal pill's six Params as the function's SECOND argument, and every
// active slot 0..5 is a candidate for it (0x4a573e `cmp [esp+0x48],ecx` /
// 0x4a5744 `cmp bl,0x5; ja`).

func universal(strength uint32) CureRule {
	return CureRule{HasElem: true, Elem: [6]uint32{strength, strength, strength, strength, strength, strength}}
}

// TestRound786UniversalPillWindsTheElementalSixBack: each elemental state's
// start moves back by its own Param x the slot's duration unit (0x4a58b4..
// 0x4a58e6: the jump table at 0x4a59d0 picks Param[slot], 0x410b40 turns it
// into ms), and a state the move puts past its duration ends.
func TestRound786UniversalPillWindsTheElementalSixBack(t *testing.T) {
	var h Holder
	h.Put(Record{Code: "bu", Slot: SlotBurn, StartMs: 1000, DurationMs: 30000})   // 750 ms a point
	h.Put(Record{Code: "ps", Slot: SlotPoison, StartMs: 1000, DurationMs: 60000}) // 1000 ms a point
	h.Put(Record{Code: "se", Slot: 6, Level: 2, StartMs: 1000, DurationMs: 9000}) // sleep: not a candidate
	now := uint32(5000)
	if !h.Cure(universal(36), now, nil, nil) {
		t.Fatal("the burn should end: 4 s in, 36 x 750 = 27 s back, past its 30 s")
	}
	if h.Holds(SlotBurn) {
		t.Fatal("burn still held")
	}
	p, ok := h.Get(SlotPoison)
	if !ok {
		t.Fatal("poison ended: 4 s in, 36 s back is 40 s of its 60 s")
	}
	want := uint32(1000)
	want -= 36000
	if p.StartMs != want {
		t.Fatalf("poison start %d, want %d (wound back 36 x 1000 ms)", int32(p.StartMs), int32(want))
	}
	if !h.Holds(6) {
		t.Fatal("sleep (slot 6) is not one of the six: the pill must leave it")
	}
}

// TestRound786CureExpiryIsStrict: the state ends only when the elapsed time
// is ABOVE its duration -- 0x4a590b `cmp eax,[esi+0xc]` / 0x4a590e `jbe`
// keeps it at exactly its duration (the same comparison Expired keeps).
func TestRound786CureExpiryIsStrict(t *testing.T) {
	var h Holder
	h.Put(Record{Code: "bu", Slot: SlotBurn, StartMs: 10000, DurationMs: 7500})
	// 10 points x 750 = 7500 back: elapsed = 0 + 7500 = exactly the duration.
	h.Cure(universal(10), 10000, nil, nil)
	if !h.Holds(SlotBurn) {
		t.Fatal("elapsed == duration must keep the state (jbe)")
	}
	h.Cure(universal(0), 10001, nil, nil) // a zero Param is skipped outright (0x4a58cf `test edi,edi; je`)
	r, _ := h.Get(SlotBurn)
	if r.StartMs != 10000-7500 {
		t.Fatalf("a zero Param moved the start to %d", r.StartMs)
	}
	h.Cure(universal(1), 10000, nil, nil)
	if h.Holds(SlotBurn) {
		t.Fatal("one more point puts it past its duration")
	}
}

// TestRound786CurtExpiryIsStrict: the skills' curt path shares the same end
// test (both join at 0x4a58ef), so a curt that lands a state exactly on its
// duration keeps it too.
func TestRound786CurtExpiryIsStrict(t *testing.T) {
	var h Holder
	h.Put(Record{Code: "bu", Slot: SlotBurn, StartMs: 1000, DurationMs: 3000})
	h.Cure(CureRule{HasCurt: true, CurtMask: MaskForSlot(SlotBurn), CurtStrength: 4}, 1000, nil, nil)
	if !h.Holds(SlotBurn) {
		t.Fatal("4 x 750 = 3000 back at elapsed 0 is exactly the duration: kept")
	}
}

// TestRound786PurificationPillRule: the curl path with rcur 1 -- one random
// candidate among the held states the mask names, chance Param3, level cap
// Param2 (slot 308's kind-1 call, 0x49b7f4..0x49b85d).
func TestRound786PurificationPillRule(t *testing.T) {
	rule := CureRule{HasCurl: true, CurlMask: 0x17fafc0, CurlChance: 100, CurlLevel: 3, Rcur: 1}
	var h Holder
	h.Put(Record{Code: "st", Slot: 14, Level: 1, StartMs: 0, DurationMs: 9000}) // stun: bit 14 is not in the mask
	h.Put(Record{Code: "se", Slot: 6, Level: 2, StartMs: 0, DurationMs: 9000})
	h.Put(Record{Code: "bu", Slot: SlotBurn, StartMs: 0, DurationMs: 9000}) // elemental: not in the mask
	var chances []int
	roll := func(c int) bool { chances = append(chances, c); return c >= 100 }
	if !h.Cure(rule, 10, roll, func([]int) {}) {
		t.Fatal("the sleep (level 2 <= 3, chance 100) should end")
	}
	if h.Holds(6) || !h.Holds(14) || !h.Holds(SlotBurn) {
		t.Fatalf("only the sleep may end: sleep %v stun %v burn %v", h.Holds(6), h.Holds(14), h.Holds(SlotBurn))
	}
	if len(chances) != 1 || chances[0] != 100 {
		t.Fatalf("rolled %v, want one roll at 100", chances)
	}
	// A level above the cap divides the chance: 100 / (5 - 3) = 50.
	h.Put(Record{Code: "ds", Slot: 16, Level: 5, StartMs: 0, DurationMs: 9000})
	chances = nil
	h.Cure(rule, 10, roll, func([]int) {})
	if len(chances) != 1 || chances[0] != 50 || !h.Holds(16) {
		t.Fatalf("level 5 over cap 3: rolled %v (want [50]), held %v", chances, h.Holds(16))
	}
}

// TestRound786PurificationTriesOneCandidate: rcur 1 caps the walk at one
// state even when several are held (0x4a57b3 `cmp ebx,eax; jbe` keeps
// min(n, rcur[0])).
func TestRound786PurificationTriesOneCandidate(t *testing.T) {
	rule := CureRule{HasCurl: true, CurlMask: 0x17fafc0, CurlChance: 100, CurlLevel: 12, Rcur: 1}
	var h Holder
	h.Put(Record{Code: "se", Slot: 6, Level: 2, DurationMs: 9000})
	h.Put(Record{Code: "rt", Slot: 7, Level: 2, DurationMs: 9000})
	h.Put(Record{Code: "fe", Slot: 9, Level: 2, DurationMs: 9000})
	h.Cure(rule, 10, func(int) bool { return true }, func([]int) {})
	held := 0
	for _, s := range []int{6, 7, 9} {
		if h.Holds(s) {
			held++
		}
	}
	if held != 2 {
		t.Fatalf("%d of 3 held after one pill, want 2", held)
	}
}
