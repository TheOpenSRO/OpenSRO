package session

// The buff requirement re-check (round 839, lane P): what a running buff does
// when the devil's (or angel's) spirit that let it be cast is taken off or
// runs out. Everything READ in SR_GameServer.exe unless labelled.
//
// GObjPC::FUN_0059f0e0 (s:0x59f0e0, called with the skill book pc+0xa30)
// walks the book's running records. A record its owner cast on itself (ctx
// +0x20 == 1) whose skill carries a 'reqi' list (refskill +0x3a0) has the list
// evaluated again, the cast gate's way (Skill_CheckCastRequirement 0x58d480):
// kinds 1/2/3/9/10/11 the armour parts, 4 the shield, 6 the weapon, and kind
// 14 value 1 -- the avatar storage's item at index 4 (vslot +0x584(4) is
// CGObjChar 0x4a6910, CGStorage::GetItem on pc+0x1c34) present and passing
// FUN_00498610 (s:0x498610: a 3/1/14 item whose time is over fails, any other
// item passes). 'reqn' (+0x3b4) makes the list ALL-of. Then refskill +0x65,
// Basic_Activity (skilldata column 8, docs/protocol/skill_fields.md), decides:
//
//   - 0, a passive: its params are taken off while the list fails
//     (ParamKeeper_RemoveContributionsOf, record +0x10 = 0) and put back
//     (ApplySkillParamsToChar) when it holds again. OpenSRO keeps no passive
//     records, and no kind-14 skill is passive (below), so nothing is modelled
//     for it.
//   - non-zero, an active buff: a failing list ends it (FUN_0059eff0(0), its
//     0xB072), unless its Basic_Code holds "SKILL_CH_FIRE_SHIELD_"
//     (FUN_009dddc0 on refskill +0xc).
//
// Who runs it: CGItemEquip::DetachAbilityByItemOptLevel (s:0x50f1f0, from
// CGObjPC::StorageOperation s:0x50f941) after an equipment move (type 0 with
// an equipment slot, type 7) or an avatar move (0x23 / 0x24) that changed a
// worn item (s:0x50f53f), and CGObjPC::ChangeItemDurability (s:0x4e71a2).
// The spirit's expiry while worn does NOT run it: the 10-second rental check
// (CGObjChar::Create registers 0x4ac6d0 at 10.0, s:0x4a707b -> vslot_365
// 0x4eb7a0 -> CGStorage::CheckRentalItemValidity 0x4b9060 -> the avatar
// storage's slot 37, DetachAbilityByItemOptLevel s:0x4bbd60) removes the
// item's params, takes its skills out of the book (0x498050 -> 0x4984c0 ->
// 0x59eac0, which frees only the learned entry, not a record's context) and
// sends 0x3078 {3, slot}, and calls nothing else (its disassembly
// 0x4bbd60..0x4bbe4f). So a buff the spirit's skill started keeps running to
// its own end after the spirit runs out, until the next re-check (READ by
// absence in that function; that no other path ends it is INFERRED).
//
// MEASURED (the archive's skilldata through export-refdata, 2026-10-28): 23
// skills carry a kind-14 entry, every one the list "14:1" alone with no
// 'reqn' -- the 21 skills refskillbyitemoptleveldata gives the devil's and
// angel's spirits (SKILL_MALL_NASRUN_*, SKILL_MALL_AMALRUN_*,
// SKILL_EVENT_NASRUN_ECCENTRICDEMON_01) and the two CELESTIAL_WAR rows -- all
// Basic_Activity 1 or 2 (active), 'dura' 300, 600 or 1800 s.
//
// OURS, disclosed: OpenSRO runs the re-check at the avatar moves only, and
// there only for the records whose list holds a kind-14 entry. The equipment
// moves and the durability change (the weapon, shield and armour kinds) do
// not run it yet -- a buff whose weapon was swapped away keeps running, as it
// did before this round (OPEN).

import (
	"context"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// spiritReqSlot is the avatar storage index kind 14 reads (s:0x59f284 `push
// 0x4`).
const spiritReqSlot = 4

// fireShieldCode is the Basic_Code fragment FUN_0059f0e0 spares (s:0x59f391
// pushes the string at 0xafd9dc for FUN_009dddc0; a hit skips the end).
const fireShieldCode = "SKILL_CH_FIRE_SHIELD_"

// spiritReqHolds is kind 14 value 1's test over the avatar storage held
// (avatar.List's) at now: index 4 holds an item, and it is not a devil's spirit whose
// time is over.
func spiritReqHolds(held []avatar.Held, now time.Time) bool {
	for _, h := range held {
		if h.Slot.Index != spiritReqSlot || h.Item == nil {
			continue
		}
		if avatar.IsDevilSpirit(h.Item) {
			return avatar.Awake(h.Slot.Durability, now)
		}
		return true
	}
	return false
}

// spiritReqKind reports whether reqs holds a kind-14 entry.
func spiritReqKind(reqs []combat.CastRequirement) bool {
	for _, r := range reqs {
		if r.Kind == combat.CastReqFlagKind {
			return true
		}
	}
	return false
}

// buffReqsHold is FUN_0059f0e0's list walk for a kind-14 list: the kind-14
// value-1 entries answer spirit, the others pass (OURS: the equipment kinds
// are not re-checked here, see the file's note). all is 'reqn'.
func buffReqsHold(reqs []combat.CastRequirement, all bool, spirit bool) bool {
	if len(reqs) == 0 {
		return true
	}
	for _, r := range reqs {
		ok := true
		if r.Kind == combat.CastReqFlagKind {
			ok = r.Value == 1 && spirit
		}
		if all && !ok {
			return false
		}
		if !all && ok {
			return true
		}
	}
	return all
}

// buffReqFails reports whether the re-check ends rec: a self-cast active
// record of a skill whose kind-14 list no longer holds (not a fire shield).
func buffReqFails(rec buff.Record, row *refdata.Skill, spirit bool) bool {
	if row == nil || !rec.SelfCast() || rec.Activity == 0 {
		return false
	}
	reqs := combat.ParseCastRequirements(row.ReqCastList)
	if !spiritReqKind(reqs) {
		return false
	}
	if strings.Contains(row.BasicCode, fireShieldCode) {
		return false
	}
	return !buffReqsHold(reqs, row.ReqCastAll, spirit)
}

// recheckSpiritBuffs is the re-check after an avatar move of characterID's
// (s:0x50f53f): every running buff of its own whose spirit requirement no
// longer holds ends, and its zone hears the OpBuffEnd. held is the avatar
// storage after the move.
func recheckSpiritBuffs(hub *world.Hub, characterID int64, held []avatar.Held, now time.Time) []buff.Record {
	spirit := spiritReqHolds(held, now)
	l := buffLock(characterID)
	l.Lock()
	defer l.Unlock()
	ended, sp := buffBooks.EndWhere(characterID, func(r buff.Record) bool {
		return buffReqFails(r, rowOf(false, characterID, r.SkillID), spirit)
	})
	if len(ended) > 0 {
		var zone []world.Entity
		if hub != nil {
			zone = zoneOf(hub, characterID)
		}
		broadcastBuffEnd(zone, characterID, ended, sp)
	}
	return ended
}

// recheckSpiritBuffsAfterMove reads the avatar storage and runs the re-check.
func recheckSpiritBuffsAfterMove(ctx context.Context, d AvatarDeps, characterID int64) {
	held, err := avatar.List(ctx, d.Avatars, d.Items, characterID)
	if err != nil {
		return
	}
	recheckSpiritBuffs(d.Hub, characterID, held, time.Now())
}
