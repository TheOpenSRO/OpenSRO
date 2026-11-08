package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// The player's dead state, the server half (round 549; the client half is
// round 548, docs/protocol/monster_ai.md "The player's dead state: the client
// half"). Until this round a monster's killing blow put the player back on
// its feet in the same call (monsterStrike's RespawnHP), so no player was ever
// dead on the wire. Behind cmd/server's -player-dead-state
// (OPENSRO_PLAYER_DEAD_STATE), OFF by default, a monster's kill now leaves the
// character in life state 2 (world.LifeDead) at HP 0, with its potion queue
// emptied and its keep-up cancelled; while dead its moves are neither stored
// nor relayed and its attacks, casts, items, pick-ups, duel blows, trade
// requests, zone changes and GM teleports are refused; the monster AI treats
// it as no target. It comes back through OpRevive and retail's two choices
// (round 665, "THE CHOICES" below): option 1 returns it to its return point,
// alive at the load path's trunc(0.4 x MaxHP), and option 2 -- level 10 or
// under only -- revives it where it lies, HP at 1 + trunc(0.4 x MaxHP) as
// the retail handler's arithmetic lands it (reviveHPDelta, round 550), MP at
// character.RespawnMP. Nothing revives it unasked: retail has no timed
// revive outside a fortress war, so round 549's 30 s in-place auto-revive
// is gone (it revived players among their killers, who killed them again).
// With the flag off a kill still respawns at once, but at the return point
// since round 665 (returnAfterKill), not in place; the one other
// flag-independent piece is the entry revive of a stored HP 0
// (handleEnterWorld, the last stand-in below).
//
// GROUNDING, re-read on the RE box for this round (2026-09-24):
//
//   - Life state 1 ALIVE / 2 DEAD: world.LifeAlive / world.LifeDead, from
//     docs/protocol/character_state.md rounds 411-413 (the typed receiver).
//   - The retail resurrect request, GObjPC_HandleResurrectMsg_053 (0x50fee0):
//     one u8 option; acts only in life state 2 (`cmp al,0x2` at 0x510077);
//     refuses during a siege countdown above 0xa5; then (a) death cause
//     [this+0x1cb4] == 2 (leveldata.DeathCauseNoPenalty -- not a monster's
//     kill, which is 3) or (b) option 2 with IGObj::GetMaxLevel (+0x128) at
//     most 10 (`cmp al,0xa; ja` at 0x51017f) -> GObjPC::Revive(1) (`push 0x1;
//     call 0x4df290` at 0x5100e3) and ApplyHPMPDelta(GetParam(3) x 0.4,
//     GetParam(4) x 0.4, 8) (`call 0x4a86a0` at 0x51015d), the 0.4 being
//     `fmul QWORD ds:0xb460f0` at 0x5100fa / 0x51019e -- 0xb460f0 reads
//     `00 00 00 a0 99 99 d9 3f` = 0x3FD99999A0000000 = 0.4000000059604645,
//     the FLOAT 0.4 widened to a double (round 550's correction of "the
//     double 0.4"; character.RespawnFraction says why the exact 0.4 gives
//     the same integer) -- and each product TRUNCATED: `fnstcw; or eax,0xc00;
//     fldcw; fistp` sets rounding control 11, toward zero -- on path (a) at
//     0x510102..0x510122 (HP) and 0x510136..0x51014e (MP); path (b) has its
//     own identical pair, 0x5101a6 fnstcw / 0x5101af or eax,0xc00 / 0x5101be
//     fldcw / 0x5101c6 fistp (HP), then the MP `fmul` at 0x5101d4 and its
//     fnstcw at 0x5101da (round 551 named the paths; round 550 cited only
//     (a)'s); (c) option 1 -> Revive(0), the return-point path, and
//     GameEventLog 0x15/2.
//   - GObjPC::ApplyHPMPDelta (0x4a86a0) is ADDITIVE (round 550): it hands
//     both deltas to GObjPC::FUN_004a87d0 -- each non-zero one first scaled
//     by 1 - param/100, param 143 for HP (`mov eax,0x8f` at 0x4a86bb, `fdiv
//     QWORD ds:0xb45af0` = 100.0 at 0x4a86c9, `fld1; fsubrp; fimul`) and 144
//     for MP (0x4a8706, 0x4a8714), the panic and combustion percentages of
//     round 491, zero while neither state is on and not modelled -- which
//     itself scales nothing: it reads GetHP (+0x108) and
//     ADDS the delta (`add edi,ebx` at 0x4a8821) before SetHP
//     (GObjChar::FUN_004a66f0: at or above GetMaxHP (+0x110) the maximum,
//     below 0 zero), and the same for MP through +0x10c / +0x114 /
//     FUN_004a6790. So option 2 lands at HP = min(MaxHP, 1 + trunc(0.4 x
//     MaxHP)) -- the 1 from Revive(1) below -- and MP = min(MaxMP, MP at
//     death + trunc(0.4 x MaxMP)), the death path not being seen to write
//     MP (one probe: the decompiles of GObjPC_OnDeath 0x4e6980 and
//     FUN_004e67b0 name neither MP slot, +0x10c / +0x114, nor FUN_004a6790
//     nor either ApplyHPMPDelta; a write by another route is not excluded).
//   - GObjPC::Revive (0x4df290): with 1 it passes 1 through SetLifeState
//     (+0x1f0) FIRST, then +0x55c, SetBodyMode (+0x318) and ApplyHPMPDelta(this,
//     1, 0, 8) -- one HP, the pools being the caller's; with 0 it does NOT set
//     the life state there and asks CGObjPC::FUN_004e08a0 for the RETURN
//     POINT, which this round read: the character's `_CHAR.AppointedTeleport`
//     (+0xa4, the designated teleport gate, its position through
//     FUN_004e0a40) and, for an unknown gate ("someone designated unknown
//     teleport gate: %d") or a siege world, `_CHAR.LatestRegion / PosX / PosY
//     / PosZ / WorldID` (+0x94, +0x98, +0x9c, +0xa0, +0xec;
//     docs/protocol/db_bind_offsets.tsv), then slot 0x378 with it.
//   - AITactics_IsValidTarget (0x540de0, round 424) returns no target unless
//     GetLifeState() == 1 (the `(+0xf8)() != 1` test before its body-mode
//     tests): a dead player is no AI target.
//   - Death empties both potion lists: GObjPC::FUN_004e67b0 (0x4e67b7 ->
//     FUN_0049a4c0), and ApplyHPMPDelta lands nothing unless GetLifeState is
//     1 (`cmp al,0x1` at 0x4a87e8 after the +0xf8 call at 0x4a87e6).
//   - A dead player may not use an item: Item_HandleUseItem (0x510980) asks
//     GetLifeState (0x510c9c; `cmp al,0x1` at 0x510ca6) and answers 0x1889
//     (0x510cd0) unless the state is 1 -- or 2 for one exempt TID class
//     (`(tid & 0xf800) == 0x3000` under FUN_004929c0, `cmp al,0x2` at
//     0x510cb6), which OpenSRO does not model.
//   - A dead player may not ask for a trade: GObjPC_HandleTradeMsg_081
//     (0x5154e0) asks the REQUESTER's GetLifeState (0x515607; `cmp al,0x1` at
//     0x515611) and answers 0x181d otherwise.
//
// THE CHOICES (round 665), READ from both binaries on the RE box:
//
//   - The client's dead window is message box kind 3, built by
//     UI_SILKMALL::FUN_00644c90's case 3: the line
//     UIIT_MSG_MSGBOX_ASK_SELF_REBIRTH_2 ("Choose a method to resurrect
//     yourself.") outside a fortress war, and two buttons. Control 0xc9
//     (the box's +0x800) is UIIT_MSG_MSGBOX_REBIRTH_POINT_BUTTON ("Resurrect
//     at the specified point.") -- the literal 0xd9d340 pushed at 0x6455ed;
//     REBIRTH_STANDING_BUTTON (0xd9d390) when the builder's ebx is 2, and
//     UIIT_MSG_FLAGWAR_GO_TO_REVIVAL (0xd9d3e0) in a flag world. Control 0xca
//     (+0x804, drawn with msgbox_rebirth_button.ddj) is
//     UIIT_MSG_MSGBOX_REBIRTH_STANDING_BUTTON ("Resurrect at the present
//     point.") while the player's MaxLevel (FUN_009d4d70, the byte at
//     player+0x20d8) is at most 10 (`cmp al,0xa; ja` at 0x645688), else
//     UIIT_MSG_MSGBOX_REBIRTH_HELP_BUTTON ("Waiting for other player's
//     help.", 0xd9d2f8).
//   - The box's event map (entries of 0x28 bytes at 0xeb5e88 and 0xeb5eb0,
//     their handlers stored by the initializer at 0xd6a82b / 0xd6a835) sends
//     control 0xc9 to FUN_0063b6e0, which records result 1, and 0xca to
//     FUN_0063b8b0, which records 0; both hand it to FUN_00777dd0 ->
//     FUN_00797d90(kind 3, result), whose case (the kind-3 entry of the jump
//     table at 0x798a8c) asks the MaxLevel again (0x797e1c): at 10 or under,
//     result 1 sends 0x3053 with the byte 1 (0x797e30 push 0x3053 -> 0x841780,
//     Net_SendRequestPacket) and any other result sends 0x3053 with the byte 2
//     (0x797eec `mov BYTE PTR [esp+0x16],0x2`); above 10, result 1 sends the
//     byte 1 (0x797f06..0x797f4a) and any other sends NOTHING (0x797efd `jne
//     0x798a61`). So the request is 0x3053 {u8 option}, the handler's one
//     byte; "0x7053" in earlier rounds was the project's 0x7000|op
//     precedent, not a read. OpenSRO keeps its placeholder OpRevive.
//   - The server answers with no message of its own: the handler's paths
//     end in Revive and ApplyHPMPDelta, whose state and pool changes are
//     what the client hears. OpenSRO's OpReviveResult stands for them.
//   - No timed revive in the open world. GObjPC::Revive has THIRTEEN call
//     sites (`call 0x4df290` in srv.asm: 0x406181, 0x4158de, 0x46ccd0,
//     0x49ff54, 0x4f2c95, 0x5100e7, 0x51018b, 0x510210, 0x51e5af, 0x51e67b,
//     0x52d9ff, 0x5f0e6f, 0x662b17 -- round 665 first counted ten; its review
//     found the last three): the resurrect handler (three), the resurrection
//     scroll (FUN_0049ff20), a transaction's reply (trs_wait_response::
//     vslot_002, 0x46cb30: Revive(1) on a PC in state 2, GameEventLog 0x15/3
//     -- INFERRED another player's resurrection), the GM command dispatcher
//     (two), the siege countdown (0x52d9ff, PeriodicUpdateInSiege), the flag
//     world's checker (0x5f0e6f), the battle arena's own timed revive
//     (0x662b17, CBattleArenaInfo::vslot_004 0x662a20: a GetTickCount
//     deadline, then Revive(1)), a scripted warp job (AJStateChanger::
//     vslot_002 kind 0xb/0, 0x405f70, whose creators were not traced) and two
//     CMainProcess paths. The PC's one-second tick (CGObjPC::PeriodicUpdate,
//     0x52aa90) calls none of them; its state-2 branch is the
//     SetCharacterState(0xf) one. Only a fortress war and the battle arena
//     revive on a timer -- not the open world.
//   - The handler's other two arms (round 665's review): a message with
//     nothing left to read (+0x103e == +0x103c) takes the PC out of the world
//     (FUN_004df050(4), the leave path) before any option is read; and a
//     death of cause 2 (the byte at +0x72d, leveldata.DeathCauseNoPenalty)
//     revives in place whatever the option and the level. OpenSRO's dead
//     state only ever follows a monster's kill (cause 3), so the cause-2 arm
//     is not reached; its empty request is the pre-665 client's, read as the
//     level's one choice (ReviveOption), not as a disconnect (OURS).
//   - Revive(0) (option 1) resolves the return point through
//     CGObjPC::FUN_004e08a0 (above): FUN_004260b0 looks
//     `_CHAR.AppointedTeleport` up as a ref object, whose +0x190 is its
//     teleport record (RefTeleport_ExtractData, teleport_network.md), and
//     FUN_004e0a40 -> FUN_00407760 reads that record's region (+0x20),
//     X/Y/Z (+0x26/+0x28/+0x2a, shorts) and world (+0x48) -- the same
//     arrival the gate teleport uses (0x513779). It then leaves through
//     slot 0x378 (CGObjPC::vslot_222, 0x4df590), which stores the
//     destination and takes the PC out of the world (FUN_004df050) to enter
//     it again there; Revive(0) itself sets no life state and no pool. The
//     re-entry's load path restores a stored zero pool to 40 %
//     (GObjPC::FUN_004e1120, character.RespawnFraction), so the character
//     arrives alive at trunc(0.4 x MaxHP).
//
// STAND-INS, each disclosed at its line and in the round's section:
//
//   - The return point (round 686, recall.go) is retail's: the character's
//     `_CHAR.AppointedTeleport` (above), which a town gate's "Designate as
//     return/recall point" line sets (GObjPC_HandleDesignateRecallMsg_059),
//     else its race's gate (STORE_CH_GATE / STORE_EU_GATE, SR_ShardManager
//     FUN_0042bb20), landing on that gate's teleportdata point. Until round 686 it was every
//     character's entry point (spawnZone's arrival), and it still is for a
//     China character on a server with no -teleport-dir (OURS; recall.go's
//     header has the other fallbacks).
//   - The level test reads Level for GetMaxLevel (+0x128). They are equal
//     here: a death never costs a level (GObjPC_OnDeath leaves CurLevel
//     alone) and OpenSRO has no other way down.
//   - The revived MP. Retail ADDS trunc(0.4 x MaxMP) to the MP the character
//     died with (ApplyHPMPDelta above); OpenSRO SETS the tracker to
//     character.RespawnMP, a stand-in. (Corrected round 607: this used to
//     say mana.Tracker regenerates by wall clock while dead. It regenerates
//     nothing now, and the regen tick's first test is the life state --
//     read, 0x4e29a9 -- so the MP she died with is intact; SET for ADD is
//     the whole difference.) The HP is exact: a dead character's HP is 0
//     (potions land nothing, and the regen tick skips the dead), and
//     reviveHPDelta adds the handler's sum through Store.Heal, the same
//     add-and-clamp.
//   - The flag-off instant respawn (monsterStrike's RespawnHP) keeps the
//     load path's trunc(0.4 x MaxHP), not the handler's +1: that wire is
//     what an older client's tests pin, and the compression of a death and
//     a revive into one call is the stand-in there, not the number.
//   - The empty request. Round 548's client sends OpRevive with no payload;
//     retail's request carries the u8 option, and since round 665 OpenSRO's
//     does too (the option's first byte). An empty request -- a client from
//     before round 665 with its one Revive button -- is read as option 2 at
//     level 10 or under and option 1 above it: the one choice retail offers
//     at that level, so it neither loops nor is refused. OURS.
//   - A refused option 2 above level 10 is answered with a reason
//     (reviveRefusedLevel). Retail's handler does nothing at all (the
//     `bVar3 < 0xb` test at 0x51017f falls out of the handler), and its
//     client never sends it (FUN_00797d90 sends nothing for that button above
//     level 10); OpenSRO answers so a stray request does not hang.
//   - The protection after a revive is modelled since round 786
//     (arrival.go): Revive(1) sets body mode 2 for 6.0 s (0xb45b78; 11.0 s,
//     0xb45bb8, in a siege world) -- ReviveHandler's startProtection in
//     place -- and a return to the return point is a world re-entry, whose
//     CGObjPC::vslot_391 (0x4df9e0) sets body mode 2 for the world's time
//     (CGameWorld 0x5eb2d0: 6.0 s) at the client's 0x3012 (releaseArrival).
//   - The refusal strings (deadRefusal, "not dead") and the pick-up, duel,
//     zone-change and GM-teleport refusals, whose retail handlers were not
//     read for a life-state test (the pick-up handler 0x034 is a vtable
//     thunk; the duel and zone messages were not opened).
//   - Revive on entry (handleEnterWorld): a character logged out dead enters
//     at RespawnFraction. The FRACTION is the load path's own rule
//     (character.RespawnFraction: GObjPC::FUN_004e1120 restores a stored
//     zero pool to 40 %), applied whatever the flag says -- a character dead
//     when the flag is turned off must not enter alive at 0 HP; doing it at
//     entry rather than keeping the character dead across sessions is the
//     stand-in.

