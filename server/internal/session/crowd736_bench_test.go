//go:build linux

package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"log/slog"
	"math/rand"
	"net"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 736, crowd scale: what the server does when N players stand in one
// place and each moves, measured through the server's own code.
//
// The layers measured (and the ones not):
//
//   - The server side is the real gateway.Server on loopback TCP: the real
//     Session, its outbound queue and writer goroutine (gateway.go, round
//     662), the real proto framing. Each player's client is a TCP connection
//     in a CHILD PROCESS (this test binary re-run as TestCrowd736Child) that
//     only drains its socket and counts bytes and frames, so the parent's
//     getrusage CPU is the server's alone (the handler, the queues, the
//     writers' syscalls, GC), not the readers'.
//   - The N players already standing there are put in the world.Hub with
//     hub.Enter directly (OURS harness shortcut): entering them through
//     enterOwned failed past ~150 players until round 737 (the arrival list
//     outgrew one frame). Since round 737 each is given a player view holding
//     the players of its 3 x 3 blocks (playerview.go), as the world entry
//     leaves it, so every move goes through the production known-set check.
//   - The one ARRIVING player goes through the real enterOwned (the shared
//     tail of OpEnterWorld/Start, world.go) against in-memory stores, and
//     leaves through the real WorldDisconnectHandler: the spawn burst and the
//     enter/leave costs. With the SQL stores production uses, enterOwned also
//     makes two store reads per player in view (playerRecord's body and
//     worn items); the memory stores make those cheap here.
//   - Round 737: a move reaches only the players in view of the mover (the
//     3 x 3 blocks). The serial drive checks the count against the window
//     rule; the layouts are "town" (one 3 x 3 window around the arrival
//     point), "field" (10 x 10 blocks) and "block" (one block: everyone sees
//     everyone, round 736's fan-out, to measure C2 alone).
//     OPENSRO_CROWD736_LAYOUTS picks them ("block/serial,town/parallel").
//   - The moves are the real handleMove (world.go), called from the test
//     goroutine with the server-side session -- the gateway read loop's
//     decode of a 12-byte payload is skipped. Each player moves once per
//     simulated second (OURS model, the caller's); the client's real cadence
//     while walking is one OpMove every MIN_SEND_INTERVAL = 0.05 s
//     (client/scripts/World3D.gd:842, gate at :15135), 20 a second.
//   - Every player wears 13 items (every equipment.Slot), each +3, the
//     weapon and shield +7 (OURS, a full kit for the bytes); names are 12
//     characters.
//
// Run the table (about two minutes):
//
//	OPENSRO_CROWD736=1 go test -count=1 -p 1 -run 'TestCrowd736Measure' -v ./internal/session/
//
// OPENSRO_CROWD736_N picks the sizes (default "20,200,1000"). Without
// OPENSRO_CROWD736 only the N=20 smoke run (TestCrowd736Smoke) runs.

// opCrowdHello is the child's first frame on each connection: u32 index. A
// test-only opcode.
const opCrowdHello uint16 = 0xbe36

// crowdKit is the full kit every crowd player wears: every slot.
func crowdKit() []equipment.Slot {
	out := make([]equipment.Slot, 0, equipment.MaxEquipSlots)
	for s := 0; s < equipment.MaxEquipSlots; s++ {
		out = append(out, equipment.Slot(s))
	}
	return out
}

// crowdStores makes n characters, each in its own account, each in a full
// kit.
func crowdStores(t testing.TB, n int) (character.Store, equipment.Store, []*character.Character) {
	t.Helper()
	ctx := context.Background()
	chars := character.NewMemStore()
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	out := make([]*character.Character, n)
	for i := 0; i < n; i++ {
		c, err := chars.Create(ctx, int64(i+1), fmt.Sprintf("Crowd%07d", i)) // 12 characters
		if err != nil {
			t.Fatal(err)
		}
		out[i] = c
		for _, slot := range crowdKit() {
			plus := uint8(3)
			if slot == equipment.SlotWeapon || slot == equipment.SlotShield {
				plus = 7
			}
			item := int64(3700 + int(slot))
			if err := inv.AddItemInstance(ctx, c.ID, item, 1, inventory.Instance{OptLevel: plus}); err != nil {
				t.Fatal(err)
			}
			slots, _ := inv.List(ctx, c.ID)
			idx := -1
			for _, s := range slots {
				if s.ItemID == item {
					idx = s.Index
				}
			}
			if err := eq.Equip(ctx, c.ID, slot, idx); err != nil {
				t.Fatalf("equip %d slot %d: %v", c.ID, slot, err)
			}
		}
	}
	return chars, eq, out
}

