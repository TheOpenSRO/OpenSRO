package session

import (
	"context"
	"fmt"
	"io"
	"math/rand"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Round 656's benchmark: one monster AI tick at 12,000 monsters -- round
// 657's ~10,200 field rows with room -- spread evenly over a 40 x 30 grid of
// regions in one bucket (-single-frame's "world"), with 50 or 100 players
// connected over real TCP (each client drains its socket). "spread" puts the
// players anywhere on the grid, "town" puts them all within Jangan's 5 x 5
// regions. The runtime runs 50 ticks (5 s of game time) before the clock
// starts, so the brains exist and their states are mixed; each op is one
// tick, its pushes written included. "aggro" turns -monster-battle and
// -monster-aggro on (no strike stores: the chase runs, nobody is hit).
//
// It uses only what the base revision has, so the same file measures before
// and after; benchSetup656 (aitick656_setup_test.go) installs what round 656
// adds -- the area of interest and the sleep -- and is a no-op stub when the
// file is run against the base.
func BenchmarkMonsterAITick(b *testing.B) {
	for _, players := range []int{50, 100} {
		for _, layout := range []string{"spread", "town"} {
			for _, aggro := range []bool{false, true} {
				name := fmt.Sprintf("monsters=12000/players=%d/%s/aggro=%v", players, layout, aggro)
				b.Run(name, func(b *testing.B) { benchAITick(b, 12000, players, layout, aggro) })
			}
		}
	}
}

func benchAITick(b *testing.B, nMonsters, nPlayers int, layout string, aggro bool) {
	monsterBattle.Store(aggro)
	monsterAggro.Store(aggro)
	defer monsterBattle.Store(false)
	defer monsterAggro.Store(false)

	const zone = "world"
	rng := rand.New(rand.NewSource(656))
	monsters := combat.NewHub()
	for i := 0; i < nMonsters; i++ {
		x := (rng.Float64()*40 - 20) * 1920
		z := (rng.Float64()*30 - 15) * 1920
		monsters.SpawnSpecies(zone, testMangyang, x, 0, z, 30, 1, 1, 1)
	}
	hub := world.NewHub()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		b.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	var entered sync.WaitGroup
	entered.Add(nPlayers)
	srv := &gateway.Server{Addr: addr, Handle: func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
		id := int64(leUint64(p.Data[0:8]))
		x, _, _ := decodeFloat32(p.Data[8:12])
		z, _, _ := decodeFloat32(p.Data[12:16])
		hub.Enter(sess, id, "p", 1, zone, world.Position{X: float64(x), Z: float64(z)})
		entered.Done()
		return nil
	}}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(ctx)
	var conns []net.Conn
	defer func() {
		for _, c := range conns {
			c.Close()
		}
	}()
	for i := 0; i < nPlayers; i++ {
		var conn net.Conn
		for try := 0; try < 50; try++ {
			if conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond); err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if err != nil {
			b.Fatal(err)
		}
		conns = append(conns, conn)
		go io.Copy(io.Discard, conn)
		var x, z float64
		if layout == "town" {
			x, z = (rng.Float64()*5-2.5)*1920, (rng.Float64()*5-2.5)*1920
		} else {
			x, z = (rng.Float64()*40-20)*1920, (rng.Float64()*30-15)*1920
		}
		hello := append(encodeInt64(int64(i+1)), encodeFloat32(float32(x))...)
		hello = append(hello, encodeFloat32(float32(z))...)
		if err := proto.Write(conn, &proto.Packet{Opcode: 0x7ffe, Data: hello}, nil, nil); err != nil {
			b.Fatal(err)
		}
	}
	entered.Wait()

	a := newMonsterAI(hub, monsters, nil, MonsterAIConfig{}, rand.New(rand.NewSource(656)), nil)
	monsterAIRuntime.Store(a)
	defer monsterAIRuntime.Store(nil)
	perTick := benchSetup656(b, a, hub, monsters)

	now := time.Date(2026, 9, 30, 12, 0, 0, 0, time.UTC)
	step := func() {
		if perTick != nil {
			perTick()
		}
		a.tick(now)
		now = now.Add(MonsterAITick)
	}
	for i := 0; i < 50; i++ {
		step()
	}
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		step()
	}
	b.StopTimer()
	b.ReportMetric(float64(b.Elapsed().Microseconds())/1000/float64(b.N), "ms/tick")
}
