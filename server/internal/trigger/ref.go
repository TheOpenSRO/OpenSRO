// Package trigger is the game worlds' trigger engine (round 869,
// docs/protocol/game_worlds.md section 9): the reference tables
// (_RefTriggerCommon, _RefTrigger, its events, conditions and actions with
// their parameter groups, the categories and their binding to worlds) and a
// per-layer Engine that runs them. Labels as in the spec: READ (s: the
// game server), MEASURED (the tables), INFERRED, OURS, OPEN.
package trigger

import (
	"fmt"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
)

// The vocabulary (MEASURED, _RefTriggerCommon's CodeName128; TID1 1 event,
// 2 condition, 3 action).
const (
	EventWorldCreate     = "TRIGGER_EVENT_WORLD_CREATE"
	EventWorldEntrance   = "TRIGGER_EVENT_WORLD_ENTRANCE"
	EventSelectTalk      = "TRIGGER_EVENT_SELECT_TALK_WINDOW"
	EventPositionZone    = "TRIGGER_EVENT_POSITION_EVENTZONE"
	EventMonsterKill     = "TRIGGER_EVENT_MONSTER_KILL"
	EventSelectNPC       = "TRIGGER_EVENT_SELECT_NPC"
	CondZoneIn           = "TRIGGER_CONDITION_POSITION_EVENTZONE_IN"
	CondZoneOut          = "TRIGGER_CONDITION_POSITION_EVENTZONE_OUT"
	CondMonsterKill      = "TRIGGER_CONDITION_MONSTER_KILL"
	CondHiveKill         = "TRIGGER_CONDITION_MONSTER_HIVE_KILL"
	CondRarityKill       = "TRIGGER_CONDITION_MONSTER_RARITY_KILL"
	CondVariableSingle   = "TRIGGER_CONDITION_VARIABLE_SINGLE"
	CondUserLevel        = "TRIGGER_CONDITION_USER_LEVEL"
	CondMonsterLevel     = "TRIGGER_CONDITION_MONSTER_LEVEL"
	CondMonsterLevelKill = "TRIGGER_CONDITION_MONSTER_LEVEL_KILL"
	CondUserItem         = "TRIGGER_CONDITION_USER_ITEM"
	CondUserQuest        = "TRIGGER_CONDITION_USER_QUEST"
	CondNPCCode          = "TRIGGER_CONDITION_NPC_CODENAME"
	ActLoadMonster       = "TRIGGER_ACTION_MONSTER_LOAD_MONSTER"
	ActActiveNest        = "TRIGGER_ACTION_MONSTER_ACTIVE_NEST"
	ActCreateStruct      = "TRIGGER_ACTION_CREATEOBJECT_STRUCT"
	ActCreateTeleport    = "TRIGGER_ACTION_CREATEOBJECT_TELEPORT"
	ActSwitchEventZone   = "TRIGGER_ACTION_SWITCH_EVENTZONE"
	ActSwitchTrigger     = "TRIGGER_ACTION_SWITCH_TRIGGER"
	ActSwitchTeleport    = "TRIGGER_ACTION_SWITCH_TELEPORT"
	ActNotifyWindow      = "TRIGGER_ACTION_MESSAGE_NOTIFY_WINDOW"
	ActSystemWindow      = "TRIGGER_ACTION_MESSAGE_SYSTEM_WINDOW"
	ActVariableValue     = "TRIGGER_ACTION_VARIABLE_VALUE"
	ActVariableAdd       = "TRIGGER_ACTION_VARIABLE_ADDITION"
	ActVariableSub       = "TRIGGER_ACTION_VARIABLE_SUBTRACTION"
	ActNPCLoad           = "TRIGGER_ACTION_NPC_LOAD"
	ActScriptCinema      = "TRIGGER_ACTION_SCRIPT_CINEMA"
)

