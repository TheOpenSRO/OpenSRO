package proto

import "testing"

// Round 868: every game-world request reaches the same handler slot as the
// reply read for it (docs/protocol/game_worlds.md, forgotten_world.md), and the
// reply is the table's 0xB000 | index.
func TestGameWorldRequestsShareTheirReplySlot(t *testing.T) {
	for _, tc := range []struct {
		name     string
		req, ack uint16
		slot     uint16
	}{
		{"teleport", OpTeleportUse, OpTeleportUseAck, 0x05A},
		{"instance exit", OpInstanceExit, OpInstanceExitAck, 0x51D},
		{"recall list", OpPartyRecallList, OpPartyRecallListAck, 0x519},
		{"recall summon", OpPartyRecallSummon, OpPartyRecallSummonAck, 0x51A},
		{"recall answer", OpPartyRecallAnswer, OpPartyRecallAnswerAck, 0x51C},
	} {
		ri, rok := DispatchIndex(tc.req)
		ai, aok := DispatchIndex(tc.ack)
		if !rok || !aok || ri != ai || ri != tc.slot {
			t.Errorf("%s: request %#x -> (%#x, %v), ack %#x -> (%#x, %v), want both %#x",
				tc.name, tc.req, ri, rok, tc.ack, ai, aok, tc.slot)
		}
		if got, ok := ReplyOpcode(tc.req); !ok || got != tc.ack {
			t.Errorf("%s: ReplyOpcode(%#x) = (%#x, %v), want (%#x, true)", tc.name, tc.req, got, ok, tc.ack)
		}
	}
	// The pushes are server-initiated 0x3xxx words, not table replies.
	for _, op := range []uint16{OpEventZoneState, OpTimedJobPush} {
		if op&0xF000 != 0x3000 {
			t.Errorf("push %#x is not a 0x3xxx server push", op)
		}
	}
	if NoticeWordInstanceCloses != 0x0C1A || NoticeWordTriggerMessage != 0x0C1C {
		t.Error("the 0x300C sub-words are 0x0C1A (close warning) and 0x0C1C (trigger notice)")
	}
}
