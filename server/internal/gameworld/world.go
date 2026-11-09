package gameworld

import (
	"context"
	"log/slog"
	"math/rand"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trigger"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The world's passes (OURS cadence): the base tick, and the nest pass every
// NestPass (cmd/server's nestPassPeriod for the open world).
const (
	TickPeriod = 100 * time.Millisecond
	NestPass   = 250 * time.Millisecond
)

// CloseReason is why a layer closes.
type CloseReason int

const (
	// CloseEnd is WorldDurationTime run out (m:0x658810's end).
	CloseEnd CloseReason = iota + 1
	// CloseEmpty is WorldEmptyRemainTime with nobody inside.
	CloseEmpty
	// CloseManual is a GM's or the server's own close.
	CloseManual
)

func (r CloseReason) String() string {
	switch r {
	case CloseEnd:
		return "end"
	case CloseEmpty:
		return "empty"
	case CloseManual:
		return "manual"
	}
	return "unknown"
}

// Hooks are what the session layer and cmd/server give every world: the
// runtimes a world drives and the messages its lifecycle and triggers send.
// Each is optional and runs on the world's own goroutine.
type Hooks struct {
	// Open builds the world's runtimes and nests (before its first tick).
	Open func(w *World)
	// Tick runs each TickPeriod while someone is inside (the monster AI,
	// the area of interest): an empty instance ticks no monsters.
	Tick func(w *World, now time.Time)
	// Spawned hears the monsters each nest pass hatched.
	Spawned func(w *World, ids []int64)
	// Warn is a GAMEWORLD_DISAPPEARANCE_TIME threshold passed: left is the
	// time to the end (the 0x300C 0x0C1A warning, game_worlds.md 4).
	Warn func(w *World, left time.Duration)
	// Close takes everyone still inside to their return points (READ
	// s:0x5f80b0) before the layer is torn down.
	Close func(w *World, reason CloseReason)
	// Message, LoadMonster, ZoneSwitched and Other carry the triggers'
	// actions to the players (trigger.Host).
	Message      func(w *World, kind uint8, key string, targets []int64)
	LoadMonster  func(w *World, code string, count int, num1 int64, targets []int64)
	ZoneSwitched func(w *World, z *EventZoneObj)
	Other        func(w *World, a trigger.Action, ev trigger.Event, targets []int64)
	// PartyMaster is the layer's party master (TARGET_PLAYER_PARTY_MASTER).
	PartyMaster func(w *World) int64
}

// World is one game-world unit: world 1 layer 1 (the open world) or one
// instance layer. It owns its entity hub, monster hub, ground items, nests,
// trigger engine, event zones and timers, and runs them on its own goroutine;
// it shares no lock and no mutable map with another world (game_worlds.md
// 12.1). Reference data (Ref) is shared read-only.
type World struct {
	Ref      *WorldRef
	ID       registry.InstanceID
	Key      uint32
	Owner    int64
	Party    int64
	Created  time.Time
	Expires  time.Time
	Hub      *world.Hub
	Monsters *combat.Hub
	Ground   *grounditem.Hub
	Triggers *trigger.Engine
	// Ext is the session layer's per-world runtimes (its monster AI, area
	// of interest), set by Hooks.Open.
	Ext any
	// Logger hears the world's lifecycle.
	Logger *slog.Logger

	mgr   *Manager
	clock Clock
	hooks Hooks
	// external is the open world, whose monsters, nests and passes
	// cmd/server's own loops run: its goroutine carries the triggers only.
	external bool

	ctx    context.Context
	cancel context.CancelFunc
	inbox  chan func()
	done   chan struct{}

	mu         sync.Mutex
	members    []int64
	emptySince time.Time
	emptyTimer Timer
	timers     []Timer
	// actTimers are the triggers' delayed actions (kept apart from the
	// lifecycle's timers, which Age re-arms).
	actTimers []Timer
	closed    bool
	warned    map[time.Duration]bool

	// Owned by the world's goroutine.
	nests     *nest.Scheduler
	nestByID  map[int64]*nest.Slot
	hiveCaps  map[int64]int
	hatched   map[int64]trigger.Monster
	deaths    []int64
	spawned   []int64
	rng       *rand.Rand
	lastNests time.Time
	zones     map[string]*EventZoneObj
	// hatchLogged: the first hatch pass has been logged.
	hatchLogged bool
}

// Of is the world unit owning hub h, nil for a bare hub.
func Of(h *world.Hub) *World {
	if h == nil {
		return nil
	}
	w, _ := h.Unit().(*World)
	return w
}

// Members is who is inside, in the order they entered.
func (w *World) Members() []int64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]int64(nil), w.members...)
}

