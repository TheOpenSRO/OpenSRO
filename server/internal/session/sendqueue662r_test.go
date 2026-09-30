package session

import (
	"runtime"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/statuseffect"
)

// Round 662's review (the merge with round 659): a monster that comes into a
// player's window already under a state goes out as ONE enter, then its
// OpObjectStatus, then its leg -- a single batch, so no other frame for the
// session comes between them, and the enter is never sent twice. 2,000 enters
// of a bleeding, walking monster race 20,000 filler frames from another
// goroutine to the same session; the client checks every enter's next two
// frames.
func TestAnEnteringMonsterWithAStatusIsOneEnterThenStatusThenLeg(t *testing.T) {
	fx := statusFXForTest(t)
	monsters := combat.NewHub()
	r := newListRig(t, monsters)
	c := r.join(t, 1, 0, 0)
	sess := r.session(1)
	m := monsters.SpawnSpecies("jangan", strikeMangyang, 5, 0, 5, 1000, 0, 0, 0)
	rec, ok := statuseffect.Resolve(statuseffect.Run{Code: "bl", Values: []int{30000, 100, 1, 50, 0}},
		statuseffect.Target{}, fx.ms(time.Now()), func(int, int) bool { return true })
	if !ok {
		t.Fatal("setup: the bleeding did not resolve")
	}
	h := &statuseffect.Holder{}
	h.Put(rec)
	fx.mu.Lock()
	fx.mobs[m.ID] = h
	fx.mu.Unlock()
	walking, _ := monsters.Get(m.ID)
	walking.Moving, walking.DestX, walking.DestZ, walking.MoveSpeed = true, 50, 50, 16

	// Several Ps even on a one-core host, so the OS interleaves the two
	// senders between any two of their Sends.
	defer runtime.GOMAXPROCS(runtime.GOMAXPROCS(4))
	const enters, fillers = 2000, 20000
	const opFiller uint16 = 0x7ffd
	var wg sync.WaitGroup
	start := make(chan struct{})
	wg.Add(2)
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < enters; i++ {
			if err := sendMonsterEnter(sess, walking, 1.5); err != nil {
				t.Errorf("enter %d: %v", i, err)
				return
			}
		}
	}()
	go func() {
		defer wg.Done()
		<-start
		for i := 0; i < fillers; i++ {
			if err := sess.Send(&proto.Packet{Opcode: opFiller, Data: []byte{byte(i)}}); err != nil {
				t.Errorf("filler %d: %v", i, err)
				return
			}
			runtime.Gosched()
		}
	}()
	close(start)
	wg.Wait()

	gotEnters, broken := 0, 0
	for n := 0; n < enters*3+fillers; {
		p := c.read(t)
		n++
		switch p.Opcode {
		case opFiller:
			continue
		case OpMonsterSpawned:
			gotEnters++
			st := c.read(t)
			leg := c.read(t)
			n += 2
			if st.Opcode != OpObjectStatus || leg.Opcode != OpMonsterMoved {
				broken++
				if broken <= 3 {
					t.Errorf("enter %d was followed by %#04x then %#04x; want OpObjectStatus (%#04x) then OpMonsterMoved (%#04x)",
						gotEnters, st.Opcode, leg.Opcode, OpObjectStatus, OpMonsterMoved)
				}
				continue
			}
			if s, err := DecodeObjectStatus(st.Data); err != nil || s.OwnerID != m.ID || s.Mask == 0 {
				t.Errorf("enter %d's status: %+v, %v", gotEnters, s, err)
			}
			if mv, err := DecodeMonsterMoved(leg.Data); err != nil || mv.MonsterID != m.ID {
				t.Errorf("enter %d's leg: %+v, %v", gotEnters, mv, err)
			}
		default:
			broken++
			if broken <= 3 {
				t.Errorf("frame %#04x arrived outside an enter's sequence", p.Opcode)
			}
		}
	}
	if gotEnters != enters || broken > 0 {
		t.Errorf("%d enters arrived for %d sent, %d sequences broken", gotEnters, enters, broken)
	}
}