// playerDeadState is cmd/server's -player-dead-state, OFF by default. An
// atomic because cmd/server sets it on the boot goroutine and the strike
// reads it on session readers, keep-up goroutines and the AI's strike workers.
var playerDeadState atomic.Bool

// SetPlayerDeadState turns the player's dead state on or off. cmd/server
// calls it once at boot, before the gateway serves. Only ENTERING the state
// is gated: everything else follows the state itself, so a character can
// only be dead while the flag is on.
func SetPlayerDeadState(on bool) { playerDeadState.Store(on) }

// The revive pair, placeholders in the world group like every opcode here
// (docs/protocol/PROTOCOL_DECISION.md). 0x0028/0x0029 were free before round
// 548 (grep, 2026-09-24) and the client half pins them
// (client/scripts/net/world.gd OP_REVIVE / OP_REVIVE_RESULT).
const (
	OpRevive       uint16 = 0x0028 // client -> server, u8 option (empty from a client before round 665)
	OpReviveResult uint16 = 0x0029 // server -> the requester
)

// The resurrect options, retail's own byte (GObjPC_HandleResurrectMsg_053
// 0x50fee0; the client's FUN_00797d90 sends 1 or 2 -- "THE CHOICES" above).
const (
	// ReviveOptionReturnPoint is "Resurrect at the specified point.":
	// GObjPC::Revive(0), to the return point.
	ReviveOptionReturnPoint byte = 1
	// ReviveOptionPresentPoint is "Resurrect at the present point.":
	// GObjPC::Revive(1) where the character lies, honoured only while the
	// max level is at most PresentPointMaxLevel.
	ReviveOptionPresentPoint byte = 2
)

