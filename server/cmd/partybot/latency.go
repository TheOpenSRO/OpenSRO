package main

// The latency run (round 786, OURS): what the server's side of "the monsters
// pop up late" and "my attacks take a while to register" measures, without a
// rendered client.
//
//	partybot -mode latency -addr HOST:PORT -tp "x z" [-name Lat] [-level 140]
//	         [-walk 60s] [-speed 105] [-heading 0] [-attacks 60] [-nodelay=true]
//	         [-crowd 0] [-crowd-pace 150ms]
//
// The walk (after the attacks): the bot runs a straight line at -speed units a second (a
// relocated move every 50 ms, as the client's own position stream) and, for
// every monster the server tells it about as an enter (OpMonsterSpawned while
// the bot's own 320-unit block changed in the last second), prints how far
// the monster is from the bot on each axis and how long after the crossing
// the message came. Retail's window is the 3 x 3 message blocks (READ,
// session/aoi.go), so every enter should be 320..640 units ahead on the axis
// of the crossing.
//
// The attacks: for each, the nearest live monster is approached (a relocated
// move 3 units off it, then 300 ms), and the client's own release is sent --
// the stop report (OpMove with the stop flag, which the server answers to
// nobody but the watchers) and the OpAttack, back to back, as
// World3D._release_pending_attack writes them -- and the time to the
// OpAttackResult naming the monster is printed. -nodelay=false is a socket
// with Nagle's algorithm on (the client before round 786: Godot's
// StreamPeerTCP default); true is the Go default, TCP_NODELAY.
//
// -crowd N logs N more bots in around the probe, one every -crowd-pace
// (150 ms: a login's two bcrypt hashes; 40 ms timed most of 300 out), each
// relocating a few units every second (load on the hub, the area of interest
// and the watchers' pushes).

