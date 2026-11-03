package session

import (
	"sort"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/stall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// The world's side of the server metrics (round 858, OURS): the zone label
// and the snapshot the scrape reads (metrics.SetWorldSource).

// metricZones are the named zones, sorted, for nearestZone.
var metricZones = func() []string {
	out := make([]string, 0, len(worldmap.ZoneCentre))
	for z := range worldmap.ZoneCentre {
		out = append(out, z)
	}
	sort.Strings(out)
	return out
}()

// nearestZone is the named zone whose centre region is nearest region
// (rx, ry), by region distance.
func nearestZone(rx, ry int) string {
	best, bestD := "other", -1
	for _, z := range metricZones {
		c := worldmap.ZoneCentre[z]
		dx, dy := c[0]-rx, c[1]-ry
		if d := dx*dx + dy*dy; bestD < 0 || d < bestD {
			best, bestD = z, d
		}
	}
	return best
}

// zoneLabelOf is the zone a player is counted and logged under, from a
// bounded set: a named town (its own bucket; or, in the one world frame of
// -single-frame and in an "x/y" region label, the town whose centre region
// is nearest where it stands), a served dungeon's label, or "other".
func zoneLabelOf(e world.Entity) string {
	z := e.Zone
	if z == "" {
		return "other"
	}
	if _, ok := worldmap.ZoneCentre[z]; ok {
		return z
	}
	if rid, ok := dungeonOf(z); ok {
		if ServedDungeon(rid) {
			return z
		}
		return "dungeon"
	}
	if z == worldmap.WorldBucket {
		rx, ry, _, _ := worldmap.FromWorld(e.Pos.X, e.Pos.Z, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
		return nearestZone(rx, ry)
	}
	if rx, ry, ok := worldmap.ParseRegionLabel(z); ok {
		return nearestZone(rx, ry)
	}
	return "other"
}

// MetricsSource is the scrape's view of the running world: the players by
// zone, the objects by kind, the logged-in sessions and the mover pass's
// lock hold. Any argument may be nil.
func MetricsSource(hub *world.Hub, monsters *combat.Hub, ground *grounditem.Hub, stalls *stall.Hub, logins *LoginService) func() metrics.WorldSnapshot {
	return func() metrics.WorldSnapshot {
		s := metrics.WorldSnapshot{PlayersByZone: map[string]int{}, Entities: map[string]int{}}
		if hub != nil {
			for _, e := range hub.AllEntities() {
				s.PlayersByZone[zoneLabelOf(e)]++
			}
			s.Entities["player"] = hub.Count()
			s.MoverHold = hub.LastPassHold().Seconds()
		}
		if monsters != nil {
			s.Entities["monster"] = monsters.Count()
		}
		if ground != nil {
			s.Entities["ground_item"] = ground.Count()
		}
		if stalls != nil {
			s.Entities["stall"] = stalls.Count()
		}
		if w := npcWorldRuntime.Load(); w != nil {
			s.Entities["npc"] = w.placed
		} else {
			s.Entities["npc"] = 0
		}
		cosWorld.mu.Lock()
		s.Entities["cos"] = len(cosWorld.byUID)
		cosWorld.mu.Unlock()
		if logins != nil && logins.Online != nil {
			s.Authenticated = logins.Online.Count()
		}
		return s
	}
}

// gmMetricVerbs are the GM console's commands (gm.Deps.Run's cases): a
// command's label is its verb when it is one of these, else "unknown".
var gmMetricVerbs = func() map[string]bool {
	m := map[string]bool{}
	for _, v := range strings.Fields("tp goto give item avatar gold level heal spawn kill spawnunique damage durability sp hwan " +
		"notice invsize speed hurt afflict hour ban block unblock blockinfo chatban unchatban tradeban untradeban questblock " +
		"jobexp jobweek guildlevel guildperm guildabsent guildgp union guildwar silk lottery plus adv") {
		m[v] = true
	}
	return m
}()

// gmMetricVerb is a GM line's bounded verb label.
func gmMetricVerb(line string) string {
	v := strings.TrimPrefix(gmVerb(line), "/")
	if gmMetricVerbs[v] {
		return v
	}
	return "unknown"
}

// The server loops' metrics (metrics.Loop): one per ticker, named in
// opensro_loop_tick_seconds{loop}.
var (
	loopMonsterAI   = metrics.NewLoop("monster_ai", MonsterAITick)
	loopAOI         = metrics.NewLoop("monster_aoi", AOITick)
	loopCOS         = metrics.NewLoop("cos", cosTick)
	loopBuffs       = metrics.NewLoop("buffs", buffPoll)
	loopToggles     = metrics.NewLoop("toggles", buffPoll)
	loopStatus      = metrics.NewLoop("status", StatusTick)
	loopRegen       = metrics.NewLoop("regen", regenPoll)
	loopMover       = metrics.NewLoop("mover", moverPassPeriod)
	loopPotions     = metrics.NewLoop("potions", potionTickInterval)
	loopGroundItems = metrics.NewLoop("ground_items", time.Second)
)
