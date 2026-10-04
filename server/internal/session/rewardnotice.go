package session

import (
	"context"
	"log/slog"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// expGainFor is the 0x3056 a kill receiver is sent for its payout (round 716).
//
// The EXP is what the character's EXP actually rose by: at the level cap
// GObjPC_GainExpAndLevel clamps the amount to what fits before it writes the
// message (READ, 0x4e5365..0x4e5390 store requirement - current - 1 into the
// amount), which is expAdded. The skill EXP is the payout's. The stat-point
// u16 follows only when the award raised the level (0x4e58df), and carries
// the character's unspent stat points after it.
func expGainFor(m combat.Monster, p killPayout) charmsg.ExpGain {
	g := charmsg.ExpGain{Source: uint32(m.ID), Exp: p.expAdded, SkillExp: p.sp}
	if p.levelUp != nil {
		g.LevelUp = true
		g.StatPoints = uint16(p.levelUp.StatPoints)
	}
	return g
}

// sendExpGain tells one receiver its share. GainExpAndLevel sends nothing
// when both amounts are zero (0x4e5393..0x4e53a1 jump to the end).
func sendExpGain(hub *world.Hub, characterID int64, g charmsg.ExpGain) {
	if g.Exp == 0 && g.SkillExp == 0 {
		return
	}
	e, ok := entityOf(hub, characterID)
	if !ok || e.Session == nil {
		return
	}
	if err := e.Session.Send(&proto.Packet{Opcode: charmsg.OpExpGain, Data: g.Encode()}); err != nil {
		slog.Debug("exp gain: send failed", "character", characterID, "err", err)
	}
}

// tellGold sends a party gold-share member its new total as 0x304E kind 1,
// shown (round 716; GObjPC::FUN_005bc7f0 -> OffsetGold(amount, 0, 0x17, 1, 1)).
func tellGold(ctx context.Context, chars character.Store, hub *world.Hub, characterID int64) {
	e, ok := entityOf(hub, characterID)
	if !ok || e.Session == nil || chars == nil {
		return
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		slog.Debug("gold share: reading the member's gold failed", "character", characterID, "err", err)
		return
	}
	if err := e.Session.Send(&proto.Packet{Opcode: charmsg.OpCharInfo, Data: charmsg.EncodeGold(c.Gold, true)}); err != nil {
		slog.Debug("gold share: send failed", "character", characterID, "err", err)
	}
}