// PresentPointMaxLevel is the highest max level option 2 revives at: the
// server's `bVar3 < 0xb` on IGObj::GetMaxLevel (+0x128; `cmp al,0xa; ja` at
// 0x51017f) and the client's `cmp al,0xa; ja` at 0x645688 (the button's
// label) and 0x797e21 (the send). READ.
const PresentPointMaxLevel = 10

// reviveRefusedLevel answers option 2 above PresentPointMaxLevel. The
// wording is OURS: retail's handler does nothing for it.
const reviveRefusedLevel = "you can resurrect at the present point only up to level 10"

// ReviveOption is the option an OpRevive payload asks for: its first byte,
// or -- for the empty payload of a client before round 665 -- the one
// choice retail offers at the character's level (option 2 at level
// PresentPointMaxLevel or under, else option 1; the header's stand-in).
func ReviveOption(data []byte, level int) byte {
	if len(data) > 0 {
		return data[0]
	}
	if level <= PresentPointMaxLevel {
		return ReviveOptionPresentPoint
	}
	return ReviveOptionReturnPoint
}

// deadRefusal is the error string a request refused for being dead carries.
// OpenSRO's own wording; the engine answers a code (0x1889 for an item,
// 0x181d for a trade request, GUILDERR_IM_DEAD for guild work).
const deadRefusal = "you are dead"

