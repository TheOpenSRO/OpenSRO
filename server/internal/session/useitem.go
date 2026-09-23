package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/storage"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Using a consumable. Until now potions dropped, stacked in the bag and did
// nothing at all -- the one thing a potion is for was missing.
const (
	// MOVED from 0x0080/0x0081 on 2026-09-20. Those were already
	// OpPartyCreate/OpPartyCreateResult, taken a month earlier, and this pair
	// collided with them.
	//
	// gateway.Chain offers a packet to EVERY handler, and each one decides by
	// opcode whether it is theirs -- so a use-item request was processed twice:
	// UseItemHandler consumed the berry and replied success, and the party
	// handler then failed to read a party-create payload out of the same bytes
	// and replied "malformed request". Both replies carried 0x0081, so the
	// client displayed both: "it used the berry from my inventory but it took a
	// second and it still said malformed request" (playtest 2026-09-20).
	//
	// Use-item moves because it is the newcomer -- party has held 0x0080 since
	// 2026-08-19 and use-item took it on 2026-09-14.
	OpUseItem       uint16 = 0x008a // client -> server
	OpUseItemResult uint16 = 0x008b // server -> client
)

// UseItemRequest asks to consume one of whatever is in an inventory slot.
type UseItemRequest struct {
	CharacterName string
	InventorySlot int32
}

func (r *UseItemRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(int64(r.InventorySlot))...)
}

func DecodeUseItemRequest(data []byte) (*UseItemRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseItemRequest: %w", err)
	}
	slot, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseItemRequest: slot: %w", err)
	}
	return &UseItemRequest{CharacterName: fields[0], InventorySlot: int32(slot)}, nil
}

// UseItemResult reports what the item did. HP/MP are the values *after* the
// item was used, so the client can redraw both bars without asking again.
// RestoredHP/RestoredMP are what landed AT ONCE: an absolute potion's first
// step (round 509, PotionQueue); its other four arrive a second apart through
// the stats push.
type UseItemResult struct {
	Error      string
	HP         int32
	MaxHP      int32
	MP         int32
	MaxMP      int32
	RestoredHP int32
	RestoredMP int32
	Remaining  int32 // how many of the stack are left
}

func (r *UseItemResult) Encode() []byte {
	out := encodeStrings(r.Error)
	buf := make([]byte, 28)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.HP))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.MaxHP))
	binary.LittleEndian.PutUint32(buf[8:12], uint32(r.MP))
	binary.LittleEndian.PutUint32(buf[12:16], uint32(r.MaxMP))
	binary.LittleEndian.PutUint32(buf[16:20], uint32(r.RestoredHP))
	binary.LittleEndian.PutUint32(buf[20:24], uint32(r.RestoredMP))
	binary.LittleEndian.PutUint32(buf[24:28], uint32(r.Remaining))
	return append(out, buf...)
}

func DecodeUseItemResult(data []byte) (*UseItemResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UseItemResult: %w", err)
	}
	r := &UseItemResult{Error: fields[0]}
	if len(rest) >= 28 {
		r.HP = int32(binary.LittleEndian.Uint32(rest[0:4]))
		r.MaxHP = int32(binary.LittleEndian.Uint32(rest[4:8]))
		r.MP = int32(binary.LittleEndian.Uint32(rest[8:12]))
		r.MaxMP = int32(binary.LittleEndian.Uint32(rest[12:16]))
		r.RestoredHP = int32(binary.LittleEndian.Uint32(rest[16:20]))
		r.RestoredMP = int32(binary.LittleEndian.Uint32(rest[20:24]))
		r.Remaining = int32(binary.LittleEndian.Uint32(rest[24:28]))
	}
	return r, nil
}

// The item kinds whose use restores the USER's own HP/MP (round 491). The
// engine picks an item's use by its TID, never by whether its Param block
// happens to hold numbers:
//
//   - FUN_00489de0, the object factory, builds a CGItemExpendable for
//     TypeID1 3 / TypeID2 3 (`param_1 >> 2 & 7` == 3, `param_1 >> 5 & 3` == 3);
//     equipment and pet summoners are other classes with other DoJobs.
//   - CGItemExpendable::DoJob (0x0049aca0, vtable 0x00aeb2b4 slot 306, the
//     `+0x4c8` call Item_HandleUseItem makes) switches on TypeID3
//     (`TID >> 7 & 0xf`). Case 1 sends TypeID4 4/5/6/7/9 to slot 327
//     (0x0049d240) and 10 to slot 330 (0x0049cc80); every other TypeID4 goes
//     to slot 308 (0x0049b710).
//   - Slot 308 under TypeID3 1: TypeID4 8 is GObjPC::AddHwanCount (the berserk
//     potion); any other reads the amounts through GObjPC::FUN_0049aa70 --
//     Param1 (+0x2a0) HP, Param2 (+0x2c0) HP %, Param3 (+0x2e0) MP, Param4
//     (+0x300) MP %, the exporter's columns 118/120/122/124 -- and applies them
//     to the owner PC (0x49b90c..0x49b946).
//   - Slot 327 applies 4/5/7's amounts to a PET the packet names (its owner
//     must be the user), revives a pet (6) or feeds one (9); slot 330 repairs a
//     siege structure (10). None of them touches the user's pool.
//
// So the user's HP/MP comes back only from 3/3/1/x with x outside
// {4,5,6,7,8,9,10}; in real itemdata that is the 58 rows of TypeID4 1 (HP), 2
// (MP) and 3 (both). Among the DIRECT pool writes an item use makes (the item
// paths among GObjPC::ApplyHPMPDelta's call sites), the one other is the
// resurrection kind 3/3/13/6 (UseByKind 0x0049c2b0 case 6 -> FUN_0049ff20),
// which refuses a user whose life state is not 2 with 0x1887
// UIIT_MSG_STRGERR_ONLY_THE_DEAD_CAN_USE_RESURRECT_SCROLL and fills HP/MP only
// as part of reviving a dead one (GObjPC::Revive) -- a use srrevamp does not
// model. That census is scoped to direct writes: UseByKind's cases 1..3 cast
// the skill whose id is the row's Param1 (+0x2a0, looked up by FUN_0046c1f0,
// applied by FUN_0059b8d0), and a pool write such a skill makes was not
// traced. The gate is unaffected -- on those rows Param1 is a skill id, not a
// restore amount.
const (
	// recoveryFamily is TypeID3 1 under TypeItem/TypeExpendable: DoJob's case
	// 1 (0x0049aca0).
	recoveryFamily = 1
	// berserkPotionKind is TypeID4 8 under recoveryFamily: slot 308's
	// `bVar3 != 8` test (0x0049b89a `cmp al,0x8`) sends it to AddHwanCount.
	berserkPotionKind = 8
)

