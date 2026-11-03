package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Guild war (round 844, lane V; docs/protocol/guild_war.md). READ in
// SR_GameServer.exe (s:) and SR_ShardManager.exe (m:); the ShardManager's
// jobs are direct store calls (one process).
//
//   - 0x7110 the proclamation (Guild_ValidateWarDeclaration s:0x5c6b60): the
//     target master online and within 300.0, then the ladder; success asks the
//     target master with 0x3080 kind 10 and waits 30 s (s:0x46c9e9).
//   - 0x3080 the answer (s:0x46cb30 -> s:0x5c8510): its checks go to the
//     declarer as 0xB110 {2, code}; an acceptance begins the war (m:0x43be90),
//     takes the stake from both masters (reason 10) and sends 0x38F5 0x19 to
//     both guilds (s:0x5cade0).
//   - A kill between two guilds at war (cause 5, s:0x4e6590) scores
//     guild.WarKillPoints (s:0x5c721x), counts the members (s:0x5cb430) and
//     tells both guilds 0x38F5 0x1d; a side reaching the victory target wins
//     (m:0x43c320).
//   - The 1 s check (m:0x438430): past the end with the totals apart, the
//     higher wins; 0x38F5 0x1f every 60 s for a timed war (m:0x40c69c).
//   - 0x7112 the end proposal is a surrender (s:0x5c7390): 0x1a to the other
//     guild, 0x1b to the own, and after 60 s the other guild wins (UNJOIN,
//     m:0x43ccf0).
//   - The winner's guild keeps LodgedGold (both stakes) as booty
//     (s:0x5c4f20); 0x7114 asks it at the guild manager (any member), 0x7113
//     claims it (the master; s:0x5c72a0 / s:0x5c7330).
//
// OURS: the 0x1c78 "talking to this NPC" check is the NPC in reach
// (npcTarget); the battle arena and ghost-hunt refusals (0x4c7a, 0x4c79) have
// no zone here; a second proclamation to a master already asked is refused
// 0x4c06 (TARGET_BUSY).

type guildWarDeps struct {
	chars  character.Store
	guilds guild.Store
	wars   guild.WarStore
	hub    *world.Hub
}

var guildWarBox atomic.Pointer[guildWarDeps]

// warCache mirrors the store's wars (loaded once; the store stays the truth
// and every change goes through both), so the per-blow hostility test reads
// no database.
var warCache = struct {
	mu   sync.RWMutex
	wars map[int64]guild.War
}{wars: map[int64]guild.War{}}

func cacheWar(w guild.War) {
	warCache.mu.Lock()
	warCache.wars[w.ID] = w
	warCache.mu.Unlock()
}

func uncacheWar(id int64) {
	warCache.mu.Lock()
	delete(warCache.wars, id)
	warCache.mu.Unlock()
}

// cachedWarBetween is the war between guilds a and b (ok false: none).
func cachedWarBetween(a, b int64) (guild.War, bool) {
	if a == 0 || b == 0 || a == b {
		return guild.War{}, false
	}
	warCache.mu.RLock()
	defer warCache.mu.RUnlock()
	for _, w := range warCache.wars {
		if w.Has(a) && w.Other(a) == b {
			return w, true
		}
	}
	return guild.War{}, false
}

// cachedWarsOf is guildID's wars, by id.
func cachedWarsOf(guildID int64) []guild.War {
	warCache.mu.RLock()
	defer warCache.mu.RUnlock()
	var out []guild.War
	for _, w := range warCache.wars {
		if w.Has(guildID) {
			out = append(out, w)
		}
	}
	sortWars(out)
	return out
}

func sortWars(ws []guild.War) {
	for i := 1; i < len(ws); i++ {
		for j := i; j > 0 && ws[j].ID < ws[j-1].ID; j-- {
			ws[j], ws[j-1] = ws[j-1], ws[j]
		}
	}
}

// hostileCount is guild +0x44 (the wars map's size).
func hostileCount(guildID int64) int { return len(cachedWarsOf(guildID)) }

