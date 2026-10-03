package teleport

// The refusal codes of the teleport path, with the UIIT token each carries in
// docs/protocol/error_codes.md.
const (
	// ErrNotEnoughMoney: the character's gold is below the fee.
	// GObjPC::HandleTeleportUse (0x513590) sets it at 0x513749, and
	// CMainProcess::FUN_004f2b50 on its own teleport path after the evaluator.
	ErrNotEnoughMoney = 0x1c07 // UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY
	// ErrTradeCart: rule types 2 and 7 (IGObj::IHaveCart, vslot 187).
	ErrTradeCart = 0x1c10 // UIIT_MSG_INTERACTION_FAIL_CANT_USE_TELEPORT_WITH_TRADECART
	// ErrLevelRange: rule type 1. error_emitters.tsv lists FUN_00513a70 as
	// its only emitter.
	ErrLevelRange = 0x1c15 // UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT
	// ErrPvPState: rule type 3, the character's PvP state is one D1 bars.
	// error_codes.md has no row for 0x1c19, so its text is unknown.
	ErrPvPState = 0x1c19
	// ErrRocItem: rule types 4 and 5, the item in D1 not held.
	ErrRocItem = 0x1c23 // UIIT_MSG_QUEST_ROC_CANNOT_ENTRANCE
	// ErrRocJob: rule type 6. error_codes.md gives it the same token as 0x1c23.
	ErrRocJob = 0x1c24 // UIIT_MSG_QUEST_ROC_CANNOT_ENTRANCE
)

// PvPState is the character's PvP state, the byte at chardata+0xc (the
// PC's +0x30 is its chardata pointer), with the engine's own names
// (PvPSTATE_*, the string table at 0xc6404c that the state dump
// FUN_00567190 indexes by that byte -- docs/protocol/character_state.md,
// "The chardata offsets, from the index expressions"). Rule type 3 tests it.
type PvPState uint8

const (
	PvPNeutral   PvPState = 0 // PvPSTATE_NEUTRAL
	PvPAssaulter PvPState = 1 // PvPSTATE_ASSAULTER
	PvPMurderer  PvPState = 2 // PvPSTATE_MURDERER
)

// FeeWaiverLevel: a character below this level pays no fee. Both teleport
// paths read IGObj::GetMaxLevel (vslot 74, +0x128) and zero the fee unless it
// is above 20 -- `cmp al,0x14; ja; xor esi,esi` at 0x5136de in
// GObjPC::HandleTeleportUse (0x513590), and `if (bVar4 < 0x15)` in
// CMainProcess::FUN_004f2b50. (A second test, `cmp al,0xa` at 0x5136f0, can
// only zero a fee already zeroed.) OpenSRO has one Level and no level loss,
// so Level stands in for MaxLevel -- the two are equal unless a character lost
// levels, which OpenSRO cannot do. Disclosed.
const FeeWaiverLevel = 21

// Waiver says why a quoted fee is zero when the link has one.
type Waiver uint8

const (
	// WaiverNone: nothing was waived. The fee is the link's, which may be 0
	// (188 of the retail table's 292 links cost nothing).
	WaiverNone Waiver = iota
	// WaiverLevel: the engine's own rule, level below FeeWaiverLevel.
	WaiverLevel
	// WaiverGM: OWN DESIGN, the user's ask (2026-09-25): GM accounts always
	// travel free.
	WaiverGM
	// WaiverFlag: OWN DESIGN, the same ask: free for everyone while testing,
	// behind a server flag that defaults off.
	WaiverFlag
)

// QuoteFee is what using link costs a character, and why it is zero when the
// link has a fee. The engine's order is kept: the link's fee (word 1), then
// the level waiver; the two own-design waivers come after, so a character the
// engine already lets through free is reported as the engine's case.
//
// What is NOT modelled: the fortress tax the engine adds when the gate's vslot
// 276 says so (Fortress_TaxRatioAsFloat 0x486390, round 321) -- OpenSRO has no
// fortresses, so no gate is taxed. Disclosed.
func QuoteFee(link Link, level int, isGM, freeFlag bool) (fee int64, waiver Waiver) {
	switch {
	case link.Fee == 0:
		return 0, WaiverNone
	case level < FeeWaiverLevel:
		return 0, WaiverLevel
	case isGM:
		return 0, WaiverGM
	case freeFlag:
		return 0, WaiverFlag
	}
	return link.Fee, WaiverNone
}