// restoresUserPool reports whether the engine's use dispatch sends an item of
// this kind to the user's own HP/MP recovery (see recoveryFamily).
func restoresUserPool(it *refdata.Item) bool {
	if it.TypeID1 != equipment.TypeItem || it.TypeID2 != equipment.TypeExpendable || it.TypeID3 != recoveryFamily {
		return false
	}
	switch it.TypeID4 {
	case 4, 5, 6, 7, 9: // DoJob case 1 -> slot 327 (0x0049d240): a pet's HP/MP, revival, feed
		return false
	case 10: // DoJob case 1 -> slot 330 (0x0049cc80): siege structure repair
		return false
	case berserkPotionKind: // slot 308 -> GObjPC::AddHwanCount
		return false
	}
	return true
}

// The amount a recovery potion restores, as GObjPC::FUN_0049aa70 computes it
// (round 496). The dump's C drops every x87 instruction of that function, so
// this is read from srv.asm (0x49aa70..0x49ac42).
const (
	// potionStatDivisor is the double 416.0 at .rdata 0xb45e98 (bytes
	// 00 00 00 00 00 00 7a 40), the operand of `fdiv QWORD PTR ds:0xb45e98`
	// at 0x49abbd (HP) and 0x49ac18 (MP).
	potionStatDivisor = 416.0
	// potionPercentDivisor is the double 100.0 at .rdata 0xb45af0 (bytes
	// 00 00 00 00 00 00 59 40), the operand of `fdiv QWORD PTR ds:0xb45af0`
	// at 0x49aae9 (HP %) and 0x49ab28 (MP %).
	potionPercentDivisor = 100.0
)

// potionRestore returns the HP and MP a recovery potion restores, from its
// Param1..4 (refdata.Item.RestoreHP, RestoreHPPct, RestoreMP, RestoreMPPct) and
// the user's Level, Str, Int and maximum pools. It is GObjPC::FUN_0049aa70,
// which slot 308 (0x0049b710) calls for every recovery kind, read from the
// disassembly in the engine's own order of operations:
//
//   - The absolute path, taken when Param1 (+0x2a0) or Param3 (+0x2e0) is
//     non-zero (0x49aa95 / 0x49aaa3):
//     HP = trunc(((1 + GetParam(1)/416) * 1.02^(Level-1)) * Param1) and
//     MP = trunc(((1 + GetParam(2)/416) * 1.02^(Level-1)) * Param3).
//     Level is vtable +0x124 IGObj::GetLevel, taken as a byte (0x49ab79
//     `movzx eax,al`) less one (`lea esi,[eax-0x1]`). 1.02 is the double at
//     .rdata 0xb45ea0 (character.StatGrowth; `fld QWORD` at 0x49ab73 and
//     0x49abd4), raised to that power by the inlined binary exponentiation at
//     0x49ab87..0x49aba7 (square-and-multiply on |n|, then 1/x if n < 0) and
//     stored as a double (0x49abad `fstp QWORD`). GetParam is vtable +0x104,
//     CGObjChar::GetParam 0x4aa5c0 -> ParamKeeper_GetParamChecked ->
//     Param_GetValue (0x4b33ae `fld DWORD`), so the stat arrives as a float;
//     params 1 and 2 are Str and Int (character.go's GParamKeeper notes).
//     The HP term adds `fld1` (0x49abc3); the MP term adds the double 1.0 at
//     .rdata 0xb45ac0 (0x49ac1e `fadd QWORD`; bytes 00 00 00 00 00 00 f0 3f).
//     Each product is `fimul` by the Param (0x49abcd / 0x49ac28). A zero
//     Param in this path yields zero; the percentage pair is not read.
//   - The percentage path, taken only when Param1 and Param3 are BOTH zero:
//     HP = trunc(GetMaxHP * float32(Param2/100)) when Param2 (+0x2c0) is
//     non-zero, and MP the same with Param4 (+0x300) and GetMaxMP (vtable
//     +0x110 / +0x114). The fraction is rounded to a float by 0x49aaef
//     `fstp DWORD` before 0x49aaf3 `fmul DWORD`, so 70% of 100 is 69; the
//     real rows' 20/25/40/100 % round up or exactly and land as integer
//     arithmetic would.
//   - Every float-to-int is 0x9fbb40, MSVC's _ftol2_sse: `cvttsd2si`, or the
//     x87 fallback with its truncation fix-up -- toward zero either way, as
//     Go's conversion is. The Go arithmetic is float64 in the same order,
//     which matches the x87 at the Windows default 53-bit precision control;
//     this function does not set the control word itself.
//
// srrevamp models no Str/Int bonuses, so the character's own Str and Int are
// passed for GetParam(1)/(2) -- the same values MaxHP and MaxMP are built
// from.
func potionRestore(param1, param2, param3, param4, level, str, intel, maxHP, maxMP int) (hp, mp int) {
	if param1 == 0 && param3 == 0 {
		percent := func(pct, pool int) int {
			frac := float32(float64(pct) / potionPercentDivisor)
			return int(float64(pool) * float64(frac))
		}
		if param2 != 0 {
			hp = percent(param2, maxHP)
		}
		if param4 != 0 {
			mp = percent(param4, maxMP)
		}
		return hp, mp
	}
	n := int(uint8(level)) - 1
	m := n
	if m < 0 {
		m = -m
	}
	growth, base := 1.0, character.StatGrowth
	for {
		if m&1 != 0 {
			growth *= base
		}
		m >>= 1
		if m == 0 {
			break
		}
		base *= base
	}
	if n < 0 {
		growth = 1 / growth
	}
	hp = int((1 + float64(float32(str))/potionStatDivisor) * growth * float64(param1))
	mp = int((1 + float64(float32(intel))/potionStatDivisor) * growth * float64(param3))
	return hp, mp
}