// guildsHostile is IsHostileGuild for two characters' guilds (s:0x4eb390 ->
// CGuild slot 7): both in guilds, and those guilds at war.
func guildsHostile(ctx context.Context, a, b int64) bool {
	if a == b || guildWarBox.Load() == nil {
		return false
	}
	ga, gb := int64(guildPlateOf(ctx, a).ID), int64(guildPlateOf(ctx, b).ID)
	_, ok := cachedWarBetween(ga, gb)
	return ok
}

var warTickerOnce sync.Once

// GuildWarHandler serves the war's requests. The wars are read from the guild
// store (MemStore and SQLStore keep them) and the 1 s check starts once.
func GuildWarHandler(chars character.Store, guilds guild.Store, hub *world.Hub) gateway.Handler {
	ws, _ := guilds.(guild.WarStore)
	d := &guildWarDeps{chars: chars, guilds: guilds, wars: ws, hub: hub}
	if ws != nil {
		guildWarBox.Store(d)
		gm.GuildWars = GuildWarCommands{}
		// The union request's 0x4c42 (lane U's unionops.go asks this).
		hostile := func(_ context.Context, a, b int64) bool {
			_, at := cachedWarBetween(a, b)
			return at
		}
		unionHostile.Store(&hostile)
		loadWarCache(context.Background(), ws)
		warTickerOnce.Do(func() { go warTicker() })
	}
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		d := guildWarBox.Load()
		if d == nil {
			return nil
		}
		switch p.Opcode {
		case guild.OpWarDeclare:
			handleWarDeclare(ctx, sess, p.Data, d)
		case guild.OpWarEnd:
			handleWarSurrender(ctx, sess, p.Data, d)
		case guild.OpWarAsk:
			handleWarAskReward(ctx, sess, p.Data, d)
		case guild.OpWarClaim:
			handleWarClaimReward(ctx, sess, p.Data, d)
		}
		return nil
	}
}

func loadWarCache(ctx context.Context, ws guild.WarStore) {
	wars, err := ws.Wars(ctx)
	if err != nil {
		slog.Warn("guild wars not loaded", "err", err)
		return
	}
	warCache.mu.Lock()
	warCache.wars = map[int64]guild.War{}
	for _, w := range wars {
		warCache.wars[w.ID] = w
	}
	warCache.mu.Unlock()
}

// toGuild sends op/data to guildID's members in the world.
func (d *guildWarDeps) toGuild(ctx context.Context, guildID int64, op uint16, data []byte) {
	g, err := d.guilds.Get(ctx, guildID)
	if err != nil || g == nil {
		return
	}
	for _, m := range g.Members {
		if e, ok := entityOf(d.hub, m.CharacterID); ok {
			sendGuild(e.Session, op, data)
		}
	}
}

func (d *guildWarDeps) guildName(ctx context.Context, id int64) string {
	if g, err := d.guilds.Get(ctx, id); err == nil && g != nil {
		return g.Name
	}
	return ""
}

// --- the hostile list (0x3109) -----------------------------------------------

// sendHostileList is 0x3109 to sess for g (CGuild slot 8, s:0x5c38a0): at
// world entry (s:0x4dfbe8) and to a joining member (s:0x5c8f5a), only while
// the guild has a war.
func sendHostileList(ctx context.Context, sess *gateway.Session, g *guild.Guild) {
	d := guildWarBox.Load()
	if d == nil || sess == nil || g == nil {
		return
	}
	wars := cachedWarsOf(g.ID)
	if len(wars) == 0 {
		return
	}
	entries := make([]guild.HostileEntry, 0, len(wars))
	for i := range wars {
		name := d.guildName(ctx, wars[i].Other(g.ID))
		if name == "" {
			entries = append(entries, guild.HostileEntry{})
			continue
		}
		entries = append(entries, guild.HostileEntry{War: &wars[i], EnemyName: name})
	}
	sendGuild(sess, guild.OpHostileList, guild.EncodeHostileList(entries, time.Now()))
}

// --- the proclamation (0x7110) and its answer (0x3080) --------------------------

type warRequest struct {
	declarer, target int64 // the two masters
	guildA, guildB   int64
	dec              guild.WarDeclaration
	timer            *time.Timer
}