// errNotDead is revivePlayer's answer for a character that is not in life
// state 2 -- the retail handler's `cmp al,0x2` (0x510077), which does nothing
// for a living character.
var errNotDead = errors.New("not dead")

// ReviveResult is the OpReviveResult payload: a u16-prefixed error string,
// empty on success, then s32 HP and s32 MP -- the pools the character came
// back with (client/scripts/net/world.gd decode_revive_result). A refusal
// carries no tail; the client's decoder takes it either way.
type ReviveResult struct {
	Error string
	HP    int32
	MP    int32
}

func (r *ReviveResult) Encode() []byte {
	out := encodeStrings(r.Error)
	if r.Error != "" {
		return out
	}
	tail := make([]byte, 8)
	binary.LittleEndian.PutUint32(tail[0:4], uint32(r.HP))
	binary.LittleEndian.PutUint32(tail[4:8], uint32(r.MP))
	return append(out, tail...)
}

// DecodeReviveResult mirrors the client's decoder: a refusal with or without
// its tail, a success needing all eight bytes. Only tests call it -- the
// message goes server to client.
func DecodeReviveResult(data []byte) (*ReviveResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ReviveResult: %w", err)
	}
	r := &ReviveResult{Error: fields[0]}
	if r.Error != "" {
		return r, nil
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding ReviveResult: truncated vitals")
	}
	r.HP = int32(binary.LittleEndian.Uint32(rest[0:4]))
	r.MP = int32(binary.LittleEndian.Uint32(rest[4:8]))
	return r, nil
}

