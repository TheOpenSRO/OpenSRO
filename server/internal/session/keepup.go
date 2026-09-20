package session

import (
	"context"
	"math"
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/durability"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/grounditem"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The keep-up. In the original ONE click starts a plain attack and the
// SERVER repeats it: the per-character action queue is a
// `CGCharAutoCommandActor` (the binary's own class name, vtable 0xaecd0c),
// ticked from CGObjChar::Update at most every 30 ms, whose attack tick
// (0x4ad8e0) runs an action through four phases -- 0 measure reach, 1
// approach, 2 execute, 3 `[HANDLE_ATTACK-KeepUp]` -- and phase 3 loops the
// action back to phase 1 for as long as
//
//   - the context's skill still resolves (the base attack of the weapon in
//     hand, re-read each pass from SkillGlobal's default-attack table);
//   - the base attack's cooldown has lapsed (Skill_CheckUseConditions with
//     mask 1: the ReuseDelay gate alone, so the cadence IS ReuseDelay);
//   - no other action has been queued behind it (queue depth 2 ends it: the
//     next action takes over);
//   - the target still exists and is alive (IGObj slot 6).
//
// The skill tick (0x4ae590) joins the same loop from the other side: when a
// skill's CastingTime + ActionDuration has played and its Basic_Code row has
// AutoAttackType == 1 (skilldata col 19), phase 3 pushes a NEW kind-1 attack
// action carrying the same target, and the plain swings continue from there.
// The staff, wand and harp base attacks carry 0 and never hand off. Read
// 2026-09-19, round 256; the whole machine is in docs/protocol/auto_command.md.
//
// Two things srrevamp cannot do the engine's way, and does not pretend to:
//
//   - The engine WALKS the attacker back into reach (phase 1's
//     MoveTowardObject). srrevamp's server does not move players, so a
//     repeat that finds its target out of reach ENDS the run instead. The
//     reach test itself is the engine's (combat.InReach on the round-247
//     band).
//   - The retail client cancels a running action when the player clicks to
//     move (0x7074 with the cancel byte). srrevamp's client has no such
//     packet, so a position update (OpMove, only ever sent for a real move)
//     cancels the run. That mapping is this project's, not read.
type autoAttack struct {
	mu   sync.Mutex
	runs map[int64]*autoRun
	seq  uint64
}

type autoRun struct {
	seq    uint64
	target int64
	stop   chan struct{}
}

// keepUp is the process-wide tracker: one run per character at most, the
// way the engine's actor holds one front action.
var keepUp = newAutoAttack()

func newAutoAttack() *autoAttack { return &autoAttack{runs: map[int64]*autoRun{}} }

// Arm replaces whatever run the character has with a new one against
// target. swing fires after `first`, then again after whatever delay it
// returns, until it returns false or the run is cancelled or replaced.
func (a *autoAttack) Arm(characterID, target int64, first time.Duration, swing func() (time.Duration, bool)) {
	a.mu.Lock()
	if old, ok := a.runs[characterID]; ok {
		close(old.stop)
	}
	a.seq++
	run := &autoRun{seq: a.seq, target: target, stop: make(chan struct{})}
	a.runs[characterID] = run
	a.mu.Unlock()
	go a.loop(characterID, run, first, swing)
}

// Cancel ends the character's run, if any.
func (a *autoAttack) Cancel(characterID int64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if run, ok := a.runs[characterID]; ok {
		close(run.stop)
		delete(a.runs, characterID)
	}
}

// Target reports what the character is auto-attacking, if anything.
func (a *autoAttack) Target(characterID int64) (int64, bool) {
	a.mu.Lock()
	defer a.mu.Unlock()
	run, ok := a.runs[characterID]
	if !ok {
		return 0, false
	}
	return run.target, true
}

func (a *autoAttack) current(characterID int64, seq uint64) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	run, ok := a.runs[characterID]
	return ok && run.seq == seq
}

func (a *autoAttack) finish(characterID int64, seq uint64) {
	a.mu.Lock()
	defer a.mu.Unlock()
	if run, ok := a.runs[characterID]; ok && run.seq == seq {
		delete(a.runs, characterID)
	}
}

func (a *autoAttack) loop(characterID int64, run *autoRun, first time.Duration, swing func() (time.Duration, bool)) {
	timer := time.NewTimer(clampDelay(first))
	defer timer.Stop()
	for {
		select {
		case <-run.stop:
			return
		case <-timer.C:
		}
		if !a.current(characterID, run.seq) {
			return
		}
		next, again := swing()
		if !again {
			a.finish(characterID, run.seq)
			return
		}
		timer.Reset(clampDelay(next))
	}
}