// The per-kind potion lock (round 508). A recovery potion carries no COOLTIME
// descriptor, but CGItemExpendable slot 308 (0x0049b710) keeps a reuse lock of
// its own, one bit per recovery kind, in the word at [pc+0x30]+8:
//
//   - The gate. Slot 308's first act for TypeID3 1 (after sending TypeID4 8
//     to AddHwanCount) is GObjPC::FUN_004eb410 (0x49b8b6); a zero answer is
//     0x185b WAIT_FOR_REUSE_DELAY (0x49b8c2), and CGItemExpendable::DoJob
//     (0x0049aca0) returns any result but 1 before it decrements the count
//     (LAB_0049af45), so the refused potion is kept. FUN_004eb410 maps the
//     kind to a bit through the jump table at 0x4eb574 and answers whether
//     that bit is clear in the BYTE at [pc+0x30]+8 (0x4eb42b `movzx`).
//   - The arm. After the heal, FUN_004e0ab0 (0x49b98e, EBX = the bit from the
//     gate, 0x49b97e) ORs the bit in (0x4e0ac0) and queues an AJStateChanger
//     record of type 6 (0x4e0af6) carrying the bit (+0xd) and a float32 delay
//     (+0x10, 0x4e0aec) on the PC's job manager at pc+0x1d8 (0x4e0af0).
//   - The unit is SECONDS. The manager's update, FUN_004065d0, takes
//     GetTickCount minus the last update (0x4065e8..0x4065f0), converts it
//     with `fdiv QWORD PTR ds:0xb45c68` -- the double 1000.0, bytes 00 00 00
//     00 00 40 8f 40 (0x406605) -- and hands that to each record's vtable +8,
//     AJStateChanger::vslot_002, which subtracts it from +0x10 (0x405f79
//     `fld`, 0x405f7c `fsub`) and keeps the record while the rest is above 0
//     (0x405f94).
//   - The release. When it reaches 0, vslot_002's type-6 case clears exactly
//     that bit (0x4060da `movzx edx,BYTE [edi+0xd]`, 0x4060e2 `not edx`,
//     0x4060e4 `and edx,ecx`, 0x4060e6 store) and the record is dropped.
//
// So each kind locks only itself: an HP potion's bit does not stop an MP
// potion, and a percentage HP potion shares the absolute one's bit.
//
// DISCLOSED, not modelled:
//   - The manager is ticked every 0.3 s, not continuously: CGObjChar::vslot_000
//     registers the thunk 0x4a6990 (`lea eax,[ecx+0x1d8]; jmp 0x4065d0`) on
//     the timer vector at +0x18c with the float 0.3 at 0xb45b8c (0x4a6e29),
//     the vector whose 1.0 entry is the one-second job (round 411). And a
//     record armed while others are queued is first decremented by the time
//     since the last tick, not since the arm (FUN_004066a0 resets the clock
//     only when the list is empty). So retail frees the bit on a tick, within
//     about 0.3 s either side of the delay; srrevamp frees it at the delay.
//   - GObjPC::FUN_004e67b0 zeroes the whole word and drops the type-6 records
//     (0x4e67c8 FUN_004066c0(6), 0x4e67d0). CGObjPC slots 306 and 307
//     (0x529b10, 0x52cdb0) call it; their pet and mercenary versions set life
//     state 2 (docs/protocol/character_state.md). srrevamp does not clear the
//     lock there, so a potion drunk just before one of those paths stays
//     locked for the rest of its delay.
//   - The lock lives on the PC object in the engine and in the handler here,
//     so a relog inside the delay does not clear it in srrevamp.
const (
	// potionReuseAbsoluteChina is the float32 1.1 at .rdata 0xb461b8 (bytes
	// cd cc 8c 3f; 1.10000002 s, 24 ns over 1100 ms), loaded by
	// 0x49b96c `fld DWORD` for an absolute potion when the Country byte is 0.
	potionReuseAbsoluteChina = 1100 * time.Millisecond
	// potionReuseAbsoluteEurope is the float32 15.1 at 0xb461ac (bytes
	// 9a 99 71 41; 15.1000004 s), 0x49b978 `fld DWORD`, for an absolute potion
	// when the Country byte is non-zero. Every srrevamp character is China
	// (characterCountry), so nothing selects it today.
	potionReuseAbsoluteEurope = 15100 * time.Millisecond
	// potionReusePercentage is the float32 4.1 at 0xb461b0 (bytes 33 33 83
	// 40; 4.09999990 s, 95 ns under 4100 ms), 0x49b964 `fld DWORD`, for a
	// percentage potion whatever the Country.
	potionReusePercentage = 4100 * time.Millisecond
)

// potionReuseBit is FUN_004eb410's kind-to-bit map for TypeID3 1, the jump
// table at 0x4eb574 indexed by TypeID4-1 (0x4eb4c2 `add eax,-1`): 1 -> 1
// (0x4eb4d1), 2 -> 2 (0x4eb4ec), 3 -> 4 (0x4eb507). The table's 4, 5 and 7
// (8, 0x10, 0x20) are kinds DoJob sends to slot 327, not to slot 308, and
// restoresUserPool refuses them before this is asked. Any other kind that
// reaches slot 308 has no bit: index 5 and anything past the table's 7
// entries (`cmp eax,0x6; ja`, 0x4eb4c5) go to 0x4eb493, which answers 0 --
// always 0x185b. No real recovery row has such a kind.
func potionReuseBit(typeID4 int) (bit uint32, ok bool) {
	switch typeID4 {
	case 1:
		return 1, true
	case 2:
		return 2, true
	case 3:
		return 4, true
	}
	return 0, false
}

// potionReuseDelay is the delay slot 308 hands FUN_004e0ab0, chosen at
// 0x49b957..0x49b978 by the Country byte of the PC's ref row (+0x88; 0 China,
// 1 Europe, round 480) and FUN_0049aa70's absolute flag, which it sets to 1 at
// 0x49ac37 on the absolute path (Param1 or Param3 non-zero) and to 0 at
// 0x49ab42 on the percentage path:
//
//	cmp BYTE [edx+0x88],0 ; jne 0x49b974
//	test esi,esi ; jne -> 1.1 ; else 4.1       (China)
//	0x49b974: test esi,esi ; je -> 4.1 ; 15.1  (any other Country)
func potionReuseDelay(country int, absolute bool) time.Duration {
	if !absolute {
		return potionReusePercentage
	}
	if country == equipment.CountryChina {
		return potionReuseAbsoluteChina
	}
	return potionReuseAbsoluteEurope
}