// EmptySince is when the last member left (or the opening), zero while
// someone is inside.
func (w *World) EmptySince() time.Time {
	w.mu.Lock()
	defer w.mu.Unlock()
	if len(w.members) > 0 {
		return time.Time{}
	}
	return w.emptySince
}

// Closed reports a torn-down world.
func (w *World) Closed() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.closed
}

// Open reports the open world.
func (w *World) Open() bool { return w.ID.World == OpenWorldID }

// Mgr is the manager that opened the world.
func (w *World) Mgr() *Manager { return w.mgr }

// Clock is the world's clock.
func (w *World) Clock() Clock { return w.clock }

// Post runs f on the world's goroutine (dropped once the world is closed).
func (w *World) Post(f func()) {
	select {
	case <-w.done:
	case w.inbox <- f:
	}
}

// Sync waits until everything posted before it has run.
func (w *World) Sync() {
	ch := make(chan struct{})
	select {
	case <-w.done:
		return
	case w.inbox <- func() { close(ch) }:
	}
	select {
	case <-ch:
	case <-w.done:
	}
}

// Done is closed when the world has been torn down.
func (w *World) Done() <-chan struct{} { return w.done }

func (w *World) start() {
	w.ctx, w.cancel = context.WithCancel(context.Background())
	w.inbox = make(chan func(), 1024)
	w.done = make(chan struct{})
	w.rng = rand.New(rand.NewSource(time.Now().UnixNano() ^ int64(w.Key)))
	w.nestByID = map[int64]*nest.Slot{}
	w.hiveCaps = map[int64]int{}
	w.hatched = map[int64]trigger.Monster{}
	w.zones = map[string]*EventZoneObj{}
	w.warned = map[time.Duration]bool{}
	w.Hub.SetUnit(w)
	if w.Monsters != nil {
		w.Monsters.SetUnit(w)
	}
	w.buildZones()
	var trigs []*trigger.Trigger
	if w.mgr != nil && w.mgr.ref != nil {
		trigs = w.mgr.ref.Triggers.ForWorld(int(w.ID.World))
	}
	w.Triggers = trigger.NewEngine(trigs, (*worldHost)(w))
	if w.Logger != nil {
		w.Triggers.Log = func(t *trigger.Trigger, ev trigger.Event) {
			w.Logger.Info("trigger fired", "world", w.ID.String(), "trigger", t.Code, "event", ev.Kind, "user", ev.User)
		}
	}
	ready := make(chan struct{})
	go w.run(ready)
	<-ready
	w.armTimers()
}

func (w *World) run(ready chan struct{}) {
	defer close(w.done)
	if w.hooks.Open != nil && !w.external {
		w.hooks.Open(w)
	}
	if !w.external {
		w.Triggers.Fire(trigger.Event{Kind: trigger.EventWorldCreate})
	}
	close(ready)
	var tick *time.Ticker
	var tc <-chan time.Time
	if !w.external {
		tick = time.NewTicker(TickPeriod)
		defer tick.Stop()
		tc = tick.C
	}
	for {
		select {
		case <-w.ctx.Done():
			// Drain what was posted before the cancel.
			for {
				select {
				case f := <-w.inbox:
					f()
				default:
					return
				}
			}
		case f := <-w.inbox:
			f()
		case <-tc:
			w.pass(w.clock.Now())
		}
	}
}

// pass is one base tick: the nest pass every NestPass, then the hooks'
// runtimes while someone is inside.
func (w *World) pass(now time.Time) {
	if w.nests != nil && (w.lastNests.IsZero() || now.Sub(w.lastNests) >= NestPass) {
		w.lastNests = now
		w.NestPass(now)
	}
	if w.hooks.Tick != nil && len(w.Members()) > 0 {
		w.hooks.Tick(w, now)
	}
}

