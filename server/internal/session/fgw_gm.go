package session

// The Forgotten World's GM aids (round 869 lane W3, OURS: QA tools, not in
// the original's console -- forgotten_world.md 11 SERVER item 8):
//
//	/fgw <world id | codename>   open a layer of the world for the GM and stand
//	                             its gate at the GM (a hole's use without the
//	                             item and its checks; the entry is the gate's
//	                             own, with every check)
//	/fgwtime <duration>          move the clock of the GM's layer (inside) or of
//	                             the GM's newest gate's layer (World.Age: its
//	                             warnings, end and empty close as if it passed)
//	/fgwtime limit <duration>    move the GM's own re-entry limit and hole cool
//	                             time that far toward their end
//	/fgwkill [n]                 kill (up to n of) the monsters of the GM's
//	                             layer now alive, each as a kill by the GM:
//	                             the triggers hear them (MONSTER_KILL, the hive
//	                             counts), no exp, gold or drops
//	/fgwpillar [band]            load the band's dimension pillar at the GM in
//	                             the open world (the world-1 trigger's action at
//	                             chance 1; band defaults to the GM's level's)

import (
	"context"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// fgwCommand runs the Forgotten World's GM aids; ok is false for any other
// line.
func fgwCommand(ctx context.Context, sess *gateway.Session, line string) (gm.Result, bool) {
	f := strings.Fields(strings.TrimPrefix(strings.TrimSpace(line), "/"))
	if len(f) == 0 {
		return gm.Result{}, false
	}
	verb := strings.ToLower(f[0])
	if verb != "fgw" && verb != "fgwtime" && verb != "fgwkill" && verb != "fgwpillar" {
		return gm.Result{}, false
	}
	m := GameWorlds()
	if m == nil {
		return gm.Result{Refused: true, Text: "no game-world data (-gameworld-dir)"}, true
	}
	hub := sessionHub(sess)
	if hub == nil {
		return gm.Result{Refused: true, Text: "not in the world"}, true
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return gm.Result{Refused: true, Text: "not in the world"}, true
	}
	switch verb {
	case "fgw":
		return fgwOpenGate(ctx, m, hub, e, f[1:]), true
	case "fgwtime":
		return fgwTime(ctx, m, hub, e, f[1:]), true
	case "fgwkill":
		return fgwKill(hub, e, f[1:]), true
	default:
		return fgwPillar(m, hub, e, f[1:]), true
	}
}

func fgwOpenGate(ctx context.Context, m *gameworld.Manager, hub *world.Hub, e world.Entity, args []string) gm.Result {
	if len(args) != 1 {
		return gm.Result{Refused: true, Text: "usage: /fgw <world id | INS_GOD_ codename>"}
	}
	ref := m.Ref().WorldByCode(args[0])
	if ref == nil {
		if id, err := strconv.Atoi(args[0]); err == nil {
			ref = m.Ref().World(uint16(id))
		}
	}
	if ref == nil || !ref.IsGodWorld() {
		return gm.Result{Refused: true, Text: "not a Forgotten World: " + args[0]}
	}
	if instanceOf(hub) != nil {
		return gm.Result{Refused: true, Text: "stand in the open world"}
	}
	gw, _ := gameworld.ParseGodWorld(ref.Code)
	hole := gameworld.Hole{World: ref.Code, Grade: gw.Grade, LevelMin: ref.Config.LevelMin, LevelMax: ref.Config.LevelMax,
		MaxPlayers: ref.MaxUsers, Access: gameworld.AccessOwner}
	// The hole this world's items name (its RefObjID goes in the gate's
	// record): the first item row whose Desc2 is the world, when the item
	// table is loaded.
	hole.RefID = fgwHoleRefOf(ctx, ref.Code)
	var party uint32
	if ps := gameWorldDeps().Parties; ps != nil {
		if p, in := ps.Get(e.CharacterID); in {
			party = p.ID
		}
	}
	w, err := m.Open(ctx, ref.ID, e.CharacterID, int64(party))
	if err != nil {
		return gm.Result{Refused: true, Text: "open: " + err.Error()}
	}
	g := makeGate(hub, e, w, hole, party)
	return gm.Result{Text: fmt.Sprintf("opened %s %s, gate %#x (hole %d) at %.0f, %.0f", w.ID, ref.Code, g.UID, hole.RefID, e.Pos.X, e.Pos.Z)}
}

// fgwHoleRefs is the hole item of each world codename (cmd/server fills it
// from the item table; empty, a GM gate names hole 0).
var fgwHoleRefs = map[string]uint32{}

// SetFGWHoleRefs records which hole item names each world (cmd/server).
func SetFGWHoleRefs(m map[string]uint32) { fgwHoleRefs = m }

func fgwHoleRefOf(_ context.Context, world string) uint32 { return fgwHoleRefs[strings.ToUpper(world)] }

func fgwTime(ctx context.Context, m *gameworld.Manager, hub *world.Hub, e world.Entity, args []string) gm.Result {
	usage := gm.Result{Refused: true, Text: "usage: /fgwtime <duration> | /fgwtime limit <duration>"}
	if len(args) == 2 && strings.EqualFold(args[0], "limit") {
		d, err := time.ParseDuration(args[1])
		if err != nil || d <= 0 {
			return usage
		}
		return fgwMoveLimits(ctx, e.CharacterID, d)
	}
	if len(args) != 1 {
		return usage
	}
	d, err := time.ParseDuration(args[0])
	if err != nil || d <= 0 {
		return usage
	}
	w := instanceOf(hub)
	if w == nil {
		var newest *fgwGate
		gates.mu.Lock()
		for _, g := range gates.byUID {
			if g.Owner == e.CharacterID && (newest == nil || g.UID > newest.UID) {
				newest = g
			}
		}
		gates.mu.Unlock()
		if newest != nil {
			w = newest.World
		}
	}
	if w == nil {
		return gm.Result{Refused: true, Text: "not in a layer and no gate of yours stands"}
	}
	w.AgeAsync(d)
	return gm.Result{Text: fmt.Sprintf("%s aged %s", w.ID, d)}
}

// fgwMoveLimits moves characterID's running re-entry limits and kept item
// cool times d toward their end (an end passed ends them).
func fgwMoveLimits(ctx context.Context, characterID int64, d time.Duration) gm.Result {
	st := gameWorldDeps().Timed
	if st == nil {
		return gm.Result{Refused: true, Text: "no timed-job store"}
	}
	jobs, err := st.List(ctx, characterID)
	if err != nil {
		return gm.Result{Refused: true, Text: err.Error()}
	}
	now := time.Now()
	moved := 0
	for _, j := range jobs {
		if j.Type != TimedJobWorldGroup && j.Type != TimedJobItemCoolTime {
			continue
		}
		j.Start, j.End = j.Start.Add(-d), j.End.Add(-d)
		if err := st.Put(ctx, j); err != nil {
			continue
		}
		if j.Type == TimedJobItemCoolTime {
			left := j.End.Sub(now)
			if left < 0 {
				left = 0
			}
			itemCooldowns.ArmItem(characterID, j.Ref, uint32(j.Key), left, now)
		}
		moved++
	}
	return gm.Result{Text: fmt.Sprintf("moved %d limit(s) by %s", moved, d)}
}

func fgwKill(hub *world.Hub, e world.Entity, args []string) gm.Result {
	w := instanceOf(hub)
	if w == nil {
		return gm.Result{Refused: true, Text: "not in a layer"}
	}
	limit := -1
	if len(args) == 1 {
		n, err := strconv.Atoi(args[0])
		if err != nil || n < 1 {
			return gm.Result{Refused: true, Text: "usage: /fgwkill [n]"}
		}
		limit = n
	}
	parties := gameWorldDeps().Parties
	killed := 0
	for _, m := range w.Monsters.AppendAll(nil) {
		if limit >= 0 && killed >= limit {
			break
		}
		if m.HP <= 0 {
			continue
		}
		dead, died, ok, watchers, hits := damageMonsterWatched(hub, w.Monsters, m.ID, e.CharacterID, m.HP)
		if !ok || !died {
			continue
		}
		killed++
		msg := (&MonsterDied{MonsterID: dead.ID}).Encode()
		for _, o := range watchers {
			sendMonsterPush(o.Session, &proto.Packet{Opcode: OpMonsterDied, Data: msg})
		}
		noteMonsterKilled(hub, parties, hits, dead)
	}
	return gm.Result{Text: fmt.Sprintf("killed %d in %s", killed, w.ID), RefreshMonsters: true}
}

func fgwPillar(m *gameworld.Manager, hub *world.Hub, e world.Entity, args []string) gm.Result {
	if instanceOf(hub) != nil {
		return gm.Result{Refused: true, Text: "stand in the open world"}
	}
	w := unitOf(hub)
	d := gameWorldDeps()
	if w == nil || d.Spawn == nil {
		return gm.Result{Refused: true, Text: "no open-world unit or no species table"}
	}
	code := ""
	if len(args) == 1 {
		code = strings.ToUpper(args[0])
		if !strings.HasPrefix(code, gameworld.PillarPrefix) {
			code = gameworld.PillarPrefix + code
		}
	} else {
		// The pillar the GM's level would earn: the world-1 trigger whose
		// killer band holds it (the first, by the data's order).
		for _, t := range m.Ref().Triggers.ForWorld(int(gameworld.OpenWorldID)) {
			for _, a := range t.Actions {
				if p := a.Params.Get("MONSTER_SELECT"); gameworld.IsPillar(p) && pillarBandHolds(t, e.Level) {
					code = p
				}
			}
			if code != "" {
				break
			}
		}
	}
	if code == "" {
		return gm.Result{Refused: true, Text: "no pillar for level " + strconv.Itoa(e.Level)}
	}
	id, ok := d.Spawn(w, code, e.Zone, e.Pos.X+10, e.Pos.Y, e.Pos.Z)
	if !ok {
		return gm.Result{Refused: true, Text: "cannot spawn " + code}
	}
	BroadcastMonsterSpawned(hub, w.Monsters, id)
	return gm.Result{Text: fmt.Sprintf("loaded %s #%d", code, id), RefreshMonsters: true}
}

// pillarBandHolds reports whether a pillar trigger's USER_LEVEL conditions
// admit level.
func pillarBandHolds(t interface{ UserLevelBand() (int, int) }, level int) bool {
	lo, hi := t.UserLevelBand()
	return level >= lo && (hi == 0 || level <= hi)
}
