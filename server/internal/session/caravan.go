package session

import (
	"context"
	"log/slog"
	"math/rand"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/ai"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/safezone"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// The caravans and their waves (round 804; docs/protocol/jobs.md "NPC
// thieves and hunters"). READ in SR_GameServer.exe:
//
//   - A player is registered as a caravan (s:0x60c5a0, a map keyed by his
//     id; one already registered is left as it is) when he closes a
//     specialty trader's dialog while his transport holds goods (EndInteraction
//     s:0x510872, logging "Trader Registered, TradeRisk: %d"), when a good is
//     picked up into his transport (s:0x4e9676), and when a transport holding
//     goods is registered to him (s:0x4fa861).
//   - Every caravan counts the main loop's milliseconds (s:0x60c610 ->
//     s:0x60bc80); past its threshold the threshold is rolled again (60 to
//     120 s, jobs.WaveDelayMs) and the caravan checked (s:0x60bd40): its
//     player in the world, his transport alive and holding goods -- else the
//     caravan is dropped. A transport in a town region (IsBattleField 0) gets
//     no wave this time. Otherwise a wave (s:0x60bf30): NPC thieves round a
//     trader's transport, NPC hunters round anyone else's, their count from
//     the trade value (jobs.WaveCountBase / WaveCount), each one's level
//     (jobs.WaveLevel) and row (jobs.MobLevels.Pick, the group by the
//     player's region's continent), the tactics row 2001+ / 2011+, a 2 %
//     champion, spawned on the nest hatch's ring of 150 round the transport
//     (GObjPC::FUN_005f6eb0 -> FUN_00531240).
//
// OURS, disclosed: the loop is a 250 ms ticker; waves need the monster AI (a
// wave without brains would stand still); the spawn routine keeps no record
// of a wave and nothing in the engine removes one -- it stays until killed --
// but OpenSRO removes a wave's monsters that are not fighting once their
// caravan is dropped, so finished runs do not leave them on the roads.

// CaravanDeps is what the waves are built from (cmd/server).
type CaravanDeps struct {
	// Thieves and Hunters are the monster tables (s:0x6bb8a0, s:0x6bc5a0).
	Thieves, Hunters *jobs.MobLevels
	// Specs are the job monsters' spawn data by reference id.
	Specs map[int64]*combat.MinionSpec
	// Tactics are the _RefTactics rows 2001..2004 and 2011..2014.
	Tactics map[int64]*combat.Tactics
	// MonFactor is TRADE_MON_FACTOR (specialty.ShardMonFactor by default).
	MonFactor uint32
	// NPCThieves sends the NPC thieves' waves round a trader's caravan (the
	// original always does). OURS, round 812: a server switch, off by
	// default at the user's request; off, a trader's caravan still runs its
	// clock (s:0x60bc80) but its wave spawns nothing. The NPC hunters'
	// waves round a thief's or hunter's caravan are not affected.
	NPCThieves bool
	Hub        *world.Hub
	Monsters   *combat.Hub
	Logger     *slog.Logger
	Rand       *rand.Rand
}

type caravan struct {
	acc, threshold int
}

type caravanRuntime struct {
	d    CaravanDeps
	dice nest.Dice
	mu   sync.Mutex
	list map[int64]*caravan
	// waves maps a wave monster to its caravan's player; orphans are the
	// monsters of dropped caravans still to be removed.
	waves   map[int64]int64
	orphans []int64
}

var caravanRT atomic.Pointer[caravanRuntime]

// SetCaravanDeps installs the waves' runtime (nil tables: none).
func SetCaravanDeps(d CaravanDeps) {
	if d.Thieves == nil || d.Hunters == nil || d.Monsters == nil || d.Hub == nil {
		caravanRT.Store(nil)
		return
	}
	if d.Logger == nil {
		d.Logger = slog.Default()
	}
	if d.Rand == nil {
		d.Rand = rand.New(rand.NewSource(time.Now().UnixNano()))
	}
	if d.MonFactor == 0 {
		d.MonFactor = 2300
	}
	caravanRT.Store(&caravanRuntime{d: d, dice: nest.RandDice(d.Rand), list: map[int64]*caravan{}, waves: map[int64]int64{}})
}

// RunCaravans ticks the caravans until ctx ends.
func RunCaravans(ctx context.Context) {
	go func() {
		t := time.NewTicker(250 * time.Millisecond)
		defer t.Stop()
		last := time.Now()
		for {
			select {
			case <-ctx.Done():
				return
			case now := <-t.C:
				if rt := caravanRT.Load(); rt != nil {
					rt.tick(ctx, int(now.Sub(last)/time.Millisecond))
				}
				last = now
			}
		}
	}()
}

// registerCaravan is s:0x60c5a0: a new caravan's clock at 0 and its first
// threshold rolled; one already registered is left alone.
func registerCaravan(ctx context.Context, characterID int64, why string) {
	rt := caravanRT.Load()
	if rt == nil {
		return
	}
	rt.mu.Lock()
	if _, ok := rt.list[characterID]; ok {
		rt.mu.Unlock()
		return
	}
	c := &caravan{threshold: jobs.WaveDelayMs(rt.dice)}
	rt.list[characterID] = c
	rt.mu.Unlock()
	level := 0
	if e, ok := rt.d.Hub.EntityByCharacterID(characterID); ok {
		level = e.Level
	}
	rt.d.Logger.Info("caravan: trader registered", "character", characterID, "why", why,
		"trade_risk", tradeScaleOf(ctx, characterID, level), "first_wave_ms", c.threshold)
}

// caravanOnEnd is EndInteraction's registration (s:0x510838..0x510872): a
// dialog closed in mode 5 or 6 at a specialty trader (OpenSRO: an NPC with
// 0xc; the engine asks the NPC's quotation map) while the player's transport
// holds goods. Any job.
func caravanOnEnd(ctx context.Context, sess *gateway.Session, hub *world.Hub, npcUID uint32, mode byte) {
	if mode != 5 && mode != 6 || hub == nil || caravanRT.Load() == nil {
		return
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	pl, found := npcInZone(npcUID, e.Zone)
	if !found || !npcHas(pl.npc.Interact, npctalk.IDSpecial) || !haveTradeItem(ctx, e.CharacterID) {
		return
	}
	registerCaravan(ctx, e.CharacterID, "a specialty trader's dialog closed")
}

func (rt *caravanRuntime) tick(ctx context.Context, dt int) {
	if dt <= 0 {
		return
	}
	type due struct {
		id int64
	}
	var fire []due
	rt.mu.Lock()
	for id, c := range rt.list {
		c.acc += dt
		if c.acc >= c.threshold {
			// FUN_0060bd00 first: the next threshold, the clock at 0.
			c.acc, c.threshold = 0, jobs.WaveDelayMs(rt.dice)
			fire = append(fire, due{id})
		}
	}
	rt.mu.Unlock()
	for _, f := range fire {
		rt.fire(ctx, f.id)
	}
	rt.reapOrphans()
}

// fire is s:0x60bc80's path past the threshold.
func (rt *caravanRuntime) fire(ctx context.Context, characterID int64) {
	e, ok := rt.d.Hub.EntityByCharacterID(characterID)
	o := ownTransport(characterID)
	if !ok || o == nil || !haveTradeItem(ctx, characterID) {
		rt.drop(characterID, "the player, his transport or its goods are gone")
		return
	}
	cosWorld.mu.Lock()
	zone, pos := o.zone, o.at(time.Now())
	cosWorld.mu.Unlock()
	if _, town := safeRegionAt(zone, pos.X, pos.Z); town {
		return
	}
	if monsterAIRuntime.Load() == nil {
		return
	}
	rt.wave(ctx, e, zone, pos)
}

// drop removes a caravan; its waves' monsters become orphans to remove.
func (rt *caravanRuntime) drop(characterID int64, why string) {
	rt.mu.Lock()
	delete(rt.list, characterID)
	n := 0
	for id, owner := range rt.waves {
		if owner == characterID {
			rt.orphans = append(rt.orphans, id)
			delete(rt.waves, id)
			n++
		}
	}
	rt.mu.Unlock()
	rt.d.Logger.Info("caravan: dropped", "character", characterID, "why", why, "wave_monsters_left", n)
}

// wave is s:0x60bf30.
func (rt *caravanRuntime) wave(ctx context.Context, e world.Entity, zone string, at world.Position) {
	level := e.Level
	value := tradeAmountOf(ctx, e.CharacterID, level)
	th := specialtyNow().d.Thresholds
	scale := int(th.Scale(value))
	job := jobStateNow(ctx, e.CharacterID)
	rt.mu.Lock()
	dice := rt.dice
	base := jobs.WaveCountBase(value, th[1], rt.d.MonFactor, transportHoldsBargainGoods(ctx, e.CharacterID))
	n := jobs.WaveCount(base, dice)
	tacticsID := jobs.WaveTacticsID(job, dice)
	kind := jobs.WaveMobKind(job)
	if kind == jobs.MobNPCThief && !rt.d.NPCThieves {
		rt.mu.Unlock()
		rt.d.Logger.Info("caravan: wave skipped, NPC thieves are off (-npc-thieves)", "character", e.CharacterID,
			"value", value, "scale", scale, "count", n)
		return
	}
	table := rt.d.Hunters
	if kind == jobs.MobNPCThief {
		table = rt.d.Thieves
	}
	// The player's region's continent (s:0x60c027 -> 0x60bdd0). OURS: with
	// no region table (-regions-csv unset) the China rows stand in.
	group := 0
	if r, ok := regionAt(e.Zone, e.Pos.X, e.Pos.Z); ok {
		group = jobs.WaveGroup(r.Continent)
	}
	tactics := rt.d.Tactics[tacticsID]
	type spawn struct {
		spec     *combat.MinionSpec
		champion bool
		x, z     float64
	}
	var spawns []spawn
	for i := 0; i < n; i++ {
		lv := jobs.WaveLevel(scale, level, dice)
		id := table.Pick(group, lv, dice)
		if id == 0 {
			continue
		}
		_ = dice() // the heading (s:0x60c086): a random facing, which the hatch rolls again
		champion := jobs.WaveChampion(dice)
		dx, dz := nest.HatchOffset(dice, jobs.WaveRadius)
		if spec := rt.d.Specs[id]; spec != nil {
			spawns = append(spawns, spawn{spec, champion, at.X + dx, at.Z + dz})
		}
	}
	rt.mu.Unlock()
	var ids []int64
	for _, s := range spawns {
		sp := s.spec.Species
		class := nest.Class(0)
		if s.champion {
			class = 1
		}
		sp.Rarity = nest.ClampClassByLevel(class, sp.Level).Rank()
		m := rt.d.Monsters.SpawnHatched(zone, sp, s.x, at.Y, s.z, s.spec.MaxHP, s.spec.Defense, s.spec.Attack, s.spec.Gold,
			combat.Hatch{HomeX: s.x, HomeZ: s.z, Tactics: tactics})
		ids = append(ids, m.ID)
	}
	rt.mu.Lock()
	for _, id := range ids {
		rt.waves[id] = e.CharacterID
	}
	rt.mu.Unlock()
	for _, id := range ids {
		BroadcastMonsterSpawned(rt.d.Hub, rt.d.Monsters, id)
	}
	rt.d.Logger.Info("caravan: wave", "character", e.CharacterID, "job", job, "kind", kind, "value", value, "scale", scale,
		"count", n, "spawned", len(ids), "tactics", tacticsID, "group", group, "at_x", at.X, "at_z", at.Z, "ids", ids)
}

// reapOrphans removes the dropped caravans' wave monsters that are not
// fighting (OURS, the package comment).
func (rt *caravanRuntime) reapOrphans() {
	rt.mu.Lock()
	if len(rt.orphans) == 0 {
		rt.mu.Unlock()
		return
	}
	ids := rt.orphans
	rt.orphans = nil
	rt.mu.Unlock()
	a := monsterAIRuntime.Load()
	var keep []int64
	for _, id := range ids {
		if _, alive := rt.d.Monsters.Get(id); !alive {
			continue
		}
		if a == nil || !a.removeIdle(id) {
			keep = append(keep, id)
		}
	}
	if len(keep) > 0 {
		rt.mu.Lock()
		rt.orphans = append(rt.orphans, keep...)
		rt.mu.Unlock()
	}
}

// removeIdle removes monster id when its brain is not fighting (not in
// BATTLE), telling the players whose window holds it at the next pass. True
// when it is gone.
func (a *monsterAI) removeIdle(id int64) bool {
	a.mu.Lock()
	defer a.mu.Unlock()
	if b := a.brains[id]; b != nil && b.machine.State() == ai.StateBattle {
		return false
	}
	m, ok := a.monsters.Get(id)
	if !ok {
		return true
	}
	cell := combat.CellOf(m.Zone, m.X, m.Z)
	watchers := a.watchersOf(cell)
	gone, removed := a.monsters.Remove(id)
	if !removed {
		return true
	}
	chanceMemory.Forget(gone.ID)
	statusFX.forgetMonster(gone.ID)
	a.pending = append(a.pending, monsterPush{zone: gone.Zone, cell: cell, also: watchers,
		packet: &proto.Packet{Opcode: OpMonsterLeft, Data: (&MonsterLeft{IDs: []int64{gone.ID}}).Encode()}})
	return true
}

// regionAt is the region row under (x, z) in zone, town or not.
func regionAt(zone string, x, z float64) (safezone.Region, bool) {
	t := safeRegions.Load()
	if t == nil {
		return safezone.Region{}, false
	}
	fx, fy, ok := entityFrame(zone)
	if !ok {
		return safezone.Region{}, false
	}
	rx, ry, _, _ := worldmap.FromWorld(x, z, fx, fy)
	if rx < 0 || rx > 0xFF || ry < 0 || ry > 0xFF {
		return safezone.Region{}, false
	}
	return t.Region(worldmap.RegionID(rx, ry))
}