// crowdChild is the parent's handle on the child process's connections.
type crowdChild struct {
	cmd *exec.Cmd
	in  io.WriteCloser
	out *bufio.Reader
}

// snap returns each connection's cumulative bytes and frames received.
func (c *crowdChild) snap(t testing.TB) (bytes, frames []int64) {
	b, f, _ := c.snap3(t)
	return b, f
}

// snap3 is snap with each connection's OpEntityMoved frames (round 737: the
// moves told apart from the spawns a block crossing adds).
func (c *crowdChild) snap3(t testing.TB) (bytes, frames, moves []int64) {
	t.Helper()
	if _, err := io.WriteString(c.in, "snap\n"); err != nil {
		t.Fatal(err)
	}
	for {
		line, err := c.out.ReadString('\n')
		if err != nil {
			t.Fatalf("child: %v", err)
		}
		if !strings.HasPrefix(line, "CROWD ") {
			continue
		}
		f := strings.Fields(line)[1:]
		bytes, frames, moves = make([]int64, len(f)/3), make([]int64, len(f)/3), make([]int64, len(f)/3)
		for i := range bytes {
			bytes[i], _ = strconv.ParseInt(f[3*i], 10, 64)
			frames[i], _ = strconv.ParseInt(f[3*i+1], 10, 64)
			moves[i], _ = strconv.ParseInt(f[3*i+2], 10, 64)
		}
		return bytes, frames, moves
	}
}

func (c *crowdChild) close() {
	_, _ = io.WriteString(c.in, "quit\n")
	_ = c.in.Close()
	done := make(chan struct{})
	go func() { _ = c.cmd.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = c.cmd.Process.Kill()
	}
}

func sumFrom(xs []int64, from, to int) int64 {
	var s int64
	for _, x := range xs[from:to] {
		s += x
	}
	return s
}

func diff(a, b []int64) []int64 {
	out := make([]int64, len(a))
	for i := range a {
		out[i] = a[i] - b[i]
	}
	return out
}

