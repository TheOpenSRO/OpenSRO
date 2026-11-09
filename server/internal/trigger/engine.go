package trigger

import (
	"sync"
	"time"
)

// Monster is what an event tells the engine about a monster.
type Monster struct {
	ID     int64
	Code   string
	Hive   int64 // the hive its nest belongs to (0: not hatched by a nest)
	Rarity int
	Level  int
}

// Event is one happening in a layer. User is the character that caused it
// (the event user, TARGET_PLAYER_EVENT_USER), 0 for none.
type Event struct {
	Kind      string
	User      int64
	UserLevel int
	Monster   *Monster
	// Zone is the event zone of a POSITION_EVENTZONE event, In whether the
	// user came into it (else went out).
	Zone string
	In   bool
	// NPC is the codename of a SELECT_NPC / SELECT_TALK_WINDOW event's NPC.
	NPC string
}

// Host is what a layer gives its engine. Every call comes from the engine
// on the layer's own goroutine (Fire, or a delayed action through After).
type Host interface {
	// ActivateNest wakes the layer's copy of a dormant nest (READ
	// s:0x682fb0 sets its +0x14 = 1); false when the layer has no such nest.
	ActivateNest(nestID int64) bool
	// LoadMonster spawns count monsters of code at each target (INFERRED,
	// game_worlds.md 9; num1 is NUM_INPUT_1, OPEN).
	LoadMonster(code string, count int, num1 int64, targets []int64)
	// SwitchEventZone sets the layer's event zone on or off (READ
	// s:0x683d90: state 2 for ON, 1 for OFF, 0x351E on a change).
	SwitchEventZone(zone string, on bool)
	// Message sends 0x300C {0x0C1C, kind, key} (READ s:0x5f9450: kind 1 the
	// notice window, 2 the system window) to the targets.
	Message(kind uint8, key string, targets []int64)
	// Players is the characters in the layer, in the order they entered.
	Players() []int64
	// PartyMaster is the layer's party master (0 for none).
	PartyMaster() int64
	// HiveCap is the sum of the hive's nests' dwMaxTotalCount in this layer
	// (READ s:0x55e9b0, MONSTER_HIVE_KILL's threshold).
	HiveCap(hive int64) int
	// Other runs an action the engine does not carry itself
	// (CREATEOBJECT_*, SWITCH_TELEPORT, NPC_LOAD, SCRIPT_CINEMA): the
	// Forgotten World's lane and later content add them.
	Other(a Action, ev Event, targets []int64)
	// After runs f after d on the layer's goroutine (the action Delay).
	After(d time.Duration, f func())
	// Chance is a uniform draw in [0, 1) from the layer's random source.
	Chance() float64
	// Pick is a uniform draw in [0, n).
	Pick(n int) int
}

// Engine runs one layer's triggers. Safe for concurrent use (one lock per
// engine; nothing shared between layers).
type Engine struct {
	mu      sync.Mutex
	host    Host
	byEvent map[string][]*Trigger
	// active is each trigger's IsActive, switched by SWITCH_TRIGGER.
	active map[int]bool
	// fired marks a non-repeating trigger that ran (INFERRED: IsRepeat 0
	// fires once per layer).
	fired map[int]bool
	// hiveKills counts the layer's kills of each hive's monsters (READ
	// s:0x690a70).
	hiveKills map[int64]int
	vars      map[string]int64
	// Log, when set, hears every trigger that runs (for the server's log).
	Log func(t *Trigger, ev Event)
}

// NewEngine is the engine of a layer running triggers (a world's,
// Ref.ForWorld).
func NewEngine(triggers []*Trigger, host Host) *Engine {
	e := &Engine{host: host, byEvent: map[string][]*Trigger{}, active: map[int]bool{}, fired: map[int]bool{},
		hiveKills: map[int64]int{}, vars: map[string]int64{}}
	for _, t := range triggers {
		e.byEvent[t.Event] = append(e.byEvent[t.Event], t)
		e.active[t.ID] = t.Active
	}
	return e
}

// Fire runs every trigger of ev's kind whose conditions pass, in the order
// the world's categories bind them.
func (e *Engine) Fire(ev Event) {
	e.mu.Lock()
	if ev.Kind == EventMonsterKill && ev.Monster != nil && ev.Monster.Hive != 0 {
		e.hiveKills[ev.Monster.Hive]++
	}
	var run []*Trigger
	for _, t := range e.byEvent[ev.Kind] {
		if !e.active[t.ID] || (!t.Repeat && e.fired[t.ID]) {
			continue
		}
		if !e.passLocked(t, ev) {
			continue
		}
		if !t.Repeat {
			e.fired[t.ID] = true
		}
		run = append(run, t)
	}
	e.mu.Unlock()
	for _, t := range run {
		if e.Log != nil {
			e.Log(t, ev)
		}
		e.runActions(t, ev)
	}
}

// passLocked is the condition chain (INFERRED, game_worlds.md 9; the rule in
// the binary is OPEN): the conditions in Sequence order, each one's OnTrue or
// OnFalse word deciding -- NEXT goes on to the next, RETURN_TRUE passes,
// RETURN_FALSE fails; a chain that runs out passes, as does no condition.
func (e *Engine) passLocked(t *Trigger, ev Event) bool {
	for _, c := range t.Conditions {
		word := c.OnFalse
		if e.condLocked(c, ev) {
			word = c.OnTrue
		}
		switch word {
		case ChainReturnTrue:
			return true
		case ChainReturnFalse:
			return false
		}
	}
	return true
}

