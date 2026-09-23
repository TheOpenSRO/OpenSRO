package session

import (
	"context"
	"encoding/binary"
	"fmt"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
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
// srrevamp applies that amount at once, capped at the missing amount. Three
// DISCLOSED GAPS sit between it and the pool:
//
//   - The engine does not land an absolute amount at once. Slot 308 hands it
//     to GObjPC::FUN_004ef450 (0x49b946), which queues it on pc+0x1d58
//     through FUN_0049a5b0: FUN_0049a0c0 cuts it into a step of amount/5
//     (0x49a0c0 `imul 0x66666667; sar edx,1`, clamped to 1..1000000) with a
//     count of 4 (0x49a0d6); the first step is applied at once (0x49a82a
//     ApplyHPMPDelta) and each remaining one by FUN_0049a510, which
//     CGObjPC::PeriodicUpdate (0x52aa90, the one-second job, round 411)
//     calls on every tick (0x52acd0) and which takes a step from the head
//     entry of each pool's queue. So a potion lands in five equal steps a
//     second apart, 5 x (amount/5) in total, and a new entry is not queued
//     while the pool plus what is queued already exceeds (HP, 0x49a76a
//     `jg`) or reaches (MP, 0x49a7d6 `jge`) the maximum. A percentage
//     amount lands in full at once (FUN_0049a5b0's other path). srrevamp
//     models no queue.
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
// pill, a pet potion, a berserk potion, a resurrection scroll, a storage
// expansion. The engine USES those -- each has its own DoJob branch -- and
// srrevamp models none of their effects, so it refuses them with the
// restores-nothing reason and keeps the item. That refusal is srrevamp's
// DISCLOSED GAP, not an engine refusal.
func UseItemHandler(chars character.Store, inv inventory.Store, items combat.ItemLookup, mp *mana.Tracker) gateway.Handler {
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
		for _, sl := range slots {
			if sl.Index == int(req.InventorySlot) {
				itemID, have = sl.ItemID, sl.Quantity
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
		// WAIT_FOR_REUSE_DELAY (0x185b). A plain HP/MP potion carries no
		// COOLTIME descriptor -- but slot 308 has a per-kind potion gate of
		// its own (round 496; NOT modelled, a DISCLOSED GAP): FUN_004eb410
		// answers 0x185b while the kind's bit (TypeID4 1/2/3 -> 1/2/4) is set
		// in the byte at [pc+0x30]+8, and after a use FUN_004e0ab0 sets it
		// with a float32 of 1.1 (.rdata 0xb461b8), 15.1 (0xb461ac, when the
		// byte at the PC's ref row +0x88 is non-zero) or 4.1 (0xb461b0, a
		// percentage potion), handed to a state-changer record. Its unit and
		// what clears the bit were not read.
		if it.CooltimeMs > 0 && !itemCooldowns.Ready(characterID, it.CooltimeGroup, time.Now()) {
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

		// Health first. Healing is capped at the missing amount so the
		// reported "restored" figure is what the player actually got, not
		// what the label promises.
		missingHP := maxHP - owned.HP
		if missingHP < 0 {
			missingHP = 0
		}
		if healHP > missingHP {
			healHP = missingHP
		}
		newHP := owned.HP
		if healHP > 0 {
			newHP, err = chars.Heal(ctx, characterID, healHP, maxHP)
			if err != nil {
				return fail("healing failed")
			}
		}

		newMP := maxMP
		if mp != nil {
			cur := mp.Current(characterID, maxMP)
			missingMP := maxMP - cur
			if healMP > missingMP {
				healMP = missingMP
			}
			if healMP < 0 {
				healMP = 0
			}
			mp.Restore(characterID, maxMP, healMP)
			newMP = cur + healMP
		} else {
			healMP = 0
		}

		// Nothing to gain is not a reason to spend the potion.
		if healHP <= 0 && healMP <= 0 {
			return fail("no need for that right now")
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
			itemCooldowns.Arm(characterID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, time.Now())
		}

		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
			HP: int32(newHP), MaxHP: int32(maxHP),
			MP: int32(newMP), MaxMP: int32(maxMP),
			RestoredHP: int32(healHP), RestoredMP: int32(healMP),
			Remaining: int32(remaining),
		}).Encode()})
	}
}
