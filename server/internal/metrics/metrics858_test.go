package metrics

import (
	"bytes"
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics/opcodescan"
)

// The generated opcode table is the code's opcodes today: a new opcode
// constant fails this until `go generate ./internal/metrics` is run.
func TestOpcodeTableIsCurrent(t *testing.T) {
	entries, err := opcodescan.Scan("../..")
	if err != nil {
		t.Fatal(err)
	}
	want := opcodescan.Render(entries)
	got, err := os.ReadFile("opcodes_gen.go")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("opcodes_gen.go is stale: run `go generate ./internal/metrics` (%d opcodes in the code, table has %d)",
			len(entries), len(knownOpcodes))
	}
	if len(knownOpcodes) < 300 {
		t.Fatalf("only %d opcodes found; the scan missed the session package?", len(knownOpcodes))
	}
	for op, g := range map[uint16]string{0x7021: "world", 0x6102: "login", 0x7001: "lobby"} {
		if knownOpcodes[op] != g {
			t.Errorf("opcode 0x%04x group %q, want %q", op, knownOpcodes[op], g)
		}
	}
}

// An opcode the code does not name is counted as "other": a client sending
// random opcodes cannot grow the label set.
func TestUnknownOpcodesShareOneLabel(t *testing.T) {
	if OpcodeLabel(0x7021) != "0x7021" {
		t.Fatalf("known opcode label %q", OpcodeLabel(0x7021))
	}
	before := Value("gateway_packets_total", "dir", "in", "opcode", "other")
	for op := uint16(0xF000); op < 0xF100; op++ {
		if _, known := knownOpcodes[op]; known {
			continue
		}
		PacketIn(op)
	}
	if got := Value("gateway_packets_total", "dir", "in", "opcode", "other") - before; got < 200 {
		t.Fatalf("unknown opcodes counted %v under other", got)
	}
	PacketIn(0x7021)
	PacketIn(0x7021)
	if got := Value("gateway_packets_total", "dir", "in", "opcode", "0x7021", "group", "world"); got != 2 {
		t.Fatalf("0x7021 counted %v, want 2", got)
	}
}

func TestHandlerDoneObservesAndCountsFailures(t *testing.T) {
	start := time.Now().Add(-3 * time.Millisecond)
	HandlerDone(0x7021, start, false, false)
	HandlerDone(0x7021, start, true, false)
	HandlerDone(0x7021, start, false, true)
	if got := Value("gateway_handler_seconds", "group", "world"); got != 3 {
		t.Fatalf("handler histogram count %v, want 3", got)
	}
	if Value("gateway_handler_errors_total", "group", "world", "kind", "error") != 1 ||
		Value("gateway_handler_errors_total", "group", "world", "kind", "panic") != 1 {
		t.Fatal("handler error/panic counters did not move")
	}
}

func TestLoopTickCountsOverruns(t *testing.T) {
	l := NewLoop("test_loop", 10*time.Millisecond)
	l.Tick(time.Now())
	l.Tick(time.Now().Add(-50 * time.Millisecond))
	if got := Value("loop_tick_seconds", "loop", "test_loop"); got != 2 {
		t.Fatalf("ticks %v, want 2", got)
	}
	if got := Value("loop_overruns_total", "loop", "test_loop"); got != 1 {
		t.Fatalf("overruns %v, want 1", got)
	}
	if Value("loop_last_tick_timestamp_seconds", "loop", "test_loop") < float64(time.Now().Unix()-5) {
		t.Fatal("last tick timestamp not set")
	}
	var nilLoop *Loop
	nilLoop.Tick(time.Now()) // a nil loop is a no-op
}

func TestTeleportKindIsBounded(t *testing.T) {
	for via, want := range map[string]string{
		"gate teleport": "gate", "zone change": "zone_change", "walk-in teleport": "walk_in",
		"reverse return scroll": "return_scroll", "guild recall": "guild_recall", "/unstuck": "unstuck",
		"gm /goto": "gm", "anything else": "other",
	} {
		if got := TeleportKind(via); got != want {
			t.Errorf("TeleportKind(%q) = %q, want %q", via, got, want)
		}
	}
}

