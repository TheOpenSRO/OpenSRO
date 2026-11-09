package main

// The multi-process integration test (round 869 lane W2,
// docs/protocol/game_worlds.md 14 SERVER item 11): this package's binary
// run as four processes on one host -- a front, the open world's host and
// two instance hosts -- on a PostgreSQL the test owns
// (OPENSRO_TEST_CLUSTER_DSN; a throwaway database, never a live one), and
// characters driven through the front on the client's own wire: the
// placement on the least-loaded host, the hand-off in and back out, a
// whisper and a party line across processes, a host killed with a player
// inside (recovered at its return point), and a drain.

import (
	"bufio"
	"context"
	"database/sql"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
)

// clusterDSN is the test's own database, or "" (the test is skipped).
func clusterDSN() string { return os.Getenv("OPENSRO_TEST_CLUSTER_DSN") }

func freePort(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().String()
}

// synthWorlds writes a game-world export with the open world and world 63
// (50 layers of 4, 2 h, 10 min empty close, a start in region 0x7EE4):
// the spec's numbers, no game files.
func synthWorlds(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	write := func(name string, tab *reftable.Table) {
		f, err := os.Create(filepath.Join(dir, name+".csv"))
		if err != nil {
			t.Fatal(err)
		}
		defer f.Close()
		if err := tab.WriteCSV(f); err != nil {
			t.Fatal(err)
		}
	}
	w := reftable.New("ID", "WorldCodeName128", "Type", "WorldMaxCount", "WorldMaxUserCount", "WorldEntryType",
		"WorldEntranceType", "WorldLeaveType", "WorldDurationTime", "WorldEmptyRemainTime", "ConfigGroupCodeName128")
	w.Append("1", "INS_DEFAULT", "0", "1", "0", "0", "0", "0", "0", "0", "xxx")
	w.Append("63", "INS_GOD_TOGUI_35_50_LEVEL_1", "1", "50", "4", "0", "0", "0", "7200000", "600000", "G63")
	write(gameworld.TableWorld, w)
	r := reftable.New("WorldID", "RegionID")
	for _, rid := range []int{0x7EE4, 0x7EE3} {
		r.Append("63", fmt.Sprint(rid))
	}
	write(gameworld.TableRegion, r)
	sp := reftable.New("WorldID", "RegionID", "PosX", "PosY", "PosZ", "Param")
	sp.Append("63", fmt.Sprint(0x7EE4), "1063", "693", "1125", "0")
	write(gameworld.TableStartPos, sp)
	return dir
}

// proc is one server process.
type proc struct {
	name string
	cmd  *exec.Cmd
	log  string
}

func (p *proc) tail() string {
	b, _ := os.ReadFile(p.log)
	s := string(b)
	if len(s) > 6000 {
		s = s[len(s)-6000:]
	}
	return s
}

func (p *proc) waitLog(t *testing.T, what string, d time.Duration) {
	t.Helper()
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if b, _ := os.ReadFile(p.log); strings.Contains(string(b), what) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("%s: no %q in its log:\n%s", p.name, what, p.tail())
}

// tclient is a character on the client's wire.
type tclient struct {
	t    *testing.T
	name string
	conn net.Conn
	mu   sync.Mutex
	got  []*proto.Packet
	wake chan struct{}
	char int64
}

func dialClient(t *testing.T, addr, name string) *tclient {
	t.Helper()
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	c := &tclient{t: t, name: name, conn: conn, wake: make(chan struct{}, 1)}
	go func() {
		r := bufio.NewReader(conn)
		for {
			p, err := proto.Read(r, nil, nil)
			if err != nil {
				return
			}
			if p.Opcode == session.OpChangeZoneResult {
				// The client's loading is done at once.
				c.send(session.OpReadyToPlay, nil)
			}
			c.mu.Lock()
			c.got = append(c.got, p)
			c.mu.Unlock()
			select {
			case c.wake <- struct{}{}:
			default:
			}
		}
	}()
	t.Cleanup(func() { conn.Close() })
	return c
}

func (c *tclient) send(op uint16, data []byte) {
	_ = proto.Write(c.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil)
}

// wait takes the first packet since the last wait matching ok.
func (c *tclient) wait(what string, d time.Duration, ok func(*proto.Packet) bool) *proto.Packet {
	c.t.Helper()
	end := time.Now().Add(d)
	for {
		c.mu.Lock()
		for i, p := range c.got {
			if ok(p) {
				c.got = append(c.got[:i:i], c.got[i+1:]...)
				c.mu.Unlock()
				return p
			}
		}
		c.mu.Unlock()
		left := time.Until(end)
		if left <= 0 {
			c.t.Fatalf("%s: no %s in %v", c.name, what, d)
		}
		select {
		case <-c.wake:
		case <-time.After(left):
		}
	}
}