func cpuNow() time.Duration {
	var ru syscall.Rusage
	_ = syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

// crowdResult is one run's numbers.
type crowdResult struct {
	n                              int
	layout, drive                  string
	events                         int
	seconds                        int
	driveWall, drainWall, cpu      time.Duration
	rxBytes, rxFrames              int64 // received by the N movers over the run
	rxMoves, wantMoves             int64 // their OpEntityMoved frames, and the window rule's count (serial drive)
	enterErr                       error
	enterWall, leaveWall           time.Duration
	burstBytes, burstFrames        int64 // to the arriver
	enteredBytes, enteredFrames    int64 // to the N already there, summed
	leftBytes, leftFrames          int64
	maxClientBytes, minClientBytes int64
}

// runCrowd runs one layout at n players.
func runCrowd(t *testing.T, n int, layout, drive string, seconds int) crowdResult {
	t.Helper()
	ctx := context.Background()
	chars, eq, cs := crowdStores(t, n+1)
	hub := world.NewHub()

	sessions := make([]*gateway.Session, n+1)
	var hello sync.WaitGroup
	hello.Add(n + 1)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		Handle: func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
			if p.Opcode == opCrowdHello && len(p.Data) == 4 {
				sessions[binary.LittleEndian.Uint32(p.Data)] = sess
				hello.Done()
			}
			return nil
		}}
	sctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go srv.ListenAndServe(sctx)
	time.Sleep(50 * time.Millisecond)

	// The child: this binary, its own test-db lock directory (TestMain's
	// flock would otherwise wait on ours).
	cmd := exec.Command(os.Args[0], "-test.run", "^TestCrowd736Child$", "-test.count=1")
	cmd.Env = append(os.Environ(), "OPENSRO_CROWD736_CHILD="+addr,
		"OPENSRO_CROWD736_CONNS="+strconv.Itoa(n+1), "TMPDIR="+t.TempDir())
	cmd.Stderr = os.Stderr
	in, _ := cmd.StdinPipe()
	outPipe, _ := cmd.StdoutPipe()
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	child := &crowdChild{cmd: cmd, in: in, out: bufio.NewReader(outPipe)}
	defer child.close()
	waited := make(chan struct{})
	go func() { hello.Wait(); close(waited) }()
	select {
	case <-waited:
	case <-time.After(60 * time.Second):
		t.Fatal("the child's connections did not all say hello")
	}

	// The crowd: n players already standing there.
	rng := rand.New(rand.NewSource(736))
	span, origin := 960.0, -320.0 // town: one 3x3 window of 320-unit blocks around the arrival point (0,0)
	switch layout {
	case "field":
		span, origin = 3200.0, -1600.0 // a 10x10-block field
	case "block":
		// Round 737: everyone in one 320-unit block, all in view of all --
		// round 736's town as the bucket made it, to measure C2 alone.
		span, origin = 300.0, -310.0
	}
	pos := make([]world.Position, n)
	for i := 0; i < n; i++ {
		pos[i] = world.Position{X: origin + rng.Float64()*span, Z: origin + rng.Float64()*span}
		hub.Enter(sessions[i], cs[i].ID, cs[i].Name, cs[i].Level, spawnZone, pos[i])
	}
	// Round 737: each player's client holds the players in its view, as the
	// world entry leaves it (playerview.go) -- the production path, where
	// every move is checked against the recipient's known set.
	cur := append([]world.Position(nil), pos...) // where each stands, for the window rule below
	deps := viewDeps{hub: hub, eq: eq, chars: chars}
	for i := 0; i < n; i++ {
		invalidateLook(cs[i].ID)
		v := startPlayerView(cs[i].ID, sessions[i], deps)
		e, _ := hub.EntityBySession(sessions[i].ID())
		for _, o := range hub.ViewOfCharacter(e.CharacterID) {
			if o.CharacterID != e.CharacterID {
				v.known[o.CharacterID] = o.Arrival
			}
		}
	}
	defer func() {
		for i := 0; i <= n; i++ {
			forgetPlayerView(cs[i].ID, sessions[i])
		}
	}()

	quiet := func() ([]int64, []int64) {
		// Nothing more arriving for 150 ms.
		prev, _ := child.snap(t)
		for {
			time.Sleep(150 * time.Millisecond)
			b, f := child.snap(t)
			if sumFrom(b, 0, len(b)) == sumFrom(prev, 0, len(prev)) {
				return b, f
			}
			prev = b
		}
	}

	r := crowdResult{n: n, layout: layout, drive: drive, seconds: seconds}
	// The arrival, through the real enterOwned.
	b0, f0 := quiet()
	arriver := cs[n]
	owned, _ := chars.GetByID(ctx, arriver.ID)
	t0 := time.Now()
	r.enterErr = enterOwned(ctx, sessions[n], owned, chars, eq, hub, nil, nil)
	r.enterWall = time.Since(t0)
	b1, f1 := quiet()
	db, df := diff(b1, b0), diff(f1, f0)
	r.burstBytes, r.burstFrames = db[n], df[n]
	r.enteredBytes, r.enteredFrames = sumFrom(db, 0, n), sumFrom(df, 0, n)
	// And its leaving, through the real disconnect handler.
	t0 = time.Now()
	WorldDisconnectHandler(hub, nil)(sessions[n])
	r.leaveWall = time.Since(t0)
	b2, f2 := quiet()
	r.leftBytes, r.leftFrames = sumFrom(diff(b2, b1), 0, n), sumFrom(diff(f2, f1), 0, n)

	// The moves: every player once per simulated second.
	pkts := make([][]*proto.Packet, seconds)
	for s := range pkts {
		pkts[s] = make([]*proto.Packet, n)
		for i := 0; i < n; i++ {
			pos[i].X += rng.Float64()*10 - 5
			pos[i].Z += rng.Float64()*10 - 5
			pkts[s][i] = &proto.Packet{Opcode: OpMove, Data: (&MoveRequest{X: float32(pos[i].X), Z: float32(pos[i].Z)}).Encode()}
		}
	}
	r.events = n * seconds
	// The window rule (round 737): a move reaches the others whose block is
	// within one of the mover's new block, counted here as the serial drive
	// makes them (each mover's position as of its own move).
	_, _, m2 := child.snap3(t)
	cpu0 := cpuNow()
	t0 = time.Now()
	for s := 0; s < seconds; s++ {
		order := rng.Perm(n)
		if drive == "parallel" {
			// One goroutine per mover, as the gateway's read loops are.
			var wg sync.WaitGroup
			wg.Add(n)
			for _, i := range order {
				go func(i int) {
					defer wg.Done()
					_ = handleMove(sessions[i], pkts[s][i], hub, nil)
				}(i)
			}
			wg.Wait()
		} else {
			for _, i := range order {
				_ = handleMove(sessions[i], pkts[s][i], hub, nil)
				// A player that sees the mover before and after the move is
				// sent it; one that sees it only after is spawned it instead
				// (the 0x3015 carries the position), and one that saw it
				// only before is despawned.
				m, _ := DecodeMoveRequest(pkts[s][i].Data)
				co := world.CellOf(spawnZone, cur[i])
				cur[i] = world.Position{X: float64(m.X), Z: float64(m.Z)}
				ci := world.CellOf(spawnZone, cur[i])
				for j := 0; j < n; j++ {
					cj := world.CellOf(spawnZone, cur[j])
					if j != i && world.InView(ci, cj) && world.InView(co, cj) {
						r.wantMoves++
					}
				}
			}
		}
	}
	r.driveWall = time.Since(t0)
	b3, last := settleQuiet(t, child, n)
	r.drainWall = last.Sub(t0)
	r.cpu = cpuNow() - cpu0
	_, f3, m3 := child.snap3(t)
	mb, mf := diff(b3, b2), diff(f3, f2)
	r.rxBytes, r.rxFrames = sumFrom(mb, 0, n), sumFrom(mf, 0, n)
	r.rxMoves = sumFrom(diff(m3, m2), 0, n)
	r.minClientBytes, r.maxClientBytes = mb[0], mb[0]
	for _, x := range mb[:n] {
		r.minClientBytes = min(r.minClientBytes, x)
		r.maxClientBytes = max(r.maxClientBytes, x)
	}
	if drive != "parallel" && r.rxMoves != r.wantMoves {
		t.Errorf("n=%d %s: the movers received %d OpEntityMoved, the window rule says %d", n, layout, r.rxMoves, r.wantMoves)
	}
	return r
}