// The chain words of a condition's OnTrue / OnFalse (MEASURED values).
const (
	ChainNext        = "NEXT"
	ChainReturnTrue  = "RETURN_TRUE"
	ChainReturnFalse = "RETURN_FALSE"
)

// The target words of TARGET_PLAYER_INS_SELECT, numbered as READ s:0x5f9750.
const (
	TargetAll         = "TARGET_PLAYER_ALL"          // 1
	TargetPartyMaster = "TARGET_PLAYER_PARTY_MASTER" // 2
	TargetRandom      = "TARGET_PLAYER_RANDOM"       // 3
	TargetEventUser   = "TARGET_PLAYER_EVENT_USER"   // 4
)

// Params is one parameter group: ValueCodeName128 -> Value (a name may
// repeat; the first is Get's, every one is All's).
type Params map[string][]string

// Get is the first value of key ("" when absent).
func (p Params) Get(key string) string {
	if v := p[key]; len(v) > 0 {
		return v[0]
	}
	return ""
}

// Int is Get as an integer (0 when absent or not a number).
func (p Params) Int(key string) int64 {
	v, _ := strconv.ParseInt(strings.TrimSpace(p.Get(key)), 10, 64)
	return v
}

// Float is Get as a float.
func (p Params) Float(key string) float64 {
	v, _ := strconv.ParseFloat(strings.TrimSpace(p.Get(key)), 64)
	return v
}

// Condition is one _RefTriggerCondition row bound to a trigger.
type Condition struct {
	ID       int
	Kind     string // the common's codename
	OnTrue   string
	OnFalse  string
	Sequence int
	Params   Params
}

// Action is one _RefTriggerAction row bound to a trigger, in binding order.
type Action struct {
	ID     int
	Kind   string
	Delay  time.Duration
	Params Params
}

// Trigger is one _RefTrigger row with its event, conditions (in Sequence
// order) and actions (in binding-id order).
type Trigger struct {
	ID         int
	Code       string
	Active     bool
	Repeat     bool
	Index      int
	Event      string
	Conditions []Condition
	Actions    []Action
}

// Category is a _RefTriggerCategory row and its triggers.
type Category struct {
	ID       int
	Code     string
	Triggers []*Trigger
}

// Ref is every trigger table, joined.
type Ref struct {
	Triggers   map[int]*Trigger
	Categories map[int]*Category
	// ByWorld is the categories bound to each game world
	// (_RefGameWorldBindTriggerCategory), in binding order.
	ByWorld map[int][]*Category
}

// ForWorld is every trigger of world id's categories, in category then
// binding order, each once.
func (r *Ref) ForWorld(world int) []*Trigger {
	if r == nil {
		return nil
	}
	var out []*Trigger
	seen := map[int]bool{}
	for _, c := range r.ByWorld[world] {
		for _, t := range c.Triggers {
			if !seen[t.ID] {
				seen[t.ID] = true
				out = append(out, t)
			}
		}
	}
	return out
}

// Tables is what BuildRef reads: a table by its database name, nil when the
// operator's export does not have it.
type Tables func(name string) *reftable.Table

// TableNames is every table BuildRef reads.
var TableNames = []string{
	"_RefTriggerCommon", "_RefTrigger", "_RefTriggerEvent", "_RefTriggerBindEvent",
	"_RefTriggerCondition", "_RefTriggerBindCondition", "_RefTriggerConditionParam",
	"_RefTriggerAction", "_RefTriggerBindAction", "_RefTriggerActionParam",
	"_RefTriggerCategory", "_RefTriggerCategoryBindTrigger", "_RefGameWorldBindTriggerCategory",
}

// in service: a table without a Service column counts every row.
func inService(t *reftable.Table, row []string) bool {
	return !t.Has("Service") || t.Int(row, "Service") != 0
}

