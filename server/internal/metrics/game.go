package metrics

import (
	"strings"
	"sync"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
)

// Logins and sessions.
var (
	logins = factory.counterVec("logins_total",
		"Login attempts decided by the login service (both wires), by result: ok, or the refusal (wrong_password, blocked, inspection, already_connected, full, ip_limit, failed, ...).",
		"result")
	worldEntries = factory.counter("world_entries_total",
		"Characters that entered the world (a character select's Start that placed the character).")
	characterOps = factory.counterVec("character_ops_total",
		"Lobby operations that succeeded, by op: create, delete, restore.", "op")
)

// LoginResult counts one decided login.
func LoginResult(result string) { logins.WithLabelValues(result).Inc() }

// WorldEntry counts one character placed in the world.
func WorldEntry() { worldEntries.Inc() }

// CharacterOp counts one lobby operation.
func CharacterOp(op string) { characterOps.WithLabelValues(op).Inc() }

// Movement, teleports and deaths.
var (
	moveLegs = factory.counterVec("move_legs_total",
		"Movement legs the server started for players (0x7021 accepted), by kind: destination or heading.", "kind")
	moveRefused = factory.counterVec("move_refused_total",
		"Movement requests the world refused before a leg, by reason.", "reason")
	moveLegEnds = factory.counterVec("move_leg_ends_total",
		"Player legs the server's mover ended on its own, by reason: wall (the walk met a wall, round 812/857) or run_limit.", "reason")
	moveClaims = factory.counterVec("move_claims_total",
		"Client position claims (stops and placements), by result: taken, refused (past the allowance), refused_wall (past a wall the server's walk found, round 857), refused_state (rooted or trading).",
		"result")
	moveCorrections = factory.counter("move_corrections_total",
		"Corrections sent to a client whose claimed position the server did not take.")
	teleports = factory.counterVec("teleports_total",
		"Warps between zones or places, by kind: gate, zone_change (GM), walk_in, return_scroll, guild_recall, revive, unstuck, gm, other.", "kind")
	zoneChangeRefused = factory.counterVec("zone_change_refused_total",
		"OpChangeZone requests refused, by reason: not_gm (round 854), dead, same_zone, not_in_world, malformed.", "reason")
	playerDeaths = factory.counter("player_deaths_total",
		"Player characters killed (life state alive -> dead, -player-dead-state).")
	playerRevives = factory.counter("player_revives_total",
		"Player characters revived.")
)

// MoveLeg counts one leg started (heading true: a heading run).
func MoveLeg(heading bool) {
	if heading {
		moveLegs.WithLabelValues("heading").Inc()
	} else {
		moveLegs.WithLabelValues("destination").Inc()
	}
}

func MoveRefused(reason string) { moveRefused.WithLabelValues(reason).Inc() }
func MoveLegEnd(reason string)  { moveLegEnds.WithLabelValues(reason).Inc() }
func MoveClaim(result string)   { moveClaims.WithLabelValues(result).Inc() }
func MoveCorrection()           { moveCorrections.Inc() }
func PlayerDeath()              { playerDeaths.Inc() }
func PlayerRevive()             { playerRevives.Inc() }

// Teleport counts one warp; via is session.warpVia's path name, folded onto
// the kinds above so no free text becomes a label.
func Teleport(via string) { teleports.WithLabelValues(TeleportKind(via)).Inc() }

// TeleportKind folds a warp's path name onto the label set.
func TeleportKind(via string) string {
	switch {
	case via == "gate teleport":
		return "gate"
	case via == "zone change":
		return "zone_change"
	case via == "walk-in teleport":
		return "walk_in"
	case strings.Contains(via, "return scroll"):
		return "return_scroll"
	case via == "guild recall":
		return "guild_recall"
	case via == "/unstuck":
		return "unstuck"
	case strings.HasPrefix(via, "gm"):
		return "gm"
	case strings.Contains(via, "revive"), strings.Contains(via, "resurrect"):
		return "revive"
	}
	return "other"
}

func ZoneChangeRefused(reason string) { zoneChangeRefused.WithLabelValues(reason).Inc() }

