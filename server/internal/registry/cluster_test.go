package registry

import (
	"context"
	"database/sql"
	"errors"
	"os"
	"sort"
	"sync"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
)

// testDSN is the PostgreSQL the cluster tests run on: OPENSRO_TEST_CLUSTER_DSN,
// else the suite's shared test database. The tables are the registry's own
// (world_*), emptied by each test.
func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_CLUSTER_DSN"); v != "" {
		return v
	}
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

func TestMain(m *testing.M) {
	release := testdb.Lock(testDSN())
	code := m.Run()
	release()
	os.Exit(code)
}

// openPostgres is a fresh Postgres registry with lease, or a skip when no
// database answers.
func openPostgres(t *testing.T, lease time.Duration) *Postgres {
	t.Helper()
	db, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Skipf("no PostgreSQL: %v", err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		t.Skipf("no PostgreSQL at %s: %v", testDSN(), err)
	}
	t.Cleanup(func() { db.Close() })
	p, err := NewPostgres(context.Background(), db, lease)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(`TRUNCATE world_hosts, world_instances, world_instance_members, world_presence, world_returns`); err != nil {
		t.Fatal(err)
	}
	return p
}

// suite is one Cluster under test, with a way to let time pass beyond the
// lease.
type suite struct {
	c       Cluster
	expire  func()
	realNow bool
}

func memorySuite() suite {
	now := time.Date(2026, 11, 9, 12, 0, 0, 0, time.UTC)
	var mu sync.Mutex
	m := NewMemory(func() time.Time { mu.Lock(); defer mu.Unlock(); return now })
	m.SetLease(time.Second)
	return suite{c: m, expire: func() { mu.Lock(); now = now.Add(2 * time.Second); mu.Unlock() }}
}

func eachCluster(t *testing.T, run func(t *testing.T, s suite)) {
	t.Run("memory", func(t *testing.T) { run(t, memorySuite()) })
	t.Run("postgres", func(t *testing.T) {
		p := openPostgres(t, time.Second)
		run(t, suite{c: p, expire: func() { time.Sleep(1300 * time.Millisecond) }, realNow: true})
	})
}

func TestClusterSlotsMembersPresence(t *testing.T) {
	eachCluster(t, func(t *testing.T, s suite) {
		ctx := context.Background()
		c := s.c
		a, err := c.Open(ctx, OpenRequest{World: 63, Layers: 2, Lifetime: 2 * time.Hour, Host: "h1"})
		if err != nil || a.ID != (InstanceID{63, 1}) || a.Host != "h1" {
			t.Fatalf("first open %+v %v", a, err)
		}
		if d := a.Expires.Sub(a.Created); d != 2*time.Hour {
			t.Fatalf("lifetime %v", d)
		}
		b, _ := c.Open(ctx, OpenRequest{World: 63, Layers: 2, Host: "h1"})
		if b.ID.Layer != 2 || b.Key == a.Key || !b.Expires.IsZero() {
			t.Fatalf("second open %+v", b)
		}
		if _, err := c.Open(ctx, OpenRequest{World: 63, Layers: 2}); !errors.Is(err, ErrNoSlot) {
			t.Fatalf("third open: %v, want ErrNoSlot", err)
		}
		if n, err := c.Join(ctx, a.ID, a.Key, 7); n != 1 || err != nil {
			t.Fatalf("join: %d %v", n, err)
		}
		if n, _ := c.Join(ctx, a.ID, a.Key, 8); n != 2 {
			t.Fatalf("second join: %d", n)
		}
		if p, ok, _ := c.Presence(ctx, 7); !ok || p.Instance != a.ID || p.Key != a.Key || p.Host != "h1" {
			t.Fatalf("presence %+v %v", p, ok)
		}
		if _, err := c.Join(ctx, a.ID, a.Key+1, 9); !errors.Is(err, ErrNoInstance) {
			t.Fatalf("a stale key joins: %v", err)
		}
		got, _ := c.Get(ctx, a.ID)
		sort.Slice(got.Members, func(i, j int) bool { return got.Members[i] < got.Members[j] })
		if len(got.Members) != 2 || got.Members[0] != 7 {
			t.Fatalf("get %+v", got)
		}
		c.Leave(ctx, a.ID, a.Key, 7)
		if n, _ := c.Leave(ctx, a.ID, a.Key, 8); n != 0 {
			t.Fatalf("leave: %d", n)
		}
		if got, _ := c.Get(ctx, a.ID); got.EmptySince.IsZero() {
			t.Fatalf("empty since not stamped %+v", got)
		}
		if err := c.Close(ctx, a.ID, a.Key); err != nil {
			t.Fatal(err)
		}
		if _, err := c.Get(ctx, a.ID); !errors.Is(err, ErrNoInstance) {
			t.Fatalf("closed get: %v", err)
		}
		again, _ := c.Open(ctx, OpenRequest{World: 63, Layers: 2})
		if again.ID.Layer != 1 || again.Key == a.Key {
			t.Fatalf("the freed slot %+v", again)
		}
		if l, _ := c.List(ctx); len(l) != 2 || l[0].ID.Layer != 1 || l[1].ID.Layer != 2 {
			t.Fatalf("list %+v", l)
		}
		if _, err := c.Open(ctx, OpenRequest{World: 1, Layers: 1, Layer: 1}); err != nil {
			t.Fatal(err)
		}
		if _, err := c.Open(ctx, OpenRequest{World: 1, Layers: 1, Layer: 1}); !errors.Is(err, ErrNoSlot) {
			t.Fatalf("the open world twice: %v", err)
		}
	})
}