var warRequests = struct {
	mu sync.Mutex
	m  map[int64]*warRequest // the target master -> the request
}{m: map[int64]*warRequest{}}

func takeWarRequest(target int64) *warRequest {
	warRequests.mu.Lock()
	defer warRequests.mu.Unlock()
	r := warRequests.m[target]
	delete(warRequests.m, target)
	if r != nil && r.timer != nil {
		r.timer.Stop()
	}
	return r
}

// warDeclareCode is s:0x5c6b60's ladder, 0 to ask the target.
func (d *guildWarDeps) warDeclareCode(ctx context.Context, me world.Entity, dec guild.WarDeclaration) (uint16, *guild.Guild, *guild.Guild, world.Entity) {
	target := guildByName(ctx, dec.Target)
	if target == nil {
		return guild.ErrWarCantFindTargetGuild, nil, nil, world.Entity{}
	}
	tm, ok := entityOf(d.hub, target.LeaderID)
	if !ok || tm.Zone != me.Zone || dist3(tm.Pos, me.Pos) > guild.WarRange {
		return guild.ErrWarTooFar, nil, target, tm
	}
	mine, err := d.guilds.GetByCharacter(ctx, me.CharacterID)
	if err != nil || mine == nil {
		return guild.ErrWarNotInGuild, nil, target, tm
	}
	if _, _, okp := guild.ParseWarPeriod(dec.Period); !okp || int(dec.VictoryIndex) >= len(guild.WarVictoryPoints) {
		return guild.ErrWarBadTerms, mine, target, tm
	}
	if mine.ID == target.ID {
		// OURS: the client refuses it first (SELFWAR); no server code is read.
		return guild.ErrWarBadTerms, mine, target, tm
	}
	if mine.LeaderID != me.CharacterID {
		return guild.ErrWarPermissionDenied, mine, target, tm
	}
	if c, err := d.chars.GetByID(ctx, me.CharacterID); err != nil || c.Gold < int64(dec.Stake) {
		return guild.ErrWarDeclarerGold, mine, target, tm
	}
	if dec.Stake > guild.MaxWarStake {
		return guild.ErrWarStakeLimit, mine, target, tm
	}
	if hostileCount(mine.ID) >= guild.MaxHostileGuilds {
		return guild.ErrWarMaxHostileGuild, mine, target, tm
	}
	if hostileCount(target.ID) >= guild.MaxHostileGuilds {
		return guild.ErrWarTargetMaxHostileGuild, mine, target, tm
	}
	if _, at := cachedWarBetween(mine.ID, target.ID); at {
		return guild.ErrWarEnemyGuild, mine, target, tm
	}
	if u := unionOfGuild(ctx, mine.ID); u != nil && u.Has(target.ID) {
		return guild.ErrWarAllyGuild, mine, target, tm
	}
	return 0, mine, target, tm
}

func handleWarDeclare(ctx context.Context, sess *gateway.Session, data []byte, d *guildWarDeps) {
	dec, ok := guild.DecodeWarDeclaration(data)
	if !ok {
		return
	}
	me, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	code, mine, target, tm := d.warDeclareCode(ctx, me, dec)
	if code != 0 {
		slog.Info("guild war refused", "character_id", me.CharacterID, "target", dec.Target, "code", fmt.Sprintf("0x%x", code))
		sendGuild(sess, guild.OpWarDeclareR, guild.EncodeFail(code))
		return
	}
	req := &warRequest{declarer: me.CharacterID, target: tm.CharacterID, guildA: mine.ID, guildB: target.ID, dec: dec}
	warRequests.mu.Lock()
	if _, busy := warRequests.m[tm.CharacterID]; busy {
		warRequests.mu.Unlock()
		sendGuild(sess, guild.OpWarDeclareR, guild.EncodeFail(guild.CodeTargetBusy))
		return
	}
	warRequests.m[tm.CharacterID] = req
	req.timer = time.AfterFunc(guild.WarRequestTimeout, func() {
		if r := takeWarRequest(req.target); r == req {
			// s:0x46ce51 -> s:0x5ccd00: the declarer is told 0x4c10.
			if e, ok := entityOf(d.hub, req.declarer); ok {
				sendGuild(e.Session, guild.OpWarDeclareR, guild.EncodeFail(guild.ErrWarTimedOut))
			}
		}
	})
	warRequests.mu.Unlock()
	sendGuild(tm.Session, guild.OpRequest, guild.EncodeWarProclamation(uint32(me.CharacterID), mine.Name,
		dec.Type, dec.Period, dec.VictoryIndex, dec.Stake))
	slog.Info("guild war proclaimed", "declarer", me.CharacterID, "guild", mine.Name, "target", target.Name,
		"period", fmt.Sprintf("0x%x", dec.Period), "victory", dec.VictoryIndex, "stake", dec.Stake)
}

