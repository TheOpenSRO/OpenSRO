package session

import (
	"context"
	"log/slog"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// RunRegen is the engine's passive recovery: CGObjPC::vslot_362 on each
// character's own 4 s timer (mana's package note has the whole reading).
//
// Round 605 settled it: a tick restores a percentage of the MAXIMUM HP and MP
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
			regenPass(ctx, hub, chars, deps, logger, now, false)
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
			regenOne(ctx, e, chars, deps, logger, now)
		}
	}
}

// regenOne is one firing of CGObjPC::vslot_362 for e.
func regenOne(ctx context.Context, e world.Entity, chars character.Store, deps RegenDeps, logger *slog.Logger, now time.Time) {
	// `if (GetLifeState() != 1) return;` -- the first test.
	if e.Life != world.LifeAlive {
		return
	}
	c, err := chars.GetByID(ctx, e.CharacterID)
	if err != nil {
		return
	}
	maxHP, maxMP := c.MaxHP(), c.MaxMP()
	curMP := maxMP
	if deps.Mana != nil {
		curMP = deps.Mana.Current(c.ID, maxMP)
	}
	// Both pools full: nothing to do.
	if c.HP >= maxHP && curMP >= maxMP {
		return
	}
	// Only STAND and SIT regenerate, at their own rate.
	rate, ok := motions.regenRate(c.ID, now)
	if !ok {
		return
	}
	hp := mana.RegenPerTick(maxHP, rate)
	mp := mana.RegenPerTick(maxMP, rate)
	newHP, newMP := c.HP, curMP
	if hp > 0 && c.HP < maxHP {
		if newHP, err = chars.Heal(ctx, c.ID, hp, maxHP); err != nil {
			if logger != nil {
				logger.Warn("regen: healing failed", "character", c.ID, "err", err)
			}
			return
		}
	}
	if mp > 0 && curMP < maxMP && deps.Mana != nil {
		newMP = deps.Mana.Restore(c.ID, maxMP, mp)
	}
	// Tell the client, or the bar only moves when something else happens to
	// refresh it. The stats reply is what the HUD already listens to.
	if e.Session != nil {
		c.HP = newHP
		if result, err := buildCharacterStats(ctx, c, c.ID, deps.Equipment, deps.Items, deps.Skills, deps.Mana); err == nil {
			_ = e.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
		}
	}
	if logger != nil {
		logger.Debug("regen", "character", c.ID, "rate", rate, "hp", newHP, "maxHP", maxHP, "mp", newMP, "maxMP", maxMP)
	}
}
