package session

// Round 844 lane G (part 2): the guild recall -- the master's "Guild Member
// Summon Scroll" (itemdata 9267, TypeID 3/3/12/3; the guild store's tab 3) --
// as the original runs it (READ unless marked; docs/protocol/guild.md, "The
// guild recall"):
//
//   - the use (s:0x49afe0, case TID4 3): no guild 0x4c0d, an instance world
//     0x18c1, not the master or the guild under Param3's level (5) 0x18bc,
//     not in a town 0x18c2, in region 0x60b6 0x18c7, the reuse (Param1,
//     3,600 s) running 0x185b; then the scroll is spent;
//   - the ShardManager (sm:0x434f90 / 0x437e70) asks every online member but
//     the master: 0x7030 {u32 job, u32 caster, u32 Param2 / 1000 = 30 s}; the
//     job lives 180 s;
//   - the answer 0x7031 {u32 job, u32 caster, u8 yes} (s:0x4ee1d0): a dead,
//     teleporting, murdering, cart-driving or busy target 0x18c1; else B031
//     {1} whatever the answer, and a yes moves the member to where the
//     master stood when the scroll was used (0x3833 -> s:0x5ba690: the delay
//     floored to 0.1 s; the client's 30 s gauge is cosmetic).

import (
	"context"
	"encoding/binary"
	"log/slog"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/teleport"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	OpRecallAsk          uint16 = 0x7030 // S->C {u32 job, u32 caster, u32 seconds}
	OpRecallAnswer       uint16 = 0x7031 // C->S {u32 job, u32 caster, u8 yes}
	OpRecallAnswerResult uint16 = 0xB031 // {1} | {2, u16}

	recallErrInstance = 0x18c1 // UIIT_MSG_GUILD_RECALL_ERROR
	recallErrNotTown  = 0x18c2 // UIIT_MSG_GUILD_RECALL_ERROR
	recallErrRight    = 0x18bc // UIIT_MSG_GUILD_ITEM_RIGHT_LIMIT
	recallErrThief    = 0x18c7 // UIIT_MSG_GUILD_RECALL_LIMIT
	recallErrReuse    = 0x185b // UIIT_MSG_WAIT_FOR_REUSE_DELAY

	// recallRegionThief is the region the recall is refused in (READ
	// s:0x49b180 `cmp WORD PTR [eax],0x60b6`; INFERRED the thief town, the
	// Korean UIIT_MSG_GUILD_RECALL_LIMIT naming it).
	recallRegionThief = 0x60b6
)

// RecallJobLife is the ShardManager job's life (READ sm:0x783700's 180.0):
// an answer after it is dropped, as is the box's own 180 s timer.
const RecallJobLife = 180 * time.Second

// recallItem is the scroll: TypeID 3/3/12/3 (READ c:0x667000). Its Param1 is
// the reuse in ms, Param2 the gauge in ms, Param3 the guild level (this
// export's RestoreHP, RestoreHPPct, RestoreMP).
func recallItem(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == 3 && it.TypeID2 == 3 && it.TypeID3 == 12 && it.TypeID4 == 3
}

// recallRefusals are OURS words beside the codes (the client shows the
// codes' own texts).
var recallRefusals = map[uint16]string{
	guild.CodeNotInGuild: "You are not in a guild.",
	recallErrInstance:    "The guild recall cannot be used here.",
	recallErrNotTown:     "The guild recall can only be used in towns.",
	recallErrRight:       "You are not qualified to use the item.",
	recallErrThief:       "The guild recall cannot be used here.",
	recallErrReuse:       "Please wait for the reuse delay.",
}

type recallJob struct {
	id      uint32
	caster  int64
	guildID int64
	place   teleport.Place
	expires time.Time
}

var recallJobs = struct {
	mu     sync.Mutex
	byID   map[uint32]*recallJob
	nextID uint32
	reuse  map[int64]time.Time // the caster's reuse end (timed job (2, 3))
}{byID: map[uint32]*recallJob{}, reuse: map[int64]time.Time{}}

// recallWarp is the move's dependencies (main sets them, SetGuildRecallWarp).
var recallWarp struct {
	mu   sync.Mutex
	eq   equipment.Store
	zerk *berserk.Tracker
}

// SetGuildRecallWarp gives the recall what a warp needs.
func SetGuildRecallWarp(eq equipment.Store, zerk *berserk.Tracker) {
	recallWarp.mu.Lock()
	recallWarp.eq, recallWarp.zerk = eq, zerk
	recallWarp.mu.Unlock()
}