// settleQuiet waits until the n movers' byte counts have not changed for
// 300 ms and returns them with the time of the last change seen (the drain's
// end, to within the 10 ms poll).
func settleQuiet(t *testing.T, child *crowdChild, n int) ([]int64, time.Time) {
	t.Helper()
	b, _ := child.snap(t)
	last := time.Now()
	deadline := last.Add(180 * time.Second)
	for time.Since(last) < 300*time.Millisecond && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
		nb, _ := child.snap(t)
		if sumFrom(nb, 0, n) != sumFrom(b, 0, n) {
			b, last = nb, time.Now()
		}
	}
	return b, last
}

func (r crowdResult) log(t *testing.T) {
	sec := float64(r.seconds)
	n := float64(r.n)
	enter := "ok"
	if r.enterErr != nil {
		enter = "FAILED: " + r.enterErr.Error()
	}
	rule := "n/a: a parallel drive's order is the scheduler's"
	if r.drive != "parallel" {
		rule = strconv.FormatInt(r.wantMoves, 10)
	}
	t.Logf("CROWD736 n=%d layout=%s drive=%s | moves/s=%d ns/move=%.0f wall-ms/sim-s=%.1f delivered-ms/sim-s=%.1f cpu-ms/sim-s=%.1f | per-client pkts/s=%.1f KB/s=%.2f (min %.2f max %.2f) | total MB/s=%.3f pkts/s=%.0f | moves delivered %d (window rule %s)",
		r.n, r.layout, r.drive, r.n,
		float64(r.driveWall.Nanoseconds())/float64(r.events),
		float64(r.driveWall.Microseconds())/1000/sec, float64(r.drainWall.Microseconds())/1000/sec, float64(r.cpu.Microseconds())/1000/sec,
		float64(r.rxFrames)/n/sec, float64(r.rxBytes)/n/sec/1000,
		float64(r.minClientBytes)/sec/1000, float64(r.maxClientBytes)/sec/1000,
		float64(r.rxBytes)/sec/1e6, float64(r.rxFrames)/sec, r.rxMoves, rule)
	t.Logf("CROWD736 n=%d layout=%s | enter %s in %v: arriver got %d frames / %d bytes (MaxPayload %d); the %d present got %d frames / %d bytes | leave in %v: %d frames / %d bytes",
		r.n, r.layout, enter, r.enterWall, r.burstFrames, r.burstBytes, proto.MaxPayload,
		r.n, r.enteredFrames, r.enteredBytes, r.leaveWall, r.leftFrames, r.leftBytes)
}