func TestQueryLabels(t *testing.T) {
	for q, want := range map[string][2]string{
		"SELECT gold FROM characters WHERE id = $1":                         {"select", "characters"},
		"  update inventory_slots SET qty = $1":                             {"update", "inventory_slots"},
		"INSERT INTO economy_ops (op_key) VALUES ($1)":                      {"insert", "economy_ops"},
		"DELETE FROM friends WHERE a = $1":                                  {"delete", "friends"},
		"-- comment\nWITH x AS (SELECT 1) SELECT * FROM x":                  {"with", "x"},
		"CREATE TABLE IF NOT EXISTS guilds (id bigint)":                     {"ddl", "guilds"},
		"SELECT pg_advisory_lock($1)":                                       {"select", "none"},
		"SELECT c.name FROM characters c JOIN guild_members g ON g.id=c.id": {"select", "characters"},
	} {
		op, table := QueryLabels(q)
		if op != want[0] || table != want[1] {
			t.Errorf("QueryLabels(%q) = %s, %s; want %s, %s", q, op, table, want[0], want[1])
		}
	}
}

// Serve answers /metrics with the families the dashboards read.
func TestServeExposesTheFamilies(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	addr, err := Serve(ctx, "127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	LoginResult("ok")
	WorldEntry()
	MoveLeg(false)
	Teleport("gate teleport")
	Damage("monster", "attack", 10)
	GoldIn(5)
	SetWorldSource(func() WorldSnapshot {
		return WorldSnapshot{PlayersByZone: map[string]int{"jangan": 2}, Entities: map[string]int{"monster": 7}, Authenticated: 3}
	})
	defer SetWorldSource(nil)
	resp, err := http.Get("http://" + addr.String() + "/metrics")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	for _, want := range []string{
		"opensro_build_info{", "go_goroutines", "process_cpu_seconds_total", "go_sched_latencies_seconds",
		`opensro_logins_total{result="ok"}`, "opensro_world_entries_total", `opensro_move_legs_total{kind="destination"}`,
		`opensro_teleports_total{kind="gate"}`, `opensro_combat_damage_total{source="attack",target="monster"}`,
		`opensro_gold_total{dir="in"}`, `opensro_players_online_by_zone{zone="jangan"} 2`, "opensro_players_online 2",
		`opensro_world_entities{kind="monster"} 7`, `opensro_sessions{state="authenticated"} 3`,
		"opensro_loop_period_seconds", "opensro_start_time_seconds",
	} {
		if !strings.Contains(string(body), want) {
			t.Errorf("/metrics lacks %s", want)
		}
	}
	// Off: an empty address serves nothing.
	if a, err := Serve(ctx, "", nil); a != nil || err != nil {
		t.Fatalf("Serve(\"\") = %v, %v", a, err)
	}
}

func TestCountingHandlerCountsByLevel(t *testing.T) {
	var buf bytes.Buffer
	l := slog.New(NewCountingHandler(slog.NewTextHandler(&buf, &slog.HandlerOptions{Level: slog.LevelInfo})))
	before := Value("log_messages_total", "level", "ERROR")
	debugBefore := Value("log_messages_total", "level", "DEBUG")
	l.Error("boom", "err", errors.New("x"))
	l.With("k", "v").Error("boom again")
	l.Debug("not written")
	if got := Value("log_messages_total", "level", "ERROR") - before; got != 2 {
		t.Fatalf("errors counted %v, want 2", got)
	}
	if Value("log_messages_total", "level", "DEBUG") != debugBefore {
		t.Fatal("a disabled DEBUG line was counted")
	}
	if !strings.Contains(buf.String(), "level=ERROR msg=boom err=x") {
		t.Fatalf("text format changed: %q", buf.String())
	}
}

// The driver wrapper counts and times statements and transactions, and
// passes everything through.
func TestDBWrapperCountsStatements(t *testing.T) {
	db := sql.OpenDB(WrapConnector(fakeConnector{}, "test_pool"))
	defer db.Close()
	ctx := context.Background()
	if _, err := db.ExecContext(ctx, "UPDATE characters SET gold = gold + $1 WHERE id = $2", 1, 2); err != nil {
		t.Fatal(err)
	}
	rows, err := db.QueryContext(ctx, "SELECT gold FROM characters WHERE id = $1", 2)
	if err != nil {
		t.Fatal(err)
	}
	rows.Close()
	if _, err := db.ExecContext(ctx, "DELETE FROM broken"); err == nil {
		t.Fatal("the fake's failing statement succeeded")
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := tx.ExecContext(ctx, "INSERT INTO economy_ops (op_key) VALUES ($1)", "k"); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	stmt, err := db.PrepareContext(ctx, "SELECT name FROM guilds WHERE id = $1")
	if err != nil {
		t.Fatal(err)
	}
	r2, err := stmt.QueryContext(ctx, 1)
	if err != nil {
		t.Fatal(err)
	}
	r2.Close()
	stmt.Close()
	for _, c := range []struct {
		op, table string
		want      float64
	}{{"update", "characters", 1}, {"select", "characters", 1}, {"delete", "broken", 1}, {"insert", "economy_ops", 1}, {"select", "guilds", 1}} {
		if got := Value("db_queries_total", "pool", "test_pool", "op", c.op, "table", c.table); got != c.want {
			t.Errorf("%s %s counted %v, want %v", c.op, c.table, got, c.want)
		}
	}
	if Value("db_errors_total", "pool", "test_pool", "table", "broken") != 1 {
		t.Error("the failing statement was not counted as an error")
	}
	if Value("db_transactions_total", "pool", "test_pool", "result", "commit") != 1 {
		t.Error("the commit was not counted")
	}
	if Value("db_query_seconds", "pool", "test_pool") != 5 {
		t.Errorf("histogram count %v, want 5", Value("db_query_seconds", "pool", "test_pool"))
	}
}

// fakeConnector is a minimal driver: every statement succeeds with no rows,
// except one that names the table "broken".
type fakeConnector struct{}

func (fakeConnector) Connect(context.Context) (driver.Conn, error) { return &fakeConn{}, nil }
func (fakeConnector) Driver() driver.Driver                        { return nil }

type fakeConn struct{}

func (c *fakeConn) Prepare(q string) (driver.Stmt, error) { return &fakeStmt{q}, nil }
func (c *fakeConn) Close() error                          { return nil }
func (c *fakeConn) Begin() (driver.Tx, error)             { return fakeTx{}, nil }
func (c *fakeConn) ExecContext(_ context.Context, q string, _ []driver.NamedValue) (driver.Result, error) {
	if strings.Contains(q, "broken") {
		return nil, errors.New("fake: broken")
	}
	return driver.RowsAffected(1), nil
}
func (c *fakeConn) QueryContext(_ context.Context, q string, _ []driver.NamedValue) (driver.Rows, error) {
	return &fakeRows{}, nil
}

type fakeStmt struct{ q string }

func (s *fakeStmt) Close() error                               { return nil }
func (s *fakeStmt) NumInput() int                              { return -1 }
func (s *fakeStmt) Exec([]driver.Value) (driver.Result, error) { return driver.RowsAffected(1), nil }
func (s *fakeStmt) Query([]driver.Value) (driver.Rows, error)  { return &fakeRows{}, nil }

type fakeTx struct{}

func (fakeTx) Commit() error   { return nil }
func (fakeTx) Rollback() error { return nil }

type fakeRows struct{}

func (*fakeRows) Columns() []string         { return []string{"x"} }
func (*fakeRows) Close() error              { return nil }
func (*fakeRows) Next([]driver.Value) error { return io.EOF }
