package session

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 874: a death can take a level away, and the EXP a resurrection gives
// back can return it -- both through GObjPC_GainExpAndLevel (s:0x4e5250,
// vtable slot 0x170), as the original does.
//
// READ, SR_GameServer.exe:
//
//   - GObjPC_OnDeath (s:0x4e6980) and the job death (s:0x4e6820) hand the
//     penalty to slot 0x170 as a NEGATIVE amount (s:0x4e6bad `neg eax`). Its
//     negative branch (s:0x4e5406..0x4e5546, 0x4e569c..0x4e56f5) drops the
//     level by one when the EXP goes below zero and adds the lower level's
//     requirement back (leveldata.LoseExp), then GObjPC_SetLevel(new, old)
//     (s:0x4e555e -> s:0x4e4d90).
//   - GObjPC_SetLevel on a level DOWN writes CurLevel (+0x65) and nothing else
//     of the row: MaxLevel (+0x66), the stat points (+0x84), Str and Int are
//     touched only inside `MaxLevel < new` (character.LevelsRewarded). It
//     refreshes the guild member's level (FUN_005c3540, 0x38F5 type 6 field
//     0x01) and the academy member's (FUN_005de6c0 field 6) on every change --
//     world.Hub.SetLevel's hook (academyLevelChanged, guildMemberLevelChanged)
//     -- re-reads the level entry, sets param 0 (the level) and the level's
//     params 54/55, and refreshes the worn items' params with NO level test
//     (CGPCInventoryOP::RefreshEquipParamEntryForPC s:0x4bb3e0): gear above
//     the new level stays worn and counts. Only a level UP heals to full
//     (ApplyHPMPDelta(max - cur), s:0x4e5076) and sends 0x3054.
//   - The negative amount is kept as the last loss, pc+0x1ce0 (s:0x4e5710,
//     whatever the RemainExpOffset clamp did), which GObjPC::Revive clears
//     (s:0x4df2e8) and a resurrection scroll (s:0x49ff43) or skill
//     (s:0x59483c) reads before its revive.
//
// MEASURED: a level-20 character with 1,000 EXP died and was level 19 at
// 93.34 % (1,000 - 16,919 + 238,878 = 222,959 of 238,878), "[16919]Experience
// Points lost.", HP/MP maxima 1,296 -> 1,271 with MP clamped to 1,271, then
// 0x38F5 {06, id, 01, 19} and 0x3C80 {05, id, 06, 19}; the dead window was the
// help one (its max level 70); _Char kept MaxLevel 70, Str/Int 89 and 207
// stat points; the character select showed level 19. A 100 % scroll after a
// level-65 -> 64 death returned the level with 0x3054 (the level-up pillar
// and "You have advanced to level [65]." in the centre) and full HP.

// loseExp is slot 0x170 with -loss on the fresh row c (the caller holds the
// leveling lock): the EXP falls, one level with it when it runs out, MaxLevel,
// the points, Str and Int stay; the hub's level follows (and with it the
// academy and guild refresh), the MP clamps to the lower maximum, and the
// loss is the character's last (noteDeathLoss). It returns the new level.
func loseExp(ctx context.Context, chars character.Store, hub *world.Hub, mp *mana.Tracker, c *character.Character, loss int64) (int, error) {
	if c == nil || loss <= 0 {
		return 0, nil
	}
	newLevel, newExp := levelTable.LoseExp(c.Level, c.Exp, loss)
	if err := chars.SetLeveling(ctx, c.ID, newLevel, newExp, c.StatPoints, c.Str, c.Int); err != nil {
		return c.Level, err
	}
	noteDeathLoss(c.ID, loss)
	if newLevel != c.Level {
		slog.Info("death: level lost", "character_id", c.ID, "from", c.Level, "to", newLevel, "exp", newExp, "loss", loss)
		if hub != nil {
			hubOfChar(hub, c.ID).SetLevel(c.ID, newLevel)
		}
		if mp != nil {
			maxMP := character.MaxMPWith(c.Int, newLevel, character.BonusOf(c.ID))
			if cur, ok := mp.Peek(c.ID); ok && cur > maxMP {
				mp.Set(c.ID, maxMP)
			}
		}
	}
	return newLevel, nil
}

// expReturned is what returnExp did.
type expReturned struct {
	// added is the EXP that went on (the amount, held below the cap level's
	// requirement as Advance holds it).
	added int64
	// levelUp is the OpLevelUp to send when a level came back, else nil.
	levelUp *LevelUp
}

// returnExp is slot 0x170 with a positive amount after a resurrection (round
// 874): Advance's carry, a level regained with its full heal and 0x3054 --
// and its stat points, Str and Int only above MaxLevel
// (character.LevelsRewarded). It takes the leveling lock itself.
func returnExp(ctx context.Context, chars character.Store, hub *world.Hub, mp *mana.Tracker, characterID, amount int64) (expReturned, error) {
	var out expReturned
	if amount <= 0 {
		return out, nil
	}
	unlock := character.LockLeveling(characterID)
	defer unlock()
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return out, fmt.Errorf("returning exp: %w", err)
	}
	newLevel, newExp, _ := levelTable.Advance(c.Level, c.Exp, amount)
	paid := character.LevelsRewarded(c.Level, newLevel, c.HighestLevel())
	statPoints := c.StatPoints + paid*leveldata.StatPointsPerLevel
	str := c.Str + paid*character.StatGrowthPerLevel
	intel := c.Int + paid*character.StatGrowthPerLevel
	if err := chars.SetLeveling(ctx, characterID, newLevel, newExp, statPoints, str, intel); err != nil {
		return out, fmt.Errorf("returning exp: %w", err)
	}
	out.added = expAdded(levelTable, c.Level, c.Exp, newLevel, newExp)
	if newLevel > c.Level {
		if hub != nil {
			hubOfChar(hub, characterID).SetLevel(characterID, newLevel)
		}
		if err := chars.ResetHP(ctx, characterID); err != nil {
			return out, fmt.Errorf("returning exp: refilling hp: %w", err)
		}
		if mp != nil {
			mp.Refill(characterID, character.MaxMPWith(intel, newLevel, character.BonusOf(characterID)))
		}
		out.levelUp = &LevelUp{NewLevel: int32(newLevel), StatPoints: int32(statPoints)}
		slog.Info("resurrection: level regained", "character_id", characterID, "from", c.Level, "to", newLevel, "paid_levels", paid)
	}
	return out, nil
}

// tellExpReturned sends what returnExp did, in the original's order
// (MEASURED, a 100 % scroll's revive: 0x3054, the stats, then 0x3056 with the
// EXP): the level-up effect to everyone in view and OpLevelUp, then the
// 0x3056 line "[N]Experience Points gained." (source 0, MEASURED).
func tellExpReturned(sess *gateway.Session, hub *world.Hub, characterID int64, r expReturned) {
	if sess == nil || r.added <= 0 && r.levelUp == nil {
		return
	}
	g := charmsg.ExpGain{Exp: r.added}
	if r.levelUp != nil {
		announceLevelUp(hubOfChar(hub, characterID), characterID)
		_ = sess.Send(&proto.Packet{Opcode: OpLevelUp, Data: r.levelUp.Encode()})
		g.LevelUp = true
		g.StatPoints = uint16(r.levelUp.StatPoints)
	}
	sendExpGainTo(sess, g)
}