func (c *tclient) op(op uint16) func(*proto.Packet) bool {
	return func(p *proto.Packet) bool { return p.Opcode == op }
}

func (c *tclient) zone(d time.Duration) *session.ChangeZoneResult {
	c.t.Helper()
	p := c.wait("a zone change", d, c.op(session.OpChangeZoneResult))
	r, err := session.DecodeChangeZoneResult(p.Data)
	if err != nil || !r.OK {
		c.t.Fatalf("%s: zone change %+v %v", c.name, r, err)
	}
	return r
}

func (c *tclient) gm(line string) string {
	c.t.Helper()
	c.send(session.OpGMCommand, (&session.GMCommandRequest{Name: c.name, Line: line}).Encode())
	p := c.wait("the GM answer to "+line, 10*time.Second, c.op(session.OpGMCommandResult))
	r, _ := session.DecodeGMCommandResult(p.Data)
	return r.Text
}

func (c *tclient) chat(kind byte, target, text string) {
	c.send(session.OpChatSend, (&session.ChatSendRequest{Type: kind, Target: target, Message: text}).Encode())
}

func (c *tclient) heard(kind byte, text string, d time.Duration) {
	c.t.Helper()
	c.wait(fmt.Sprintf("chat %d %q", kind, text), d, func(p *proto.Packet) bool {
		if p.Opcode != session.OpChatUpdate {
			return false
		}
		u, err := session.DecodeChatUpdate(p.Data)
		return err == nil && u.Type == kind && u.Message == text
	})
}

func (c *tclient) login(user string) {
	c.t.Helper()
	c.send(session.OpLogin, (&session.LoginRequest{Username: user, Password: "pw"}).Encode())
	p := c.wait("the login result", 10*time.Second, c.op(session.OpLoginResult))
	if lr, err := session.DecodeLoginResult(p.Data); err != nil || !lr.OK {
		c.t.Fatalf("%s: login %+v %v", c.name, lr, err)
	}
	c.send(session.OpStart, (&session.StartRequest{Name: c.name}).Encode())
	p = c.wait("the world entry", 10*time.Second, c.op(session.OpEnterWorldResult))
	if er, err := session.DecodeEnterWorldResult(p.Data); err != nil || !er.OK {
		c.t.Fatalf("%s: enter %+v %v", c.name, er, err)
	}
	c.send(session.OpReadyToPlay, nil)
}

// pings is n echo round trips of c (OpPing, OURS), sorted.
func (c *tclient) pings(n int) []time.Duration {
	c.t.Helper()
	var out []time.Duration
	for i := 0; i < n; i++ {
		tok := []byte{byte(i), byte(i >> 8), 0x86, 0x9}
		start := time.Now()
		c.send(session.OpPing, tok)
		c.wait("a ping echo", 5*time.Second, func(p *proto.Packet) bool {
			return p.Opcode == session.OpPingEcho && string(p.Data) == string(tok)
		})
		out = append(out, time.Since(start))
	}
	sort.Slice(out, func(i, j int) bool { return out[i] < out[j] })
	return out
}

func p50p99(ds []time.Duration) string {
	return fmt.Sprintf("p50 %v p99 %v", ds[len(ds)/2].Round(time.Microsecond), ds[len(ds)*99/100].Round(time.Microsecond))
}

// hostOf is where the registry has a character.
func hostOf(t *testing.T, db *sql.DB, char int64) string {
	t.Helper()
	var h string
	db.QueryRow(`SELECT host FROM world_presence WHERE character = $1`, char).Scan(&h)
	return h
}