// SetNests gives the world its nest scheduler (Hooks.Open, cmd/server's
// builder: the scheduler's Hatcher spawns into w.Monsters).
func (w *World) SetNests(s *nest.Scheduler) {
	w.nests = s
	w.Monsters.LogDeaths(true)
}

// AddNest registers a nest of hive with the scheduler (SetNests first).
// Its cap counts toward the hive's MONSTER_HIVE_KILL sum (READ s:0x55e9b0:
// the sum of the hive's nests' dwMaxTotalCount).
func (w *World) AddNest(sl *nest.Slot, hive int64) {
	w.nests.Add(sl)
	if sl.ID != 0 {
		w.nestByID[sl.ID] = sl
	}
	w.hiveCaps[hive] += sl.Cap
}

// NoteHatched records what a hatched monster is, for the triggers (its
// hive, codename, rarity and level).
func (w *World) NoteHatched(id int64, m trigger.Monster) {
	m.ID = id
	w.hatched[id] = m
}

// Nests is the world's nest scheduler, nil for none.
func (w *World) Nests() *nest.Scheduler { return w.nests }

// NestPass is one hive pass at now: the deaths since the last, then the
// hatches, handed to Hooks.Spawned.
func (w *World) NestPass(now time.Time) {
	if w.nests == nil {
		return
	}
	w.deaths = w.Monsters.DrainDeaths(w.deaths[:0])
	for _, id := range w.deaths {
		w.nests.Died(id, now)
	}
	w.spawned = w.nests.Pass(now, w.spawned[:0])
	if len(w.spawned) > 0 && w.hooks.Spawned != nil {
		w.hooks.Spawned(w, w.spawned)
	}
	if len(w.spawned) > 0 && !w.hatchLogged && w.Logger != nil {
		w.hatchLogged = true
		w.Logger.Info("instance hatched", "world", w.ID.String(), "first_pass", len(w.spawned), "nests", w.nests.Nests())
	}
}

// MonsterKilled is a monster of this world killed, user its killer (0 for
// none): the trigger engine's MONSTER_KILL. Safe from any goroutine.
func (w *World) MonsterKilled(m combat.Monster, user int64, userLevel int) {
	w.Post(func() {
		tm, ok := w.hatched[m.ID]
		if !ok {
			tm = trigger.Monster{ID: m.ID}
		}
		tm.Code, tm.Rarity, tm.Level = m.CodeName, m.Rarity, m.Level
		delete(w.hatched, m.ID)
		w.Triggers.Fire(trigger.Event{Kind: trigger.EventMonsterKill, User: user, UserLevel: userLevel, Monster: &tm})
	})
}

// Fire posts a trigger event to the world's goroutine.
func (w *World) Fire(ev trigger.Event) {
	w.Post(func() { w.Triggers.Fire(ev) })
}

// Enter counts character char in (its level for WORLD_ENTRANCE): the empty
// close stops, the registry hears it, and the world's entrance triggers
// fire.
func (w *World) Enter(char int64, level int) {
	w.mu.Lock()
	in := false
	for _, c := range w.members {
		if c == char {
			in = true
		}
	}
	if !in {
		w.members = append(w.members, char)
	}
	if w.emptyTimer != nil {
		w.emptyTimer.Stop()
		w.emptyTimer = nil
	}
	w.mu.Unlock()
	if w.mgr != nil && w.mgr.reg != nil {
		w.mgr.reg.Join(context.Background(), w.ID, w.Key, char)
	}
	if !in && !w.external {
		w.Fire(trigger.Event{Kind: trigger.EventWorldEntrance, User: char, UserLevel: level})
	}
}

// Leave counts character char out; the last one out starts the empty close
// (WorldEmptyRemainTime from now: "empty since" re-stamped at 0 users,
// m:0x658f10).
func (w *World) Leave(char int64) {
	w.mu.Lock()
	for i, c := range w.members {
		if c == char {
			w.members = append(w.members[:i], w.members[i+1:]...)
			break
		}
	}
	empty := len(w.members) == 0
	if empty {
		w.emptySince = w.clock.Now()
		w.armEmptyLocked()
	}
	w.mu.Unlock()
	if w.mgr != nil && w.mgr.reg != nil {
		w.mgr.reg.Leave(context.Background(), w.ID, w.Key, char)
	}
}