// useGuildRecall is the scroll's use.
func useGuildRecall(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64,
	it *refdata.Item, held inventory.Slot, have int) error {
	refuse := func(code uint16) error {
		return sendUseResult(sess, &UseItemResult{Error: recallRefusals[code], Code: code, Remaining: int32(have)})
	}
	d := guildOps.Load()
	if d == nil || d.hub == nil {
		return sendUseResult(sess, &UseItemResult{Error: "guilds are not available", Remaining: int32(have)})
	}
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	g, err := d.guilds.GetByCharacter(ctx, characterID)
	if err != nil {
		return refuse(guild.CodeNotInGuild)
	}
	if _, inDungeon := dungeonOf(e.Zone); inDungeon {
		return refuse(recallErrInstance)
	}
	if g.LeaderID != characterID || g.Level < it.RestoreMP {
		return refuse(recallErrRight)
	}
	if !inTownAt(e) {
		return refuse(recallErrNotTown)
	}
	place, ok := placeOfEntity(e)
	if !ok {
		return refuse(recallErrInstance)
	}
	if place.Region == recallRegionThief {
		return refuse(recallErrThief)
	}
	now := time.Now()
	recallJobs.mu.Lock()
	if until, ok := recallJobs.reuse[characterID]; ok && now.Before(until) {
		recallJobs.mu.Unlock()
		return refuse(recallErrReuse)
	}
	recallJobs.mu.Unlock()
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return sendUseResult(sess, &UseItemResult{Error: "using failed", Remaining: int32(have)})
	}
	reuse := time.Duration(it.RestoreHP) * time.Millisecond
	seconds := uint32(it.RestoreHPPct / 1000)
	recallJobs.mu.Lock()
	recallJobs.reuse[characterID] = now.Add(reuse)
	if recallJobs.nextID == 0 {
		recallJobs.nextID = 1
	}
	job := &recallJob{id: recallJobs.nextID, caster: characterID, guildID: g.ID, place: place, expires: now.Add(RecallJobLife)}
	recallJobs.nextID++
	recallJobs.byID[job.id] = job
	recallJobs.mu.Unlock()
	if err := sendUseResult(sess, &UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)}); err != nil {
		return err
	}
	ask := binary.LittleEndian.AppendUint32(nil, job.id)
	ask = binary.LittleEndian.AppendUint32(ask, uint32(characterID))
	ask = binary.LittleEndian.AppendUint32(ask, seconds)
	for _, m := range g.Members {
		if m.CharacterID == g.LeaderID {
			continue
		}
		if t, ok := reachOf(d.hub, m.CharacterID); ok && t.Session != nil {
			sendGuild(t.Session, OpRecallAsk, ask)
		}
	}
	slog.Info("guild recall", "guild_id", g.ID, "caster", characterID, "job", job.id, "region", place.Region)
	return nil
}

// handleRecallAnswer is s:0x4ee1d0.
func (d guildOpsDeps) handleRecallAnswer(ctx context.Context, sess *gateway.Session, data []byte) error {
	if len(data) < 9 || d.hub == nil {
		return nil
	}
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	id := binary.LittleEndian.Uint32(data)
	yes := data[8] == 1
	if e.Life == world.LifeDead || deadBySession(d.hub, sess) || tradeEstablishedOn(d.hub, e.CharacterID) ||
		npcTalkOpen(sess.ID()) {
		sendGuild(sess, OpRecallAnswerResult, guild.EncodeFail(recallErrInstance))
		return nil
	}
	// B031 {1} whatever the answer (READ: the answer byte is not tested).
	sendGuild(sess, OpRecallAnswerResult, guild.EncodeOK())
	recallJobs.mu.Lock()
	job := recallJobs.byID[id]
	if job != nil && time.Now().After(job.expires) {
		delete(recallJobs.byID, id)
		job = nil
	}
	recallJobs.mu.Unlock()
	if !yes || job == nil {
		return nil
	}
	// The member must still be in the caster's guild (the ShardManager's
	// list was the guild's; OURS: checked again at the answer).
	if gid, err := d.guilds.GuildIDOf(ctx, e.CharacterID); err != nil || gid != job.guildID {
		return nil
	}
	zone, bucket, pos, frame, ok := placeArrival(job.place.Region, job.place.X, job.place.Y, job.place.Z, teleport.MainWorld)
	if !ok {
		return nil
	}
	recallWarp.mu.Lock()
	eq, zerk := recallWarp.eq, recallWarp.zerk
	recallWarp.mu.Unlock()
	// s:0x5ba690: the move's delay floored to 0.1 s.
	time.AfterFunc(100*time.Millisecond, func() {
		if _, err := warpVia(context.Background(), sess, eq, d.chars, d.hub, zerk, zone, bucket, pos, frame, "guild recall"); err != nil {
			slog.Debug("guild recall: the warp failed", "character_id", e.CharacterID, "err", err)
		}
	})
	return nil
}
