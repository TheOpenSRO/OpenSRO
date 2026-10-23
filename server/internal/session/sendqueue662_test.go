package session

import (
	"math/rand"
	"sync/atomic"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 662: the monster AI's tick pushes to every watcher in turn from one
// goroutine (monsterAI.deliver). A watcher that stops reading used to hold
// it -- each push a write, each write waiting once the socket was full, up to
// the session's 10 s send budget -- and so every other player's monsters
// froze with it. With the per-session queue a push is a queue append: the
// tick never waits, the stalled client is closed by its queue limit, and the
// other watcher gets every push. Two real TCP clients through the list rig,
// both watching one cell; one never reads. Only APIs the base has, so the
// file builds on 1ea6b02 for the negative.
func TestASlowClientNeverHoldsTheAITick(t *testing.T) {
	monsters := combat.NewHub()
	r := newListRig(t, monsters)
	r.join(t, 1, 0, 0) // never reads
	fast := r.join(t, 2, 10, 10)
	var fastGot atomic.Int64
	go func() {
		for {
			if _, err := proto.Read(fast.r, nil, nil); err != nil {
				return
			}
			fastGot.Add(1)
		}
	}()
	a := newMonsterAI(r.hub, monsters, nil, MonsterAIConfig{}, rand.New(rand.NewSource(662)), nil)
	push := monsterPush{zone: "jangan", cell: combat.CellOf("jangan", 0, 0),
		packet: &proto.Packet{Opcode: OpMonsterMoved, Data: make([]byte, 16<<10)}}

	// 1,000 ticks of one 16 KB push each (16 MB to each watcher, a tick a
	// millisecond): far past the loopback's buffers for the client that does
	// not read.
	var longest time.Duration
	ticks := 0
	end := time.Now().Add(5 * time.Second)
	for ticks < 1000 && time.Now().Before(end) {
		t0 := time.Now()
		got := a.deliver(push, nil)
		longest = max(longest, time.Since(t0))
		if len(got) != 2 {
			t.Fatalf("tick %d reached %d watchers, want 2", ticks, len(got))
		}
		ticks++
		time.Sleep(time.Millisecond)
	}
	if ticks < 1000 {
		t.Errorf("only %d of 1000 ticks ran in 5 s", ticks)
	}
	if longest > 50*time.Millisecond {
		t.Errorf("the longest tick took %v: the tick waited on the client that does not read", longest.Round(time.Millisecond))
	}
	deadline := time.Now().Add(5 * time.Second)
	for fastGot.Load() < int64(ticks) && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if fastGot.Load() != int64(ticks) {
		t.Errorf("the reading client got %d of %d pushes", fastGot.Load(), ticks)
	}
	if err := r.session(1).Send(&proto.Packet{Opcode: OpMonsterMoved}); err == nil {
		t.Errorf("the client that never read is still open after 16 MB")
	}
	t.Logf("%d ticks, longest %v; the reading client got %d pushes", ticks, longest, fastGot.Load())
}