// Combat.
var (
	skillCasts = factory.counter("skill_casts_total",
		"Player skill casts announced to the zone (a cast id drawn: attack, buff, heal, chain and periodic casts).")
	damageEvents = factory.counterVec("combat_damage_events_total",
		"Blows that dealt damage, by target (monster, player) and source (attack: a player's or a pet's blow on a monster; monster, duel, pvp on a player).",
		"target", "source")
	damageAmount = factory.counterVec("combat_damage_total",
		"Hit points taken by those blows, by target and source.", "target", "source")
	monstersSpawned = factory.counter("monsters_spawned_total",
		"Monsters spawned (roster, nests, uniques, GM).")
	monstersKilled = factory.counter("monsters_killed_total",
		"Monsters killed by a blow.")
	monstersRemoved = factory.counter("monsters_removed_total",
		"Monsters removed without a death (walked into a town, despawned).")
)

func SkillCast() { skillCasts.Inc() }

// Damage counts one blow of amount on target from source.
func Damage(target, source string, amount int) {
	damageEvents.WithLabelValues(target, source).Inc()
	if amount > 0 {
		damageAmount.WithLabelValues(target, source).Add(float64(amount))
	}
}

func MonsterSpawned() { monstersSpawned.Inc() }
func MonsterKilled()  { monstersKilled.Inc() }
func MonsterRemoved() { monstersRemoved.Inc() }

// Items and the economy.
var (
	itemsDropped = factory.counterVec("items_dropped_total",
		"Stacks put on the ground, by kind: gold or item.", "kind")
	itemsPicked = factory.counterVec("items_picked_total",
		"Ground stacks picked up, by picker (player, pet) and kind (gold, item).", "by", "kind")
	itemsExpired = factory.counter("items_expired_total",
		"Ground stacks that lay past their lifetime and vanished.")
	goldFlow = factory.counterVec("gold_total",
		"Gold credited to (in) and debited from (out) characters' purses, summed over every character (the store's AddGold / DeductGold). A credit in an economy transaction that then rolls back is counted too.",
		"dir")
	mallPurchases = factory.counterVec("mall_purchases_total",
		"Item mall purchases, by result: ok or refused.", "result")
	silkSpent = factory.counter("silk_spent_total",
		"Silk paid for item mall purchases.")
	gachaDraws = factory.counter("gacha_draws_total",
		"Magic POP draws.")
	stallEvents = factory.counterVec("stall_events_total",
		"Player stall events: opened, closed, sold, sale_failed.", "event")
	exchanges = factory.counterVec("exchanges_total",
		"Player exchanges (trades) that reached the deal, by result: done or failed.", "result")
)

func ItemDropped(gold bool)           { itemsDropped.WithLabelValues(goldKind(gold)).Inc() }
func ItemPicked(by string, gold bool) { itemsPicked.WithLabelValues(by, goldKind(gold)).Inc() }
func ItemsExpired(n int)              { itemsExpired.Add(float64(n)) }

func goldKind(gold bool) string {
	if gold {
		return "gold"
	}
	return "item"
}

// GoldIn and GoldOut count a purse credit and debit.
func GoldIn(amount int64) {
	if amount > 0 {
		goldFlow.WithLabelValues("in").Add(float64(amount))
	}
}

func GoldOut(amount int64) {
	if amount > 0 {
		goldFlow.WithLabelValues("out").Add(float64(amount))
	}
}

// MallPurchase counts one mall buy and the silk it cost.
func MallPurchase(ok bool, silk int64) {
	if !ok {
		mallPurchases.WithLabelValues("refused").Inc()
		return
	}
	mallPurchases.WithLabelValues("ok").Inc()
	if silk > 0 {
		silkSpent.Add(float64(silk))
	}
}

func GachaDraw()              { gachaDraws.Inc() }
func StallEvent(event string) { stallEvents.WithLabelValues(event).Inc() }
func Exchange(ok bool) {
	if ok {
		exchanges.WithLabelValues("done").Inc()
	} else {
		exchanges.WithLabelValues("failed").Inc()
	}
}

