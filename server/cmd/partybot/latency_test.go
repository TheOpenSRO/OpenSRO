package main

import (
	"math"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

// The latency mode's reading of the wire (round 786): an enter that follows
// the bot's own block crossing is timed from the crossing and placed ahead of
// it on the walk's heading; one with no recent crossing is only filed; a list
// files its monsters; a death and a leave forget them; an attack result goes
// to the waiting attack.
func TestLatencyTapTimesEntersFromTheCrossing(t *testing.T) {
	latOpts.heading = 0 // +x
	st := &latState{monsters: map[int64]*latMonster{}, results: make(chan *session.AttackResult, 4)}
	tap := st.tap("world")
	spawn := func(id int64, x, z float32) *proto.Packet {
		m := &session.MonsterSpawned{Monster: session.MonsterSnapshot{ID: id, Name: "Mangyang", X: x, Z: z, HP: 10, MaxHP: 10}}
		return &proto.Packet{Opcode: session.OpMonsterSpawned, Data: m.Encode()}
	}

	// No crossing yet: filed, not timed.
	tap(spawn(1, 500, 0))
	if len(st.enters) != 0 || st.monsters[1] == nil {
		t.Fatalf("an enter with no crossing: enters %v, filed %v", st.enters, st.monsters[1])
	}

	st.x, st.z = 100, 50
	st.crossedAt = time.Now().Add(-40 * time.Millisecond)
	tap(spawn(2, 520, 30))
	if len(st.enters) != 1 {
		t.Fatalf("want one timed enter, got %v", st.enters)
	}
	e := st.enters[0]
	if math.Abs(e.ahead-420) > 1e-3 || math.Abs(e.side+20) > 1e-3 {
		t.Errorf("ahead %.1f side %.1f, want 420 and -20", e.ahead, e.side)
	}
	if e.after < 40*time.Millisecond || e.after > time.Second {
		t.Errorf("after %s, want about 40 ms", e.after)
	}

	// A list files its monsters; a death and a leave forget them.
	list := &session.MonsterListResult{Monsters: []session.MonsterSnapshot{{ID: 3, X: 1, Z: 2, HP: 5, MaxHP: 5}, {ID: 4, X: 3, Z: 4, HP: 5, MaxHP: 5}}}
	tap(&proto.Packet{Opcode: session.OpMonsterListResult, Data: list.Encode()})
	if st.monsters[3] == nil || st.monsters[4] == nil {
		t.Fatalf("the list's monsters were not filed: %v", st.monsters)
	}
	tap(&proto.Packet{Opcode: session.OpMonsterDied, Data: (&session.MonsterDied{MonsterID: 3}).Encode()})
	tap(&proto.Packet{Opcode: session.OpMonsterLeft, Data: (&session.MonsterLeft{IDs: []int64{4}}).Encode()})
	if st.monsters[3] != nil || st.monsters[4] != nil {
		t.Errorf("a death and a leave should forget the monster: %v", st.monsters)
	}

	tap(&proto.Packet{Opcode: session.OpAttackResult, Data: (&session.AttackResult{MonsterID: 2}).Encode()})
	select {
	case r := <-st.results:
		if r.MonsterID != 2 {
			t.Errorf("result for %d, want 2", r.MonsterID)
		}
	default:
		t.Error("the attack result did not reach the waiting attack")
	}
}