import (
	"fmt"
	"math"
	"math/rand"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

type latencyOpts struct {
	walk      time.Duration
	speed     float64
	heading   float64
	attacks   int
	noDelay   bool
	crowd     int
	crowdPace time.Duration
	attackTo  time.Duration
}

var latOpts latencyOpts

// latVerbose prints every enter (PARTYBOT_TRACE set).
var latVerbose = os.Getenv("PARTYBOT_TRACE") != ""

// latMonster is what the bot knows of a monster.
type latMonster struct {
	x, z  float64
	alive bool
}

type latState struct {
	mu        sync.Mutex
	x, z      float64
	cell      combat.Cell
	crossedAt time.Time
	monsters  map[int64]*latMonster
	enters    []latEnter
	results   chan *session.AttackResult
}

type latEnter struct {
	ahead, side, dist float64
	after             time.Duration
}

func (s *latState) tap(zone string) func(p *proto.Packet) {
	return func(p *proto.Packet) {
		now := time.Now()
		switch p.Opcode {
		case session.OpMonsterSpawned:
			m, err := session.DecodeMonsterSpawned(p.Data)
			if err != nil {
				return
			}
			s.mu.Lock()
			s.monsters[m.Monster.ID] = &latMonster{x: float64(m.Monster.X), z: float64(m.Monster.Z), alive: m.Monster.HP > 0}
			if !s.crossedAt.IsZero() && now.Sub(s.crossedAt) < time.Second {
				dx, dz := float64(m.Monster.X)-s.x, float64(m.Monster.Z)-s.z
				h := latOpts.heading * math.Pi / 180
				ahead := dx*math.Cos(h) + dz*math.Sin(h)
				side := -dx*math.Sin(h) + dz*math.Cos(h)
				s.enters = append(s.enters, latEnter{ahead: ahead, side: side, dist: math.Hypot(dx, dz), after: now.Sub(s.crossedAt)})
				if latVerbose {
					fmt.Printf("ENTER %d ahead %.0f side %.0f after %.1f ms\n", m.Monster.ID, ahead, side, ms(now.Sub(s.crossedAt)))
				}
			}
			s.mu.Unlock()
		case session.OpMonsterListResult:
			r, err := session.DecodeMonsterListResult(p.Data)
			if err != nil {
				return
			}
			s.mu.Lock()
			for _, m := range r.Monsters {
				s.monsters[m.ID] = &latMonster{x: float64(m.X), z: float64(m.Z), alive: m.HP > 0}
			}
			s.mu.Unlock()
		case session.OpMonsterMoved:
			m, err := session.DecodeMonsterMoved(p.Data)
			if err != nil {
				return
			}
			s.mu.Lock()
			if lm := s.monsters[m.MonsterID]; lm != nil {
				lm.x, lm.z = float64(m.DestX), float64(m.DestZ)
			}
			s.mu.Unlock()
		case session.OpMonsterDied:
			if d, err := session.DecodeMonsterDied(p.Data); err == nil {
				s.mu.Lock()
				delete(s.monsters, d.MonsterID)
				s.mu.Unlock()
			}
		case OpMonsterLeftWire:
			if l, err := session.DecodeMonsterLeft(p.Data); err == nil {
				s.mu.Lock()
				for _, id := range l.IDs {
					delete(s.monsters, id)
				}
				s.mu.Unlock()
			}
		case session.OpAttackResult:
			if r, err := session.DecodeAttackResult(p.Data); err == nil {
				select {
				case s.results <- r:
				default:
				}
			}
		}
	}
}

// OpMonsterLeftWire is session.OpMonsterLeft (kept apart so the switch reads
// as the wire).
const OpMonsterLeftWire = session.OpMonsterLeft

func latencyScenario(addr, name string, level int, at string) error {
	if at == "" {
		return fmt.Errorf("-mode latency needs -tp \"x z\"")
	}
	var tx, tz float64
	if _, err := fmt.Sscanf(at, "%f %f", &tx, &tz); err != nil {
		return fmt.Errorf("-tp %q: %v", at, err)
	}
	b, err := connect(addr, strings.ToLower(name), name, level)
	if err != nil {
		return err
	}
	if tc, ok := b.conn.(*net.TCPConn); ok {
		tc.SetNoDelay(latOpts.noDelay)
	}
	st := &latState{monsters: map[int64]*latMonster{}, results: make(chan *session.AttackResult, 64)}
	b.tap = st.tap(b.zone)
	for i := 0; i < latOpts.crowd; i++ {
		go latCrowdBot(addr, fmt.Sprintf("%sc%03d", name, i), at)
		time.Sleep(latOpts.crowdPace) // paced, as swarm's -rate paces its logins
	}
	b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: "/tp " + at}).Encode())
	time.Sleep(2 * time.Second) // the warp, the 0x3012, the release
	b.mu.Lock()
	y := b.y
	b.mu.Unlock()
	st.mu.Lock()
	st.x, st.z = tx, tz
	st.cell = combat.CellOf("world", tx, tz)
	st.mu.Unlock()
	b.moveTo(float32(tx), y, float32(tz))
	b.send(session.OpMonsterList, nil)
	time.Sleep(time.Second)
	fmt.Printf("[%s] at %.0f, %.0f; %d monsters known; nodelay=%v crowd=%d\n", name, tx, tz, len(st.monsters), latOpts.noDelay, latOpts.crowd)

	// The attacks.
	var rtts []time.Duration
	refused := 0
	for i := 0; i < latOpts.attacks; i++ {
		st.mu.Lock()
		best, bestD := int64(0), 250.0
		for id, m := range st.monsters {
			if d := math.Hypot(m.x-st.x, m.z-st.z); m.alive && d < bestD {
				best, bestD = id, d
			}
		}
		var mx, mz float64
		if best != 0 {
			mx, mz = st.monsters[best].x, st.monsters[best].z
		}
		st.mu.Unlock()
		if best == 0 {
			b.send(session.OpMonsterList, nil)
			time.Sleep(time.Second)
			continue
		}
		// Stand 3 units off it, on the line from where the bot is.
		st.mu.Lock()
		dx, dz := st.x-mx, st.z-mz
		d := math.Hypot(dx, dz)
		if d < 0.01 {
			dx, dz, d = 1, 0, 1
		}
		st.x, st.z = mx+dx/d*3, mz+dz/d*3
		x, z := st.x, st.z
		st.mu.Unlock()
		b.moveTo(float32(x), y, float32(z))
		time.Sleep(300 * time.Millisecond)
		drainResults(st.results)
		// The release: the stop report, then the attack, back to back.
		sent := time.Now()
		b.send(session.OpMove, (&session.MoveRequest{X: float32(x), Y: y, Z: float32(z), Stopped: true}).Encode())
		b.send(session.OpAttack, (&session.AttackRequest{CharacterName: name, TargetMonsterID: best}).Encode())
		got := false
		deadline := time.After(latOpts.attackTo)
		for !got {
			select {
			case r := <-st.results:
				if r.MonsterID != best && r.MonsterID != 0 {
					continue
				}
				rtt := time.Since(sent)
				got = true
				if r.Error != "" {
					refused++
					fmt.Printf("[%s] attack %d on %d: %s after %.1f ms\n", name, i, best, r.Error, ms(rtt))
					st.mu.Lock()
					delete(st.monsters, best)
					st.mu.Unlock()
					continue
				}
				rtts = append(rtts, rtt)
				fmt.Printf("[%s] attack %d on %d: result after %.1f ms (died %v)\n", name, i, best, ms(rtt), r.MonsterDied)
			case <-deadline:
				got = true
				fmt.Printf("[%s] attack %d on %d: no result in %s\n", name, i, best, latOpts.attackTo)
			}
		}
		// End the server's keep-up (a walk cancels it, keepup.go), so its
		// swings are not taken for the next click's answer, and wait out the
		// base attack's re-use delay (punch 1.5 s, two-hander 2 s), so the
		// next click is not the cadence's deferral either.
		st.mu.Lock()
		st.x += 1
		x = st.x
		st.mu.Unlock()
		b.send(session.OpMove, (&session.MoveRequest{X: float32(x), Y: y, Z: float32(z)}).Encode())
		time.Sleep(2100 * time.Millisecond)
		drainResults(st.results)
	}
	if len(rtts) > 0 {
		sort.Slice(rtts, func(i, j int) bool { return rtts[i] < rtts[j] })
		over := 0
		for _, r := range rtts {
			if r >= 20*time.Millisecond {
				over++
			}
		}
		fmt.Printf("LATENCY attacks nodelay=%v crowd=%d n=%d refused=%d request->result p50 %.1f ms p95 %.1f ms max %.1f ms, %d at 20 ms or more\n",
			latOpts.noDelay, latOpts.crowd, len(rtts), refused, ms(rtts[len(rtts)/2]), ms(rtts[len(rtts)*95/100]), ms(rtts[len(rtts)-1]), over)
	}
	// The walk.
	if latOpts.walk > 0 {
		h := latOpts.heading * math.Pi / 180
		step := 50 * time.Millisecond
		end := time.Now().Add(latOpts.walk)
		for time.Now().Before(end) {
			time.Sleep(step)
			st.mu.Lock()
			st.x += math.Cos(h) * latOpts.speed * step.Seconds()
			st.z += math.Sin(h) * latOpts.speed * step.Seconds()
			if c := combat.CellOf("world", st.x, st.z); c != st.cell {
				st.cell, st.crossedAt = c, time.Now()
			}
			x, z := st.x, st.z
			st.mu.Unlock()
			b.moveTo(float32(x), y, float32(z))
		}
		st.mu.Lock()
		en := append([]latEnter(nil), st.enters...)
		st.mu.Unlock()
		reportEnters(name, en)
	}

	return nil
}

