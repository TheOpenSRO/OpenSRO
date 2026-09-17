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
