package main

// The swarm's Postgres side: the bot accounts, the gear and start position
// written before a bot enters the world, and `down`'s cleanup. Every query is
// keyed to the accounts named ^prefix[0-9]{4}$ (guard.go), matched by
// Postgres and checked again here.

import (
	"context"
	"database/sql"
	"fmt"
	"math"
	"math/rand"
	"sort"
	"strings"

	_ "github.com/jackc/pgx/v5/stdlib"
	"golang.org/x/crypto/bcrypt"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/storage"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

func openDB(dsn string) (*sql.DB, error) {
	if dsn == "" {
		return nil, fmt.Errorf("no -pg DSN given")
	}
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}
	// A small budget: the server's own pool (40 by default) shares Postgres's
	// max_connections (100 by default) with this tool (deploy/README.md).
	db.SetMaxOpenConns(4)
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("connecting to postgres: %w", err)
	}
	return db, nil
}

// ensureAccounts makes accounts prefix0000..prefix(n-1) exist with password
// pw. It writes them directly (bcrypt at its minimum cost) rather than through
// the server's OpRegister, whose bcrypt at the default cost would cost the
// server tens of milliseconds of CPU per bot; the password of an existing bot
// account is reset to pw. Returns how many were created.
func ensureAccounts(ctx context.Context, db *sql.DB, prefix string, n int, pw string) (int, error) {
	pattern, err := botPattern(prefix)
	if err != nil {
		return 0, err
	}
	hash, err := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.MinCost)
	if err != nil {
		return 0, err
	}
	names := make([]string, n)
	for i := range names {
		names[i] = botName(prefix, i)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `INSERT INTO accounts (username, password_hash)
		SELECT u, $2 FROM unnest($1::text[]) AS u WHERE u ~ $3
		ON CONFLICT (username) DO NOTHING`, names, hash, pattern)
	if err != nil {
		return 0, fmt.Errorf("creating the bot accounts: %w", err)
	}
	created, _ := res.RowsAffected()
	if _, err := tx.ExecContext(ctx, `UPDATE accounts SET password_hash = $2 WHERE username = ANY($1::text[]) AND username ~ $3`,
		names, hash, pattern); err != nil {
		return 0, fmt.Errorf("setting the bot accounts' password: %w", err)
	}
	return int(created), tx.Commit()
}

// botChar is a bot's character as the database has it.
type botChar struct {
	ID     int64
	Gender string
}

// botCharacter is the character named name on the bot account name, if any.
func botCharacter(ctx context.Context, db *sql.DB, prefix, name string) (botChar, bool, error) {
	pattern, err := botPattern(prefix)
	if err != nil {
		return botChar{}, false, err
	}
	var c botChar
	err = db.QueryRowContext(ctx, `SELECT c.id, c.gender FROM characters c JOIN accounts a ON a.id = c.account_id
		WHERE a.username = $1 AND a.username ~ $2 AND c.name = $1 AND c.deleted_at IS NULL`, name, pattern).Scan(&c.ID, &c.Gender)
	if err == sql.ErrNoRows {
		return botChar{}, false, nil
	}
	return c, err == nil, err
}

// The plaza: a disc around Jangan's spawn, region 97/168 local (1002, 1020)
// (AGENTS.md: the game's own spawn; the dragon's pedestal at (1002, 917) is
// solid and stays outside a 60-unit disc). Height 20 is the China start
// spawns' (session.StartSpawns, READ); a client lifts a body onto the ground.
const (
	plazaZone          = "jangan"
	plazaRX, plazaRY   = 97, 168
	plazaX, plazaZ     = 1002.0, 1020.0
	plazaY             = 20.0
	defaultPlazaRadius = 55.0
)

// plazaPoint is a uniform point of the disc, region-local.
func plazaPoint(r *rand.Rand, radius float64) (lx, lz float64) {
	d := radius * math.Sqrt(r.Float64())
	a := r.Float64() * 2 * math.Pi
	return plazaX + d*math.Cos(a), plazaZ + d*math.Sin(a)
}

// standFor is bot i's starting spot, region-local.
func standFor(seed int64, i int, radius float64) (lx, lz float64) {
	return plazaPoint(rand.New(rand.NewSource(seed*15485863+int64(i))), radius)
}

