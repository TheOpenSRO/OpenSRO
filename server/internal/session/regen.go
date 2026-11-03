package session

import (
	"context"
	"log/slog"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// RunRegen is the engine's passive recovery: CGObjPC::vslot_362 on each
// character's own 4 s timer (mana's package note has the whole reading).
//
// Round 607 settled it: a tick restores a percentage of the MAXIMUM HP and MP
// -- 0.8% standing still, 8% sitting -- floored at 1 and capped at half the
// maximum, and restores nothing while walking, running or getting up or down.
// Before that this loop healed 4% of the CURRENT HP on one global ticker and
// mana regenerated lazily inside mana.Tracker at the same rate; the percentage
// was our own and the pool was the wrong one.
//
// The timer is per character, as the engine's is: registered when the
// character enters the world (motions.enter), first firing 4 s later and then
// every 4 s. This loop polls at regenPoll to find the characters whose timer
// is due; the poll granularity is ours.
func RunRegen(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, logger *slog.Logger) {
	ticker := time.NewTicker(regenPoll)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-ticker.C:
			start := time.Now()
			regenPass(ctx, hub, chars, deps, logger, now, false)
			loopRegen.Tick(start)
		}
	}
}

// regenPoll is how often RunRegen looks for due timers. OURS: a tick fires up
// to this late.
const regenPoll = 100 * time.Millisecond

// RegenDeps are what building a stats reply needs, so the healed character's
// bar moves without waiting for the client to ask.
type RegenDeps struct {
	Equipment equipment.Store
	Items     combat.ItemLookup
	Skills    skill.Store
	Mana      *mana.Tracker
	// Berserk is the orb tracker a revive ends a running berserk in
	// (endBerserk: GObjPC::Revive's SetBodyMode(2, ...)); nil leaves it.
	Berserk *berserk.Tracker
}

// regenPass fires the tick for every online character whose timer is due at
// now -- or, with all, for every one of them whatever their timers say, which
// is how a test drives the rule without waiting.
func regenPass(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, logger *slog.Logger, now time.Time, all bool) {
	if hub == nil || chars == nil {
		return
	}
	for _, e := range hub.AllEntities() {
		if all || motions.regenDue(e.CharacterID, now) {
			regenOne(ctx, hub, e, chars, deps, logger, now)
		}
	}
}

// regenOne is one firing of CGObjPC::vslot_362 for e.
//
// The pools are read and written under e's kill lock (killLock), with the life
// state and the row read afresh there, because a blow and its death are not one
// step here as they are in the engine (whose object queue runs both before
// anything else): a blow writes HP 0 and only then takes the lock to decide the
// kill. A tick in that gap used to raise the pool off 0, and fallen() then
// dropped the kill; and a life state read from the snapshot e could heal a
// character a kill had just put in life state 2. Now a tick that reads HP 0
// restores no HP -- the character is being killed, or is an HP-cost caster
// left at 0 -- though MP still comes back (OURS: the engine has no such
// window), and a dead character gets nothing (read: the life test comes first).
//
// The window is NARROWED, NOT CLOSED: the blow's own write is not under the
// lock, so a blow that lands between this tick's read and its Heal can still be
// covered by the heal -- fallen() then finds her above 0 and the kill is not
// taken, as with a potion step in the same gap (fallen's own note). She stays
// killable by the next blow.
//
// The stats push -- a TCP write that can block -- goes out after the lock is
// released.
func regenOne(ctx context.Context, hub *world.Hub, e world.Entity, chars character.Store, deps RegenDeps, logger *slog.Logger, now time.Time) {
	// `if (GetLifeState() != 1) return;` -- the first test.
	if e.Life != world.LifeAlive {
		return
	}
	c := regenApply(ctx, hub, e, chars, deps, logger, now)
	if c == nil || e.Session == nil {
		return
	}
	// Tell the client, or the bar only moves when something else happens to
	// refresh it. The stats reply is what the HUD already listens to.
	result, err := buildCharacterStats(ctx, c, c.ID, deps.Equipment, deps.Items, deps.Skills, deps.Mana)
	if err != nil {
		return
	}
	// Building the reply reads the stores outside the lock, and a lethal blow
	// can take the lock, kill her and push HP 0 in that time; a regen push
	// landing after it drew a live bar on a dead character (round 607's third
	// review). So the life state and the pool are read again right before the
	// send, and a push whose HP is no longer hers is dropped -- whatever
	// changed it sent its own. A blow in the instant between this check and
	// the write is left to the client, which ignores a stats HP while dead
	// (World3D._on_world_stats).
	if !regenPushStillTrue(ctx, hub, chars, c.ID, int(result.HP)) {
		return
	}
	_ = e.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
}

