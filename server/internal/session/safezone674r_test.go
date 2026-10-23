package session

import (
	"context"
	"log/slog"
	"math/rand"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 674's review: what the players are sent for a town removal on the
// production path (a.push nil, the area of interest installed), and the log
// levels of the two kinds of removal.

// The jangan frame's cell rows (combat.CellOf): row k spans world z
// [320k - 960, 320k - 640), so the town's line at z 960 is the top of row 5
// and the bottom of row 6.

// A view moved off the removed monster's cell between the removal and the
// pass's pushes -- the area of interest's reconcile runs on its own ticker --
// still gets the leave. The reconcile cannot name the monster (it is out of
// the hub), and the cell's watchers at the send no longer include the view,
// so without the watchers taken at the removal the player keeps a ghost body.
func TestTownRemovalReachesAViewThatMovedOffBeforeThePush(t *testing.T) {
	installTowns674(t, towns674, fields674)
	monsters := combat.NewHub()
	m := spawnAt(t, monsters, "jangan", 0, 1000) // row 6, the field
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	c := r.join(t, 1, 0, 1100) // row 6: the window holds rows 5-7
	v.reconcile()
	a := installMonsterAIForTest(t, r.hub, monsters, 1, nil) // nil: the production push
	a.tick(aiT0)                                             // the brain; no step on the first pass
	if !monsters.Exists(m) {
		t.Fatal("setup: the monster in the field was removed")
	}
	c.quiet(t, 100*time.Millisecond)

	r.mu.Lock()
	sess := r.sessions[1]
	r.mu.Unlock()
	tickPushHook = func() {
		// The player walks off: her view moves to row 10, out of the window
		// of row 5, before the pass's pushes go out.
		r.hub.Relocate(sess, world.Position{X: 0, Z: 2400}, world.MoveRelocate, 0)
		v.reconcile()
	}
	t.Cleanup(func() { tickPushHook = nil })
	monsters.SetMotion(m, 0, 900, 1000, 1)
	a.tick(aiT0.Add(MonsterAITick)) // one 100-unit step: z 900, row 5, the town
	tickPushHook = nil
	if monsters.Exists(m) {
		t.Fatal("setup: the monster that stepped into the town was not removed")
	}
	left, entered, _ := aoiFrames(t, c.quiet(t, 200*time.Millisecond))
	if !sameIDs(left, []int64{m}) {
		t.Fatalf("OpMonsterLeft named %v, want [%d]: the player who could see the monster when it was removed keeps its body", left, m)
	}
	if len(entered) != 0 {
		t.Errorf("entered %v after the move, want none", entered)
	}
}

// A monster whose step carries it into a player's window and into a town in
// the same pass: the step owes the player an enter (v.step's crossing), the
// removal runs before the enter is delivered, and the enter is dropped for a
// monster no longer in the hub -- no OpMonsterSpawned, no leg. The leave the
// removal sends is harmless (the client drops an id it does not draw).
func TestTownRemovalInTheSamePassAsItsEnterSendsNoBody(t *testing.T) {
	installTowns674(t, towns674, fields674)
	monsters := combat.NewHub()
	m := spawnAt(t, monsters, "jangan", 0, 1000) // row 6
	r := newListRig(t, monsters)
	v := installAOIForTest(t, r.hub, monsters)
	c := r.join(t, 1, 0, 480) // row 4: the window holds rows 3-5, not 6
	v.reconcile()
	a := installMonsterAIForTest(t, r.hub, monsters, 1, nil)
	a.tick(aiT0)
	c.quiet(t, 100*time.Millisecond)
	monsters.SetMotion(m, 0, 900, 1000, 1)
	a.tick(aiT0.Add(MonsterAITick)) // row 6 -> row 5: an enter for the player, and the town
	if monsters.Exists(m) {
		t.Fatal("setup: the monster that stepped into the town was not removed")
	}
	left, entered, legs := aoiFrames(t, c.quiet(t, 200*time.Millisecond))
	for _, id := range entered {
		if id == m {
			t.Fatalf("OpMonsterSpawned for the monster removed in the pass its enter was owed: the client draws a body nothing will remove")
		}
	}
	for _, l := range legs {
		if l.MonsterID == m {
			t.Fatalf("a leg %+v for the removed monster", l)
		}
	}
	if len(left) > 1 || (len(left) == 1 && left[0] != m) {
		t.Errorf("OpMonsterLeft named %v, want at most the removed monster", left)
	}
}

// logRecord is one record a captureHandler kept.
type logRecord struct {
	level slog.Level
	msg   string
	attrs map[string]string
}

// captureHandler keeps every record, every level.
type captureHandler struct {
	mu      sync.Mutex
	records []logRecord
}

func (h *captureHandler) Enabled(context.Context, slog.Level) bool { return true }
func (h *captureHandler) Handle(_ context.Context, r slog.Record) error {
	rec := logRecord{level: r.Level, msg: r.Message, attrs: map[string]string{}}
	r.Attrs(func(a slog.Attr) bool {
		rec.attrs[a.Key] = a.Value.String()
		return true
	})
	h.mu.Lock()
	h.records = append(h.records, rec)
	h.mu.Unlock()
	return nil
}
func (h *captureHandler) WithAttrs([]slog.Attr) slog.Handler { return h }
func (h *captureHandler) WithGroup(string) slog.Handler      { return h }

func (h *captureHandler) take() []logRecord {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := h.records
	h.records = nil
	return out
}

// OURS, the logging (round 674's review): a monster removed where it was
// placed -- a nest standing in a town hatches and loses one every second or
// two while a player is near -- is logged at Debug, and counted in one INFO
// line a minute; a monster that walked in keeps its INFO line.
func TestTownRemovalLogLevels(t *testing.T) {
	installTowns674(t, towns674, fields674)
	h := &captureHandler{}
	hub := world.NewHub()
	monsters := newAIHub(5)
	a := newMonsterAI(hub, monsters, slog.New(h), MonsterAIConfig{}, rand.New(rand.NewSource(5)), func(string, *proto.Packet) {})
	monsterAIRuntime.Store(a)
	t.Cleanup(func() { monsterAIRuntime.Store(nil) })

	removals := func(recs []logRecord) (info, debug []logRecord) {
		for _, r := range recs {
			if !strings.HasPrefix(r.msg, "monster removed: it entered a town") {
				continue
			}
			if r.level == slog.LevelInfo {
				info = append(info, r)
			} else if r.level == slog.LevelDebug {
				debug = append(debug, r)
			}
		}
		return info, debug
	}

	// Placed: two monsters spawned in the town.
	monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 0, 30, 1, 1, 1)
	monsters.SpawnSpecies("jangan", testMangyang, 100, 0, 0, 30, 1, 1, 1)
	now := aiT0
	monsterAITick(now)
	info, debug := removals(h.take())
	if len(info) != 0 || len(debug) != 2 {
		t.Fatalf("two monsters placed in the town: %d INFO and %d Debug removal lines, want 0 and 2", len(info), len(debug))
	}
	if debug[0].attrs["how"] != "placed there" {
		t.Errorf("the Debug line's how is %q, want \"placed there\"", debug[0].attrs["how"])
	}

	// The minute's count: one INFO line once a minute has passed since the
	// first, naming both, and none before.
	var summaries []logRecord
	for i := 0; i < int(townPlacedPeriod/MonsterAITick); i++ {
		now = now.Add(MonsterAITick)
		monsterAITick(now)
		for _, r := range h.take() {
			if strings.HasPrefix(r.msg, "monsters removed on placement in a town") {
				if now.Sub(aiT0) < townPlacedPeriod {
					t.Fatalf("the count was logged %v after the first removal, before the period", now.Sub(aiT0))
				}
				summaries = append(summaries, r)
			}
		}
	}
	if len(summaries) != 1 || summaries[0].level != slog.LevelInfo || summaries[0].attrs["count"] != "2" {
		t.Fatalf("the minute's count lines %+v, want one INFO line with count 2", summaries)
	}

	// Walked in: a monster stepping over the line from the field.
	m := monsters.SpawnSpecies("jangan", testMangyang, 0, 0, 1000, 30, 1, 1, 1)
	now = now.Add(MonsterAITick)
	monsterAITick(now) // its brain, in the field
	monsters.SetMotion(m.ID, 0, 900, 1000, 1)
	now = now.Add(MonsterAITick)
	monsterAITick(now)
	info, debug = removals(h.take())
	if len(info) != 1 || len(debug) != 0 || info[0].attrs["how"] != "walked in" {
		t.Fatalf("a monster that walked into the town: INFO %+v, Debug %+v; want one INFO line, how \"walked in\"", info, debug)
	}
}