// BuildRef joins the trigger tables. A missing table leaves its part empty;
// a binding to a row that does not exist is an error.
func BuildRef(tables Tables) (*Ref, error) {
	ref := &Ref{Triggers: map[int]*Trigger{}, Categories: map[int]*Category{}, ByWorld: map[int][]*Category{}}
	each := func(name string, f func(t *reftable.Table, row []string) error) error {
		t := tables(name)
		if t == nil {
			return nil
		}
		for _, row := range t.Rows {
			if !inService(t, row) {
				continue
			}
			if err := f(t, row); err != nil {
				return fmt.Errorf("%s: %w", name, err)
			}
		}
		return nil
	}
	common := map[int]string{}
	if err := each("_RefTriggerCommon", func(t *reftable.Table, r []string) error {
		common[int(t.Int(r, "ID"))] = t.Get(r, "CodeName128")
		return nil
	}); err != nil {
		return nil, err
	}
	params := func(name string) (map[string]Params, error) {
		out := map[string]Params{}
		err := each(name, func(t *reftable.Table, r []string) error {
			g := t.Get(r, "GroupCodeName128")
			if out[g] == nil {
				out[g] = Params{}
			}
			k := t.Get(r, "ValueCodeName128")
			out[g][k] = append(out[g][k], t.Get(r, "Value"))
			return nil
		})
		return out, err
	}
	condParams, err := params("_RefTriggerConditionParam")
	if err != nil {
		return nil, err
	}
	actParams, err := params("_RefTriggerActionParam")
	if err != nil {
		return nil, err
	}
	if err := each("_RefTrigger", func(t *reftable.Table, r []string) error {
		id := int(t.Int(r, "ID"))
		ref.Triggers[id] = &Trigger{ID: id, Code: t.Get(r, "CodeName128"), Active: t.Int(r, "IsActive") != 0,
			Repeat: t.Int(r, "IsRepeat") != 0, Index: int(t.Int(r, "IndexNumber"))}
		return nil
	}); err != nil {
		return nil, err
	}
	events := map[int]string{}
	if err := each("_RefTriggerEvent", func(t *reftable.Table, r []string) error {
		events[int(t.Int(r, "ID"))] = common[int(t.Int(r, "RefTriggerCommonID"))]
		return nil
	}); err != nil {
		return nil, err
	}
	if err := each("_RefTriggerBindEvent", func(t *reftable.Table, r []string) error {
		tr := ref.Triggers[int(t.Int(r, "TriggerID"))]
		ev, ok := events[int(t.Int(r, "TriggerEventID"))]
		if tr == nil || !ok {
			return nil // a binding to a row out of service
		}
		tr.Event = ev
		return nil
	}); err != nil {
		return nil, err
	}
	conds := map[int]Condition{}
	if err := each("_RefTriggerCondition", func(t *reftable.Table, r []string) error {
		id := int(t.Int(r, "ID"))
		conds[id] = Condition{ID: id, Kind: common[int(t.Int(r, "RefTriggerCommonID"))], OnTrue: t.Get(r, "OnTrue"),
			OnFalse: t.Get(r, "OnFalse"), Sequence: int(t.Int(r, "Sequence")), Params: condParams[t.Get(r, "ParamGroupCodeName128")]}
		return nil
	}); err != nil {
		return nil, err
	}
	if err := each("_RefTriggerBindCondition", func(t *reftable.Table, r []string) error {
		tr := ref.Triggers[int(t.Int(r, "TriggerID"))]
		c, ok := conds[int(t.Int(r, "TriggerConditionID"))]
		if tr == nil || !ok {
			return nil
		}
		tr.Conditions = append(tr.Conditions, c)
		return nil
	}); err != nil {
		return nil, err
	}
	acts := map[int]Action{}
	if err := each("_RefTriggerAction", func(t *reftable.Table, r []string) error {
		id := int(t.Int(r, "ID"))
		acts[id] = Action{ID: id, Kind: common[int(t.Int(r, "RefTriggerCommonID"))],
			Delay: time.Duration(t.Int(r, "Delay")) * time.Millisecond, Params: actParams[t.Get(r, "ParamGroupCodeName128")]}
		return nil
	}); err != nil {
		return nil, err
	}
	type bound struct {
		bind int
		a    Action
	}
	actBinds := map[int][]bound{}
	if err := each("_RefTriggerBindAction", func(t *reftable.Table, r []string) error {
		tid := int(t.Int(r, "TriggerID"))
		a, ok := acts[int(t.Int(r, "TriggerActionID"))]
		if ref.Triggers[tid] == nil || !ok {
			return nil
		}
		actBinds[tid] = append(actBinds[tid], bound{int(t.Int(r, "ID")), a})
		return nil
	}); err != nil {
		return nil, err
	}
	for tid, bs := range actBinds {
		// INFERRED: actions run in their binding rows' order (the ids rise
		// with the order the scripts list them in every MEASURED world).
		sort.SliceStable(bs, func(i, j int) bool { return bs[i].bind < bs[j].bind })
		for _, b := range bs {
			ref.Triggers[tid].Actions = append(ref.Triggers[tid].Actions, b.a)
		}
	}
	for _, tr := range ref.Triggers {
		sort.SliceStable(tr.Conditions, func(i, j int) bool { return tr.Conditions[i].Sequence < tr.Conditions[j].Sequence })
	}
	if err := each("_RefTriggerCategory", func(t *reftable.Table, r []string) error {
		id := int(t.Int(r, "ID"))
		ref.Categories[id] = &Category{ID: id, Code: t.Get(r, "CodeName128")}
		return nil
	}); err != nil {
		return nil, err
	}
	type cbind struct{ bind, trig int }
	cb := map[int][]cbind{}
	if err := each("_RefTriggerCategoryBindTrigger", func(t *reftable.Table, r []string) error {
		cid := int(t.Int(r, "TriggerCategoryID"))
		cb[cid] = append(cb[cid], cbind{int(t.Int(r, "ID")), int(t.Int(r, "TriggerID"))})
		return nil
	}); err != nil {
		return nil, err
	}
	for cid, bs := range cb {
		c := ref.Categories[cid]
		if c == nil {
			continue
		}
		sort.SliceStable(bs, func(i, j int) bool { return bs[i].bind < bs[j].bind })
		for _, b := range bs {
			if tr := ref.Triggers[b.trig]; tr != nil {
				c.Triggers = append(c.Triggers, tr)
			}
		}
	}
	type wbind struct{ bind, cat int }
	wb := map[int][]wbind{}
	if err := each("_RefGameWorldBindTriggerCategory", func(t *reftable.Table, r []string) error {
		w := int(t.Int(r, "GameWorldID"))
		wb[w] = append(wb[w], wbind{int(t.Int(r, "ID")), int(t.Int(r, "TriggerCategoryID"))})
		return nil
	}); err != nil {
		return nil, err
	}
	for w, bs := range wb {
		sort.SliceStable(bs, func(i, j int) bool { return bs[i].bind < bs[j].bind })
		for _, b := range bs {
			if c := ref.Categories[b.cat]; c != nil {
				ref.ByWorld[w] = append(ref.ByWorld[w], c)
			}
		}
	}
	return ref, nil
}

// UserLevelBand is the band a trigger's USER_LEVEL conditions admit (round
// 869 lane W3: the pillar triggers' killer band): SIGN_LEFT_BIG_EQUAL n is
// the low end, SIGN_RIGHT_BIG_EQUAL n the high one (compare's INFERRED
// reading); 0 for an end no condition names.
func (t *Trigger) UserLevelBand() (lo, hi int) {
	for _, c := range t.Conditions {
		if c.Kind != CondUserLevel {
			continue
		}
		switch c.Params.Get("SIGN_SELECT") {
		case "SIGN_LEFT_BIG_EQUAL":
			lo = int(c.Params.Int("NUM_INPUT"))
		case "SIGN_RIGHT_BIG_EQUAL":
			hi = int(c.Params.Int("NUM_INPUT"))
		}
	}
	return lo, hi
}