// compare is SIGN_SELECT (INFERRED from the pillar triggers' bands, where a
// LEFT and a RIGHT condition bound a value from below and above):
// SIGN_LEFT_BIG_EQUAL holds for value >= n, SIGN_RIGHT_BIG_EQUAL for n >=
// value, anything else for value == n.
func compare(sign string, value, n int64) bool {
	switch sign {
	case "SIGN_LEFT_BIG_EQUAL":
		return value >= n
	case "SIGN_RIGHT_BIG_EQUAL":
		return n >= value
	case "SIGN_LEFT_BIG":
		return value > n
	case "SIGN_RIGHT_BIG":
		return n > value
	}
	return value == n
}

func (e *Engine) condLocked(c Condition, ev Event) bool {
	m := ev.Monster
	switch c.Kind {
	case CondHiveKill:
		hive := c.Params.Int("HIVE_MONSTER_SELECT")
		if m == nil || m.Hive != hive {
			return false
		}
		cap := e.host.HiveCap(hive)
		return cap > 0 && e.hiveKills[hive] >= cap
	case CondMonsterKill:
		return m != nil && m.Code == c.Params.Get("MONSTER_SELECT")
	case CondRarityKill:
		return m != nil && int64(m.Rarity) == c.Params.Int("NUM_INPUT")
	case CondMonsterLevel, CondMonsterLevelKill:
		return m != nil && compare(c.Params.Get("SIGN_SELECT"), int64(m.Level), c.Params.Int("NUM_INPUT"))
	case CondUserLevel:
		return ev.User != 0 && compare(c.Params.Get("SIGN_SELECT"), int64(ev.UserLevel), c.Params.Int("NUM_INPUT"))
	case CondZoneIn:
		return ev.Zone != "" && ev.In && ev.Zone == c.Params.Get("EVENT_ZONE_SELECT")
	case CondZoneOut:
		return ev.Zone != "" && !ev.In && ev.Zone == c.Params.Get("EVENT_ZONE_SELECT")
	case CondNPCCode:
		return ev.NPC != "" && ev.NPC == c.Params.Get("NPC_SELECT")
	case CondVariableSingle:
		return compare(c.Params.Get("SIGN_SELECT"), e.vars[c.Params.Get("VARIABLE_SELECT")], c.Params.Int("NUM_INPUT"))
	}
	// USER_ITEM, USER_QUEST: no row of the MEASURED data uses them, and
	// their params are OPEN. A condition the engine cannot judge fails.
	return false
}

// targets is TARGET_PLAYER_INS_SELECT's players (READ s:0x5f9750).
func (e *Engine) targets(p Params, ev Event) []int64 {
	switch p.Get("TARGET_PLAYER_INS_SELECT") {
	case TargetEventUser:
		if ev.User != 0 {
			return []int64{ev.User}
		}
		return nil
	case TargetPartyMaster:
		if m := e.host.PartyMaster(); m != 0 {
			return []int64{m}
		}
		return nil
	case TargetRandom:
		ps := e.host.Players()
		if len(ps) == 0 {
			return nil
		}
		return []int64{ps[e.host.Pick(len(ps))]}
	}
	return e.host.Players()
}

// runActions runs t's actions in order, each after its own Delay from the
// trigger's firing (INFERRED: game_worlds.md 9 reads Delay as "the action
// runs that long after the trigger fires"; READ semantics OPEN). The
// targets are chosen when the action runs.
func (e *Engine) runActions(t *Trigger, ev Event) {
	for _, a := range t.Actions {
		a := a
		if a.Delay > 0 {
			e.host.After(a.Delay, func() { e.act(a, ev) })
			continue
		}
		e.act(a, ev)
	}
}

func (e *Engine) act(a Action, ev Event) {
	switch a.Kind {
	case ActActiveNest:
		e.host.ActivateNest(a.Params.Int("NEST_MONSTER_SELECT"))
	case ActLoadMonster:
		// FLOAT_INPUT is the chance (INFERRED: 0.001 on the pillar triggers,
		// 1 on the Wreck curse), NUM_INPUT_2 the count.
		if chance := a.Params.Float("FLOAT_INPUT"); chance < 1 && e.host.Chance() >= chance {
			return
		}
		n := int(a.Params.Int("NUM_INPUT_2"))
		if n < 1 {
			n = 1
		}
		e.host.LoadMonster(a.Params.Get("MONSTER_SELECT"), n, a.Params.Int("NUM_INPUT_1"), e.targets(a.Params, ev))
	case ActSwitchEventZone:
		e.host.SwitchEventZone(a.Params.Get("EVENT_ZONE_SELECT"), a.Params.Get("ON_OFF_SWITCH") == "ON")
	case ActNotifyWindow:
		e.host.Message(1, a.Params.Get("STRING_INPUT"), e.targets(a.Params, ev))
	case ActSystemWindow:
		e.host.Message(2, a.Params.Get("STRING_INPUT"), e.targets(a.Params, ev))
	case ActSwitchTrigger:
		// No MEASURED row uses it; its params are OPEN.
		e.host.Other(a, ev, nil)
	case ActVariableValue, ActVariableAdd, ActVariableSub:
		key := a.Params.Get("VARIABLE_SELECT")
		n := a.Params.Int("NUM_INPUT")
		e.mu.Lock()
		switch a.Kind {
		case ActVariableValue:
			e.vars[key] = n
		case ActVariableAdd:
			e.vars[key] += n
		default:
			e.vars[key] -= n
		}
		e.mu.Unlock()
	default:
		e.host.Other(a, ev, e.targets(a.Params, ev))
	}
}