// deadBySession reports whether the character on sess is in the world and
// dead: the "must be alive" test every refusing handler makes, on the O(1)
// session index.
func deadBySession(hub *world.Hub, sess *gateway.Session) bool {
	if hub == nil || sess == nil {
		return false
	}
	e, ok := hub.EntityBySession(sess.ID())
	return ok && e.Life == world.LifeDead
}

// deadCharacter reports whether characterID is in the world and dead, for a
// caller that holds only the character (a swing's target, a duel's opponent).
func deadCharacter(hub *world.Hub, characterID int64) bool {
	if hub == nil {
		return false
	}
	e, ok := hub.EntityByCharacterID(characterID)
	return ok && e.Life == world.LifeDead
}

// markDead is what a monster's killing blow does to characterID under
// -player-dead-state, once the experience penalty is applied (monsterStrike):
// life state 2 with the time of death (world.Hub.SetLifeState), the potion
// queue emptied -- GObjPC::FUN_004e67b0's FUN_0049a4c0 empties both lists, and
// ApplyHPMPDelta would land nothing on a dead character anyway (0x4a87e8) --
// and the keep-up cancelled. HP stays where ApplyDamage left it, 0. It reports
// whether the compare-and-swap made the change. Which of two racing kills
// gets here is decided one step earlier, under the character's kill lock
// (killLock, round 551; the caller holds it): monsterStrike reads her back
// under the lock and only the blow that finds her alive at 0 comes here, so
// the second blow never charges the penalty and the swap cannot fail against
// another kill or a revive (revivePlayer takes the same lock). Round 550 had
// the store's transition flag decide instead, which left a character alive at
// 0 unkillable; before that both blows read died=true and both charged
// leveldata.DeathPenaltyExp before the second's compare-and-swap failed here.
func markDead(deps strikeDeps, characterID int64, now time.Time) bool {
	changed := deps.hub.SetLifeState(characterID, world.LifeAlive, world.LifeDead, now)
	if changed {
		metrics.PlayerDeath()
	}
	if deps.potions != nil {
		deps.potions.drop(characterID)
	}
	cancelActions(characterID)
	// Round 834: a death closes the exchange 0x182b (CGObjPC::vslot_306 /
	// 307, s:0x529ce0 / 0x52cf41).
	exchangeEnd(characterID, ExchangeErrCancel)
	// Round 839: a death closes an owner's stall 0x3c0e and takes a visitor
	// out (CGObjPC::vslot_306 / 307, s:0x529ca4 / 0x52cf05).
	stallEnd(characterID, StallErrClosedDeath)
	// A death ends every buff (round 616). OURS, disclosed: the retail
	// death path was not traced to a book clear -- GObjPC_OnDeath (0x4e6980)
	// holds none, and CGObjChar::SetLifeState (0x4a9c80) on state 2 calls an
	// unidentified +0x188 member's slot 4 -- so this is the observable rule
	// chosen, not a read one (docs/protocol/skill_buffs.md, OPEN).
	if changed {
		endBuffsOf(deps.hub, characterID)
		// Round 749: a leg still running ends where the server has the body
		// (the CGObjChar slot-300 stop, READ, sends 0xB023 to the window);
		// its own client stopped at the blow.
		if e, ok := deps.hub.EntityByCharacterID(characterID); ok && e.Session != nil {
			haltForSit(e.Session, deps.hub)
		}
	}
	return changed
}

// reviveHPDelta is what GObjPC_HandleResurrectMsg_053's option-2 path ADDS to
// a dead character's HP, which is 0 (round 550): GObjPC::Revive(1)'s
// ApplyHPMPDelta(this, 1, 0, 8) -- one HP -- and then the handler's own
// ApplyHPMPDelta(trunc(GetParam(3) x 0.4), trunc(GetParam(4) x 0.4), 8) (`call
// 0x4a86a0` at 0x51015d). Both go through GObjPC::FUN_004a87d0, which adds the
// delta to GetHP (`add edi,ebx` at 0x4a8821) and clamps through SetHP
// (GObjChar::FUN_004a66f0: GetMaxHP at or above it), and the handler
// truncates (rounding control 11: 0x510102..0x510122 on the death-cause-2
// path, 0x5101a6..0x5101c6 on option 2's -- the header). So retail lands at
// min(MaxHP, 1 + trunc(0.4 x MaxHP)); Store.Heal is the same add-and-clamp.
// The truncation is int()'s, and character.RespawnFraction's comment says why
// the exact 0.4 gives the widened float's integer.
func reviveHPDelta(maxHP int) int {
	return 1 + int(float64(maxHP)*character.RespawnFraction)
}

