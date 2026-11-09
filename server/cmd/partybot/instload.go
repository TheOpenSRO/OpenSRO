package main

// Round 869 lane W2: -mode instload, the multi-process load test
// (docs/protocol/game_worlds.md 12.7, OURS). -parties parties of
// -party-size GM bots log in through the front, form a real party, and
// enter instances: the leader opens a layer with the GM aid (/instance
// <world>; the registry places it on the least-loaded instance host) and
// the members follow it (/instance enter <world>.<layer>); then every bot
// fights inside for -duration -- each second it takes the nearest live
// monster of its layer's list, stands beside it and swings. It prints each
// entry's time (the GM line to the zone change) and a summary: entries,
// their percentiles, blows sent and answered, kills, bots lost.

import (
	"fmt"
	"math"
	"math/rand"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

var openedLayer = regexp.MustCompile(`opened and entered (\d+)\.(\d+)`)

type loadStats struct {
	mu                                 sync.Mutex
	entries                            []time.Duration
	refused                            int
	attacks, answered, kills, lostBots atomic.Int64
	layers                             map[string]int
}

func (s *loadStats) entry(d time.Duration) {
	s.mu.Lock()
	s.entries = append(s.entries, d)
	s.mu.Unlock()
}

// loadBot is one bot's fight state.
type loadBot struct {
	b      *bot
	mu     sync.Mutex
	zones  chan *session.ChangeZoneResult
	gmText chan string
	mons   []session.MonsterSnapshot
	target int64
	dead   map[int64]bool
}

func newLoadBot(b *bot) *loadBot {
	lb := &loadBot{b: b, zones: make(chan *session.ChangeZoneResult, 8), gmText: make(chan string, 8), dead: map[int64]bool{}}
	b.tap = func(p *proto.Packet) {
		switch p.Opcode {
		case session.OpChangeZoneResult:
			if r, err := session.DecodeChangeZoneResult(p.Data); err == nil && r.OK {
				select {
				case lb.zones <- r:
				default:
				}
			}
		case session.OpGMCommandResult:
			if r, err := session.DecodeGMCommandResult(p.Data); err == nil {
				select {
				case lb.gmText <- r.Text:
				default:
				}
			}
		case session.OpMonsterListResult:
			if r, err := session.DecodeMonsterListResult(p.Data); err == nil {
				lb.mu.Lock()
				if r.Page == 0 {
					lb.mons = nil
				}
				lb.mons = append(lb.mons, r.Monsters...)
				lb.mu.Unlock()
			}
		}
	}
	return lb
}

// gmLine sends a GM line and waits for its answer and, when want, the zone
// change that follows; it answers the text and the entry time.
func (lb *loadBot) gmLine(line string, want bool) (string, time.Duration, error) {
	for len(lb.zones) > 0 {
		<-lb.zones
	}
	start := time.Now()
	lb.b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: lb.b.name, Line: line}).Encode())
	var text string
	select {
	case text = <-lb.gmText:
	case <-time.After(15 * time.Second):
		return "", 0, fmt.Errorf("%s: no answer to %s", lb.b.name, line)
	}
	if !want {
		return text, 0, nil
	}
	select {
	case <-lb.zones:
		return text, time.Since(start), nil
	case <-time.After(20 * time.Second):
		return text, 0, fmt.Errorf("%s: no zone change after %s (%q)", lb.b.name, line, text)
	}
}

// fight is one bot's second: a target, a step beside it, a blow.
func (lb *loadBot) fight(st *loadStats, rng *rand.Rand) {
	b := lb.b
	// Answers of earlier blows.
	for {
		select {
		case p := <-b.other:
			if p.Opcode == session.OpAttackResult {
				st.answered.Add(1)
				if ar, err := session.DecodeAttackResult(p.Data); err == nil && ar.MonsterDied {
					st.kills.Add(1)
					lb.mu.Lock()
					lb.dead[lb.target] = true
					lb.target = 0
					lb.mu.Unlock()
				}
			}
			continue
		default:
		}
		break
	}
	lb.mu.Lock()
	var best *session.MonsterSnapshot
	if lb.target == 0 {
		b.mu.Lock()
		x, z := b.x, b.z
		b.mu.Unlock()
		bd := math.MaxFloat64
		for i := range lb.mons {
			m := &lb.mons[i]
			if m.HP <= 0 || lb.dead[m.ID] {
				continue
			}
			d := math.Hypot(float64(m.X-x), float64(m.Z-z))
			if d < bd {
				bd, best = d, m
			}
		}
		if best != nil {
			lb.target = best.ID
		}
	}
	target := lb.target
	need := lb.target == 0 || rng.Intn(10) == 0
	lb.mu.Unlock()
	if need {
		b.send(session.OpMonsterList, nil)
	}
	if best != nil {
		b.moveTo(best.X+3, best.Y, best.Z+3)
		b.mu.Lock()
		b.x, b.z = best.X+3, best.Z+3
		b.mu.Unlock()
	}
	if target != 0 {
		b.send(session.OpAttack, (&session.AttackRequest{CharacterName: b.name, TargetMonsterID: target}).Encode())
		st.attacks.Add(1)
	}
}

// worldOf is party idx's world: -world is one id, or a range "63-72" the
// parties take in turn (a world has 50 layers).
func worldOf(spec string, idx int) string {
	var lo, hi int
	if n, _ := fmt.Sscanf(spec, "%d-%d", &lo, &hi); n == 2 && hi >= lo {
		return strconv.Itoa(lo + idx%(hi-lo+1))
	}
	return spec
}

