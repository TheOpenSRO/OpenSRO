package main

import (
	"context"
	"database/sql"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/friend"
	"github.com/OpenSRO/OpenSRO/server/internal/guild"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/storage"
	"github.com/OpenSRO/OpenSRO/server/internal/testdb"
)

// ownerColumns are the column names that, in this schema, name a character
// or an account.
var ownerColumns = map[string]bool{"character_id": true, "account_id": true, "friend_id": true,
	"requester_id": true, "target_id": true, "leader_id": true}

// handledApart are the owner columns cleanup handles outside cleanupRefs.
var handledApart = map[string]bool{"guilds.leader_id": true}

func covered() map[string]bool {
	m := map[string]bool{}
	for _, r := range cleanupRefs {
		m[r.Table+"."+r.Column] = true
	}
	for k := range handledApart {
		m[k] = true
	}
	// characters.id is what character_id names; accounts.id is in the list.
	return m
}

var (
	createRE = regexp.MustCompile(`(?s)CREATE TABLE IF NOT EXISTS (\w+) \((.*?)\n\);`)
	alterRE  = regexp.MustCompile(`ALTER TABLE (\w+) ADD COLUMN IF NOT EXISTS (\w+)`)
)

// TestCleanupCoversEveryOwnerColumnInTheServerSchema reads every CREATE
// TABLE and ADD COLUMN the server's packages run (server/internal, tests
// excluded) and requires each column that names a character or an account to
// be one cleanup deletes by. A new table keyed by character_id fails here
// until cleanupRefs lists it (cleanup also finds such columns at run time,
// from information_schema, but the list is the reviewed one).
func TestCleanupCoversEveryOwnerColumnInTheServerSchema(t *testing.T) {
	cov := covered()
	found := map[string]bool{}
	err := filepath.WalkDir("../../internal", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return err
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		src := string(b)
		for _, m := range createRE.FindAllStringSubmatch(src, -1) {
			for _, line := range strings.Split(m[2], "\n") {
				f := strings.Fields(strings.TrimSpace(line))
				if len(f) > 0 && ownerColumns[f[0]] {
					found[m[1]+"."+f[0]] = true
				}
			}
		}
		for _, m := range alterRE.FindAllStringSubmatch(src, -1) {
			if ownerColumns[m[2]] {
				found[m[1]+"."+m[2]] = true
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// The containers' tables are named by constants (inventory.schemaFor).
	found[inventory.DefaultTable+".character_id"] = true
	found[inventory.WarehouseTable+".account_id"] = true
	found[storage.LegacyWarehouseTable+".character_id"] = true
	if len(found) < 12 {
		t.Fatalf("the scan found only %d owner columns (%v): is it reading the schema?", len(found), found)
	}
	for k := range found {
		if !cov[k] {
			t.Errorf("%s names a character or an account and cleanup does not delete by it", k)
		}
	}
	t.Logf("%d owner columns in the server schema, all covered", len(found))
}

func testDSN() string {
	if v := os.Getenv("OPENSRO_TEST_POSTGRES_DSN"); v != "" {
		return v
	}
	return "postgres://postgres:postgres@localhost:5432/opensro_test?sslmode=disable"
}

// testSchemaDB opens the test database in a schema of its own (dropped after),
// so nothing another package's test holds is touched.
func testSchemaDB(t *testing.T) *sql.DB {
	t.Helper()
	release := testdb.Lock(testDSN())
	t.Cleanup(release)
	admin, err := sql.Open("pgx", testDSN())
	if err != nil {
		t.Skip(err)
	}
	if err := admin.Ping(); err != nil {
		admin.Close()
		t.Skipf("no test postgres: %v", err)
	}
	schema := fmt.Sprintf("swarm_test_%d", os.Getpid())
	if _, err := admin.Exec(`DROP SCHEMA IF EXISTS ` + schema + ` CASCADE; CREATE SCHEMA ` + schema); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		admin.Exec(`DROP SCHEMA IF EXISTS ` + schema + ` CASCADE`)
		admin.Close()
	})
	u, err := url.Parse(testDSN())
	if err != nil {
		t.Fatal(err)
	}
	q := u.Query()
	q.Set("search_path", schema)
	u.RawQuery = q.Encode()
	db, err := sql.Open("pgx", u.String())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	var got string
	if err := db.QueryRow(`SELECT current_schema()`).Scan(&got); err != nil || got != schema {
		t.Fatalf("current_schema %q %v", got, err)
	}
	return db
}

// TestCleanupOnTheRealSchema migrates every store the server opens into an
// empty schema, fills each table that names a character or an account with
// bot rows and with a real player's rows, runs cleanup twice, and checks the
// bot rows are gone, the real rows are all there, and no owner column of the
// migrated schema is left uncovered.
func TestCleanupOnTheRealSchema(t *testing.T) {
	db := testSchemaDB(t)
	inv, err := inventory.NewSQLStoreOwned(db, nil, inventory.DefaultTable, "character_id")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := inventory.NewSQLStoreOwned(db, nil, inventory.WarehouseTable, "account_id"); err != nil {
		t.Fatal(err)
	}
	for _, open := range []func() error{
		func() error { _, err := account.NewSQLStore(db); return err },
		func() error { _, err := character.NewSQLStore(db); return err },
		func() error { _, err := equipment.NewSQLStore(db, inv); return err },
		func() error { _, err := skill.NewSQLStore(db); return err },
		func() error { _, err := quest.NewSQLStore(db); return err },
		func() error { _, err := guild.NewSQLStore(db); return err },
		func() error { _, err := friend.NewSQLStore(db); return err },
		func() error { _, err := refdata.NewSQLStore(db); return err },
		func() error { // the legacy warehouse, as an old install still has it
			_, err := db.Exec(`CREATE TABLE ` + storage.LegacyWarehouseTable + ` (character_id BIGINT NOT NULL, slot INTEGER NOT NULL, item_id BIGINT NOT NULL)`)
			return err
		},
	} {
		if err := open(); err != nil {
			t.Fatal(err)
		}
	}

	// Every owner column of the migrated schema is covered.
	cov := covered()
	rows, err := db.Query(`SELECT table_name, column_name FROM information_schema.columns WHERE table_schema = current_schema()`)
	if err != nil {
		t.Fatal(err)
	}
	ownerCols := map[string][]string{}
	for rows.Next() {
		var tb, c string
		rows.Scan(&tb, &c)
		if ownerColumns[c] {
			ownerCols[tb] = append(ownerCols[tb], c)
			if !cov[tb+"."+c] {
				t.Errorf("migrated schema: %s.%s is not covered", tb, c)
			}
		}
	}
	rows.Close()

	ctx := context.Background()
	mustExec := func(q string, args ...any) {
		t.Helper()
		if _, err := db.ExecContext(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	// Two bots, a real player, and accounts the pattern must not match.
	ids := map[string]int64{}
	for _, u := range []string{"swarm0000", "swarm0001", "realplayer", "swarm001", "swarm00001", "swarmy0001", "Swarm0001", "xswarm0001"} {
		var id int64
		if err := db.QueryRow(`INSERT INTO accounts (username, password_hash) VALUES ($1, 'x') RETURNING id`, u).Scan(&id); err != nil {
			t.Fatal(err)
		}
		ids[u] = id
	}
	chars := map[string]int64{}
	for _, u := range []string{"swarm0000", "swarm0001", "realplayer", "swarm001"} {
		var id int64
		if err := db.QueryRow(`INSERT INTO characters (account_id, name) VALUES ($1, $2) RETURNING id`, ids[u], u+"c").Scan(&id); err != nil {
			t.Fatal(err)
		}
		chars[u] = id
	}
	bot0, bot1, real, near := chars["swarm0000"], chars["swarm0001"], chars["realplayer"], chars["swarm001"]
	for _, c := range []int64{bot0, bot1, real, near} {
		mustExec(`INSERT INTO equipment_slots (character_id, slot, item_id, opt_level) VALUES ($1, 6, 4118, 9)`, c)
		mustExec(`INSERT INTO inventory_slots (character_id, slot, item_id, quantity) VALUES ($1, 13, 62607, 1)`, c)
		mustExec(`INSERT INTO `+storage.LegacyWarehouseTable+` (character_id, slot, item_id) VALUES ($1, 0, 1)`, c)
		mustExec(`INSERT INTO character_skills (character_id, skill_id) VALUES ($1, 1)`, c)
		mustExec(`INSERT INTO character_skill_points (character_id, points) VALUES ($1, 1)`, c)
		mustExec(`INSERT INTO character_mastery_levels (character_id, mastery_id) VALUES ($1, 257)`, c)
		mustExec(`INSERT INTO character_quests (character_id, quest_id) VALUES ($1, 1)`, c)
		mustExec(`INSERT INTO character_default_quests (character_id, quest_code, status) VALUES ($1, 'QNO', 1)`, c)
	}
	for _, u := range []string{"swarm0000", "realplayer", "swarm001"} {
		mustExec(`INSERT INTO account_storage_slots (account_id, slot, item_id, quantity) VALUES ($1, 0, 1, 1)`, ids[u])
	}
	// Friendships both ways between a bot and the real player, a request each
	// way, a bot-only guild, and a guild the real player leads with a bot in it.
	mustExec(`INSERT INTO friendships (character_id, friend_id, friend_name) VALUES ($1, $2, 'r'), ($2, $1, 'b'), ($3, $2, 'n')`, bot0, real, near)
	mustExec(`INSERT INTO friend_requests (requester_id, requester_name, target_id) VALUES ($1, 'b', $2), ($3, 'r', $1), ($3, 'r', $4)`, bot1, real, real, near)
	var botGuild, realGuild int64
	db.QueryRow(`INSERT INTO guilds (name, leader_id) VALUES ('Bots', $1) RETURNING id`, bot0).Scan(&botGuild)
	db.QueryRow(`INSERT INTO guilds (name, leader_id) VALUES ('Reals', $1) RETURNING id`, real).Scan(&realGuild)
	mustExec(`INSERT INTO guild_members (guild_id, character_id, character_name, role) VALUES ($1, $2, 'b0', 1), ($4, $3, 'b1', 0), ($4, $5, 'r', 1), ($4, $6, 'n', 0)`,
		botGuild, bot0, bot1, realGuild, real, near)

	// A short prefix is refused before anything runs.
	if _, err := cleanup(ctx, db, "swar"); err == nil {
		t.Fatal("cleanup ran with a 4-letter prefix")
	}
	rep, err := cleanup(ctx, db, "swarm")
	if err != nil {
		t.Fatal(err)
	}
	t.Logf("first run: %s", rep)
	if rep.Accounts != 2 || rep.Characters != 2 || len(rep.Extra) != 0 {
		t.Errorf("report %+v", rep)
	}

	// Nothing names a bot any more.
	botChars, botAccts := []int64{bot0, bot1}, []int64{ids["swarm0000"], ids["swarm0001"]}
	for tb, cols := range ownerCols {
		for _, c := range cols {
			want := botChars
			if c == "account_id" {
				want = botAccts
			}
			var n int
			if err := db.QueryRow(fmt.Sprintf(`SELECT count(*) FROM %s WHERE %s = ANY($1)`, quoteIdent(tb), quoteIdent(c)), want).Scan(&n); err != nil {
				t.Fatal(err)
			}
			if n != 0 {
				t.Errorf("%s.%s still names a bot in %d rows", tb, c, n)
			}
		}
	}
	for _, q := range []string{`SELECT count(*) FROM accounts WHERE id = ANY($1)`, `SELECT count(*) FROM characters WHERE account_id = ANY($1)`, `SELECT count(*) FROM guilds WHERE leader_id = ANY($1)`} {
		arg := botAccts
		if strings.Contains(q, "leader_id") {
			arg = botChars
		}
		var n int
		db.QueryRow(q, arg).Scan(&n)
		if n != 0 {
			t.Errorf("%s: %d left", q, n)
		}
	}
	// Everything else is where it was.
	var accts, realRows, nearRows, guilds, members int
	db.QueryRow(`SELECT count(*) FROM accounts`).Scan(&accts)
	db.QueryRow(`SELECT (SELECT count(*) FROM equipment_slots WHERE character_id = $1) + (SELECT count(*) FROM inventory_slots WHERE character_id = $1)
		+ (SELECT count(*) FROM character_skills WHERE character_id = $1) + (SELECT count(*) FROM character_quests WHERE character_id = $1)`, real).Scan(&realRows)
	db.QueryRow(`SELECT (SELECT count(*) FROM equipment_slots WHERE character_id = $1) + (SELECT count(*) FROM friendships WHERE character_id = $1)
		+ (SELECT count(*) FROM friend_requests WHERE target_id = $1)`, near).Scan(&nearRows)
	db.QueryRow(`SELECT count(*) FROM guilds`).Scan(&guilds)
	db.QueryRow(`SELECT count(*) FROM guild_members`).Scan(&members)
	if accts != 6 || realRows != 4 || nearRows != 3 || guilds != 1 || members != 2 {
		t.Errorf("other rows touched: accounts %d (want 6), real player's rows %d (want 4), swarm001's %d (want 3), guilds %d (want 1), members %d (want 2)",
			accts, realRows, nearRows, guilds, members)
	}

	// Idempotent.
	rep, err = cleanup(ctx, db, "swarm")
	if err != nil {
		t.Fatal(err)
	}
	var total int64
	for _, n := range rep.Rows {
		total += n
	}
	if rep.Accounts != 0 || rep.Characters != 0 || total != 0 {
		t.Errorf("second run removed %s", rep)
	}
}