// revivePlayer brings characterID back where it lies, in the order
// GObjPC_HandleResurrectMsg_053 takes: Revive(1) passes 1 through SetLifeState
// FIRST, and the pools come after (Revive's own ApplyHPMPDelta(this, 1, 0, 8),
// then the handler's). So the compare-and-swap 2 -> 1 goes first here: of two
// revives racing each other (the handler against the fallback) exactly one
// wins it and touches the pools; the loser answers errNotDead at once, and
// one OpReviveResult goes out. Until round 550 the pools went first and the
// state last, which left a window in which a blow found HP above 0 in life
// state 2: its kill's compare-and-swap 1 -> 2 failed, and the revive then set
// state 1 on a pool the blow had just emptied -- a character alive at 0 HP.
// State first, and since round 551 the whole of it -- the swap and the pools
// -- under the character's kill lock (killLock): a blow that leaves her at 0
// reads her back under that lock, so it sees either life state 2 (before
// the swap: dropped) or the revived pool (after: it lands as usual), never
// "alive at 0" between the two, which the round-551 arbiter would take for
// a kill. Then the HP: reviveHPDelta through Store.Heal (the handler's
// additive arithmetic, clamped at the maximum), and the MP tracker to
// character.RespawnMP (the disclosed stand-in in the header). A store
// failure after the state changed puts the state back with its time of
// death, so the character is dead again for the next attempt rather than
// alive at 0. It returns the character as it stands and its MP.
func revivePlayer(ctx context.Context, chars character.Store, mp *mana.Tracker, hub *world.Hub, characterID int64) (*character.Character, int, error) {
	return reviveWith(ctx, chars, mp, hub, characterID, false)
}

// reviveWith is revivePlayer with the pools chosen by where the character
// comes back. In place (option 2) they are the handler's, as revivePlayer
// says. At the return point (option 1, returnToPoint) they are the load
// path's, the one a retail Revive(0) ends in (the world re-entry; "THE
// CHOICES" in the header): a stored zero pool comes back at
// trunc(0.4 x maximum), at least 1 HP (Store.RespawnHP's rule, which
// character.RespawnFraction records), and a pool above zero is kept -- so
// the dead character's HP, which is 0, is restored, and its MP, which a
// death leaves where it was, is restored only if it is empty.
func reviveWith(ctx context.Context, chars character.Store, mp *mana.Tracker, hub *world.Hub, characterID int64, returnToPoint bool) (*character.Character, int, error) {
	if hub == nil {
		return nil, 0, errNotDead
	}
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok || e.Life != world.LifeDead {
		return nil, 0, errNotDead
	}
	l := killLock(characterID)
	l.Lock()
	defer l.Unlock()
	if !hub.SetLifeState(characterID, world.LifeDead, world.LifeAlive, time.Time{}) {
		return nil, 0, errNotDead
	}
	// A revive by any path ends a resurrection offer still waiting (round
	// 785 review).
	dropResurrectOffer(characterID)
	stillDead := func(err error) (*character.Character, int, error) {
		hub.SetLifeState(characterID, world.LifeAlive, world.LifeDead, e.DiedAt)
		return nil, 0, fmt.Errorf("session: reviving %d: %w", characterID, err)
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return stillDead(err)
	}
	delta := reviveHPDelta(c.MaxHP())
	if returnToPoint {
		delta = max(1, int(float64(c.MaxHP())*character.RespawnFraction))
	}
	hp, err := chars.Heal(ctx, characterID, delta, c.MaxHP())
	if err != nil {
		return stillDead(err)
	}
	c.HP = hp
	metrics.PlayerRevive()
	// GObjPC::Revive stands the character (SetMotionState(STAND) at
	// 0x4df427; round 607, motion.go).
	motions.stand(characterID, time.Now())
	mpNow := 0
	if mp != nil {
		mpNow = character.RespawnMP(c.MaxMP())
		if returnToPoint {
			if cur := mp.Current(characterID, c.MaxMP()); cur > 0 {
				mpNow = cur
			}
		}
		mp.Refill(characterID, mpNow)
	}
	// Round 865: a guardian's honor buffs come back with it (READ
	// s:0x46cd5e, academylive.go).
	academyRevived(ctx, characterID)
	return c, mpNow, nil
}

// sendRevived tells sess it is back: the OpReviveResult with the pools, then
// the stats push the HUD's MP bar moves on (the result carries MP, but round
// 548's client paints only HP from it and asks for its stats after; the push
// spares it the round trip, as regen's does). The push is best effort.
func sendRevived(ctx context.Context, sess *gateway.Session, c *character.Character, mpNow int, deps RegenDeps) error {
	if sess == nil {
		return nil
	}
	if c == nil {
		// Never a success without a character (round 665's review, H1).
		return sess.Send(&proto.Packet{Opcode: OpReviveResult, Data: (&ReviveResult{Error: "revive failed"}).Encode()})
	}
	res := &ReviveResult{HP: int32(c.HP), MP: int32(mpNow)}
	if err := sess.Send(&proto.Packet{Opcode: OpReviveResult, Data: res.Encode()}); err != nil {
		return err
	}
	if stats, err := buildCharacterStats(ctx, c, c.ID, deps.Equipment, deps.Items, deps.Skills, deps.Mana); err == nil {
		_ = sess.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: stats.Encode()})
	}
	return nil
}