// useItemClock is the handler's clock, a variable so a test can step it
// through the reuse delays without waiting them out.
var useItemClock = time.Now

// The potion queue (round 509). Slot 308 does not write a potion's amounts
// straight into the pools: it hands them to GObjPC::FUN_004ef450 (0x49b946,
// HP in ECX, MP in EAX, FUN_0049aa70's absolute flag in EDX), which pushes
// (pc+0x1d58, flag, HP, MP) into FUN_0049a5b0 (0x4ef450..0x4ef45d). pc+0x1d58
// holds two lists, HP (sentinel +0x4, size +0x8) and MP (+0x10, +0x14), and
// the PC at +0x18. Each node is {next, prev, step (+0x8), count (+0xc)}
// (FUN_004a0f30, 0x4a0f75..0x4a0fa2), appended at the tail (0x49a776..0x49a79e
// and 0x49a7e2..0x49a80d), so each pool is a FIFO.
//
//   - Absolute (flag 1, 0x49a733..0x49a836). For HP, when the amount is above
//     0 and the pool plus what its list still holds (FUN_0049a110: the sum of
//     step x count) does NOT EXCEED the maximum (0x49a768 `cmp ebx,esi; jg`
//     skips), FUN_0049a0c0 builds {amount/5, 4} and it is queued. For MP the
//     test is strict (0x49a7d4 `cmp ebx,esi; jge` skips), so a full MP pool
//     queues nothing while a full HP pool still queues. What was queued lands
//     its first step at once (0x49a82a ApplyHPMPDelta with the two steps).
//   - Percentage (flag 0, 0x49a5cb..0x49a726). Each non-zero amount trims its
//     pool's list -- emptied outright when the amount alone overflows the
//     pool (0x49a634 `jle` not taken -> 0x695450, which frees every node),
//     otherwise cut after the first entry whose step x count carries
//     cur + amount - max above zero (0x49a662..0x49a6de) -- and the whole
//     amount lands at once (0x49a71a ApplyHPMPDelta).
//   - The tick. FUN_0049a510 takes ONE step from the HEAD entry of each
//     non-empty list (0x49a533 `mov esi,[edx]`), decrements its count and
//     unlinks it at zero (0x49a554..0x49a56a), then applies both steps
//     (0x49a58f) -- so a second potion's steps wait behind the first's.
//     CGObjPC::PeriodicUpdate (0x52aa90, CGObjPC slot 415) calls it on every
//     pass, unconditionally (0x52acc9 `lea eax,[edi+0x1d58]`, 0x52acd0 call).
//
// Slot 308 answers 1 after FUN_004ef450 whatever was queued (0x49b996), so
// the potion is spent even when nothing lands -- at full HP, or with the pool
// plus the queue already past the maximum. srrevamp used to refuse such a
// potion as "no need for that right now" and keep it.
const (
	// potionStepDivisor: FUN_0049a0c0's `mov eax,0x66666667; imul DWORD
	// [esp+0x4]; sar edx,1; shr eax,0x1f; add eax,edx` (0x49a0c0..0x49a0d0),
	// a signed division by 5 truncated toward zero, as Go's is. So a
	// 123-point potion steps 24, and lands 5 x 24 = 120.
	potionStepDivisor = 5
	// potionStepCount is `mov DWORD PTR [esi+0x4],0x4` (0x49a0d6): the steps
	// still to come once FUN_0049a5b0 has landed the first.
	potionStepCount = 4
	// potionStepMax: a step of 1000000 or more is 1000000 (0x49a0f7
	// `cmp eax,0xf4240; jl`), and a step below 1 is 1 (0x49a0e6
	// `cmp eax,0x1; jge`).
	potionStepMax = 1000000
	// potionTickInterval is the period of the job that runs PeriodicUpdate.
	// CGObjChar::Create registers `fld1` -- 1.0 -- with the thunk 0x4ac6b0
	// (`jmp [eax+0x5b0]`, slot 364) on the timer vector at +0x18c
	// (0x4a702b..0x4a7042); CGObjPC slot 364 (0x4eb780) calls the world
	// context's slot 11, CWorldContextController::UpdatePC (0x605010), whose
	// whole body is `pc->PeriodicUpdate()` (vtable +0x67c). The vector is
	// ticked in seconds (round 223, mana.RegenInterval's note).
	potionTickInterval = time.Second
)

// The two lists at pc+0x1d58, in FUN_0049a110's index (ECX 0 at 0x49a75b, 1
// at 0x49a7c4) and FUN_0049a510's loop order.
const (
	potionPoolHP = 0
	potionPoolMP = 1
)

// potionEntry is one queued node's payload: the step and the steps left.
type potionEntry struct {
	step  int // node +0x8
	count int // node +0xc
}

// newPotionEntry is GObjPC::FUN_0049a0c0 (0x49a0c0): {amount/5, 4}, the step
// clamped to 1..1000000.
func newPotionEntry(amount int) potionEntry {
	step := amount / potionStepDivisor
	if step < 1 {
		step = 1
	} else if step >= potionStepMax {
		step = potionStepMax
	}
	return potionEntry{step: step, count: potionStepCount}
}

// PotionQueue is every character's pc+0x1d58: an HP and an MP list of
// queued potion steps. The handler lands a potion through it and
// RunPotionQueue steps it once a second. The zero value is not usable; call
// NewPotionQueue.
//
// Its lock is held across a whole drink or a whole step for one character --
// the read of the pools, the queue decision and the write -- because the
// engine runs both on the PC's own thread, and a step landing between the
// read and the decision would skew the pool-plus-queue test.
type PotionQueue struct {
	mu    sync.Mutex
	pools map[int64]*[2][]potionEntry
}

// NewPotionQueue returns an empty queue.
func NewPotionQueue() *PotionQueue {
	return &PotionQueue{pools: map[int64]*[2][]potionEntry{}}
}

// queuedLocked is FUN_0049a110 (0x49a110): the sum of step x count over one
// pool's list (0x49a12a `mov edi,[ecx+0xc]; imul edi,[ecx+0x8]`).
func (q *PotionQueue) queuedLocked(characterID int64, pool int) int {
	lists := q.pools[characterID]
	if lists == nil {
		return 0
	}
	sum := 0
	for _, e := range lists[pool] {
		sum += e.step * e.count
	}
	return sum
}