// armEmptyLocked arms the empty close (w.mu held).
func (w *World) armEmptyLocked() {
	if w.external || w.closed || w.Ref == nil || w.Ref.EmptyRemain <= 0 {
		return
	}
	if w.emptyTimer != nil {
		w.emptyTimer.Stop()
	}
	w.emptyTimer = w.clock.AfterFunc(w.Ref.EmptyRemain, func() {
		w.Post(func() {
			w.mu.Lock()
			still := len(w.members) == 0 && !w.closed
			w.mu.Unlock()
			if still {
				w.Close(CloseEmpty)
			}
		})
	})
}

// armTimers arms the end, the warnings and (the layer opens empty, m:0x6582d0)
// the empty close: the world's own timers, not a scan of every instance.
func (w *World) armTimers() {
	if w.external || w.Ref == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	now := w.clock.Now()
	if !w.Expires.IsZero() {
		w.timers = append(w.timers, w.clock.AfterFunc(w.Expires.Sub(now), func() {
			w.Post(func() { w.Close(CloseEnd) })
		}))
		for _, thr := range w.Ref.Config.Warnings {
			thr := thr
			at := w.Expires.Add(-thr)
			if !at.After(now) {
				continue
			}
			w.timers = append(w.timers, w.clock.AfterFunc(at.Sub(now), func() {
				w.Post(func() { w.warn(thr) })
			}))
		}
	}
	if len(w.members) == 0 {
		w.emptySince = now
		w.armEmptyLocked()
	}
}

func (w *World) warn(left time.Duration) {
	w.mu.Lock()
	if w.closed || w.warned[left] {
		w.mu.Unlock()
		return
	}
	w.warned[left] = true
	w.mu.Unlock()
	if w.Logger != nil {
		w.Logger.Info("instance warning", "world", w.ID.String(), "left", left)
	}
	if w.hooks.Warn != nil {
		w.hooks.Warn(w, left)
	}
}

// Close closes the layer: everyone inside to the return point (Hooks.Close),
// then its timers, its goroutine and its registry slot. Run it on the
// world's goroutine (a timer does; CloseAsync posts it).
func (w *World) Close(reason CloseReason) {
	w.mu.Lock()
	if w.closed || w.external {
		w.mu.Unlock()
		return
	}
	w.closed = true
	for _, t := range w.timers {
		t.Stop()
	}
	for _, t := range w.actTimers {
		t.Stop()
	}
	if w.emptyTimer != nil {
		w.emptyTimer.Stop()
	}
	w.mu.Unlock()
	if w.Logger != nil {
		w.Logger.Info("instance closing", "world", w.ID.String(), "key", w.Key, "reason", reason.String(),
			"members", len(w.Members()), "age", w.clock.Now().Sub(w.Created).Round(time.Millisecond))
	}
	if w.hooks.Close != nil {
		w.hooks.Close(w, reason)
	}
	if w.mgr != nil {
		w.mgr.remove(w)
	}
	w.cancel()
}

// Age moves the layer's clock forward by d (OURS, a GM's QA aid -- the
// Forgotten World checklist's /fgwtime): its opening, its end and its empty
// time move d into the past, every warning whose threshold that passes is sent
// (once), and the end or the empty close runs at once when due. Run on the
// world's goroutine (AgeAsync posts it).
func (w *World) Age(d time.Duration) {
	if d <= 0 || w.external {
		return
	}
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	for _, t := range w.timers {
		t.Stop()
	}
	w.timers = nil
	if w.emptyTimer != nil {
		w.emptyTimer.Stop()
		w.emptyTimer = nil
	}
	w.Created = w.Created.Add(-d)
	if !w.Expires.IsZero() {
		w.Expires = w.Expires.Add(-d)
	}
	empty := len(w.members) == 0
	if empty {
		w.emptySince = w.emptySince.Add(-d)
	}
	now := w.clock.Now()
	var due []time.Duration
	if !w.Expires.IsZero() {
		for _, thr := range w.Ref.Config.Warnings {
			if !w.Expires.Add(-thr).After(now) && !w.warned[thr] {
				due = append(due, thr)
			}
		}
	}
	w.mu.Unlock()
	for _, thr := range due {
		w.warn(thr)
	}
	if !w.Expires.IsZero() && !w.Expires.After(now) {
		w.Close(CloseEnd)
		return
	}
	if empty && w.Ref.EmptyRemain > 0 && !w.emptySince.Add(w.Ref.EmptyRemain).After(now) {
		w.Close(CloseEmpty)
		return
	}
	w.rearm(now, empty)
}