// ReviveHandler returns a gateway.Handler implementing OpRevive, retail's two
// choices (round 665; "THE CHOICES" in the header). The session's own
// in-world character must be dead -- a living one is answered "not dead", as
// the retail handler's `cmp al,0x2` does nothing for it. Then by the option
// (ReviveOption):
//
//   - 1, the return point: the character is moved there while still dead
//     (returnToPoint: the zone change the client reloads on, as a warp does),
//     so no monster can take it for a target between the two, and then
//     revived there with the load path's pools (reviveWith). Retail's
//     Revive(0) likewise moves first and lives again on the re-entry.
//   - 2, the present point: revived where it lies (revivePlayer) -- only at
//     level PresentPointMaxLevel or under; above it the request is refused
//     (reviveRefusedLevel) and the character stays dead.
//   - anything else: refused, the character stays dead (the handler has no
//     other arm).
//
// Either revive is answered with an OpReviveResult and the stats push. deps
// build the push, and deps.Equipment the snapshots of the characters the
// return point's zone holds.
func ReviveHandler(chars character.Store, hub *world.Hub, deps RegenDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpRevive {
			return nil
		}
		refuse := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpReviveResult, Data: (&ReviveResult{Error: reason}).Encode()})
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return refuse("not in the world")
		}
		if e.Life != world.LifeDead {
			return refuse("not dead")
		}
		var (
			c     *character.Character
			mpNow int
			err   error
		)
		switch ReviveOption(p.Data, e.Level) {
		case ReviveOptionReturnPoint:
			// werr, not err: an inner `err :=` here shadowed the switch's err,
			// so a failed revive below reached sendRevived with a nil
			// character (round 665's review, H1).
			moved, werr := returnToPoint(ctx, sess, chars, hub, deps)
			if werr != nil || !moved {
				return werr // !moved: warpTo has answered "not in the world"
			}
			c, mpNow, err = reviveWith(ctx, chars, deps.Mana, hub, e.CharacterID, true)
		case ReviveOptionPresentPoint:
			if e.Level > PresentPointMaxLevel {
				return refuse(reviveRefusedLevel)
			}
			c, mpNow, err = revivePlayer(ctx, chars, deps.Mana, hub, e.CharacterID)
		default:
			return refuse("no such resurrect option")
		}
		if errors.Is(err, errNotDead) {
			return refuse("not dead")
		}
		if err != nil {
			return refuse("revive failed")
		}
		// GObjPC::Revive's SetBodyMode(2, 0, t, 0) ends a berserk (endBerserk).
		endBerserk(hub, deps.Berserk, e.CharacterID)
		// Round 786 (arrival.go): and that SetBodyMode IS the protection --
		// body mode 2 for 6.0 s (0x4df463..0x4df496, 0xb45b78, READ). In
		// place it starts now; at the return point the arrival's release
		// starts it (CGObjPC::vslot_391), the character being held.
		if arrivalGuardOn.Load() && !arrivalHeld(e.CharacterID) {
			startProtection(hub, e.CharacterID, sess, "revive in place")
		}
		return sendRevived(ctx, sess, c, mpNow, deps)
	}
}

// returnToPoint moves the character on sess to its return point: the same
// arrival a zone change or a gate makes (warpTo) -- the mover's
// OpChangeZoneResult, the old zone's OpEntityLeft, the new zone's
// OpEntityEntered, the position saved under -persist-position. The life
// state travels with it (world.Hub.ChangeZone), so a dead character arrives
// dead and a living one alive. It reports whether anything moved.
func returnToPoint(ctx context.Context, sess *gateway.Session, chars character.Store, hub *world.Hub, deps RegenDeps) (bool, error) {
	return warpHome(ctx, sess, deps.Equipment, chars, hub, deps.Berserk, "death: return point")
}

// warpHome is the move to the return point both paths make (option 1 and
// returnAfterKill), guarded against the mover's own stale moves
// (returnGuard): armed before the move, bound to the arrival after it.
//
// The point is the character's own since round 686 (returnPointFor,
// recall.go): its designated gate, else its race's.
func warpHome(ctx context.Context, sess *gateway.Session, eq equipment.Store, chars character.Store, hub *world.Hub, zerk *berserk.Tracker, via string) (bool, error) {
	var characterID int64
	if e, ok := hub.EntityBySession(sess.ID()); ok {
		characterID = e.CharacterID
	}
	zone, bucket, pos, frame := returnPointFor(ctx, chars, characterID)
	armReturnGuard(sess, zone, pos, time.Now())
	moved, err := warpVia(ctx, sess, eq, chars, hub, zerk, zone, bucket, pos, frame, via)
	if arrived, in := hub.EntityBySession(sess.ID()); moved && in {
		bindReturnGuard(sess, arrived.Arrival)
	} else {
		sess.Set(returnGuardKey, (*returnGuard)(nil))
	}
	return moved, err
}