// guildWarAnswer takes the target master's 0x3080 when a proclamation waits
// for it; false when none does (the answer is someone else's).
func guildWarAnswer(ctx context.Context, sess *gateway.Session, me world.Entity, data []byte) bool {
	d := guildWarBox.Load()
	if d == nil {
		return false
	}
	warRequests.mu.Lock()
	_, pending := warRequests.m[me.CharacterID]
	warRequests.mu.Unlock()
	if !pending {
		return false
	}
	accept, ok := guild.DecodeWarAnswer(data)
	if !ok {
		return true
	}
	req := takeWarRequest(me.CharacterID)
	if req == nil {
		return true
	}
	declarer, ok := entityOf(d.hub, req.declarer)
	if !ok {
		return true // 0x4c0e, with no one to tell
	}
	fail := func(code uint16) { sendGuild(declarer.Session, guild.OpWarDeclareR, guild.EncodeFail(code)) }
	ga, errA := d.guilds.Get(ctx, req.guildA)
	gb, errB := d.guilds.Get(ctx, req.guildB)
	if errA != nil || errB != nil {
		fail(guild.ErrWarCantFindTargetGuild)
		return true
	}
	switch {
	case ga.LeaderID != req.declarer:
		fail(guild.ErrWarPermissionDenied)
		return true
	case gb.LeaderID != me.CharacterID:
		fail(guild.ErrWarTargetNotMaster)
		return true
	case !accept:
		fail(guild.ErrWarRefused)
		return true
	}
	stake := int64(req.dec.Stake)
	if c, err := d.chars.GetByID(ctx, me.CharacterID); err != nil || c.Gold < stake {
		fail(guild.ErrWarTargetGold)
		return true
	}
	if c, err := d.chars.GetByID(ctx, req.declarer); err != nil || c.Gold < stake {
		fail(guild.ErrWarDeclarerGold)
		return true
	}
	span, unlimited, _ := guild.ParseWarPeriod(req.dec.Period)
	now := time.Now()
	w := guild.War{Type: req.dec.Type, VictoryIndex: req.dec.VictoryIndex, LodgedGold: 2 * stake,
		GuildA: ga.ID, GuildB: gb.ID, Started: now}
	if !unlimited {
		w.EndTime = now.Add(span)
	}
	begun, err := d.wars.BeginWar(ctx, w)
	if err != nil {
		code := uint16(guild.ErrWarEnemyGuild)
		if !errors.Is(err, guild.ErrAlreadyAtWar) {
			slog.Warn("guild war not stored", "err", err)
			code = 3
		}
		fail(code)
		return true
	}
	cacheWar(*begun)
	// The stake from both masters (vslot 0x16c(-stake, .., 10)).
	for _, who := range []int64{req.declarer, me.CharacterID} {
		if stake > 0 {
			if err := d.chars.DeductGold(ctx, who, stake); err != nil {
				slog.Warn("guild war stake not taken", "character", who, "err", err)
			}
			tellGold(ctx, d.chars, d.hub, who, true)
		}
	}
	d.toGuild(ctx, ga.ID, guild.OpUpdate, guild.EncodeWarStarted(begun, gb.Name, now))
	d.toGuild(ctx, gb.ID, guild.OpUpdate, guild.EncodeWarStarted(begun, ga.Name, now))
	slog.Info("guild war begun", "war", begun.ID, "a", ga.Name, "b", gb.Name, "lodged", begun.LodgedGold,
		"end", begun.EndTime, "victory", begun.VictoryTarget())
	return true
}