// The placement: the least-loaded live active host taking instances, by
// open instances then players; a draining host and a silent one get none.
func TestClusterPlacement(t *testing.T) {
	eachCluster(t, func(t *testing.T, s suite) {
		ctx := context.Background()
		c := s.c
		if _, err := c.Pick(ctx, "v1"); !errors.Is(err, ErrNoHost) {
			t.Fatalf("no hosts: %v", err)
		}
		must := func(err error) {
			t.Helper()
			if err != nil {
				t.Fatal(err)
			}
		}
		must(c.Beat(ctx, Host{ID: "home", Addr: "a:1", Version: "v1", OpenWorld: true}))
		must(c.Beat(ctx, Host{ID: "w1", Addr: "a:2", Version: "v1", Instances: true}))
		must(c.Beat(ctx, Host{ID: "w2", Addr: "a:3", Version: "v1", Instances: true, Players: 5}))
		counts := map[string]int{}
		for i := 0; i < 6; i++ {
			in, err := c.Open(ctx, OpenRequest{World: 63, Layers: 50, Pick: true, Version: "v1"})
			if err != nil {
				t.Fatal(err)
			}
			counts[in.Host]++
		}
		if counts["w1"] != 3 || counts["w2"] != 3 || counts["home"] != 0 {
			t.Fatalf("spread %v", counts)
		}
		// A different version is taken only when no same-version host is.
		must(c.Beat(ctx, Host{ID: "w3", Addr: "a:4", Version: "v2", Instances: true}))
		if h, _ := c.Pick(ctx, "v1"); h.ID == "w3" {
			t.Fatalf("picked the other version %+v", h)
		}
		if h, _ := c.Pick(ctx, "v2"); h.ID != "w3" {
			t.Fatalf("v2 pick %+v", h)
		}
		must(c.SetHostState(ctx, "w1", HostDraining))
		must(c.SetHostState(ctx, "w2", HostDraining))
		if h, _ := c.Pick(ctx, "v1"); h.ID != "w3" {
			t.Fatalf("draining hosts picked: %+v", h)
		}
		// The state survives the next beat (a beat carries no state).
		must(c.Beat(ctx, Host{ID: "w1", Addr: "a:2", Version: "v1", Instances: true}))
		hs, _ := c.Hosts(ctx)
		for _, h := range hs {
			if h.ID == "w1" && h.State != HostDraining {
				t.Fatalf("beat reset the drain: %+v", h)
			}
		}
	})
}