// CheckRestrictions walks a link's restriction triples in order, as the
// server's evaluator FUN_00513a70 (0x513a70) does, and returns the first
// refusal code, or 0 when every rule passes. (The binary returns 1 for a pass;
// OpenSRO's refusal codes are never 0, so 0 reads as "no refusal".) The
// evaluator runs before the fee on CMainProcess::FUN_004f2b50's teleport path
// (call 0x4f2e24) and at 0x4f34a0, and in CGObjPC::vslot_309 (call 0x4ef7b9);
// each caller loads the PC into EBX (`mov ebx,ebp` just before the call), and
// every arm reads the character through it.
//
// The arms, read from 0x513a70 (the IGObj slots from igobj_vtable.md):
//
//	1: GetLevel (vslot 73) as a byte, compared UNSIGNED: below D1 (`jb`
//	   0x513b02) or above D2 (`jbe` 0x513b07 skips the refusal) -> 0x1c15.
//	2: IHaveCart (vslot 187) == 1 -> 0x1c10.
//	3: D1 has the bit for the character's PvP state -> 0x1c19:
//	   `mov eax,[ebx+0x30]` (the chardata pointer), `mov cl,[eax+0xc]`
//	   (PvPSTATE), `mov edx,1; shl edx,cl; test [esi+0x4],edx` (D1) at
//	   0x513b46..0x513b53, refusing unless the test is zero (`je` at
//	   0x513b56 skips the refusal). So D1 is a mask of barred states: bit 0
//	   NEUTRAL, bit 1 ASSAULTER, bit 2 MURDERER.
//	4: D1 != 0 and no item of ref object D1 in the inventory -> 0x1c23.
//	5: as 4, and the found item goes to FUN_004d9030 (unread).
//	6: D1 == D2 == 0 and GetJobState (vslot 71) != 4 -> 0x1c24; other data
//	   asserts and passes.
//	7: CGStorage::GetItem(8) returns an item whose vslot 0x41c answers 1,
//	   and IHaveCart == 1 -> 0x1c10.
//	any other type (0 included): no arm, passes.
//
// Where OpenSRO has the state, the arm is evaluated; where the outcome turns
// on state OpenSRO does not model, the rule refuses with the engine's code
// rather than guess (fail closed). Disclosed stand-ins:
//
//   - types 2 and 7 pass: OpenSRO has no trade carts (internal/cos is parked
//     "OpenSRO summons nothing"), so IHaveCart is never 1;
//   - type 3 is evaluated against pvp, which the caller supplies. OpenSRO
//     models no PvP state -- no PK system, and internal/duel's own-design duel
//     sets none -- so the caller passes PvPNeutral, a DISCLOSED stand-in, not
//     a read value. No retail link carries type 3 (0 of the 1,460 slots,
//     counted over /var/tmp/tables/teleportlink.txt, round 575);
//   - types 4 and 5 refuse when D1 is non-zero: the inventory is not consulted
//     here (the one retail link with them, GATE_RC_MOUNTAIN_GATE ->
//     GATE_RC_ROC_GATE, names item 23973, ITEM_QNO_RM_MEETROC_6_01);
//   - type 6 refuses on (0, 0): OpenSRO has no job state (internal/jobs is
//     parked).
//
// Enforcing the rules at all is a stand-in too. The evaluator enforces them
// only when the mode byte at link+8 is 0: after each rule it tests the byte
// (0x513ccf) and returns a failure only at 0; any non-zero value walks every
// rule and drops their failures (the result is reset to 1 per rule), then
// mode 1 asserts and returns 2 (0x513d35..0x513d65) and any other mode ends
// like a clean walk -- 1, or 0x1c23 from the post-pass over the byte vector
// the type-5 arm hands FUN_004d9030 (0x513c4b), which calls vslot 0x230 per
// byte (0x513d7d on; teleport_network.md, "The restriction triples are
// enforced"). Which value fills +8 was not read: the _REFTELELINK table loads
// through a reflective descriptor (FUN_0082d770 registers "_REFTELELINK" as
// CRefTeleLink, 0x30 bytes), not a parser this project has read, and the
// retail table's three columns between the fee and the first triple are 0 in
// all 292 rows. OpenSRO enforces the rules (mode 0) -- DISCLOSED, not read.
// A type-5 rule with a non-zero D1 refuses here, so nothing reaches a
// post-pass (with D1 0 the binary skips the arm and never calls FUN_004d9030,
// 0x513be4).
func CheckRestrictions(link Link, level int, pvp PvPState) uint16 {
	for _, r := range link.Rules {
		switch r.Type {
		case 1:
			lv := uint32(uint8(level)) // GetLevel returns a byte (`movzx eax,al`, 0x513afc)
			if lv < uint32(r.D1) || lv > uint32(r.D2) {
				return ErrLevelRange
			}
		case 3:
			// `shl edx,cl` on a 32-bit register takes the count mod 32.
			if uint32(r.D1)&(uint32(1)<<(uint(pvp)&31)) != 0 {
				return ErrPvPState
			}
		case 4, 5:
			if r.D1 != 0 {
				return ErrRocItem
			}
		case 6:
			if r.D1 == 0 && r.D2 == 0 {
				return ErrRocJob
			}
		}
	}
	return 0
}