// --- kills -------------------------------------------------------------------

// guildWarKill accounts a kill between two guilds at war (s:0x5c6fb0 ->
// 0x5c7000, m:0x43c320, s:0x5cb430): the points (victimLevel the victim's,
// or the fallen COS's), the members' counters, 0x1d to both guilds, and the
// victory target.
func guildWarKill(ctx context.Context, killer, victim world.Entity, victimLevel int, cos bool) {
	d := guildWarBox.Load()
	if d == nil {
		return
	}
	ga, gb := int64(guildPlateOf(ctx, killer.CharacterID).ID), int64(guildPlateOf(ctx, victim.CharacterID).ID)
	w, ok := cachedWarBetween(ga, gb)
	if !ok {
		return
	}
	pts := guild.WarKillPoints(victimLevel, killer.Level)
	after, err := d.wars.AddWarPoints(ctx, w.ID, ga, int64(pts))
	if err != nil {
		slog.Warn("guild war points not stored", "war", w.ID, "err", err)
		return
	}
	cacheWar(*after)
	if err := d.wars.AddWarStats(ctx, killer.CharacterID, 1, 0, int64(pts)); err != nil {
		slog.Warn("guild war counters not stored", "err", err)
	}
	if !cos {
		if err := d.wars.AddWarStats(ctx, victim.CharacterID, 0, 1, 0); err != nil {
			slog.Warn("guild war counters not stored", "err", err)
		}
	}
	// To the killer's guild: side 1, the killer, the victim (a COS: "" then
	// its owner -- the client shows "*" + the owner, c:0x5afc70).
	alias := ""
	victimName := victim.Name
	if cos {
		alias, victimName = victim.Name, ""
	}
	d.toGuild(ctx, ga, guild.OpUpdate, guild.EncodeWarKill(1, w.ID, pts, killer.CharacterID, victimName, alias))
	d.toGuild(ctx, gb, guild.OpUpdate, guild.EncodeWarKill(2, w.ID, pts, victim.CharacterID, killer.Name, ""))
	slog.Info("guild war kill", "war", w.ID, "killer", killer.Name, "victim", victim.Name, "points", pts,
		"a", after.PointsA, "b", after.PointsB)
	if winner, won := after.WinnerByPoints(); won {
		endGuildWar(ctx, d, after.ID, winner, "victory points")
	}
}

// --- the end -------------------------------------------------------------------

// endGuildWar is EndOfWar and 0x1c (s:0x5cb1e0): the war gone, the booty the
// winner's, both guilds told.
func endGuildWar(ctx context.Context, d *guildWarDeps, warID, winner int64, why string) {
	w, err := d.wars.EndWar(ctx, warID, winner)
	uncacheWar(warID)
	if err != nil {
		if !errors.Is(err, guild.ErrWarNotFound) {
			slog.Warn("guild war end not stored", "war", warID, "err", err)
		}
		return
	}
	msg := guild.EncodeWarEnded(w.ID, winner)
	d.toGuild(ctx, w.GuildA, guild.OpUpdate, msg)
	d.toGuild(ctx, w.GuildB, guild.OpUpdate, msg)
	// The engine's record: "GuildWar Guild[%d,%d] Winner[%s]".
	slog.Info(fmt.Sprintf("GuildWar Guild[%d,%d] Winner[%s]", w.GuildA, w.GuildB, d.guildName(ctx, winner)),
		"war", w.ID, "why", why, "lodged", w.LodgedGold, "a", w.PointsA, "b", w.PointsB)
}

var warSyncAt atomic.Int64

// warTicker is the ShardManager's 1 s check (m:0x438430) and its 60 s time
// sync (m:0x40c69c).
func warTicker() {
	t := time.NewTicker(guild.WarTick)
	defer t.Stop()
	for now := range t.C {
		warTick(context.Background(), now)
	}
}