func drainResults(c chan *session.AttackResult) {
	for {
		select {
		case <-c:
		default:
			return
		}
	}
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

func reportEnters(name string, en []latEnter) {
	if len(en) == 0 {
		fmt.Printf("LATENCY enters n=0\n")
		return
	}
	var ahead, after []float64
	for _, e := range en {
		ahead = append(ahead, e.ahead)
		after = append(after, ms(e.after))
	}
	sort.Float64s(ahead)
	sort.Float64s(after)
	q := func(v []float64, p float64) float64 { return v[min(len(v)-1, int(p*float64(len(v))))] }
	fmt.Printf("LATENCY enters n=%d ahead min %.0f p50 %.0f max %.0f units; crossing->enter p50 %.1f ms p95 %.1f ms max %.1f ms\n",
		len(en), q(ahead, 0), q(ahead, 0.5), q(ahead, 1), q(after, 0.5), q(after, 0.95), q(after, 1))
}

// latCrowdBot is one of -crowd's: in the world beside the probe, moving a few
// units every second until the process ends.
func latCrowdBot(addr, name, at string) {
	b, err := connect(addr, strings.ToLower(name), name, 1)
	if err != nil {
		fmt.Printf("[%s] crowd bot: %v\n", name, err)
		return
	}
	var tx, tz float64
	fmt.Sscanf(at, "%f %f", &tx, &tz)
	rng := rand.New(rand.NewSource(time.Now().UnixNano()))
	x, z := tx+rng.Float64()*200-100, tz+rng.Float64()*200-100
	for {
		time.Sleep(time.Duration(800+rng.Intn(400)) * time.Millisecond)
		x += rng.Float64()*20 - 10
		z += rng.Float64()*20 - 10
		if err := b.moveTo(float32(x), b.y, float32(z)); err != nil {
			return
		}
	}
}
