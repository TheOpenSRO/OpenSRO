package buff

// The toggles and the protection walls (round 640; docs/protocol/
// skill_buffs.md "The toggles" and "The protection walls"). Every rule here
// is READ in SR_GameServer.exe at the address given; the few that are not
// say so.

import "time"

// The damage-type bits of 'att' value[0] and of 'pw' value[0]: bit 4 the
// physical half, bit 8 the magical half (Formula_MitigatePhysicalDamage
// 0x40e450 and Formula_MitigateMagicalDamage 0x40e830 each return 0 unless
// the attacker's 'att' carries its bit; FUN_0040ebe0 / FUN_0040eef0, the wall
// twins, also require the wall's 'pw' to carry it).
const (
	TypePhysical uint32 = 4
	TypeMagical  uint32 = 8
)

// WallAbsorbs is Combat_ResolveDamage's absorb test (0x58e5f0, READ; the
// block after the wall entry's damage, 0x58f03e..0x58f0a6): a blow whose
// 'att' is att meets a wall whose 'pw' value[0] is mask, and the wall takes it
// whole -- the caster's own entry is marked 8 and skips every damage step
// (`goto LAB_005905fb`) -- when
//
//	(att has no bit 4 or mask has bit 4) and (att has no bit 8 or mask has bit 8)
//
// (bVar24 and bVar7). The second clause's `uStack_ec` term -- a second damage
// record from `att` +0x10 and the context's +0x78 -- is not modelled (OPEN):
// srrevamp's blows have no second record. A blow with no 'att' at all passes
// both clauses.
func WallAbsorbs(mask, att uint32) bool {
	if att&TypePhysical != 0 && mask&TypePhysical == 0 {
		return false
	}
	if att&TypeMagical != 0 && mask&TypeMagical == 0 {
		return false
	}
	return true
}

// WallHit is what one absorbed blow did to a wall.
type WallHit struct {
	Token uint32
	// SkillID is the wall's skill.
	SkillID int64
	// Damage is the blow's damage against the wall.
	Damage int
	// HP is what is left, never below 0; Max the wall's 'pw' value[1].
	HP, Max int
	// Broke is the entry's 0x80 flag: `if (wall HP <= accumulated damage)
	// entry+5 |= 0x80` (0x58efb6..0x58efce).
	Broke bool
}

// HitWall meets a blow of type att on ownerID's wall. When the owner has a
// wall (book+0x1dc) with HP left and WallAbsorbs, the wall takes the blow:
// damage(w) is its damage against the wall's own defence, and the wall's HP
// drops by it, to 0 at the least -- Combat_ApplyActionEffects' wall entry
// (0x593800, the `+0x10 != 0` branch: `if (wallHP < dmg) wallHP = 0; else
// wallHP -= dmg`, READ). ok is false when there is no such wall or the blow
// is not absorbed: the caster takes it the ordinary way.
//
// A wall whose HP is already 0 absorbs nothing (Combat_ResolveDamage builds
// its entry only while `ctx+0x5c +8 != 0`); it is ended by the next book
// update (EndBrokenWalls), which srrevamp runs at once after the break.
func (b *Books) HitWall(ownerID int64, att uint32, damage func(w Wall) int) (WallHit, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil || bk.wallHolder == 0 {
		return WallHit{}, false
	}
	i := bk.index(bk.wallHolder)
	if i < 0 {
		return WallHit{}, false
	}
	r := &bk.records[i]
	if !r.HasWall || r.WallHP <= 0 || !WallAbsorbs(r.Wall.Mask, att) {
		return WallHit{}, false
	}
	d := damage(r.Wall)
	if d < 0 {
		d = 0
	}
	broke := r.WallHP <= d
	if r.WallHP < d {
		r.WallHP = 0
	} else {
		r.WallHP -= d
	}
	return WallHit{Token: r.Token, SkillID: r.SkillID, Damage: d, HP: r.WallHP, Max: r.Wall.HP, Broke: broke}, true
}

