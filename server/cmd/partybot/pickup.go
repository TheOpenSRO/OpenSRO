package main

import (
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// The round-785 drop and pick-up run (-mode pickup): one character kills
// -kills monsters of -monster beside itself with real blows (bot.kill), and
// reports where each kill's stacks landed -- the spacing between the stacks of
// one kill -- and, with -pick, walks up to each stack (3 units +x of it, a
// relocation) and picks it up, printing the PickUpResult and the 0x3036 pick-up
// motion the zone is sent (its angle; the server's own log has the corpse and
// each stack, "ground drop"). With -wait it first waits, so a QA client
// standing beside it is in the world to watch the pick-ups as another player's.
// Needs the bot's account in -gm-accounts and a server run with
// -trust-client-positions (the relocations).

type pickRun struct {
	kills int
	pick  bool
	wait  time.Duration
	// at, "x y z": where to stand (a relocation) before the first kill --
	// beside a QA client's player, so it draws this one's pick-ups.
	at string
}

var pickupOpts pickRun

// isGround reports the ground-item traffic the pickup mode waits on.
func isGround(op uint16) bool {
	switch op {
	case session.OpGroundItemSpawned, session.OpPickUpResult, session.OpPickUpMotion:
		return true
	}
	return false
}

// awaitGround waits for the next ground-item message of op.
func (b *bot) awaitGround(op uint16, d time.Duration) (*proto.Packet, error) {
	deadline := time.After(d)
	for {
		select {
		case p := <-b.ground:
			if p.Opcode == op {
				return p, nil
			}
		case <-deadline:
			return nil, fmt.Errorf("%s: no 0x%04x within %s", b.name, op, d)
		}
	}
}

func pickupScenario(addr, prefix, species string, level int, o pickRun) error {
	name := prefix + "Pick"
	b, err := connect(addr, strings.ToLower(name), name, level)
	if err != nil {
		return err
	}
	if o.at != "" {
		var x, y, z float32
		if _, err := fmt.Sscanf(o.at, "%f %f %f", &x, &y, &z); err != nil {
			return fmt.Errorf("-at %q: want \"x y z\": %v", o.at, err)
		}
		b.moveTo(x, y, z)
		fmt.Printf("[%s] relocated to %.1f, %.1f, %.1f\n", b.name, x, y, z)
	}
	if o.wait > 0 {
		fmt.Printf("[%s] waiting %s\n", b.name, o.wait)
		time.Sleep(o.wait)
	}
	var pairs, near2, items int
	minPair, sumPair := math.Inf(1), 0.0
	for k := 0; k < o.kills; k++ {
		if _, err := b.kill(species); err != nil {
			return err
		}
		// The kill's stacks arrive right behind its result; collect them for
		// a moment.
		var got []*session.GroundItemSnapshot
		deadline := time.After(700 * time.Millisecond)
	collect:
		for {
			select {
			case p := <-b.ground:
				if p.Opcode != session.OpGroundItemSpawned {
					continue
				}
				s, err := session.DecodeGroundItemListResult(append([]byte{1, 0}, p.Data...))
				if err != nil || len(s.Items) != 1 {
					return fmt.Errorf("%s: undecodable ground item: %v", b.name, err)
				}
				got = append(got, &s.Items[0])
			case <-deadline:
				break collect
			}
		}
		items += len(got)
		for i := range got {
			fmt.Printf("[%s] kill %d: ground item %d (item %d x%d gold %v) at %.2f, %.2f, %.2f\n", b.name, k+1,
				got[i].ID, got[i].ItemID, got[i].Quantity, got[i].Gold, got[i].X, got[i].Y, got[i].Z)
			for j := i + 1; j < len(got); j++ {
				d := math.Hypot(float64(got[i].X-got[j].X), float64(got[i].Z-got[j].Z))
				pairs++
				sumPair += d
				minPair = math.Min(minPair, d)
				if d < 2 {
					near2++
				}
				fmt.Printf("[%s] kill %d: items %d and %d are %.2f apart\n", b.name, k+1, got[i].ID, got[j].ID, d)
			}
		}
		if !o.pick {
			continue
		}
		for _, s := range got {
			b.moveTo(s.X+3, s.Y, s.Z)
			time.Sleep(150 * time.Millisecond)
			sent := time.Now()
			b.send(session.OpPickUp, (&session.PickUpRequest{CharacterName: b.name, GroundItemID: s.ID}).Encode())
			p, err := b.awaitGround(session.OpPickUpResult, 3*time.Second)
			if err != nil {
				return err
			}
			r, err := session.DecodePickUpResult(p.Data)
			if err != nil {
				return err
			}
			res := time.Since(sent)
			if r.Code != 0 {
				fmt.Printf("[%s] pick of %d refused %#x after %s\n", b.name, s.ID, r.Code, res)
				continue
			}
			p, err = b.awaitGround(session.OpPickUpMotion, 3*time.Second)
			if err != nil {
				return err
			}
			m, err := session.DecodePickUpMotion(p.Data)
			if err != nil {
				return err
			}
			want := session.PickUpMotionAngle(float64(s.X+3), float64(s.Z), float64(s.X), float64(s.Z))
			fmt.Printf("[%s] picked %d (item %d x%d) -- result after %s, 0x3036 for %d angle %d (want %d) after %s\n", b.name, s.ID,
				r.ItemID, r.Quantity, res, m.ObjectID, m.Angle, want, time.Since(sent))
			if m.ObjectID != uint32(b.id) || m.Angle != want {
				return fmt.Errorf("%s: pick-up motion %+v, want id %d angle %d", b.name, m, uint32(b.id), want)
			}
			// A pause between picks, so a watching client's log shows each
			// clip start and end apart (OURS, a test pace).
			time.Sleep(2 * time.Second)
		}
	}
	mean := 0.0
	if pairs > 0 {
		mean = sumPair / float64(pairs)
	}
	fmt.Printf("[%s] %d kills, %d stacks, %d same-kill pairs: closest %.2f, mean %.2f, %d within 2 units\n", b.name,
		o.kills, items, pairs, minPair, mean, near2)
	return nil
}