func waitHost(t *testing.T, db *sql.DB, char int64, want func(string) bool, what string) string {
	t.Helper()
	end := time.Now().Add(10 * time.Second)
	for time.Now().Before(end) {
		if h := hostOf(t, db, char); want(h) {
			return h
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("character %d: %s (presence %q)", char, what, hostOf(t, db, char))
	return ""
}

func TestClusterFourProcesses(t *testing.T) {
	dsn := clusterDSN()
	if dsn == "" {
		t.Skip("OPENSRO_TEST_CLUSTER_DSN is not set (a throwaway PostgreSQL database for the multi-process test)")
	}
	release := testdb.Lock(dsn)
	defer release()
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.Ping(); err != nil {
		t.Skipf("no PostgreSQL at the cluster DSN: %v", err)
	}
	ctx := context.Background()
	dir := t.TempDir()
	bin := filepath.Join(dir, "opensro-server")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	// Clean registry rows from an earlier run (the tables exist once a
	// server has started on this database).
	db.Exec(`TRUNCATE world_hosts, world_instances, world_instance_members, world_presence, world_returns`)

	// The characters, made in the shared database.
	accounts, err := account.NewSQLStore(db)
	if err != nil {
		t.Fatal(err)
	}
	chars, err := character.NewSQLStore(db)
	if err != nil {
		t.Fatal(err)
	}
	suffix := fmt.Sprintf("%x", time.Now().UnixNano()&0xffffff)
	names := []string{"Ari" + suffix, "Bra" + suffix, "Cat" + suffix}
	ids := map[string]int64{}
	var users []string
	for _, n := range names {
		user := strings.ToLower(n)
		users = append(users, user)
		a, err := accounts.Register(ctx, user, "pw")
		if err != nil {
			t.Fatal(err)
		}
		c, err := chars.Create(ctx, a.ID, n)
		if err != nil {
			t.Fatal(err)
		}
		ids[n] = c.ID
	}
	worlds := synthWorlds(t)
	// A level table so /level works (synthetic numbers: the test needs
	// levels, not the game's curve).
	levels := filepath.Join(dir, "leveldata.csv")
	var lv strings.Builder
	lv.WriteString("level,exp\n")
	for i := 1; i <= 60; i++ {
		fmt.Fprintf(&lv, "%d,%d\n", i, 1000*i)
	}
	if err := os.WriteFile(levels, []byte(lv.String()), 0o644); err != nil {
		t.Fatal(err)
	}
	secret := "it-secret-" + suffix
	front, homeRelay, homeAddr := freePort(t), freePort(t), freePort(t)
	w1Relay, w2Relay := freePort(t), freePort(t)
	start := func(name string, args ...string) *proc {
		p := &proc{name: name, log: filepath.Join(dir, name+".log")}
		f, err := os.Create(p.log)
		if err != nil {
			t.Fatal(err)
		}
		base := []string{"-postgres-dsn", dsn, "-gameworld-dir", worlds, "-gm-accounts", strings.Join(users, ","), "-leveldata-csv", levels,
			"-metrics-addr", freePort(t), "-host-lease", "3s", "-drain-deadline", "3s", "-persist-position=true"}
		p.cmd = exec.Command(bin, append(base, args...)...)
		p.cmd.Env = append(os.Environ(), "OPENSRO_RELAY_SECRET="+secret)
		p.cmd.Stdout, p.cmd.Stderr = f, f
		if err := p.cmd.Start(); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if p.cmd.ProcessState == nil {
				p.cmd.Process.Kill()
				p.cmd.Wait()
			}
			if t.Failed() || os.Getenv("OPENSRO_TEST_CLUSTER_LOGS") != "" {
				t.Logf("---- %s ----\n%s", p.name, p.tail())
			}
		})
		return p
	}
	home := start("home", "-role", "world", "-world-layers", "open", "-host-id", "home", "-relay-listen", homeRelay, "-addr", homeAddr)
	home.waitLog(t, "cluster joined", 60*time.Second)
	w1 := start("w1", "-role", "world", "-world-layers", "instances", "-host-id", "w1", "-relay-listen", w1Relay)
	w2 := start("w2", "-role", "world", "-world-layers", "instances", "-host-id", "w2", "-relay-listen", w2Relay)
	w1.waitLog(t, "cluster joined", 60*time.Second)
	w2.waitLog(t, "cluster joined", 60*time.Second)
	fr := start("front", "-role", "front", "-host-id", "front", "-addr", front)
	fr.waitLog(t, "front ready", 30*time.Second)

	a := dialClient(t, front, names[0])
	b := dialClient(t, front, names[1])
	c := dialClient(t, front, names[2])
	for i, cl := range []*tclient{a, b, c} {
		cl.login(users[i])
		cl.char = ids[cl.name]
		waitHost(t, db, cl.char, func(h string) bool { return h == "home" }, "on the open world's host after its login")
		cl.gm("/level 40")
	}

	// The relay's added latency: echoes through the front against echoes
	// straight from the open world's host's own listener.
	direct := dialClient(t, homeAddr, "direct")
	viaFront, straight := a.pings(200), direct.pings(200)
	t.Logf("ping through the front %s; straight to the host %s", p50p99(viaFront), p50p99(straight))

	// A party of Aria and Bram, formed in the open world.
	a.send(party.OpCreate, party.EncodeCreate(party.JIDOf(b.char), party.FlagItemShare))
	b.wait("the party invitation", 10*time.Second, b.op(party.OpInvitation))
	b.send(party.OpInvitation, party.EncodeAnswerYes())
	a.wait("the party formed", 10*time.Second, a.op(party.OpCreateAck))

	// 1. Aria opens a layer: it is placed on an instance host, and she is
	// handed off there with the ordinary zone change.
	text := a.gm("/instance 63")
	if !strings.HasPrefix(text, "opened and entered 63.1") {
		t.Fatalf("/instance 63: %q", text)
	}
	inA := a.zone(10 * time.Second)
	hostA := waitHost(t, db, a.char, func(h string) bool { return h == "w1" || h == "w2" }, "on an instance host after the hand-off")
	if inA.Zone == "" || inA.FrameRegion == "" {
		t.Fatalf("the instance's zone change %+v", inA)
	}
	other := map[string]string{"w1": "w2", "w2": "w1"}[hostA]

	t.Logf("ping through the front to the instance host: %s", p50p99(a.pings(200)))

	// 2. Across processes: a whisper each way, a party line each way.
	b.chat(session.ChatWhisper, a.name, "to the instance")
	a.heard(session.ChatWhisper, "to the instance", 5*time.Second)
	a.chat(session.ChatWhisper, b.name, "from the instance")
	b.heard(session.ChatWhisper, "from the instance", 5*time.Second)
	a.chat(session.ChatParty, "", "party from inside")
	b.heard(session.ChatParty, "party from inside", 5*time.Second)
	b.chat(session.ChatParty, "", "party from outside")
	a.heard(session.ChatParty, "party from outside", 5*time.Second)

	// 3. Bram follows into the same layer (on the same host); Cato opens a
	// second layer, placed on the other host (the least loaded).
	if text := b.gm("/instance enter 63.1"); !strings.HasPrefix(text, "entered 63.1") {
		t.Fatalf("/instance enter: %q", text)
	}
	b.zone(10 * time.Second)
	waitHost(t, db, b.char, func(h string) bool { return h == hostA }, "in Aria's layer's host")
	if text := c.gm("/instance 63"); !strings.HasPrefix(text, "opened and entered 63.2") {
		t.Fatalf("Cato's /instance 63: %q", text)
	}
	c.zone(10 * time.Second)
	waitHost(t, db, c.char, func(h string) bool { return h == other }, "on the other instance host")
	// A party line inside one process still works after both moved.
	a.chat(session.ChatParty, "", "both inside")
	b.heard(session.ChatParty, "both inside", 5*time.Second)

	// 4. Aria leaves: back to the open world's host, where she stood.
	if text := a.gm("/instance leave"); !strings.HasPrefix(text, "left 63.1") {
		t.Fatalf("/instance leave: %q", text)
	}
	back := a.zone(10 * time.Second)
	waitHost(t, db, a.char, func(h string) bool { return h == "home" }, "back on the open world's host")
	if back.Zone == inA.Zone {
		t.Fatalf("the way out landed in the instance's zone %+v", back)
	}

	// 5. Cato's host dies (kill -9): the front recovers him on the open
	// world's host at his return point; the reaper declares the host dead
	// and his layer lost.
	victim := map[string]*proc{"w1": w1, "w2": w2}[other]
	victim.cmd.Process.Signal(syscall.SIGKILL)
	victim.cmd.Wait()
	killed := time.Now()
	c.zone(15 * time.Second)
	recovered := time.Since(killed)
	waitHost(t, db, c.char, func(h string) bool { return h == "home" }, "recovered on the open world's host")
	end := time.Now().Add(15 * time.Second)
	var state string
	for time.Now().Before(end) {
		db.QueryRow(`SELECT state FROM world_hosts WHERE id = $1`, other).Scan(&state)
		if state == "dead" {
			break
		}
		time.Sleep(100 * time.Millisecond)
	}
	var lost int
	db.QueryRow(`SELECT count(*) FROM world_instances WHERE host = $1 AND state = 'lost'`, other).Scan(&lost)
	if state != "dead" || lost != 1 {
		t.Fatalf("after the kill: host %s %q, %d lost layers", other, state, lost)
	}
	t.Logf("kill -9 of %s: Cato back in the open world after %v", other, recovered.Round(time.Millisecond))

	// 6. The drain: SIGTERM to Bram's host; he hears the close warning,
	// and at the deadline goes back to the open world; the host exits.
	survivor := map[string]*proc{"w1": w1, "w2": w2}[hostA]
	survivor.cmd.Process.Signal(syscall.SIGTERM)
	b.wait("the drain's close warning", 5*time.Second, func(p *proto.Packet) bool {
		return p.Opcode == session.OpUniqueNotice && len(p.Data) >= 2 && p.Data[0] == 0x1a && p.Data[1] == 0x0c
	})
	b.zone(15 * time.Second)
	waitHost(t, db, b.char, func(h string) bool { return h == "home" }, "back home after the drain")
	done := make(chan error, 1)
	go func() { done <- survivor.cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		t.Fatal("the drained host did not exit")
	}
	// And the party still works, all three processes later.
	b.chat(session.ChatParty, "", "home again")
	a.heard(session.ChatParty, "home again", 5*time.Second)
}
