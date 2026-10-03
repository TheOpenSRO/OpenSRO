package session

import (
	"bufio"
	"context"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 656's list harness: a gateway server whose handler puts each
// connection in the world on its first packet (opHelloForTest: s64 character
// id, f32 x, f32 z) and answers OpMonsterList with the real handler, keeping
// the handler's error. Only public session APIs, so the file builds on the
// base revision too, where the negative below fails.
const opHelloForTest uint16 = 0x7ffe

type listRig struct {
	hub      *world.Hub
	monsters *combat.Hub
	addr     string
	mu       sync.Mutex
	sessions map[int64]*gateway.Session
	errs     chan error
}

func newListRig(t *testing.T, monsters *combat.Hub) *listRig {
	t.Helper()
	r := &listRig{hub: world.NewHub(), monsters: monsters, sessions: map[int64]*gateway.Session{}, errs: make(chan error, 64)}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	r.addr = ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: r.addr, Handle: func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case opHelloForTest:
			id := int64(leUint64(p.Data[0:8]))
			x, _, _ := decodeFloat32(p.Data[8:12])
			z, _, _ := decodeFloat32(p.Data[12:16])
			r.hub.Enter(sess, id, "p", 1, "jangan", world.Position{X: float64(x), Z: float64(z)})
			r.mu.Lock()
			r.sessions[id] = sess
			r.mu.Unlock()
			return nil
		case OpMonsterList:
			err := handleMonsterList(sess, r.hub, r.monsters, monsterListPagedAsked(p.Data))
			r.errs <- err
			return err
		}
		return nil
	}}
	ctx, cancel := context.WithCancel(context.Background())
	go srv.ListenAndServe(ctx)
	t.Cleanup(cancel)
	return r
}

func leUint64(b []byte) uint64 {
	var v uint64
	for i := 7; i >= 0; i-- {
		v = v<<8 | uint64(b[i])
	}
	return v
}

// listClient is one test connection and its framed reader.
type listClient struct {
	conn net.Conn
	r    *bufio.Reader
}