// returnGuard drops the moves a character's client sent from where it fell
// after the server has moved it home (round 665's review, M1). The move to
// the return point is the server's own -- with -player-dead-state off it is
// made from the kill's goroutine, a monster's strike worker or the status
// tick, while the client, never told it died, may still be walking -- and
// handleMove takes a client's position as it comes, so a walk step in flight
// would put the server's character back among its killers while its client
// loads the town. So from the move until a move arrives near a landing point
// (the arrival, or the spot the client stands a player at in that zone,
// worldmap.LandingSpotFor), moves anywhere else are dropped. It lives on the
// session (returnGuardKey), so it goes with the connection. OURS: retail's
// server moves its own objects and has no client position to distrust.
type returnGuard struct {
	points   [][2]float64
	deadline time.Time
	// arrival is the hub's Arrival stamp of the move (world.Entity.Arrival),
	// 0 while the move is under way; a later zone change stamps another, and
	// the guard no longer applies.
	arrival uint64
}

// returnGuardKey is the session value holding the *returnGuard (nil: none).
const returnGuardKey = "session.dead.returnGuard"

// returnGuardRadius is how near, on x and on z, to a landing point a move
// must be to end the guard. OURS: the client stands the player at the
// point or the zone's spot (round 646 measured it exact), and a move from
// where it fell lies regions away; 400 units leaves room for a first step.
const returnGuardRadius = 400.0

// returnGuardGrace is how long the guard holds with no move near a landing.
// OURS, warpLandingGrace's two minutes: a slow machine's zone load.
const returnGuardGrace = warpLandingGrace

func armReturnGuard(sess *gateway.Session, zone string, pos world.Position, now time.Time) {
	pts := [][2]float64{{pos.X, pos.Z}}
	if x, z, ok := worldmap.LandingSpotFor(zone, pos.X, pos.Z); ok {
		pts = append(pts, [2]float64{x, z})
	}
	sess.Set(returnGuardKey, &returnGuard{points: pts, deadline: now.Add(returnGuardGrace)})
}

func returnGuardOf(sess *gateway.Session) *returnGuard {
	v, ok := sess.Get(returnGuardKey)
	if !ok {
		return nil
	}
	g, _ := v.(*returnGuard)
	return g
}

func bindReturnGuard(sess *gateway.Session, arrival uint64) {
	if g := returnGuardOf(sess); g != nil {
		bound := *g
		bound.arrival = arrival
		sess.Set(returnGuardKey, &bound)
	}
}

// returnGuardDrops reports whether a move of e's (on sess) to (x, z) is
// dropped: a guard stands for e's current arrival (or its move is under
// way), inside the grace, and (x, z) is near none of its landing points. A
// move near one ends the guard and is taken.
func returnGuardDrops(sess *gateway.Session, e world.Entity, x, z float64, now time.Time) bool {
	g := returnGuardOf(sess)
	if g == nil {
		return false
	}
	if now.After(g.deadline) || (g.arrival != 0 && g.arrival != e.Arrival) {
		sess.Set(returnGuardKey, (*returnGuard)(nil))
		return false
	}
	for _, p := range g.points {
		if math.Abs(x-p[0]) <= returnGuardRadius && math.Abs(z-p[1]) <= returnGuardRadius {
			sess.Set(returnGuardKey, (*returnGuard)(nil))
			return false
		}
	}
	return true
}

// returnAfterKill is the flag-off death's second half (round 665): a kill
// with -player-dead-state off respawns the character at once
// (finishKill's RespawnHP), and this then moves it to its return point, so it
// no longer comes back among the monsters that just killed it and dies again
// (the final release review's loop). OURS, disclosed: retail has one death,
// the dead state and the choice window; this compresses it and option 1 --
// the choice every level has -- into the kill. The pools stay the respawn's,
// trunc(0.4 x MaxHP) and 40 % MP, which are the load path's that a retail
// option 1 ends in. Each caller runs it after the kill's own messages
// (the result, the push), so the client hears the blow before the zone
// change; it does nothing with the flag on (the character is dead and asks
// for itself), for a character not in the world, or for one already dead
// again.
func returnAfterKill(ctx context.Context, chars character.Store, eq equipment.Store, hub *world.Hub, characterID int64) {
	if playerDeadState.Load() || hub == nil {
		return
	}
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok || e.Session == nil || e.Life != world.LifeAlive {
		return
	}
	_, _ = warpHome(ctx, e.Session, eq, chars, hub, nil, "death: respawn after a kill")
}

// savedPlace is e as a leaving session saves it (-persist-position): a
// character leaving the world dead is saved at its return point, not where it
// fell, so it re-enters in town (alive, handleEnterWorld's revive of a stored
// HP 0) and not beside the monster that killed it. READ: the PC's leave path
// FUN_004df050 asks the life state (`cmp al,0x2` at 0x4df129) and, for a dead
// PC in the main world, resolves the return point (CGObjPC::FUN_004e08a0,
// `call 0x4e08a0` at 0x4df188) and writes it as the saved region, position
// and world (0x4df194 FUN_004f9950, 0x4df1a0 FUN_004f9920, 0x4df1ae
// FUN_004f9850). The point is the character's own (returnPointFor, round
// 686). It also points the session's remembered place at the return point's
// label and frame, which savePosition writes under.
func savedPlace(chars character.Store, sess *gateway.Session, e world.Entity) world.Entity {
	if e.Life != world.LifeDead || sess == nil {
		return e
	}
	zone, _, pos, frame := returnPointFor(context.Background(), chars, e.CharacterID)
	rememberPlace(sess, zone, frame, time.Now())
	e.Pos = pos
	return e
}