// TestCrowd736Child is the child process's side: it dials the parent's
// server OPENSRO_CROWD736_CONNS times, says hello on each, drains each socket
// counting bytes and frames, and answers "snap" on stdin with the counts.
func TestCrowd736Child(t *testing.T) {
	addr := os.Getenv("OPENSRO_CROWD736_CHILD")
	if addr == "" {
		t.Skip("the child process of TestCrowd736Smoke/Measure")
	}
	n, _ := strconv.Atoi(os.Getenv("OPENSRO_CROWD736_CONNS"))
	bytes := make([]atomic.Int64, n)
	frames := make([]atomic.Int64, n)
	moves := make([]atomic.Int64, n)
	conns := make([]net.Conn, n)
	for i := 0; i < n; i++ {
		var c net.Conn
		var err error
		for k := 0; k < 100; k++ {
			if c, err = net.Dial("tcp", addr); err == nil {
				break
			}
			time.Sleep(10 * time.Millisecond)
		}
		if err != nil {
			t.Fatal(err)
		}
		conns[i] = c
		hello := make([]byte, 4)
		binary.LittleEndian.PutUint32(hello, uint32(i))
		if err := proto.Write(c, &proto.Packet{Opcode: opCrowdHello, Data: hello}, nil, nil); err != nil {
			t.Fatal(err)
		}
		go func(i int, c net.Conn) {
			buf := make([]byte, 64<<10)
			var hdr [6]byte
			have, need := 0, 0 // header bytes held; payload bytes still owed
			for {
				k, err := c.Read(buf)
				bytes[i].Add(int64(k))
				p := buf[:k]
				for len(p) > 0 {
					if need > 0 {
						step := min(need, len(p))
						need -= step
						p = p[step:]
						continue
					}
					step := min(6-have, len(p))
					copy(hdr[have:], p[:step])
					have += step
					p = p[step:]
					if have == 6 {
						frames[i].Add(1)
						if binary.LittleEndian.Uint16(hdr[2:]) == OpEntityMoved {
							moves[i].Add(1)
						}
						need = int(binary.LittleEndian.Uint16(hdr[:]) & proto.MaxPayload)
						have = 0
					}
				}
				if err != nil {
					return
				}
			}
		}(i, c)
	}
	sc := bufio.NewScanner(os.Stdin)
	w := bufio.NewWriter(os.Stdout)
	for sc.Scan() {
		switch sc.Text() {
		case "snap":
			w.WriteString("CROWD")
			for i := 0; i < n; i++ {
				fmt.Fprintf(w, " %d %d %d", bytes[i].Load(), frames[i].Load(), moves[i].Load())
			}
			w.WriteString("\n")
			w.Flush()
		case "quit":
			for _, c := range conns {
				c.Close()
			}
			return
		}
	}
}