func percentile(ds []time.Duration, p float64) time.Duration {
	if len(ds) == 0 {
		return 0
	}
	s := append([]time.Duration(nil), ds...)
	sort.Slice(s, func(i, j int) bool { return s[i] < s[j] })
	i := int(math.Ceil(p*float64(len(s)))) - 1
	if i < 0 {
		i = 0
	}
	return s[i]
}

func instLoadRun(addr, prefix string, level, parties, size int, world string, duration time.Duration) error {
	st := &loadStats{layers: map[string]int{}}
	var wg sync.WaitGroup
	sem := make(chan struct{}, 12)
	type partyBots struct{ bots []*loadBot }
	all := make([]*partyBots, parties)
	var loginErr atomic.Int64
	t0 := time.Now()
	for p := 0; p < parties; p++ {
		all[p] = &partyBots{bots: make([]*loadBot, size)}
		for i := 0; i < size; i++ {
			wg.Add(1)
			go func(p, i int) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()
				name := fmt.Sprintf("%s%03d%c", prefix, p, 'a'+i)
				b, err := connect(addr, strings.ToLower(name), name, level)
				if err != nil {
					fmt.Printf("LOGIN FAIL %s: %v\n", name, err)
					loginErr.Add(1)
					return
				}
				all[p].bots[i] = newLoadBot(b)
			}(p, i)
		}
	}
	wg.Wait()
	fmt.Printf("LOGGED IN %d bots in %v (%d failed)\n", parties*size-int(loginErr.Load()), time.Since(t0).Round(time.Millisecond), loginErr.Load())
	// Each party: formed, then into its layer.
	t1 := time.Now()
	for idx, pb := range all {
		wg.Add(1)
		go func(idx int, pb *partyBots) {
			defer wg.Done()
			bots := pb.bots
			for _, lb := range bots {
				if lb == nil {
					return
				}
			}
			lead := bots[0].b
			// The members stand beside the leader (an invitation needs
			// the target in view; a login lands at one of three starts).
			lead.mu.Lock()
			lx, ly, lz := lead.x, lead.y, lead.z
			lead.mu.Unlock()
			for _, m := range bots[1:] {
				m.b.moveTo(lx+2, ly, lz+2)
			}
			time.Sleep(time.Second)
			if err := form(lead, bots[1].b, party.FlagExpShare); err != nil {
				fmt.Printf("PARTY FAIL %s: %v\n", lead.name, err)
			} else {
				for _, m := range bots[2:] {
					lead.send(party.OpInvite, party.EncodeTarget(m.b.jid()))
					time.Sleep(300 * time.Millisecond)
					m.b.send(party.OpInvitation, party.EncodeAnswerYes())
					time.Sleep(300 * time.Millisecond)
				}
			}
			// From here the party and chat traffic is not read: drained.
			for _, lb := range bots {
				go func(b *bot) {
					for range b.in {
					}
				}(lb.b)
			}
			text, d, err := bots[0].gmLine("/instance "+worldOf(world, idx), true)
			if err != nil {
				st.mu.Lock()
				st.refused++
				st.mu.Unlock()
				fmt.Printf("ENTRY FAIL %s: %v\n", lead.name, err)
				return
			}
			m := openedLayer.FindStringSubmatch(text)
			if m == nil {
				fmt.Printf("ENTRY FAIL %s: %q\n", lead.name, text)
				return
			}
			layer := m[1] + "." + m[2]
			st.entry(d)
			fmt.Printf("ENTRY %s %s open %v\n", lead.name, layer, d.Round(time.Microsecond))
			for _, lb := range bots[1:] {
				_, d, err := lb.gmLine("/instance enter "+layer, true)
				if err != nil {
					fmt.Printf("ENTRY FAIL %s: %v\n", lb.b.name, err)
					continue
				}
				st.entry(d)
				fmt.Printf("ENTRY %s %s follow %v\n", lb.b.name, layer, d.Round(time.Microsecond))
			}
			st.mu.Lock()
			st.layers[layer]++
			st.mu.Unlock()
		}(idx, pb)
	}
	wg.Wait()
	fmt.Printf("ENTERED %d layers, %d entries in %v\n", len(st.layers), len(st.entries), time.Since(t1).Round(time.Millisecond))
	// The fight.
	fmt.Printf("FIGHT START %s\n", time.Now().Format(time.RFC3339))
	stop := time.Now().Add(duration)
	for _, pb := range all {
		for _, lb := range pb.bots {
			if lb == nil {
				continue
			}
			wg.Add(1)
			go func(lb *loadBot) {
				defer wg.Done()
				rng := rand.New(rand.NewSource(time.Now().UnixNano()))
				time.Sleep(time.Duration(rng.Intn(1000)) * time.Millisecond)
				t := time.NewTicker(time.Second)
				defer t.Stop()
				for time.Now().Before(stop) {
					<-t.C
					if lb.b.send(session.OpPing, []byte{1, 0, 0, 0}) != nil {
						st.lostBots.Add(1)
						return
					}
					lb.fight(st, rng)
				}
			}(lb)
		}
	}
	wg.Wait()
	fmt.Printf("FIGHT END %s\n", time.Now().Format(time.RFC3339))
	st.mu.Lock()
	defer st.mu.Unlock()
	fmt.Printf("SUMMARY parties=%d bots=%d layers=%d entries=%d refused=%d entry_p50=%v entry_p95=%v entry_max=%v attacks=%d answered=%d kills=%d lost=%d\n",
		parties, parties*size, len(st.layers), len(st.entries), st.refused,
		percentile(st.entries, 0.5).Round(time.Microsecond), percentile(st.entries, 0.95).Round(time.Microsecond),
		percentile(st.entries, 1).Round(time.Microsecond), st.attacks.Load(), st.answered.Load(), st.kills.Load(), st.lostBots.Load())
	return nil
}
