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

// RunRegen is the engine's passive recovery, applied to every online character
// once per mana.RegenInterval.
//
// WHY THIS EXISTS. `internal/mana` has carried the recovered rule for a while --
// `CGObjPC::vslot_362`, a percentage of the CURRENT pool, floored at 1, capped
// at half the current pool -- and nothing ever called it. A player reported it
// as "there is such thing as hp recovery, its a stat for the player and it
// passively restores health" (playtest 2026-09-20), and they were right: the
// mechanic was recovered, implemented and unwired.
//
// The interval is REAL (`.rdata 0x00b45dc0` = 4.0, and round 223 read the unit
// as seconds). The percentage is the disclosed part, and mana.RegenPerTick says
// so at its definition rather than here.
//
// A character at full health is skipped, which is the engine's own first test:
// `if (curHP == maxHP && curMP == maxMP) return;`. So is a character at 1 point,
// because the half-of-current cap truncates its floored amount to zero -- that
// is a mechanic the engine spends four instructions on, not a rounding artifact.
//
// Nothing here heals the dead: a character on 0 HP has a cap of 0 and regains
// nothing, which is the same arithmetic rather than a special case.
func RunRegen(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, logger *slog.Logger) {
	ticker := time.NewTicker(mana.RegenInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			regenTick(ctx, hub, chars, deps, logger)
		}
	}
}

// RegenDeps are what building a stats reply needs, so the healed character's
// bar moves without waiting for the client to ask.
type RegenDeps struct {
	Equipment equipment.Store
	Items     combat.ItemLookup
	Skills    skill.Store
	Mana      *mana.Tracker
}

// regenTick is one pass over the online characters. Split out so a test can
// drive it without waiting four seconds.
func regenTick(ctx context.Context, hub *world.Hub, chars character.Store, deps RegenDeps, logger *slog.Logger) {
	if hub == nil || chars == nil {
		return
	}
	for _, e := range hub.AllEntities() {
		c, err := chars.GetByID(ctx, e.CharacterID)
		if err != nil {
			continue
		}
		maxHP := character.MaxHPFor(c.Str, c.Level)
		amount := mana.RegenPerTick(c.HP, maxHP)
		if amount <= 0 {
			continue
		}
		newHP, err := chars.Heal(ctx, c.ID, amount, maxHP)
		if err != nil {
			if logger != nil {
				logger.Warn("regen: healing failed", "character", c.ID, "err", err)
			}
			continue
		}
		// Tell the client, or the bar only moves when something else happens
		// to refresh it. The stats reply is what the HUD already listens to.
		if e.Session != nil {
			c.HP = newHP
			if result, err := buildCharacterStats(ctx, c, c.ID, deps.Equipment, deps.Items, deps.Skills, deps.Mana); err == nil {
				_ = e.Session.Send(&proto.Packet{Opcode: OpCharacterStatsResult, Data: result.Encode()})
			}
		}
		if logger != nil {
			logger.Debug("regen", "character", c.ID, "amount", amount, "hp", newHP, "max", maxHP)
		}
	}
}