// join dials the rig and enters the world as character id at (x, z), waiting
// until the hub holds it.
func (r *listRig) join(t *testing.T, id int64, x, z float64) *listClient {
	t.Helper()
	var conn net.Conn
	var err error
	for i := 0; i < 50; i++ {
		if conn, err = net.DialTimeout("tcp", r.addr, 100*time.Millisecond); err == nil {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { conn.Close() })
	hello := append(encodeInt64(id), encodeFloat32(float32(x))...)
	hello = append(hello, encodeFloat32(float32(z))...)
	if err := proto.Write(conn, &proto.Packet{Opcode: opHelloForTest, Data: hello}, nil, nil); err != nil {
		t.Fatalf("hello: %v", err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		if _, ok := r.hub.EntityByCharacterID(id); ok {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the player never entered the world")
		}
		time.Sleep(5 * time.Millisecond)
	}
	return &listClient{conn: conn, r: bufio.NewReader(conn)}
}

// session is the server's session for character id.
func (r *listRig) session(id int64) *gateway.Session {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.sessions[id]
}

// read reads one frame, failing the test after 3 s.
func (c *listClient) read(t *testing.T) *proto.Packet {
	t.Helper()
	c.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	p, err := proto.Read(c.r, nil, nil)
	if err != nil {
		t.Fatalf("reading a frame: %v", err)
	}
	return p
}

// list asks for the monster list, announcing that it takes pages, and gathers every OpMonsterListResult frame
// until it holds want records, returning them and how many frames carried
// them. A handler error fails the test with it.
func (r *listRig) list(t *testing.T, c *listClient, want int) ([]MonsterSnapshot, int) {
	t.Helper()
	return r.listAs(t, c, want, []byte{MonsterListFlagPaged})
}

// listAs is list with the request's payload given: nil is a client that
// predates the capability byte.
func (r *listRig) listAs(t *testing.T, c *listClient, want int, req []byte) ([]MonsterSnapshot, int) {
	t.Helper()
	if err := proto.Write(c.conn, &proto.Packet{Opcode: OpMonsterList, Data: req}, nil, nil); err != nil {
		t.Fatalf("asking for the list: %v", err)
	}
	select {
	case err := <-r.errs:
		if err != nil {
			t.Fatalf("handleMonsterList: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("handleMonsterList never returned")
	}
	var got []MonsterSnapshot
	frames := 0
	for len(got) < want || frames == 0 {
		p := c.read(t)
		if p.Opcode != OpMonsterListResult {
			continue
		}
		frames++
		lr, err := DecodeMonsterListResult(p.Data)
		if err != nil || lr.Error != "" {
			t.Fatalf("frame %d: %v %+v", frames, err, lr)
		}
		got = append(got, lr.Monsters...)
	}
	return got, frames
}

// NEGATIVE (round 656): a list larger than one frame is sent as several and
// arrives whole. 1,500 monsters around the player encode to about 100 KB --
// three times proto.MaxPayload -- and on the base revision proto.Write
// refuses the one frame, handleMonsterList returns that error and the gateway
// closes the session (docs/TODO.md, the 32,767-byte cap).
func TestMonsterListLargerThanAFramePages(t *testing.T) {
	monsters := combat.NewHub()
	const n = 1500
	want := map[int64]bool{}
	for i := 0; i < n; i++ {
		// 12 units apart (round 664): all 1,500 inside the 3 x 3 block window.
		m := monsters.SpawnSpecies("jangan", combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", Level: 1},
			float64(i%40)*12-240, 0, float64(i/40)*12-240, 30, 1, 1, 1)
		want[m.ID] = true
	}
	r := newListRig(t, monsters)
	c := r.join(t, 1, 0, 0)
	got, frames := r.list(t, c, n)
	if frames < 2 {
		t.Errorf("%d monsters came in %d frame(s), want several", n, frames)
	}
	seen := map[int64]bool{}
	for _, m := range got {
		if !want[m.ID] {
			t.Errorf("monster %d listed, never spawned", m.ID)
		}
		if seen[m.ID] {
			t.Errorf("monster %d listed twice", m.ID)
		}
		seen[m.ID] = true
		if m.Name != "Mangyang" || m.CodeName != "MOB_CH_MANGNYANG" || m.MaxHP != 30 {
			t.Errorf("monster %d garbled across a page boundary: %+v", m.ID, m)
		}
	}
	if len(seen) != n {
		t.Errorf("%d of %d monsters arrived", len(seen), n)
	}
}

// Round 656's review: a client that does not announce MonsterListFlagPaged (an
// empty request, every client before round 656) gets the old form -- one
// frame, no trailer -- holding the monsters nearest to it that fit.
func TestMonsterListWithoutTheFlagIsOneFrameOfTheNearest(t *testing.T) {
	monsters := combat.NewHub()
	for i := 0; i < 1500; i++ {
		monsters.SpawnSpecies("jangan", combat.Species{Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", Level: 1},
			float64(i%40)*20-400, 0, float64(i/40)*20-400, 30, 1, 1, 1)
	}
	r := newListRig(t, monsters)
	c := r.join(t, 1, 0, 0)
	if err := proto.Write(c.conn, &proto.Packet{Opcode: OpMonsterList}, nil, nil); err != nil {
		t.Fatal(err)
	}
	if err := <-r.errs; err != nil {
		t.Fatalf("handleMonsterList: %v", err)
	}
	p := c.read(t)
	lr, err := DecodeMonsterListResult(p.Data)
	if err != nil || lr.Error != "" {
		t.Fatalf("%v %+v", err, lr)
	}
	if lr.Pages != 0 || len(p.Data) > proto.MaxPayload || len(lr.Monsters) < 400 || len(lr.Monsters) >= 1500 {
		t.Fatalf("an unflagged list: %d monsters in %d bytes, pages %d; want one frame of the nearest, no trailer",
			len(lr.Monsters), len(p.Data), lr.Pages)
	}
	farthestKept := 0.0
	kept := map[int64]bool{}
	for _, m := range lr.Monsters {
		kept[m.ID] = true
		farthestKept = max(farthestKept, float64(m.X)*float64(m.X)+float64(m.Z)*float64(m.Z))
	}
	for _, m := range monsters.InZone("jangan") {
		if !kept[m.ID] && m.X*m.X+m.Z*m.Z < farthestKept {
			t.Fatalf("monster %d at %.0f,%.0f was left out for a farther one", m.ID, m.X, m.Z)
		}
	}
	for _, extra := range c.quiet(t, 150*time.Millisecond) {
		t.Errorf("a second frame after the unflagged list: %#04x", extra.Opcode)
	}
}