// rearm arms the end, the warnings not yet sent and the empty close from now.
func (w *World) rearm(now time.Time, empty bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.Expires.IsZero() {
		w.timers = append(w.timers, w.clock.AfterFunc(w.Expires.Sub(now), func() {
			w.Post(func() { w.Close(CloseEnd) })
		}))
		for _, thr := range w.Ref.Config.Warnings {
			thr := thr
			at := w.Expires.Add(-thr)
			if !at.After(now) || w.warned[thr] {
				continue
			}
			w.timers = append(w.timers, w.clock.AfterFunc(at.Sub(now), func() {
				w.Post(func() { w.warn(thr) })
			}))
		}
	}
	if empty && w.Ref.EmptyRemain > 0 {
		left := w.emptySince.Add(w.Ref.EmptyRemain).Sub(now)
		w.emptyTimer = w.clock.AfterFunc(left, func() {
			w.Post(func() {
				w.mu.Lock()
				still := len(w.members) == 0 && !w.closed
				w.mu.Unlock()
				if still {
					w.Close(CloseEmpty)
				}
			})
		})
	}
}

// AgeAsync posts Age to the world's goroutine.
func (w *World) AgeAsync(d time.Duration) { w.Post(func() { w.Age(d) }) }

// CloseAsync posts Close to the world's goroutine.
func (w *World) CloseAsync(reason CloseReason) { w.Post(func() { w.Close(reason) }) }

// worldHost is the World as its trigger engine's Host.
type worldHost World

func (h *worldHost) w() *World { return (*World)(h) }

func (h *worldHost) ActivateNest(id int64) bool {
	sl := h.nestByID[id]
	if sl == nil || h.nests == nil {
		return false
	}
	h.nests.Activate(sl)
	return true
}

func (h *worldHost) LoadMonster(code string, count int, num1 int64, targets []int64) {
	if h.hooks.LoadMonster != nil {
		h.hooks.LoadMonster(h.w(), code, count, num1, targets)
	}
}

func (h *worldHost) SwitchEventZone(zone string, on bool) {
	h.w().SwitchEventZone(zone, on)
}

func (h *worldHost) Message(kind uint8, key string, targets []int64) {
	if h.hooks.Message != nil {
		h.hooks.Message(h.w(), kind, key, targets)
	}
}

func (h *worldHost) Players() []int64 {
	if h.external {
		var out []int64
		for _, e := range h.Hub.AllEntities() {
			out = append(out, e.CharacterID)
		}
		return out
	}
	return h.w().Members()
}

func (h *worldHost) PartyMaster() int64 {
	if h.hooks.PartyMaster != nil {
		return h.hooks.PartyMaster(h.w())
	}
	return 0
}

func (h *worldHost) HiveCap(hive int64) int { return h.hiveCaps[hive] }

func (h *worldHost) Other(a trigger.Action, ev trigger.Event, targets []int64) {
	if h.hooks.Other != nil {
		h.hooks.Other(h.w(), a, ev, targets)
	}
}

func (h *worldHost) After(d time.Duration, f func()) {
	w := h.w()
	t := w.clock.AfterFunc(d, func() { w.Post(f) })
	w.mu.Lock()
	w.actTimers = append(w.actTimers, t)
	w.mu.Unlock()
}

func (h *worldHost) Chance() float64 { return h.rng.Float64() }
func (h *worldHost) Pick(n int) int  { return h.rng.Intn(n) }