// The reaper: a host silent past the lease is dead, its instances lost with
// their members, its presence gone; the live host keeps everything; a dead
// host's next beat is fenced.
func TestClusterReaper(t *testing.T) {
	eachCluster(t, func(t *testing.T, s suite) {
		ctx := context.Background()
		c := s.c
		c.Beat(ctx, Host{ID: "home", OpenWorld: true})
		c.Beat(ctx, Host{ID: "w1", Instances: true})
		a, _ := c.Open(ctx, OpenRequest{World: 63, Layers: 50, Host: "w1"})
		b, _ := c.Open(ctx, OpenRequest{World: 63, Layers: 50, Host: "home"})
		c.Join(ctx, a.ID, a.Key, 11)
		c.Join(ctx, a.ID, a.Key, 12)
		c.Join(ctx, b.ID, b.Key, 13)
		c.SetOnline(ctx, Character{ID: 11, Name: "A", Host: "w1"})
		c.SetOnline(ctx, Character{ID: 13, Name: "C", Host: "home"})
		c.SetReturn(ctx, 11, Return{Zone: "jangan", Bucket: "97/168", X: 1, Y: 2, Z: 3})
		if r, _ := c.Reap(ctx); len(r.Dead) != 0 {
			t.Fatalf("reaped live hosts %+v", r)
		}
		s.expire()
		c.Beat(ctx, Host{ID: "home", OpenWorld: true})
		r, err := c.Reap(ctx)
		if err != nil {
			t.Fatal(err)
		}
		if len(r.Dead) != 1 || r.Dead[0].ID != "w1" || len(r.Lost) != 1 || r.Lost[0].ID != a.ID || r.Lost[0].State != StateLost {
			t.Fatalf("reaped %+v", r)
		}
		m := append([]int64(nil), r.Lost[0].Members...)
		sort.Slice(m, func(i, j int) bool { return m[i] < m[j] })
		if len(m) != 2 || m[0] != 11 || m[1] != 12 {
			t.Fatalf("lost members %v", m)
		}
		if _, ok, _ := c.Presence(ctx, 11); ok {
			t.Fatal("a lost instance's member is still placed")
		}
		if _, ok, _ := c.Presence(ctx, 13); !ok {
			t.Fatal("the live host's member was dropped")
		}
		on, _ := c.Online(ctx)
		if len(on) != 1 || on[0].ID != 13 {
			t.Fatalf("online %+v", on)
		}
		if rp, ok, _ := c.ReturnOf(ctx, 11); !ok || rp.Bucket != "97/168" || rp.Z != 3 {
			t.Fatalf("the return point %+v %v", rp, ok)
		}
		if err := c.Beat(ctx, Host{ID: "w1", Instances: true}); !errors.Is(err, ErrHostDead) {
			t.Fatalf("a dead host's beat: %v", err)
		}
		if r2, _ := c.Reap(ctx); len(r2.Dead) != 0 {
			t.Fatalf("reaped twice %+v", r2)
		}
		// The slot is free again.
		again, err := c.Open(ctx, OpenRequest{World: 63, Layers: 1, Host: "home"})
		if err != nil || again.ID != a.ID {
			t.Fatalf("the lost slot %+v %v", again, err)
		}
		c.ClearReturn(ctx, 11)
		if _, ok, _ := c.ReturnOf(ctx, 11); ok {
			t.Fatal("return kept")
		}
		// Offline only from the host that holds the character.
		c.SetOffline(ctx, 13, "w1")
		if on, _ := c.Online(ctx); len(on) != 1 {
			t.Fatalf("offline from another host removed it: %+v", on)
		}
		c.SetOffline(ctx, 13, "home")
		if on, _ := c.Online(ctx); len(on) != 0 {
			t.Fatalf("online %+v", on)
		}
	})
}

// Concurrent openings from several processes never share a slot.
func TestPostgresConcurrentOpens(t *testing.T) {
	p := openPostgres(t, time.Second)
	ctx := context.Background()
	p.Beat(ctx, Host{ID: "w1", Instances: true})
	p.Beat(ctx, Host{ID: "w2", Instances: true})
	var wg sync.WaitGroup
	var mu sync.Mutex
	layers := map[uint16]bool{}
	hosts := map[string]int{}
	errs := 0
	for i := 0; i < 40; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			in, err := p.Open(ctx, OpenRequest{World: 63, Layers: 50, Pick: true})
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				errs++
				return
			}
			if layers[in.ID.Layer] {
				t.Errorf("layer %d twice", in.ID.Layer)
			}
			layers[in.ID.Layer] = true
			hosts[in.Host]++
		}()
	}
	wg.Wait()
	if errs != 0 || len(layers) != 40 {
		t.Fatalf("%d errors, %d layers", errs, len(layers))
	}
	if hosts["w1"] < 15 || hosts["w2"] < 15 {
		t.Fatalf("placement under concurrency %v", hosts)
	}
}
