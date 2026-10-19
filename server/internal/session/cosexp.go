package session

import (
	"context"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/cos"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/rates"
)

// A growth pet's experience (round 795; docs/protocol/pets.md, "Round 795",
// READ): every kill its owner is paid for pays the pet too -- not a share of
// the owner's, the whole reward recomputed with the pet as the receiver
// (CGObjPC::vslot_420 -> GObjPC::FUN_004fcb00: Formula_ExpRewardForContributor
// against the pet's level, the same ratio and bonuses). OffsetExpPoint then
// either levels the pet -- while it is below its owner and below 110
// (cos.PetLevelsUp) -- walking the level rows (the character EXP curve), or
// holds the experience at the threshold less one.

// cosKillExp pays owner's growth pet for the award a.
func cosKillExp(ctx context.Context, d combatDeps, m combat.Monster, a killAward, owner *character.Character) {
	if levelTable == nil || owner == nil {
		return
	}
	for _, o := range cosWorld.owned(a.characterID) {
		cosWorld.mu.Lock()
		growth, dead, level := o.kind == cos.KindGrowth, o.dead, o.rec.Level
		cosWorld.mu.Unlock()
		if !growth || dead {
			continue
		}
		pet := *owner
		pet.Level = level
		exp, _ := killReward(ctx, d, m, a, &pet)
		exp, _ = leveldata.ApplyRewardMultiplier(exp, 0, a.multiplier)
		exp, _ = leveldata.ApplyRateBonus(exp, 0, rates.Current().ExpFor(a.inParty))
		if exp > 0 {
			cosGainExp(ctx, o, exp, uint32(m.ID), owner.Level)
		}
	}
}

// cosGainExp is OffsetExpPoint (s:0x4d6370) for a positive gain, or a loss
// (a negative delta, floored at 0, no de-level).
func cosGainExp(ctx context.Context, o *cosObj, delta int64, source uint32, ownerLevel int) {
	var newRefs []uint32
	cosWorld.mu.Lock()
	level, exp := o.rec.Level, o.rec.Exp
	next, _ := levelTable.ExpToNext(level)
	switch {
	case delta < 0:
		if exp+delta < 0 {
			delta = -exp
		}
		exp += delta
	case cos.PetLevelsUp(level, ownerLevel) && level < cos.PetMaxLevel:
		exp += delta
		for next > 0 && exp >= next && level < cos.PetMaxLevel {
			row, ok := cosRowByCode(o.row.DescStrID)
			if !ok || row.TypeID4 != o.kind {
				// "Mutate COS Failed!!!": no next row, the level stays.
				exp = next - 1
				break
			}
			exp -= next
			level++
			o.row = row
			o.rec.RefCharID, o.rec.HP, o.rec.HGP = row.ID, row.MaxHP, cos.HGPFull
			newRefs = append(newRefs, uint32(row.ID))
			next, _ = levelTable.ExpToNext(level)
		}
	default:
		// The clamp: held at the threshold less one, the delta recomputed.
		if next > 0 && exp+delta >= next {
			delta = next - 1 - exp
			if delta < 0 {
				delta = 0
			}
		}
		exp += delta
	}
	o.rec.Level, o.rec.Exp = level, exp
	cosWorld.mu.Unlock()
	if delta != 0 {
		sendToCOSOwner(o, cos.OpCOSUpdate, cos.ExpUpdate(o.uid, delta, source))
	}
	for _, ref := range newRefs {
		// The mutate's 0x30C9 type 7 and the level-up's 0x3054, to the area.
		sendAboutCOS(o, cos.OpCOSUpdate, cos.RefUpdate(o.uid, ref))
		sendAboutCOS(o, cos.OpCOSLevelUp, uint32LE(o.uid))
	}
	if len(newRefs) > 0 {
		bumpPlayerState(o.owner)
	}
	cosSave(ctx, o)
}

func uint32LE(v uint32) []byte { return []byte{byte(v), byte(v >> 8), byte(v >> 16), byte(v >> 24)} }