func warTick(ctx context.Context, now time.Time) {
	d := guildWarBox.Load()
	if d == nil {
		return
	}
	warCache.mu.RLock()
	wars := make([]guild.War, 0, len(warCache.wars))
	for _, w := range warCache.wars {
		wars = append(wars, w)
	}
	warCache.mu.RUnlock()
	doSync := now.UnixNano()-warSyncAt.Load() >= int64(guild.WarTimeSync)
	if doSync {
		warSyncAt.Store(now.UnixNano())
	}
	for i := range wars {
		w := &wars[i]
		if winner, ok := w.WinnerByTime(now); ok {
			endGuildWar(ctx, d, w.ID, winner, "time")
			continue
		}
		if doSync && !w.EndTime.IsZero() {
			msg := guild.EncodeWarTime(w, now)
			d.toGuild(ctx, w.GuildA, guild.OpUpdate, msg)
			d.toGuild(ctx, w.GuildB, guild.OpUpdate, msg)
		}
	}
}

// --- the end proposal: a surrender (0x7112) -----------------------------------

var warSurrenders sync.Map // war id -> *time.Timer

func handleWarSurrender(ctx context.Context, sess *gateway.Session, data []byte, d *guildWarDeps) {
	if len(data) < 4 {
		return
	}
	me, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	id := int64(binary.LittleEndian.Uint32(data))
	fail := func(code uint16) { sendGuild(sess, guild.OpWarEndR, guild.EncodeFail(code)) }
	mine, err := d.guilds.GetByCharacter(ctx, me.CharacterID)
	if err != nil || mine == nil {
		fail(guild.ErrWarNotInGuild)
		return
	}
	warCache.mu.RLock()
	w, known := warCache.wars[id]
	warCache.mu.RUnlock()
	if !known || !w.Has(mine.ID) {
		fail(guild.ErrWarBadTerms)
		return
	}
	if mine.LeaderID != me.CharacterID {
		fail(guild.ErrWarPermissionDenied)
		return
	}
	other := w.Other(mine.ID)
	if _, err := d.guilds.Get(ctx, other); err != nil {
		fail(guild.ErrWarCantFindTargetGuild)
		return
	}
	if _, running := warSurrenders.Load(id); running {
		return
	}
	// s:0x5cac40: 0x1a to the guild surrendered to, 0x1b to the own.
	d.toGuild(ctx, other, guild.OpUpdate, guild.EncodeWarEnding(guild.UpdateWarEndingFor, id))
	d.toGuild(ctx, mine.ID, guild.OpUpdate, guild.EncodeWarEnding(guild.UpdateWarEndingBy, id))
	slog.Info(fmt.Sprintf("GuildWar Guild[%d,%d] Surrendered Guild[%d]", w.GuildA, w.GuildB, mine.ID), "war", id)
	t := time.AfterFunc(guild.WarSurrenderDelay, func() {
		warSurrenders.Delete(id)
		endGuildWar(context.Background(), d, id, other, "surrender")
	})
	warSurrenders.Store(id, t)
}

// --- the reward (0x7114 / 0x7113) ------------------------------------------------

func handleWarAskReward(ctx context.Context, sess *gateway.Session, data []byte, d *guildWarDeps) {
	if len(data) < 4 {
		return
	}
	me, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if _, code := npcTarget(me, binary.LittleEndian.Uint32(data)); code != 0 {
		sendGuild(sess, guild.OpWarAskR, guild.EncodeFail(guild.ErrWarNoTalk))
		return
	}
	mine, err := d.guilds.GetByCharacter(ctx, me.CharacterID)
	if err != nil || mine == nil {
		sendGuild(sess, guild.OpWarAskR, guild.EncodeFail(guild.ErrWarNotInGuild))
		return
	}
	booty, err := d.wars.Booty(ctx, mine.ID)
	if err != nil || booty <= 0 {
		sendGuild(sess, guild.OpWarAskR, guild.EncodeFail(guild.ErrWarNoBooty))
		return
	}
	sendGuild(sess, guild.OpWarAskR, binary.LittleEndian.AppendUint32([]byte{1}, uint32(min(booty, math.MaxUint32))))
}