func (q *PotionQueue) pushLocked(characterID int64, pool int, e potionEntry) {
	lists := q.pools[characterID]
	if lists == nil {
		lists = &[2][]potionEntry{}
		q.pools[characterID] = lists
	}
	lists[pool] = append(lists[pool], e)
}

// trimLocked is the percentage path's cut for one pool, over = cur + amount -
// max (0x49a62d..0x49a632). Above zero the list is emptied (0x695450);
// otherwise each entry's step x count is added in turn from the head, and the
// list is cut after the first entry that carries over above zero -- that
// entry is kept whole (0x49a673..0x49a681 starts the erase at its NEXT node).
func (q *PotionQueue) trimLocked(characterID int64, pool, over int) {
	lists := q.pools[characterID]
	if lists == nil {
		return
	}
	if over > 0 {
		lists[pool] = nil
		return
	}
	for i, e := range lists[pool] {
		over += e.step * e.count
		if over > 0 {
			lists[pool] = lists[pool][:i+1]
			return
		}
	}
}

// landLocked is FUN_0049a5b0 on the pools' current values: it queues or trims
// and returns what lands at once.
func (q *PotionQueue) landLocked(characterID int64, absolute bool, hp, mp, curHP, maxHP, curMP, maxMP int) (nowHP, nowMP int) {
	if !absolute {
		if hp != 0 {
			q.trimLocked(characterID, potionPoolHP, curHP+hp-maxHP)
		}
		if mp != 0 {
			q.trimLocked(characterID, potionPoolMP, curMP+mp-maxMP)
		}
		return hp, mp
	}
	// 0x49a768 `cmp ebx,esi; jg`: HP is queued while the pool plus the queue
	// does not exceed the maximum -- a full pool with nothing queued included.
	if hp > 0 && curHP+q.queuedLocked(characterID, potionPoolHP) <= maxHP {
		e := newPotionEntry(hp)
		q.pushLocked(characterID, potionPoolHP, e)
		nowHP = e.step
	}
	// 0x49a7d4 `cmp ebx,esi; jge`: MP only while it stays BELOW the maximum.
	if mp > 0 && curMP+q.queuedLocked(characterID, potionPoolMP) < maxMP {
		e := newPotionEntry(mp)
		q.pushLocked(characterID, potionPoolMP, e)
		nowMP = e.step
	}
	return nowHP, nowMP
}

// takeLocked is FUN_0049a510 (0x49a510) for one character: one step from the
// head of each non-empty list, the head dropped once its count reaches zero.
func (q *PotionQueue) takeLocked(characterID int64) (hp, mp int) {
	lists := q.pools[characterID]
	if lists == nil {
		return 0, 0
	}
	var got [2]int
	for pool := range lists {
		if len(lists[pool]) == 0 {
			continue
		}
		head := &lists[pool][0]
		got[pool] = head.step
		head.count--
		if head.count <= 0 {
			lists[pool] = lists[pool][1:]
		}
	}
	if len(lists[potionPoolHP]) == 0 && len(lists[potionPoolMP]) == 0 {
		delete(q.pools, characterID)
	}
	return got[potionPoolHP], got[potionPoolMP]
}

// applyPotionLocked adds what landed to the pools, each clamped to its
// maximum as ApplyHPMPDelta's FUN_004a87d0 does through GObjChar::FUN_004a66f0
// (the GObjChar.h CLAMP), and returns the pools after.
func applyPotionLocked(ctx context.Context, chars character.Store, mp *mana.Tracker, characterID int64, hp, mpAmount, curHP, curMP, maxHP, maxMP int) (newHP, newMP int, err error) {
	newHP, newMP = curHP, curMP
	if hp > 0 {
		if newHP, err = chars.Heal(ctx, characterID, hp, maxHP); err != nil {
			return curHP, curMP, err
		}
	}
	if mpAmount > 0 && mp != nil {
		newMP = mp.Restore(characterID, maxMP, mpAmount)
	}
	return newHP, newMP, nil
}

// drink lands a recovery potion's amounts through the queue and returns the
// pools after it and what they gained at once. mp nil reports MP full, so an
// absolute MP amount queues nothing.
func (q *PotionQueue) drink(ctx context.Context, chars character.Store, mp *mana.Tracker, characterID int64, absolute bool, hp, mpAmount, maxHP, maxMP int) (newHP, newMP, gotHP, gotMP int, err error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return 0, 0, 0, 0, err
	}
	curMP := maxMP
	if mp != nil {
		curMP = mp.Current(characterID, maxMP)
	}
	nowHP, nowMP := q.landLocked(characterID, absolute, hp, mpAmount, c.HP, maxHP, curMP, maxMP)
	newHP, newMP, err = applyPotionLocked(ctx, chars, mp, characterID, nowHP, nowMP, c.HP, curMP, maxHP, maxMP)
	if err != nil {
		return 0, 0, 0, 0, err
	}
	return newHP, newMP, newHP - c.HP, newMP - curMP, nil
}

// step runs FUN_0049a510 for one character and applies what it took. It
// reports the character as it stands after, and whether a pool moved --
// FUN_004a87d0 flags the HP/MP update for the client only then (0x4a885c
// for HP, and its MP twin after it).
func (q *PotionQueue) step(ctx context.Context, chars character.Store, mp *mana.Tracker, characterID int64) (*character.Character, bool, error) {
	q.mu.Lock()
	defer q.mu.Unlock()
	hp, mpStep := q.takeLocked(characterID)
	// 0x49a57b..0x49a581: ApplyHPMPDelta only when either step is above 0.
	if hp <= 0 && mpStep <= 0 {
		return nil, false, nil
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return nil, false, err
	}
	maxHP, maxMP := c.MaxHP(), c.MaxMP()
	curMP := maxMP
	if mp != nil {
		curMP = mp.Current(characterID, maxMP)
	}
	newHP, newMP, err := applyPotionLocked(ctx, chars, mp, characterID, hp, mpStep, c.HP, curMP, maxHP, maxMP)
	if err != nil {
		return nil, false, err
	}
	changed := newHP != c.HP || newMP != curMP
	c.HP = newHP
	return c, changed, nil
}