// Faults: panics recovered anywhere, and log lines by level.
var (
	panics = factory.counterVec("panics_recovered_total",
		"Panics recovered without ending the process, by where: handler, disconnect_hook, cos_tick, ...", "where")
	logLines = factory.counterVec("log_messages_total",
		"Log lines written, by level (DEBUG lines only when -log-level debug).", "level")
)

func Panic(where string) { panics.WithLabelValues(where).Inc() }

// World state read at scrape time (WorldSource): nothing is counted on the
// hot path for these.
var (
	playersOnlineDesc = prometheus.NewDesc(Namespace+"_players_online",
		"Player characters in the world now.", nil, nil)
	playersZoneDesc = prometheus.NewDesc(Namespace+"_players_online_by_zone",
		"Player characters in the world now, by zone: the named town whose area they stand in (the nearest town's centre region under -single-frame), a dungeon's label, or other.",
		[]string{"zone"}, nil)
	entitiesDesc = prometheus.NewDesc(Namespace+"_world_entities",
		"Objects in the world now, by kind: player, monster, npc, cos, ground_item, stall.", []string{"kind"}, nil)
	sessionsDesc = prometheus.NewDesc(Namespace+"_sessions",
		"Client sessions now, by state: connected (any open connection), authenticated (logged in, lobby or world), in_world.",
		[]string{"state"}, nil)
	moverHoldDesc = prometheus.NewDesc(Namespace+"_world_mover_lock_hold_seconds",
		"How long the last mover pass held the world hub's write lock.", nil, nil)
)

// WorldSnapshot is what the scrape reads from the running world.
type WorldSnapshot struct {
	PlayersByZone map[string]int
	Entities      map[string]int
	Authenticated int
	MoverHold     float64
}

var worldSource atomic.Pointer[func() WorldSnapshot]

// SetWorldSource installs the function the scrape reads the world's state
// from (cmd/server; session.MetricsSnapshot). nil removes it.
func SetWorldSource(f func() WorldSnapshot) {
	if f == nil {
		worldSource.Store(nil)
		return
	}
	worldSource.Store(&f)
}

type worldCollector struct{ mu sync.Mutex }

func (c *worldCollector) Describe(ch chan<- *prometheus.Desc) {
	ch <- playersOnlineDesc
	ch <- playersZoneDesc
	ch <- entitiesDesc
	ch <- sessionsDesc
	ch <- moverHoldDesc
}

func (c *worldCollector) Collect(ch chan<- prometheus.Metric) {
	c.mu.Lock()
	defer c.mu.Unlock()
	ch <- prometheus.MustNewConstMetric(sessionsDesc, prometheus.GaugeValue, ConnectionsActiveValue(), "connected")
	f := worldSource.Load()
	if f == nil {
		return
	}
	s := (*f)()
	total := 0
	for zone, n := range s.PlayersByZone {
		total += n
		ch <- prometheus.MustNewConstMetric(playersZoneDesc, prometheus.GaugeValue, float64(n), zone)
	}
	ch <- prometheus.MustNewConstMetric(playersOnlineDesc, prometheus.GaugeValue, float64(total))
	for kind, n := range s.Entities {
		ch <- prometheus.MustNewConstMetric(entitiesDesc, prometheus.GaugeValue, float64(n), kind)
	}
	ch <- prometheus.MustNewConstMetric(sessionsDesc, prometheus.GaugeValue, float64(s.Authenticated), "authenticated")
	ch <- prometheus.MustNewConstMetric(sessionsDesc, prometheus.GaugeValue, float64(total), "in_world")
	ch <- prometheus.MustNewConstMetric(moverHoldDesc, prometheus.GaugeValue, s.MoverHold)
}

// activeConns mirrors ConnectionsActive for the sessions family.
var activeConns atomic.Int64

// ConnOpened and ConnClosed move the active connection count.
func ConnOpened() {
	ConnectionsAccepted.Inc()
	ConnectionsActive.Inc()
	activeConns.Add(1)
}

func ConnClosed() {
	ConnectionsActive.Dec()
	activeConns.Add(-1)
}

// ConnectionsActiveValue is the open connection count.
func ConnectionsActiveValue() float64 { return float64(activeConns.Load()) }

func init() {
	Registry.MustRegister(&worldCollector{})
}