// regenPushStillTrue reports whether a regen stats push carrying hp may still
// go out: the character is alive in the hub and her stored HP is still hp.
func regenPushStillTrue(ctx context.Context, hub *world.Hub, chars character.Store, characterID int64, hp int) bool {
	if hub != nil {
		if cur, ok := hub.EntityByCharacterID(characterID); !ok || cur.Life != world.LifeAlive {
			return false
		}
	}
	now, err := chars.GetByID(ctx, characterID)
	return err == nil && now.HP == hp
}

// regenApply is regenOne's work under the kill lock. It returns the character
// with its new HP when a pool changed, nil when nothing did.
func regenApply(ctx context.Context, hub *world.Hub, e world.Entity, chars character.Store, deps RegenDeps, logger *slog.Logger, now time.Time) *character.Character {
	l := killLock(e.CharacterID)
	l.Lock()
	defer l.Unlock()
	if hub != nil {
		if cur, ok := hub.EntityByCharacterID(e.CharacterID); !ok || cur.Life != world.LifeAlive {
			return nil
		}
	}
	c, err := chars.GetByID(ctx, e.CharacterID)
	if err != nil {
		return nil
	}
	maxHP, maxMP := c.MaxHP(), c.MaxMP()
	curMP := maxMP
	if deps.Mana != nil {
		curMP = deps.Mana.Current(c.ID, maxMP)
	}
	// Both pools full: nothing to do.
	if c.HP >= maxHP && curMP >= maxMP {
		return nil
	}
	// Only STAND and SIT regenerate, at their own rate.
	rate, ok := motions.regenRate(c.ID, now)
	if !ok {
		return nil
	}
	// EvaluateParam(25) / (26): the motion state's base with the other
	// entries of 'hprg' / 'mprg' (round 789: a worn avatar's percent entries,
	// avatarstats.go; and any buff's), as the tick reads them (mana.go).
	hp := mana.RegenPerTick(maxHP, float32(buffStat(c.ID, buff.ParamHPRegen, float64(rate))))
	mp := mana.RegenPerTick(maxMP, float32(buffStat(c.ID, buff.ParamMPRegen, float64(rate))))
	newHP, newMP := c.HP, curMP
	changed := false
	// HP 0 while alive: no HP (see regenOne).
	if hp > 0 && c.HP > 0 && c.HP < maxHP {
		if newHP, err = chars.Heal(ctx, c.ID, hp, maxHP); err != nil {
			if logger != nil {
				logger.Warn("regen: healing failed", "character_id", c.ID, "err", err)
			}
			return nil
		}
		changed = true
	}
	if mp > 0 && curMP < maxMP && deps.Mana != nil {
		newMP = deps.Mana.Restore(c.ID, maxMP, mp)
		changed = true
	}
	if logger != nil {
		logger.Debug("regen", "character_id", c.ID, "rate", rate, "hp", newHP, "maxHP", maxHP, "mp", newMP, "maxMP", maxMP)
	}
	if !changed {
		return nil
	}
	c.HP = newHP
	return c
}