// characters lists everyone with something queued.
func (q *PotionQueue) characters() []int64 {
	q.mu.Lock()
	defer q.mu.Unlock()
	ids := make([]int64, 0, len(q.pools))
	for id := range q.pools {
		ids = append(ids, id)
	}
	return ids
}

// drop discards a character's queue.
func (q *PotionQueue) drop(characterID int64) {
	q.mu.Lock()
	defer q.mu.Unlock()
	delete(q.pools, characterID)
}

// RunPotionQueue steps every queued potion once per potionTickInterval, the
// one-second PeriodicUpdate pass that calls FUN_0049a510 (0x52acd0), until ctx
// is canceled. deps build the stats push that moves the client's bars, as
// RunRegen's does.
//
// DISCLOSED, not modelled:
//   - Retail ticks each PC on its own timer, so the phase of the first step
//     after a drink is per character; here one ticker serves everyone. Either
//     way the second step lands up to a second after the first.
//   - Death. GObjPC::FUN_004e67b0, which CGObjPC slots 306 and 307 run while
//     the life state is 1 (0x529b10, 0x52cdb0; round 508), empties both
//     lists (0x4e67b7 -> FUN_0049a4c0), and ApplyHPMPDelta lands nothing
//     unless GetLifeState is 1 (0x4a87e8 `cmp al,0x1`). srrevamp respawns a
//     dead character at once (combat.go, RespawnHP) and does not clear the
//     queue there, so steps still queued land on the respawned character.
//   - Panic and combustion cut every step through ApplyHPMPDelta (params
//     143/144, UseItemHandler's note); srrevamp has no status effects.
func RunPotionQueue(ctx context.Context, hub *world.Hub, chars character.Store, q *PotionQueue, deps RegenDeps, logger *slog.Logger) {
	ticker := time.NewTicker(potionTickInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			potionQueueTick(ctx, hub, chars, q, deps, logger)
		}
	}
}

// potionQueueTick is one pass. Split out so a test can drive the steps
// without waiting a second for each.
//
// A character no longer in the world has its queue dropped: the engine's
// lives on the PC object (pc+0x1d58), which leaves with the character.
func potionQueueTick(ctx context.Context, hub *world.Hub, chars character.Store, q *PotionQueue, deps RegenDeps, logger *slog.Logger) {
	if hub == nil || chars == nil || q == nil {
		return
	}
	for _, id := range q.characters() {
		e, online := hub.EntityByCharacterID(id)
		if !online {
			q.drop(id)
			continue
		}
		c, changed, err := q.step(ctx, chars, deps.Mana, id)
		if err != nil {
			if logger != nil {
				logger.Warn("potion queue: step failed", "character", id, "err", err)
			}
			continue
		}
		if !changed || e.Session == nil {
			continue
		}
		// The stats reply is what the HUD already listens to (regen.go).
		if result, err := buildCharacterStats(ctx, c, c.ID, deps.Equipment, deps.Items, deps.Skills, deps.Mana); err == nil {
			_ = e.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
		}
	}
}

