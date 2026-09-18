package proto

import "testing"

// The mask is the binary's: `and eax,0x7ff` at 0x0050ef13.
func TestDispatchMaskIsElevenBits(t *testing.T) {
	if DispatchMask != 0x7ff {
		t.Errorf("DispatchMask = %#x, want 0x7ff", DispatchMask)
	}
	if idx, ok := DispatchIndex(0xB470); !ok || idx != 0x470 {
		t.Errorf("DispatchIndex(0xB470) = (%#x, %v), want (0x470, true)", idx, ok)
	}
	// Bit 0x800 set: the dispatcher's `cmp cx,ax` fails and the table is
	// never indexed.
	if _, ok := DispatchIndex(0x7C00); ok {
		t.Error("an opcode with bit 0x800 set must not be reported as dispatched")
	}
	if _, ok := DispatchIndex(0xBC80); ok {
		t.Error("0xBC80 (the DB job result) has bit 0x800 set and takes the fallback path")
	}
}

// Every academy request reaches the same handler slot as its reply. This is the
// relation that let the server's table be lined up against the client's
// handlers, and it is checked here on the four pairs that were read.
func TestAcademyRequestAndAckShareTheirSlot(t *testing.T) {
	for _, tc := range []struct {
		name     string
		req, ack uint16
		slot     uint16
	}{
		{"open", OpAcademyOpenRequest, OpAcademyOpenAck, 0x470},
		{"disband", OpAcademyDisbandRequest, OpAcademyDisbandAck, 0x471},
		{"invite", OpAcademyInviteRequest, OpAcademyInviteAck, 0x472},
		{"graduation", OpAcademyGraduationRequest, OpAcademyGraduationAck, 0x475},
	} {
		ri, rok := DispatchIndex(tc.req)
		ai, aok := DispatchIndex(tc.ack)
		if !rok || !aok || ri != ai || ri != tc.slot {
			t.Errorf("%s: request %#x -> (%#x, %v), ack %#x -> (%#x, %v), want both %#x",
				tc.name, tc.req, ri, rok, tc.ack, ai, aok, tc.slot)
		}
		if tc.req&0xF000 != 0x7000 || tc.ack&0xF000 != 0xB000 {
			t.Errorf("%s: request %#x and ack %#x are not the read 0x7xxx/0xBxxx pair",
				tc.name, tc.req, tc.ack)
		}
	}
}

// The rule holds for every academy pair that was read from both sides.
func TestReplyOpcodeMatchesTheReadPairs(t *testing.T) {
	for _, tc := range []struct{ req, ack uint16 }{
		{OpAcademyOpenRequest, OpAcademyOpenAck},
		{OpAcademyDisbandRequest, OpAcademyDisbandAck},
		{OpAcademyInviteRequest, OpAcademyInviteAck},
		{OpAcademyGraduationRequest, OpAcademyGraduationAck},
	} {
		got, ok := ReplyOpcode(tc.req)
		if !ok || got != tc.ack {
			t.Errorf("ReplyOpcode(%#x) = (%#x, %v), want (%#x, true)", tc.req, got, ok, tc.ack)
		}
	}
	if _, ok := ReplyOpcode(0x7C00); ok {
		t.Error("a request with bit 0x800 set never reaches the table, so it has no table reply")
	}
	// The rule is 0xB000 | the eleven bits, not "flip the top nibble". 0x7255
	// keeps bit 0x800 clear, so it dispatches and its reply is 0xB255.
	if got, ok := ReplyOpcode(0x7255); !ok || got != 0xB255 {
		t.Errorf("ReplyOpcode(0x7255) = (%#x, %v), want (0xB255, true)", got, ok)
	}
	// 0x7A55 does carry bit 0x800 (0xA is 1010), so it takes the fallback and
	// has no table reply. This case is here because the first version of this
	// test asserted the opposite and the run caught it.
	if _, ok := ReplyOpcode(0x7A55); ok {
		t.Error("0x7A55 carries bit 0x800 and must not be reported as dispatched")
	}
}

// The stat-point opcodes reach dispatch slots 0x050 and 0x051, which is where
// the two handlers that call GObjPC_SpendStatPoints sit.
func TestStatPointOpcodesReachTheirHandlers(t *testing.T) {
	for _, tc := range []struct {
		name     string
		req, ack uint16
		slot     uint16
	}{
		{"strength", OpIncreaseStrRequest, OpIncreaseStrAck, 0x050},
		{"intellect", OpIncreaseIntRequest, OpIncreaseIntAck, 0x051},
	} {
		ri, rok := DispatchIndex(tc.req)
		ai, aok := DispatchIndex(tc.ack)
		if !rok || !aok || ri != tc.slot || ai != tc.slot {
			t.Errorf("%s: request %#x -> (%#x, %v), ack %#x -> (%#x, %v), want both %#x",
				tc.name, tc.req, ri, rok, tc.ack, ai, aok, tc.slot)
		}
		if got, ok := ReplyOpcode(tc.req); !ok || got != tc.ack {
			t.Errorf("%s: ReplyOpcode(%#x) = (%#x, %v), want (%#x, true)", tc.name, tc.req, got, ok, tc.ack)
		}
	}
	// Strength and Intellect are adjacent and must not be swapped: the
	// handler at 0x050 is the one logging charData+0x74.
	if OpIncreaseIntRequest != OpIncreaseStrRequest+1 {
		t.Errorf("the two requests are adjacent in the engine: %#x and %#x",
			OpIncreaseStrRequest, OpIncreaseIntRequest)
	}
}