// seedCharacter writes the bot's gear and start position in one transaction:
// its worn rows replaced by gear, and its start spot in Jangan (start_zone,
// which a character enters at whether -persist-position is on or off, the
// saved position cleared so it applies with the flag on too).
func seedCharacter(ctx context.Context, db *sql.DB, prefix string, charID int64, gear []gearRow, lx, lz float64) error {
	pattern, err := botPattern(prefix)
	if err != nil {
		return err
	}
	x, z, ok := worldmap.ToZoneWorld(plazaZone, plazaRX, plazaRY, lx, lz)
	if !ok {
		return fmt.Errorf("no frame for %s", plazaZone)
	}
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	res, err := tx.ExecContext(ctx, `UPDATE characters SET start_zone = $2, start_x = $3, start_y = $4, start_z = $5,
		latest_zone = '', latest_frame = '', pos_x = 0, pos_y = 0, pos_z = 0
		WHERE id = $1 AND account_id IN (SELECT id FROM accounts WHERE username ~ $6)`, charID, plazaZone, x, plazaY, z, pattern)
	if err != nil {
		return fmt.Errorf("placing character %d: %w", charID, err)
	}
	if n, _ := res.RowsAffected(); n != 1 {
		return fmt.Errorf("character %d is not a %s bot's", charID, prefix)
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM equipment_slots WHERE character_id = $1`, charID); err != nil {
		return err
	}
	for _, g := range gear {
		if _, err := tx.ExecContext(ctx, `INSERT INTO equipment_slots (character_id, slot, item_id, variance, durability, opt_level, mag_params, adv_elixir)
			VALUES ($1, $2, $3, 0, -1, $4, ''::bytea, $5)`, charID, int(g.Slot), g.Item.ID, g.Opt, g.Adv); err != nil {
			return fmt.Errorf("wearing %d on character %d: %w", g.Item.ID, charID, err)
		}
	}
	return tx.Commit()
}

// ownerRef is one column that names a character or an account.
type ownerRef struct {
	Table, Column string
	// Account is true for an account id column, false for a character id.
	Account bool
}

// cleanupRefs are every column of the server's schema that names a
// character or an account (the CREATE TABLEs under server/internal; the
// coverage test holds this list to them). guilds.leader_id is handled apart:
// a guild is removed only when every member is a bot.
var cleanupRefs = []ownerRef{
	{"equipment_slots", "character_id", false},
	{inventory.DefaultTable, "character_id", false},
	{storage.LegacyWarehouseTable, "character_id", false},
	{"character_skills", "character_id", false},
	{"character_skill_points", "character_id", false},
	{"character_mastery_levels", "character_id", false},
	{"character_quests", "character_id", false},
	{"character_default_quests", "character_id", false},
	{"guild_members", "character_id", false},
	{"friendships", "character_id", false},
	{"friendships", "friend_id", false},
	{"friend_requests", "requester_id", false},
	{"friend_requests", "target_id", false},
	{inventory.WarehouseTable, "account_id", true},
	{"characters", "account_id", true},
	{"accounts", "id", true},
}

// cleanupReport is what down removed.
type cleanupReport struct {
	Accounts, Characters int
	Rows                 map[string]int64 // "table.column" -> rows deleted
	Extra                []string         // tables found by discovery, not in cleanupRefs
	GuildsKept           []int64          // bot-led guilds with real members, left in place
}

func (r cleanupReport) String() string {
	var keys []string
	var total int64
	for k, n := range r.Rows {
		keys = append(keys, k)
		total += n
	}
	sort.Strings(keys)
	var b strings.Builder
	fmt.Fprintf(&b, "%d accounts, %d characters, %d rows:", r.Accounts, r.Characters, total)
	for _, k := range keys {
		if r.Rows[k] > 0 {
			fmt.Fprintf(&b, " %s=%d", k, r.Rows[k])
		}
	}
	if len(r.Extra) > 0 {
		fmt.Fprintf(&b, " (also found and cleaned: %s)", strings.Join(r.Extra, ", "))
	}
	if len(r.GuildsKept) > 0 {
		fmt.Fprintf(&b, " (bot-led guilds kept, they have other members: %v)", r.GuildsKept)
	}
	return b.String()
}

// discoverRefs is cleanupRefs plus every other column named character_id or
// account_id in the database's schema, so a table added after this tool was
// written is cleaned too.
func discoverRefs(ctx context.Context, tx *sql.Tx) ([]ownerRef, []string, error) {
	refs := append([]ownerRef(nil), cleanupRefs...)
	known := map[string]bool{}
	for _, r := range refs {
		known[r.Table+"."+r.Column] = true
	}
	rows, err := tx.QueryContext(ctx, `SELECT table_name, column_name FROM information_schema.columns
		WHERE table_schema = current_schema() AND column_name IN ('character_id', 'account_id')
		ORDER BY table_name, column_name`)
	if err != nil {
		return nil, nil, err
	}
	defer rows.Close()
	var extra []string
	for rows.Next() {
		var t, c string
		if err := rows.Scan(&t, &c); err != nil {
			return nil, nil, err
		}
		if known[t+"."+c] {
			continue
		}
		known[t+"."+c] = true
		refs = append(refs[:len(refs)-2], append([]ownerRef{{t, c, c == "account_id"}}, refs[len(refs)-2:]...)...)
		extra = append(extra, t+"."+c)
	}
	return refs, extra, rows.Err()
}

func tableExists(ctx context.Context, tx *sql.Tx, table string) (bool, error) {
	var name sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT to_regclass($1)::text`, table).Scan(&name); err != nil {
		return false, err
	}
	return name.Valid, nil
}