// EndBrokenWalls is SkillAction_Buff's sub-state 2 tail (0x5830b0, the
// check at 0x585302..0x585372, READ): a record whose wall object's HP is 0
// ends -- its state bits cleared (SkillBook::SetGroupBits(Action_Overlap, 1),
// 'ovl2' for a record on another character), book[0x77] zeroed, the motion
// state reset (vslot 0x55c(0, 0xff, 0)) and 3 returned, which the book update
// ends as any end: its contributions go and its token goes out as 0xB072.
// srrevamp ends it through the same path as every end (endLocked); a wall row
// carries no 'ovl2', 'lnks' or speed run (MEASURED on the 61 rows), so the
// two ends clear the same state.
func (b *Books) EndBrokenWalls(ownerID int64) ([]Record, Speed) {
	return b.endWhere(ownerID, func(r Record) bool { return r.HasWall && r.WallHP <= 0 })
}

// drainApplies is whether SkillAction_Buff's sub-state 2 drains r's MP
// (READ, 0x585250..0x5852cc): the row carries 'onff' (+0x284) and no 'dura'
// (+0x280), and the record is the owner's own cast (ctx+0x20 == 1). An
// 'onff' row with a 'dura', or one cast on another character, goes to the
// 'summ' test instead and is never drained. (The branch is also skipped for a
// row with an 'efr' of kind 3, +0x294 -- none of the 116 'onff' rows carries
// one, MEASURED.)
func (r Record) drainApplies() bool {
	return r.HasOnff && !r.Timed() && r.SelfCast()
}

// DrainDue reports whether r's next drain is due at now: `onff[0] < now -
// ctx+0x60+8` -- strictly (0x585285).
func (r Record) DrainDue(now time.Time) bool {
	return r.drainApplies() && now.Sub(r.LastDrain).Milliseconds() > int64(r.OnffMs)
}

// DueToggles returns the owners with a drain due at now or a broken wall.
func (b *Books) DueToggles(now time.Time) []int64 {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []int64
	for owner, bk := range b.books {
		for _, r := range bk.records {
			if r.DrainDue(now) || (r.HasWall && r.WallHP <= 0) {
				out = append(out, owner)
				break
			}
		}
	}
	return out
}

// DueDrains returns ownerID's records whose drain is due at now, in book
// order.
func (b *Books) DueDrains(ownerID int64, now time.Time) []Record {
	b.mu.Lock()
	defer b.mu.Unlock()
	bk := b.books[ownerID]
	if bk == nil {
		return nil
	}
	var out []Record
	for _, r := range bk.records {
		if r.DrainDue(now) {
			out = append(out, r)
		}
	}
	return out
}

// Drained records that token's drain was taken at now: the sub-state
// re-stamps ctx+0x60+8 with GetTickCount after vslot 0x308(0, cost, 4).
func (b *Books) Drained(ownerID int64, token uint32, now time.Time) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if bk := b.books[ownerID]; bk != nil {
		if i := bk.index(token); i >= 0 {
			bk.records[i].LastDrain = now
		}
	}
}

// EndToken ends ownerID's record token, if it is still active.
func (b *Books) EndToken(ownerID int64, token uint32) ([]Record, Speed) {
	return b.endWhere(ownerID, func(r Record) bool { return r.Token == token })
}

// ToggleOff is CGCharAutoCommandActor::Tick_UseSkill's phase 0 for a row with
// 'onff' (0x4ae590, READ): when FUN_0059ef90 finds a record of the skill on
// the caster's book (the first, any token) and that record is the caster's
// own cast (ctx+0x20 == 1), FUN_0059eff0(0) ends it and the action returns 0
// -- before the gate, the costs and the cooldown. ok is false when the cast
// goes ahead as a cast. FUN_0059eff0's 'nbuf' refusal needs a record cast by
// someone else, which this branch never passes it.
func (b *Books) ToggleOff(ownerID, skillID int64) (Record, Speed, bool) {
	b.mu.Lock()
	bk := b.books[ownerID]
	var first *Record
	if bk != nil {
		for i := range bk.records {
			if bk.records[i].SkillID == skillID {
				r := bk.records[i]
				first = &r
				break
			}
		}
	}
	b.mu.Unlock()
	if first == nil || !first.SelfCast() {
		return Record{}, Speed{}, false
	}
	ended, sp := b.EndToken(ownerID, first.Token)
	if len(ended) != 1 {
		return Record{}, Speed{}, false
	}
	return ended[0], sp, true
}