// UseItemHandler consumes one item from a bag slot and applies what it
// restores.
//
// The amounts are REAL: refdata.Item.RestoreHP/RestoreMP come from the item
// table's own Param block, where each value sits beside its own label ("HP..."
// at col 118, "MP..." at 122), so an HP_POTION_01 carries 120 health and the
// large one 370. They are restore amounts ONLY on the recovery kinds above:
// the exporter emits columns 118..124 for every row, and on a return scroll
// (30000), a cure pill or a storage expansion (its slot increment, round 270)
// the same columns hold something else.
//
// The Param block is not the amount that lands: GObjPC::FUN_0049aa70 scales an
// absolute amount by the user's level and Str (HP) or Int (MP), and reads the
// percentage pair only when both absolute amounts are zero (round 496,
// potionRestore). A level-1, 20-Str character gets 125 from HP_POTION_01's 120.
//
// That amount lands the engine's way, through potions (round 509, PotionQueue:
// FUN_004ef450 -> FUN_0049a5b0 on pc+0x1d58). An absolute amount is queued as
// five steps of amount/5, the first at once and the rest one a second
// (RunPotionQueue), so HP_POTION_01's 125 arrives as 25 now and 25 on each of
// the next four ticks; it is not queued while the pool plus what is already
// queued exceeds the maximum (HP) or reaches it (MP). A percentage amount
// lands in full at once and trims the queue. Either way the potion is SPENT --
// slot 308 answers 1 whatever landed -- so one drunk at full HP is used up.
// potions nil gives the handler a queue of its own that nothing steps: only
// what lands at once arrives (tests that do not follow the steps).
//
// Two DISCLOSED GAPS sit between it and the pool:
//
//   - A zombie (status bit 0x20 at pc+0xd34, the status manager at pc+0xd30;
//     slot 5 in docs/protocol/status_effects.md) is HURT by the HP amount:
//     0x49b912 sends it to vtable +0x308 (slot 194, IGObj::ConsumeHpMp) and
//     applies the MP amount directly. srrevamp has no status effects.
//   - Panic and combustion, the next paragraph.
//
// ApplyHPMPDelta's own step is a no-op ONLY while neither panic nor combustion
// is on the character, and srrevamp does not model it.
// GObjPC::FUN_004a86a0 (ApplyHPMPDelta) multiplies the HP amount by
// (1 - param143/100) and the MP amount by (1 - param144/100) before the adjust
// that writes the pool (`MOV EAX,0x8f` / `MOV EAX,0x90` into
// ParamKeeper_GetParamChecked 0x4b3740 on the keeper at +0x1ec, then 0x4a86c9
// `fdiv` by the 100.0 at .rdata 0xb45af0, `fld1`, `fsubrp` (DE E1: 1 - p/100),
// `fimul` the amount). The 2026-09-15 finding that "neither has a SetParam
// site anywhere in the binary" was wrong: AbnormalState_Panic_Apply21
// (0x4a5320) writes param 143 (0x4a5418 `mov edi,0x8f`; 0x4a541d
// `call 0x4b3510` ParamKeeper_SetParam) and AbnormalState_Combustion_Apply22
// (0x4a54a0) writes 144 (0x4a5598 `mov edi,0x90`; 0x4a559d), each from the
// effect's +0x34 value, while the state is on -- recorded since round 248 in
// docs/protocol/status_effects.md (bits 21/22) and
// docs/protocol/param_writers.md. So a panic (combustion) effect cuts a
// potion's HP (MP) by its percentage, and srrevamp heals the full amount
// regardless.
//
// An item whose CanUse bit is clear (refdata.Item.CanUse, itemdata column 24)
// is refused before its type or reuse delay is read, as the engine refuses it
// with 0x183e CANNOT_BE_USED before the TID match and the cooldown (round 489;
// the engine's rental-expiry 0x183d and life-state 0x1889 checks come earlier
// still). That bit is set on
// every HP/MP potion and clear on elixirs, alchemy stones, materials and all
// equipment but 28 cash-shop avatars -- rows whose Param block can still read
// as an HP/MP amount.
//
// An item that restores nothing is refused rather than silently eaten -- the
// bag is full of equipment and quest items that have no use yet, and quietly
// destroying one would be the worst possible answer. That includes every
// CanUse item that is not a recovery kind (round 491): a return scroll, a cure
// pill, a pet potion, a berserk potion, a resurrection scroll. The engine USES
// those -- each has its own DoJob branch -- and srrevamp models none of their
// effects, so it refuses them with the restores-nothing reason and keeps the
// item. That refusal is srrevamp's DISCLOSED GAP, not an engine refusal.
//
// The one non-recovery kind srrevamp does model is the container expansion
// (round 498, useExpansion): the warehouse item grows the account's
// warehouse through warehouse (nil refuses it), and the bag item is refused.
func UseItemHandler(chars character.Store, inv inventory.Store, items combat.ItemLookup, mp *mana.Tracker, warehouse *storage.Service, potions *PotionQueue) gateway.Handler {
	// The per-kind potion locks (round 508), keyed by character and
	// potionReuseBit. The handler is built once per server (cmd/server), so
	// this is process-wide there, as the item cooldowns are.
	potionLocks := newItemCooldownTracker()
	if potions == nil {
		potions = NewPotionQueue()
	}
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpUseItem {
			return nil
		}
		fail := func(reason string) error {
			return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: reason}).Encode()})
		}
		req, err := DecodeUseItemRequest(p.Data)
		if err != nil {
			return fail("malformed request")
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return fail(errStr)
		}
		if inv == nil || items == nil {
			return fail("cannot use items")
		}

		slots, err := inv.List(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		var itemID int64 = -1
		var have int
		var held inventory.Slot
		for _, sl := range slots {
			if sl.Index == int(req.InventorySlot) {
				itemID, have, held = sl.ItemID, sl.Quantity, sl
				break
			}
		}
		if itemID < 0 || have < 1 {
			return fail("nothing there")
		}
		it, err := items.GetItem(ctx, itemID)
		if err != nil || it == nil {
			return fail("nothing known about that item")
		}
		// The item's own CanUse bit (round 489): Item_HandleUseItem
		// (0x00510980) -- after the empty-slot (0x1809), rental-expiry
		// (FUN_00492680, 0x183d) and life-state (0x1889) checks, which
		// srrevamp does not model here (round 490) -- calls vtable slot
		// 0xe0 -- IGObj::CanUse, CGObj::CanUse 0x00483ee0 on every CGItem*
		// class, flags bit 8 of the ref row -- and a zero answers 0x183e
		// UIIT_MSG_STRGERR_CANNOT_BE_USED before the TID match and the
		// cooldown are consulted.
		if !it.CanUse {
			return fail("that item cannot be used")
		}
		// A container expansion (round 498): its Param block is a slot count
		// and a container, never a restore amount.
		if container, n, ok := it.ContainerExpansion(); ok {
			return useExpansion(ctx, sess, fail, inv, warehouse, characterID, held, have, container, n)
		}
		// Only a recovery kind's Param block is a restore amount (round 491,
		// restoresUserPool); any other kind's effect is not modelled.
		if !restoresUserPool(it) {
			return fail("that cannot be used")
		}
		if it.RestoreHP <= 0 && it.RestoreMP <= 0 && it.RestoreHPPct <= 0 && it.RestoreMPPct <= 0 {
			return fail("that cannot be used")
		}
		// The reuse delay, the engine's way (round 263): only an item whose
		// row carries a COOLTIME descriptor has one, the timer belongs to the
		// item's cooltime GROUP, and a use inside it is refused with
		// WAIT_FOR_REUSE_DELAY (0x185b). Item_HandleUseItem asks it
		// (ItemCooldowns::IsReady) before DoJob.
		now := useItemClock()
		if it.CooltimeMs > 0 && !itemCooldowns.Ready(characterID, it.CooltimeGroup, now) {
			return fail("wait for the reuse delay")
		}
		// A plain HP/MP potion carries no COOLTIME descriptor, but slot 308
		// locks each recovery kind on its own (round 508, potionReuseBit):
		// FUN_004eb410 is the first thing slot 308 asks, before the amounts
		// (FUN_0049aa70) are computed, and it answers the same 0x185b. The
		// item is kept.
		reuseBit, knownKind := potionReuseBit(it.TypeID4)
		if !knownKind || !potionLocks.Ready(characterID, reuseBit, now) {
			return fail("wait for the reuse delay")
		}

		owned, err := chars.GetByID(ctx, characterID)
		if err != nil {
			return fail("lookup failed")
		}
		maxHP := owned.MaxHP()
		maxMP := owned.MaxMP()

		// The engine's amounts (round 496): scaled by level and Str/Int, the
		// percentage pair only when both absolutes are zero.
		healHP, healMP := potionRestore(it.RestoreHP, it.RestoreHPPct, it.RestoreMP, it.RestoreMPPct,
			owned.Level, owned.Str, owned.Int, maxHP, maxMP)
		// Slot 308's own refusal: both amounts below 1 answers 2 and the
		// potion is kept (0x49b8ef..0x49b8fe, before any pool is touched). It
		// is the answer the all-zero Param block above gets too, so it shares
		// that reason.
		if healHP < 1 && healMP < 1 {
			return fail("that cannot be used")
		}
		// FUN_0049aa70's flag: 1 on the absolute path (Param1 or Param3
		// non-zero, 0x49ac37), 0 on the percentage path (0x49ab42).
		absolute := it.RestoreHP != 0 || it.RestoreMP != 0

		// Landed through the queue (round 509, PotionQueue): an absolute
		// potion's first step now and the rest by RunPotionQueue, a
		// percentage one in full now. Nothing landing -- a full pool, or the
		// pool plus the queue past the maximum -- is not a refusal: slot 308
		// answers 1 after FUN_004ef450 whatever was queued (0x49b996), and
		// DoJob then spends the potion.
		newHP, newMP, gotHP, gotMP, err := potions.drink(ctx, chars, mp, characterID, absolute, healHP, healMP, maxHP, maxMP)
		if err != nil {
			return fail("healing failed")
		}

		if err := inv.RemoveItem(ctx, characterID, int(req.InventorySlot), 1); err != nil {
			return fail("using failed")
		}
		remaining := have - 1
		// Armed after the use succeeds, as Item_HandleUseItem does (its
		// 0x64c320 call sits behind the success reply). In memory only: the
		// engine persists a delay of five minutes or more across a relog,
		// srrevamp does not yet -- disclosed.
		if it.CooltimeMs > 0 {
			itemCooldowns.Arm(characterID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
		}
		// The kind's lock (round 508): FUN_004e0ab0 after the heal, for the
		// delay chosen by the Country and FUN_0049aa70's absolute flag
		// (potionReuseDelay). A potion drunk at full HP is armed too, as the
		// engine arms it (round 509; round 496's full-HP divergence, closed).
		potionLocks.Arm(characterID, reuseBit, potionReuseDelay(characterCountry(owned), absolute), now)

		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
			HP: int32(newHP), MaxHP: int32(maxHP),
			MP: int32(newMP), MaxMP: int32(maxMP),
			RestoredHP: int32(gotHP), RestoredMP: int32(gotMP),
			Remaining: int32(remaining),
		}).Encode()})
	}
}