// TestCrowd736Smoke is the N=20 run, always on: each move reaches the 19
// others as one 26-byte OpEntityMoved, the arrival burst fits, and the
// arrival list's frame limit is where the encoder says.
func TestCrowd736Smoke(t *testing.T) {
	if os.Getenv("OPENSRO_CROWD736_CHILD") != "" {
		t.Skip("child")
	}
	r := runCrowd(t, 20, "town", "serial", 5)
	r.log(t)
	if r.enterErr != nil {
		t.Fatalf("enter at n=20: %v", r.enterErr)
	}
	// Round 737: the moves reach exactly the players in view (runCrowd checks
	// the count against the window rule); the arrival is a 0x3015 to each of
	// the 20 present (all in its 3 x 3 blocks), after its zone notice (round
	// 737's review), and group spawns to it; the
	// leave a notice and a 0x3016 to each.
	if r.rxMoves == 0 || r.rxMoves != r.wantMoves {
		t.Fatalf("moves: %d delivered, the window rule says %d", r.rxMoves, r.wantMoves)
	}
	if r.enteredFrames != 40 || r.leftFrames != 40 {
		t.Fatalf("entered %d, left %d, want 40 each (an OpPlayerZoneNotice and the spawn or despawn, to each of 20)", r.enteredFrames, r.leftFrames)
	}
	if r.burstFrames < 3 {
		t.Fatalf("the arriver got %d frames, want its group spawns", r.burstFrames)
	}
}

// TestCrowd736Measure is the table: N = 20 / 200 / 1000 (OPENSRO_CROWD736_N),
// the town (one 3x3 window) and the field (10x10 blocks) driven serially,
// and the town again with one goroutine per mover.
func TestCrowd736Measure(t *testing.T) {
	if os.Getenv("OPENSRO_CROWD736") == "" || os.Getenv("OPENSRO_CROWD736_CHILD") != "" {
		t.Skip("set OPENSRO_CROWD736=1 to run the crowd table")
	}
	sizes := []int{20, 200, 1000}
	if s := os.Getenv("OPENSRO_CROWD736_N"); s != "" {
		sizes = nil
		for _, f := range strings.Split(s, ",") {
			v, _ := strconv.Atoi(f)
			sizes = append(sizes, v)
		}
	}
	for _, n := range sizes {
		seconds := max(3, 4000/n)
		layouts := [][2]string{{"town", "serial"}, {"field", "serial"}, {"town", "parallel"}, {"block", "serial"}, {"block", "parallel"}}
		if s := os.Getenv("OPENSRO_CROWD736_LAYOUTS"); s != "" {
			layouts = nil
			for _, f := range strings.Split(s, ",") {
				if l, d, ok := strings.Cut(f, "/"); ok {
					layouts = append(layouts, [2]string{l, d})
				}
			}
		}
		for _, run := range layouts {
			r := runCrowd(t, n, run[0], run[1], seconds)
			r.log(t)
		}
	}
}

// BenchmarkCrowd736HubMove is the part of a move done under the world hub's
// write lock (world.Hub.Relocate): the position written, the block refiled
// entity in the bucket copied out. Every mover in the bucket serialises on
// it.
func BenchmarkCrowd736HubMove(b *testing.B) {
	for _, n := range []int{20, 200, 1000} {
		b.Run(fmt.Sprintf("n=%d", n), func(b *testing.B) {
			hub := world.NewHub()
			sess := make([]*gateway.Session, n)
			for i := range sess {
				sess[i] = gateway.NewTestSession(uint64(i + 1))
				hub.Enter(sess[i], int64(i+1), "Crowd0000000", 1, spawnZone, world.Position{X: float64(i)})
			}
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				hub.Relocate(sess[i%n], world.Position{X: float64(i % 640), Z: 1}, world.MoveWalk, 0)
			}
		})
	}
}