// clampDelay keeps a repeat from spinning: the engine's actor itself ticks
// no faster than every 30 ms.
func clampDelay(d time.Duration) time.Duration {
	if d < 30*time.Millisecond {
		return 30 * time.Millisecond
	}
	return d
}

// baseAttackOf is the weapon-in-hand's plain attack: its skilldata row, via
// combat.BaseAttackSkillFor on the equipped, unbroken weapon's TypeID4 (bare
// hand otherwise), the way SkillGlobal's default-attack table resolves it.
// Nothing when the reference store cannot look skills up.
func baseAttackOf(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) (*refdata.Skill, bool) {
	skillRef, ok := items.(SkillRefStore)
	if !ok {
		return nil, false
	}
	typeID4 := combat.BareHandTypeID4
	if equipped, err := eq.Get(ctx, characterID); err == nil {
		for _, e := range equipped {
			if e.Slot != equipment.SlotWeapon || durability.IsBroken(e.Durability) {
				continue
			}
			if item, err := items.GetItem(ctx, e.ItemID); err == nil && item != nil && item.TypeID4 > 0 {
				typeID4 = item.TypeID4
			}
		}
	}
	baseID := combat.BaseAttackSkillFor(typeID4)
	if baseID == 0 {
		return nil, false
	}
	ref, err := skillRef.GetSkill(ctx, baseID)
	if err != nil || ref == nil {
		return nil, false
	}
	return ref, true
}

// equippedWeaponRange is the Range column (itemdata 94, param 33) of the
// weapon in hand. A broken weapon publishes 0 (read, round 247). A bare hand
// has no weapon record to publish from, so the param is left at its zero
// default here -- no bare-hand writer of param 33 was found, which is not
// the same as one being proven absent.
func equippedWeaponRange(ctx context.Context, characterID int64, eq equipment.Store, items combat.ItemLookup) int {
	equipped, err := eq.Get(ctx, characterID)
	if err != nil {
		return 0
	}
	for _, e := range equipped {
		if e.Slot != equipment.SlotWeapon || durability.IsBroken(e.Durability) {
			continue
		}
		if item, err := items.GetItem(ctx, e.ItemID); err == nil && item != nil {
			return item.Range
		}
	}
	return 0
}

// keepUpInReach is phase 1's Action_IsTargetWithinReach for a plain swing:
// the separation of the two bodies against casterBC + targetBC + the
// weapon's Range, with the +2 slack. The separation is taken in the ground
// plane; the engine's is the same region-aware distance every other test
// uses, and both stand on the ground.
func keepUpInReach(attacker world.Position, m combat.Monster, weaponRange int) bool {
	dist := math.Hypot(attacker.X-m.X, attacker.Z-m.Z)
	_, reach := combat.ApproachBand(combat.PlayerBCRadius, m.BCRadius, combat.EffectiveRange(0, weaponRange))
	return combat.InReach(dist, reach)
}

// combatDeps is everything a swing needs, bundled so a repeat can fire from
// outside a packet handler.
type combatDeps struct {
	chars    character.Store
	eq       equipment.Store
	items    combat.ItemLookup
	hub      *world.Hub
	monsters *combat.Hub
	quests   quest.Store
	inv      inventory.Store
	skills   skill.Store
	zerk     *berserk.Tracker
	mp       *mana.Tracker
	parties  *party.Hub
	ground   *grounditem.Hub
	// dropSrc is the real drop tables; nil falls back to combat.LootTables.
	dropSrc DropSource
}