// errStorageExpansionRefused is the expansion item's refusal: the engine's
// 0x18fe UIIT_STT_STORAGE_EXPANSION_USE_ERORR (docs/protocol/error_codes.md),
// which CGObjPC::ExpandInventory (0x004e1910) returns for either container
// when the amount does not fit (0x4e1957 `mov ax,0x18fe`) and
// CGItemExpendable::UseByKind (0x0049c2b0) case 0x11 hands back as the use's
// result. The item is kept: CGItemExpendable::DoJob (0x0049aca0) returns any
// result but 1 before it decrements the count (LAB_0049af45).
const errStorageExpansionRefused = "the storage cannot be expanded that far"

// bagExpansionAllowed is ExpandInventory's kind-0 test (0x4e195f..0x4e1989):
// `count <= cap - size` (0x4e197e `sub eax,ecx ; cmp eax,esi ; jl` refused)
// and `size + count <= 0x63` (0x4e1986 `cmp ecx,0x63 ; jg` refused). The
// engine's size counts the 13 equipment slots as well as the backpack
// (inventory.go, "HOW TO READ THE BOUNDS BELOW"), so srrevamp's is
// SlotsPerCharacter + MaxEquipSlots = 63. cap is MaxSlotsDefault, 77: the
// quest flag that raises it to 99 (GObjPC::HasInventoryExpansionQuest,
// inventory.ExpansionQuestCodes) is not modelled -- srrevamp keeps no quest
// status 8. With srrevamp's fixed bag the 32-slot item never fits (32 > 14).
func bagExpansionAllowed(slots int) bool {
	size := inventory.SlotsPerCharacter + equipment.MaxEquipSlots
	return slots <= inventory.MaxSlotsDefault-size && size+slots < inventory.SlotsHardLimit
}

// useExpansion applies a container expansion item -- CGItemExpendable::UseByKind
// (0x0049c2b0) case 0x11 (round 498): ExpandInventory with the row's Param1
// byte, container kind 0 (the bag) for Param2 0 and 3 (the warehouse) for 1.
//
//   - The warehouse (ITEM_MALL_WAREHOUSE_ADDITION, +30) grows the ACCOUNT's
//     warehouse through storage.Service.Expand, refused with 0x18fe once the
//     size would pass 210. The size is checked first so a refusal keeps the
//     item untouched; the item is then taken and the size grown atomically,
//     and a refusal there (a second use racing this one) gives it back.
//   - The bag (ITEM_MALL_INVENTORY_ADDITION, +32) runs the engine's kind-0
//     test, which srrevamp's fixed 63-slot array always fails; the item is
//     refused and kept. A smaller amount that passed would still be refused:
//     srrevamp's bag cannot grow (inventory.SlotsPerCharacter) -- a DISCLOSED
//     GAP.
//
// Not modelled: UseByKind's opening refusal 0x186b
// UIIT_MSG_STRGERR_CANT_OPERATE_REQUESTED_JOB_DURING_LOGOUT (the byte at
// [owner+0x30]+0x11 not 1), since srrevamp has no logout state here. The two
// rows carry no COOLTIME descriptor (their Param3..20 read -1 / "xxx"), so
// there is no reuse delay to consult.
//
// The reply carries no HP/MP: MaxHP 0 tells the client to leave its bars
// alone (World3D._on_use_item_result), and Remaining is the stack after the
// use. It carries no capacity either, and the client redraws only the bag on
// it, so a warehouse window left open keeps its old page count until it is
// reopened or an accepted deposit/withdraw relists it (hud_panels.gd takes
// the capacity only from the storage list) -- a DISCLOSED gap.
func useExpansion(ctx context.Context, sess *gateway.Session, fail func(string) error, inv inventory.Store,
	warehouse *storage.Service, characterID int64, held inventory.Slot, have, container, slots int) error {
	if container == refdata.ExpansionContainerBag {
		if !bagExpansionAllowed(slots) {
			return fail(errStorageExpansionRefused)
		}
		return fail("the bag cannot be expanded")
	}
	if warehouse == nil {
		return fail("the storage cannot be expanded here")
	}
	cur, err := warehouse.Capacity(ctx, characterID)
	if err != nil {
		return fail("lookup failed")
	}
	if cur+slots > storage.MaxCapacity {
		return fail(errStorageExpansionRefused)
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return fail("using failed")
	}
	if _, err := warehouse.Expand(ctx, characterID, slots); err != nil {
		if backErr := inv.AddItemInstance(ctx, characterID, held.ItemID, 1, held.Instance()); backErr != nil {
			return fail("using failed, and the item could not be returned")
		}
		if errors.Is(err, storage.ErrExpansionRefused) {
			return fail(errStorageExpansionRefused)
		}
		return fail("using failed")
	}
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1)}).Encode()})
}