func handleWarClaimReward(ctx context.Context, sess *gateway.Session, data []byte, d *guildWarDeps) {
	if len(data) < 4 {
		return
	}
	me, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if _, code := npcTarget(me, binary.LittleEndian.Uint32(data)); code != 0 {
		sendGuild(sess, guild.OpWarClaimR, guild.EncodeFail(guild.ErrWarNoTalk))
		return
	}
	mine, err := d.guilds.GetByCharacter(ctx, me.CharacterID)
	if err != nil || mine == nil {
		sendGuild(sess, guild.OpWarClaimR, guild.EncodeFail(guild.ErrWarNotInGuild))
		return
	}
	if mine.LeaderID != me.CharacterID {
		sendGuild(sess, guild.OpWarClaimR, guild.EncodeFail(guild.ErrWarPermissionDenied))
		return
	}
	booty, err := d.wars.TakeBooty(ctx, mine.ID)
	if err != nil || booty <= 0 {
		sendGuild(sess, guild.OpWarClaimR, guild.EncodeFail(guild.ErrWarNoBooty))
		return
	}
	// The ShardManager's 0x1e: the gold to the master (reason 0xb).
	if err := d.chars.AddGold(ctx, me.CharacterID, booty); err != nil {
		slog.Warn("guild war reward not paid", "character_id", me.CharacterID, "err", err)
	}
	tellGold(ctx, d.chars, d.hub, me.CharacterID, true)
	sendGuild(sess, guild.OpWarClaimR, guild.EncodeOK())
	slog.Info("guild war reward claimed", "guild", mine.Name, "gold", booty)
}

// guildAtWar is the disband handler's 0x4c46 test (s:0x5c6870).
func guildAtWar(guildID int64) bool { return hostileCount(guildID) > 0 }

// GuildWarCommands is the GM's /guildwar (round 844, OURS, a QA aid): the
// wars listed, and a war's end moved to now + seconds.
type GuildWarCommands struct{}

// List is the GM's guild's wars.
func (GuildWarCommands) List(ctx context.Context, characterID int64) (string, error) {
	d := guildWarBox.Load()
	if d == nil {
		return "", errors.New("no war store")
	}
	g, err := d.guilds.GetByCharacter(ctx, characterID)
	if err != nil {
		return "", errors.New("you are not in a guild")
	}
	wars := cachedWarsOf(g.ID)
	if len(wars) == 0 {
		return g.Name + " is at war with nobody", nil
	}
	out := ""
	now := time.Now()
	for _, w := range wars {
		out += fmt.Sprintf("war %d vs %s: %d - %d, %ds left; ", w.ID, d.guildName(ctx, w.Other(g.ID)),
			w.Points(g.ID), w.Points(w.Other(g.ID)), w.SecondsLeft(now))
	}
	return out, nil
}

// End moves the GM's guild's war with the guild named enemy to end in
// seconds (the 1 s check then ends it when the totals are apart).
func (GuildWarCommands) End(ctx context.Context, characterID int64, enemy string, seconds int) (string, error) {
	d := guildWarBox.Load()
	if d == nil {
		return "", errors.New("no war store")
	}
	g, err := d.guilds.GetByCharacter(ctx, characterID)
	if err != nil {
		return "", errors.New("you are not in a guild")
	}
	e := guildByName(ctx, enemy)
	if e == nil {
		return "", fmt.Errorf("no guild named %s", enemy)
	}
	w, ok := cachedWarBetween(g.ID, e.ID)
	if !ok {
		return "", fmt.Errorf("%s is not at war with %s", g.Name, e.Name)
	}
	end := time.Now().Add(time.Duration(seconds) * time.Second)
	if err := d.wars.SetWarEnd(ctx, w.ID, end); err != nil {
		return "", err
	}
	w.EndTime = end
	cacheWar(w)
	now := time.Now()
	msg := guild.EncodeWarTime(&w, now)
	d.toGuild(ctx, w.GuildA, guild.OpUpdate, msg)
	d.toGuild(ctx, w.GuildB, guild.OpUpdate, msg)
	return fmt.Sprintf("war %d with %s ends in %ds (points %d - %d)", w.ID, e.Name, seconds, w.Points(g.ID), w.Points(e.ID)), nil
}
