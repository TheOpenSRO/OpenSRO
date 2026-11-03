package session

import (
	"context"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// NewGuildPointSkills wraps a skill store so that the skill points a guild
// member earns from skill experience are also credited to their guild, as the
// engine does (round 525; docs/protocol/guild.md, "Where guild points come
// from").
//
// The rule is GObjPC_GainExpAndLevel's (0x4e5250). Right after it converts
// skill experience into whole points at 400:1 and grants them through vtable
// +0x174 (slot 93, AddSkillPoints), it does
//
//	if (0 < points && pc[0x72f] /* guild */ != 0 &&
//	    (pc[0x861] += points, 9 < pc[0x861])) {
//	    CGuildManager::RequestAddGuildPoints(pc[0x861]);
//	    pc[0x861] = 0;
//	}
//
// and the request's echo reaches CGuild::AddPoints (0x5c4110), which raises
// the guild's GatheredSP and the member's GP_Donation by the batch. That is
// guild.PointAccumulator (the `9 < acc` batch) and guild.Store.AddPoints.
//
// ONLY AddSkillExp is overridden, because that conversion is the one place the
// engine accumulates: GM /sp, learn refunds and the no-level-table fallback all
// go through AddSkillPoints, which passes straight through and credits nothing.
// Every other method is the inner store's.
//
// The accumulator (pc+0x2184) has exactly three touches in srv.asm. Besides
// the add at 0x4e5625, CGObjPC::vslot_000 zeroes it for every new PC object
// (0x4dea77, ebx cleared at 0x4de9cb), and FUN_004def90 FLUSHES it when the PC
// leaves the world: `if (0 < pc[0x861] && pc[0x72f] != 0) {
// RequestAddGuildPoints(pc[0x861]); pc[0x861] = 0; }` (0x4def96-0x4defc2), with
// no threshold, so one to nine pending points still reach the guild.
// FUN_004def90's one caller is FUN_004df050 (0x4df214), the take-the-PC-out
// path: transaction::OnTimeout calls it after logging "DISCONNECT FROM
// transaction::OnTimeout()", CMainProcess::FUN_00417a80 calls it for every PC
// when the ShardManager link drops, and right after the flush it calls vtable
// +0x1f0 (IGObj::SetLifeState, docs/protocol/igobj_vtable.md slot 124) with 3,
// GONE (docs/protocol/character_state.md, LIFESTATE). There is nothing to
// persist; the count lives exactly as long as the PC is in the world.
// FlushPending is that flush, and GuildPointsDisconnectHandler runs it when a
// session's connection ends.
//
// As in the engine, the accumulator is zeroed once a batch goes out, whatever
// the credit's result (0x4e5647 and 0x4defc2 write 0 without testing
// RequestAddGuildPoints' return), and a failed credit is logged, never handed
// back: the kill path would otherwise fail a kill over a guild total.
//
// RequestAddGuildPoints' (0x5c62e0) own gates, for both callers:
//   - its life test (vtable +0xf8 IGObj::GetLifeState == 1, else 0x4c07) is
//     applied with the stand-in session/guild.go's founder check uses for the
//     same engine test: alive is HP > 0 (OpenSRO stores no life state, and
//     0 HP is what character.Store.ApplyDamage reports as died). A dead
//     earner's batch is dropped, not kept. That includes the logout flush:
//     FUN_004df050's branch for a PC in state 2 (DEAD), read in round 525,
//     computes the return point and writes the saved position
//     (CGObjPC::FUN_004e08a0, FUN_004f9950/9920/9850) before FUN_004def90
//     runs, with no SetLifeState (+0x1f0) call among them, so a PC dead at
//     logout meets the request's 0x4c07;
//   - its guild-level test (`cmp al,0x5; ja` at 0x5c6335) cannot fail for
//     OpenSRO: a guild's Level stops at guild.MaxLevel, 5, because
//     guild.Store.LevelUp refuses past it (round 528), so it is not repeated.
func NewGuildPointSkills(inner skill.Store, guilds guild.Store, chars character.Store) *GuildPointSkills {
	return &GuildPointSkills{Store: inner, guilds: guilds, chars: chars, acc: make(map[int64]*guild.PointAccumulator)}
}

// GuildPointSkills is the decorator NewGuildPointSkills returns: a skill.Store
// whose AddSkillExp also books guild points, plus the logout flush.
type GuildPointSkills struct {
	skill.Store
	guilds guild.Store
	chars  character.Store

	mu  sync.Mutex
	acc map[int64]*guild.PointAccumulator // characterID -> the engine's pc+0x2184
}

// guildPointsFlushTimeout bounds one logout or shutdown flush. OpenSRO's own
// value, not the engine's: a stalled database must not hold a disconnecting
// session's goroutine, or the process's stop, indefinitely.
const guildPointsFlushTimeout = 5 * time.Second

// AddSkillExp is the inner store's, followed by the guild credit above. The
// inner store's results are returned unchanged.
func (s *GuildPointSkills) AddSkillExp(ctx context.Context, characterID int64, sexp int64) (int, int, error) {
	gained, total, err := s.Store.AddSkillExp(ctx, characterID, sexp)
	if err != nil || gained <= 0 {
		return gained, total, err
	}
	// pc[0x72f] != 0: only a member accumulates.
	//
	// A DEPARTURE on a lookup error: the engine reads pc[0x72f] from the PC
	// object in memory, which cannot fail, so a member always books. Here
	// membership is a store query; when GuildIDOf fails with anything other
	// than ErrNotInGuild (a database error), this conversion's points are
	// logged and not booked, and the guild never gets them. The count already
	// pending is untouched. FlushPending has the same gap (below).
	guildID, gerr := s.guilds.GuildIDOf(ctx, characterID)
	if gerr != nil {
		if !errors.Is(gerr, guild.ErrNotInGuild) {
			slog.Error("guild points: looking up the earner's guild", "character_id", characterID, "err", gerr)
		}
		return gained, total, err
	}

	s.mu.Lock()
	a := s.acc[characterID]
	if a == nil {
		a = &guild.PointAccumulator{}
		s.acc[characterID] = a
	}
	batch := a.Add(gained)
	s.mu.Unlock()

	if batch > 0 {
		s.request(ctx, guildID, characterID, batch)
	}
	return gained, total, err
}

// FlushPending is FUN_004def90's guild half (0x4def96-0x4defc2): whatever
// characterID has pending, any count above zero, goes to its guild, and the
// count is dropped. It removes the character's accumulator, so the map holds
// only characters that have earned since they last left the world.
//
// Not in a guild at the flush (they earned, then left it): the engine skips
// the request (0x4def9f `je`) and the PC object, count and all, goes away;
// here the count is dropped. A session that entered the world as a second
// character without disconnecting leaves the first one's count here until
// that character's next flush. A GuildIDOf database error drops the count
// too (logged), where the engine's in-memory pc[0x72f] test cannot fail --
// the same departure as AddSkillExp's.
func (s *GuildPointSkills) FlushPending(ctx context.Context, characterID int64) {
	s.mu.Lock()
	a := s.acc[characterID]
	delete(s.acc, characterID)
	s.mu.Unlock()
	if a == nil || a.Pending() <= 0 {
		return
	}
	guildID, err := s.guilds.GuildIDOf(ctx, characterID)
	if err != nil {
		if !errors.Is(err, guild.ErrNotInGuild) {
			slog.Error("guild points: looking up the leaver's guild", "character_id", characterID, "err", err)
		}
		return
	}
	s.request(ctx, guildID, characterID, a.Pending())
}

// FlushAllPending flushes every character with points pending, for a server
// that is stopping. OPENSRO'S OWN HANDLING: the engine's clean-shutdown path
// has not been read. Its one all-users-out path that has, the ShardManager
// link dropping (CMainProcess::FUN_00416f80 logs "all user connections will
// be lost (but, data saved)" and calls FUN_00417a80), runs FUN_004df050(4),
// and so the flush, for every PC. OpenSRO's gateway does not run OnDisconnect
// for sessions still open when it stops, so cmd/server calls this once the
// listener has returned.
//
// A WINDOW THIS DOES NOT CLOSE (disclosed in round 527, not fixed). When the
// listener returns, nothing else has stopped. gateway.Server.ListenAndServe
// returns without waiting for its serveConn goroutines, and a serveConn
// blocked in proto.Read only sees the cancelled context after its next
// packet, which it still hands to the handler. The keep-up swings run on
// their own timers with context.Background (keepup.go, armKeepUp). So a kill
// that converts skill experience during or after this flush books on an
// accumulator this call has already passed (or re-creates one it removed),
// and main returns without sending it: up to nine points per character, on
// a clean stop only (on a crash every pending count is lost anyway). A batch
// of ten or more that such a kill sends is lost too if main returns while
// its credit is still running. Closing it would need the gateway to track
// and close its connections and wait for them, and the keep-up loops to be
// stopped first -- a change to the gateway's lifecycle, not to this file.
func (s *GuildPointSkills) FlushAllPending(ctx context.Context) {
	s.mu.Lock()
	ids := make([]int64, 0, len(s.acc))
	for id := range s.acc {
		ids = append(ids, id)
	}
	s.mu.Unlock()
	for _, id := range ids {
		s.FlushPending(ctx, id)
	}
}

// request is CGuildManager::RequestAddGuildPoints (0x5c62e0) and its echo,
// CGuild::AddPoints (0x5c4110), for a count the caller has already taken off
// the accumulator: the life gate OpenSRO can test, then the credit.
func (s *GuildPointSkills) request(ctx context.Context, guildID, characterID int64, points int) {
	c, err := s.chars.GetByID(ctx, characterID)
	if err != nil {
		slog.Error("guild points not credited: looking up the earner", "character_id", characterID,
			"guild_id", guildID, "points", points, "err", err)
		return
	}
	if c.HP <= 0 {
		// GetLifeState != 1 -> 0x4c07 GUILDERR_IM_DEAD, and the caller has
		// zeroed the count all the same.
		slog.Info("guild points dropped: the earner is dead", "character_id", characterID,
			"guild_id", guildID, "points", points)
		return
	}
	if err := s.guilds.AddPoints(ctx, guildID, characterID, points); err != nil {
		slog.Error("guild points not credited", "character_id", characterID,
			"guild_id", guildID, "points", points, "err", err)
		return
	}
	// Round 821: the guild's GP and the member's donation to the members in
	// the world.
	if g, err := s.guilds.Get(ctx, guildID); err == nil {
		guildPointsChanged(ctx, g, characterID)
	}
}

// GuildPointsDisconnectHandler returns a func for gateway.Server's
// OnDisconnect hook: FlushPending for the disconnecting session's character,
// the engine's logout flush (FUN_004df050 -> FUN_004def90, above). It finds the
// character in hub, so it must run before WorldDisconnectHandler removes the
// session from it. A keep-up swing that lands between the two (before
// WorldDisconnectHandler cancels it) books on a fresh accumulator, which the
// character's next flush, or FlushAllPending, sends.
func GuildPointsDisconnectHandler(hub *world.Hub, gp *GuildPointSkills) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		entity, ok := hub.EntityBySession(sess.ID())
		if !ok {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), guildPointsFlushTimeout)
		defer cancel()
		gp.FlushPending(ctx, entity.CharacterID)
	}
}
