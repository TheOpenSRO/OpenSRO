package session

import (
	"context"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// expGainFor is the 0x3056 a kill receiver is sent for its payout (round 716).
//
// The EXP is the award, clamped only when the receiver STARTS at level 110:
// GObjPC_GainExpAndLevel tests the level byte before the award (0x4e52c1..
// 0x4e52d7, cmp cl,0x6e) and at 110 stores min(exp, requirement - current -
// 1) into the amount (0x4e5365..0x4e5390), which is expAdded there; below 110
// the amount is written as awarded, even when it overflows into 110 (round
// 716's review). The skill EXP is the payout's. The stat-point u16 follows
// only when the award raised the level (0x4e58df), and carries the
// character's unspent stat points after it.
func expGainFor(m combat.Monster, p killPayout) charmsg.ExpGain {
	exp := p.exp
	if p.startLevel >= leveldata.MaxCharacterLevel {
		exp = p.expAdded
	}
	g := charmsg.ExpGain{Source: uint32(m.ID), Exp: exp, SkillExp: p.sp}
	if p.levelUp != nil {
		g.LevelUp = true
		g.StatPoints = uint16(p.levelUp.StatPoints)
	}
	return g
}

// sendExpGainTo tells one receiver its share. GainExpAndLevel sends nothing
// when both amounts are zero (0x4e5393..0x4e53a1 jump to the end).
func sendExpGainTo(s *gateway.Session, g charmsg.ExpGain) {
	if s == nil || (g.Exp == 0 && g.SkillExp == 0) {
		return
	}
	if err := s.Send(&proto.Packet{Opcode: charmsg.OpExpGain, Data: g.Encode()}); err != nil {
		slog.Debug("exp gain: send failed", "err", err)
	}
}

// tellGold sends a character its new gold total as 0x304E kind 1 (round 716):
// shown for a party split's share (GObjPC::FUN_005bc7f0 -> OffsetGold(amount,
// 0, 0x17, 1, 1)), unshown for a solo pick-up (FUN_004eaca0 -> OffsetGold(
// amount, 0, 0x19, 1, 0)).
func tellGold(ctx context.Context, chars character.Store, hub *world.Hub, characterID int64, show bool) {
	e, ok := entityOf(hub, characterID)
	if !ok || e.Session == nil || chars == nil {
		return
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		slog.Debug("gold share: reading the member's gold failed", "character_id", characterID, "err", err)
		return
	}
	if err := e.Session.Send(&proto.Packet{Opcode: charmsg.OpCharInfo, Data: charmsg.EncodeGold(c.Gold, show)}); err != nil {
		slog.Debug("gold share: send failed", "character_id", characterID, "err", err)
	}
}