// cleanup deletes every bot account of prefix, its characters and every row
// that names them, in one transaction. Idempotent: a second run finds nothing.
func cleanup(ctx context.Context, db *sql.DB, prefix string) (cleanupReport, error) {
	rep := cleanupReport{Rows: map[string]int64{}}
	pattern, err := botPattern(prefix)
	if err != nil {
		return rep, err
	}
	match, _ := botMatcher(prefix)
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return rep, err
	}
	defer tx.Rollback()

	var accounts []int64
	rows, err := tx.QueryContext(ctx, `SELECT id, username FROM accounts WHERE username ~ $1 FOR UPDATE`, pattern)
	if err != nil {
		return rep, fmt.Errorf("listing the bot accounts: %w", err)
	}
	for rows.Next() {
		var id int64
		var u string
		if err := rows.Scan(&id, &u); err != nil {
			rows.Close()
			return rep, err
		}
		if !match.MatchString(u) { // Postgres's match, checked again
			rows.Close()
			return rep, fmt.Errorf("account %q matched %s in Postgres but not here: refusing", u, pattern)
		}
		accounts = append(accounts, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return rep, err
	}
	var chars []int64
	if len(accounts) > 0 {
		rows, err = tx.QueryContext(ctx, `SELECT id FROM characters WHERE account_id = ANY($1)`, accounts)
		if err != nil {
			return rep, err
		}
		for rows.Next() {
			var id int64
			if err := rows.Scan(&id); err != nil {
				rows.Close()
				return rep, err
			}
			chars = append(chars, id)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return rep, err
		}
	}
	rep.Accounts, rep.Characters = len(accounts), len(chars)

	refs, extra, err := discoverRefs(ctx, tx)
	if err != nil {
		return rep, fmt.Errorf("reading the schema: %w", err)
	}
	rep.Extra = extra

	// Guilds a bot leads: removed (their members with them) only when every
	// member is a bot.
	if ok, err := tableExists(ctx, tx, "guilds"); err != nil {
		return rep, err
	} else if ok && len(chars) > 0 {
		rows, err := tx.QueryContext(ctx, `SELECT g.id, EXISTS (SELECT 1 FROM guild_members m WHERE m.guild_id = g.id AND NOT (m.character_id = ANY($1)))
			FROM guilds g WHERE g.leader_id = ANY($1)`, chars)
		if err != nil {
			return rep, err
		}
		var drop []int64
		for rows.Next() {
			var id int64
			var others bool
			if err := rows.Scan(&id, &others); err != nil {
				rows.Close()
				return rep, err
			}
			if others {
				rep.GuildsKept = append(rep.GuildsKept, id)
			} else {
				drop = append(drop, id)
			}
		}
		rows.Close()
		if len(drop) > 0 {
			res, err := tx.ExecContext(ctx, `DELETE FROM guilds WHERE id = ANY($1)`, drop)
			if err != nil {
				return rep, err
			}
			rep.Rows["guilds.leader_id"], _ = res.RowsAffected()
		}
	}

	for _, r := range refs {
		ids := chars
		if r.Account {
			ids = accounts
		}
		if len(ids) == 0 {
			continue
		}
		ok, err := tableExists(ctx, tx, r.Table)
		if err != nil {
			return rep, err
		}
		if !ok {
			continue
		}
		// Table and column names are this file's constants or the schema's
		// own (information_schema), quoted as identifiers.
		q := fmt.Sprintf(`DELETE FROM %s WHERE %s = ANY($1)`, quoteIdent(r.Table), quoteIdent(r.Column))
		res, err := tx.ExecContext(ctx, q, ids)
		if err != nil {
			return rep, fmt.Errorf("cleaning %s.%s: %w", r.Table, r.Column, err)
		}
		n, _ := res.RowsAffected()
		rep.Rows[r.Table+"."+r.Column] += n
	}
	return rep, tx.Commit()
}

func quoteIdent(s string) string { return `"` + strings.ReplaceAll(s, `"`, `""`) + `"` }

// dbCounts is what status reports from Postgres.
type dbCounts struct {
	Accounts, Characters, WornRows, Plus3, Plus8 int
}

func countBots(ctx context.Context, db *sql.DB, prefix string) (dbCounts, error) {
	var c dbCounts
	pattern, err := botPattern(prefix)
	if err != nil {
		return c, err
	}
	err = db.QueryRowContext(ctx, `
		WITH a AS (SELECT id FROM accounts WHERE username ~ $1),
		     ch AS (SELECT id FROM characters WHERE account_id IN (SELECT id FROM a))
		SELECT (SELECT count(*) FROM a), (SELECT count(*) FROM ch),
		       (SELECT count(*) FROM equipment_slots WHERE character_id IN (SELECT id FROM ch)),
		       (SELECT count(*) FROM equipment_slots WHERE character_id IN (SELECT id FROM ch) AND slot = 6 AND opt_level + adv_elixir >= 3),
		       (SELECT count(*) FROM equipment_slots WHERE character_id IN (SELECT id FROM ch) AND slot = 6 AND opt_level + adv_elixir >= 8)`,
		pattern).Scan(&c.Accounts, &c.Characters, &c.WornRows, &c.Plus3, &c.Plus8)
	return c, err
}
