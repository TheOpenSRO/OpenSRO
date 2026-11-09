package bus

import (
	"bytes"
	"context"
	"database/sql"
	"fmt"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"

	"github.com/TheOpenSRO/OpenSRO/server/internal/testdb"
)

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

// openPG is two buses on one database -- two processes' -- or a skip.
func openPG(t *testing.T) (*Postgres, *Postgres) {
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
	a, err := NewPostgres(context.Background(), db, testDSN(), nil)
	if err != nil {
		t.Fatal(err)
	}
	b, err := NewPostgres(context.Background(), db, testDSN(), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close(); b.Close() })
	return a, b
}

func recv(t *testing.T, ch chan []byte) []byte {
	t.Helper()
	select {
	case g := <-ch:
		return g
	case <-time.After(5 * time.Second):
		t.Fatal("nothing delivered")
	}
	return nil
}

// Two processes: a host channel reaches only its subscriber, in order; the
// broadcast reaches both; a payload past NOTIFY's limit travels by its row;
// a cancelled subscription hears nothing more.
func TestPostgresBusAcrossProcesses(t *testing.T) {
	a, b := openPG(t)
	ctx := context.Background()
	onB := make(chan []byte, 64)
	cancelB := b.Subscribe("host.b", func(m []byte) { onB <- m })
	allA := make(chan []byte, 8)
	allB := make(chan []byte, 8)
	a.Subscribe(Broadcast, func(m []byte) { allA <- m })
	b.Subscribe(Broadcast, func(m []byte) { allB <- m })
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	if err := a.WaitListening(wctx); err != nil {
		t.Fatal(err)
	}
	if err := b.WaitListening(wctx); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 20; i++ {
		if err := a.Publish(ctx, "host.b", []byte(fmt.Sprintf("m%02d \x00\xff", i))); err != nil {
			t.Fatal(err)
		}
	}
	for i := 0; i < 20; i++ {
		if g := recv(t, onB); string(g) != fmt.Sprintf("m%02d \x00\xff", i) {
			t.Fatalf("message %d: %q", i, g)
		}
	}
	a.Publish(ctx, Broadcast, []byte("everyone"))
	if string(recv(t, allA)) != "everyone" || string(recv(t, allB)) != "everyone" {
		t.Fatal("broadcast")
	}
	big := bytes.Repeat([]byte{1, 2, 3, 250}, 9000)
	a.Publish(ctx, "host.b", big)
	if g := recv(t, onB); !bytes.Equal(g, big) {
		t.Fatalf("spilled payload: %d bytes back", len(g))
	}
	cancelB()
	a.Publish(ctx, "host.b", []byte("late"))
	select {
	case g := <-onB:
		t.Fatalf("delivered after cancel: %q", g)
	case <-time.After(200 * time.Millisecond):
	}
	if pub, _ := a.Stats(); pub < 22 {
		t.Fatalf("published %d", pub)
	}
}

// A channel subscribed while the listener waits is LISTENed and delivered.
func TestPostgresBusLateSubscribe(t *testing.T) {
	a, b := openPG(t)
	ctx := context.Background()
	b.Subscribe("host.first", func([]byte) {})
	wctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	b.WaitListening(wctx)
	time.Sleep(50 * time.Millisecond)
	got := make(chan []byte, 1)
	b.Subscribe("host.second", func(m []byte) { got <- m })
	if err := b.WaitListening(wctx); err != nil {
		t.Fatal(err)
	}
	a.Publish(ctx, "host.second", []byte("hi"))
	if string(recv(t, got)) != "hi" {
		t.Fatal("late subscription")
	}
}