// armKeepUp starts (or restarts) the character's keep-up against target,
// first swinging after `first` (one ReuseDelay when zero: the click was the
// first swing). It needs the base attack's row for the cadence -- with no
// row the engine's own phase 3 ends the loop ("the context's skill no longer
// resolves"), and so does this.
func armKeepUp(
	sess *gateway.Session,
	deps combatDeps,
	characterID, target int64,
	first time.Duration,
) {
	ctx := context.Background()
	base, ok := baseAttackOf(ctx, characterID, deps.eq, deps.items)
	if !ok || base.ReuseDelayMs <= 0 {
		return
	}
	every := time.Duration(base.ReuseDelayMs) * time.Millisecond
	if first <= 0 {
		first = every
	}
	keepUp.Arm(characterID, target, first, func() (time.Duration, bool) {
		m, ok := deps.monsters.Get(target)
		if !ok || m.HP <= 0 {
			return 0, false
		}
		attacker, ok := deps.hub.EntityBySession(sess.ID())
		if !ok || attacker.Zone != m.Zone {
			return 0, false
		}
		if !keepUpInReach(attacker.Pos, m, equippedWeaponRange(ctx, characterID, deps.eq, deps.items)) {
			// The engine would walk here. See the package comment.
			return 0, false
		}
		now := time.Now()
		if deps.skills != nil {
			if last, ever, err := deps.skills.LastUsed(ctx, characterID, base.ID); err == nil && ever {
				if wait := every - now.Sub(last); wait > 0 {
					// A manual click landed in between: fall back into step
					// with the cooldown rather than swinging twice.
					return wait, true
				}
			}
			_ = deps.skills.RecordUse(ctx, characterID, base.ID, now)
		}
		if err := performAttack(ctx, sess, deps.chars, deps.eq, deps.items, deps.hub, deps.monsters, deps.quests, deps.inv, deps.skills, deps.zerk, deps.mp, deps.parties, deps.ground, deps.dropSrc, characterID, target, 0, 0, 0, 1, combat.AttackPhysical); err != nil {
			return 0, false
		}
		if m, ok := deps.monsters.Get(target); !ok || m.HP <= 0 {
			return 0, false
		}
		return every, true
	})
}

// handOffDelay is how long the skill tick waits before pushing the plain
// attack: the skill's CastingTime + ActionDuration (the CastingTime the
// server holds already has PreparingTime folded in, SkillGlobal's post-load
// pass adds it), measured from the cast.
func handOffDelay(ref *refdata.Skill) time.Duration {
	if ref == nil {
		return 0
	}
	return time.Duration(ref.CastingTimeMs+ref.ActionDurationMs) * time.Millisecond
}

// skillHandsOff is the skill tick's phase-3 test: AutoAttackType == 1 on the
// row that was cast.
func skillHandsOff(ref *refdata.Skill) bool {
	return ref != nil && ref.AutoAttackType == 1
}

// firstSwingInReach is the reach gate on a manual OpAttack click.
//
// It is the same test the repeats use, applied one step earlier: without it
// the first click of a fight hit from any distance, because only the keep-up
// checked (playtest 2026-09-20, item 2). A monster or attacker that cannot be
// resolved, or a zone mismatch, is not in reach.
//
// A missing world hub means this server is not tracking positions at all, in
// which case there is nothing to measure and the swing is allowed: refusing
// would break a deployment that has no position source rather than fix one.
func firstSwingInReach(
	ctx context.Context,
	sess *gateway.Session,
	eq equipment.Store,
	items combat.ItemLookup,
	hub *world.Hub,
	monsters *combat.Hub,
	characterID, target int64,
) bool {
	if hub == nil || monsters == nil {
		return true
	}
	m, ok := monsters.Get(target)
	if !ok || m.HP <= 0 {
		return true // performAttack reports the real reason
	}
	attacker, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return true
	}
	if attacker.Zone != m.Zone {
		// Not a reach question: performAttack reports "target not found",
		// which is what a cross-zone click has always meant and is a better
		// answer than "too far away".
		return true
	}
	return keepUpInReach(attacker.Pos, m, equippedWeaponRange(ctx, characterID, eq, items))
}

// skillInReach is firstSwingInReach for a cast: the same recovered test with
// the SKILL's range instead of the weapon's.
//
// combat.EffectiveRange takes a skill range as its first argument and falls
// back to the weapon's when the skill declares none, so a melee skill with
// Action_Range 0 reaches exactly as far as the weapon in hand and a bow skill
// reaches its own distance. Nothing here is new arithmetic -- the cast path
// simply never called it, and resolved a skill at any distance at all
// (playtest 2026-09-20).
func skillInReach(
	ctx context.Context,
	sess *gateway.Session,
	eq equipment.Store,
	items combat.ItemLookup,
	hub *world.Hub,
	monsters *combat.Hub,
	characterID, target int64,
	skillRange int,
) bool {
	if hub == nil || monsters == nil {
		return true
	}
	m, ok := monsters.Get(target)
	if !ok || m.HP <= 0 {
		return true // performAttack reports the real reason
	}
	attacker, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return true
	}
	if attacker.Zone != m.Zone {
		// Not a reach question, exactly as for a plain swing.
		return true
	}
	dist := math.Hypot(attacker.Pos.X-m.X, attacker.Pos.Z-m.Z)
	_, reach := combat.ApproachBand(combat.PlayerBCRadius, m.BCRadius,
		combat.EffectiveRange(skillRange, equippedWeaponRange(ctx, characterID, eq, items)))
	return combat.InReach(dist, reach)
}
