package storage

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"

	"github.com/OpenSRO/srrevamp/server/internal/inventory"
)

// LegacyWarehouseTable is the per-character warehouse table this server
// wrote until 2026-09-19. MigrateToAccounts empties it into
// inventory.WarehouseTable; it is never written again.
const LegacyWarehouseTable = "storage_slots"

// migrationName is the schema_migrations row that records the move.
const migrationName = "warehouse_per_account"

// Migrated is what MigrateToAccounts did, for the boot log.
type Migrated struct {
	Applied    bool  // false when the migration had already run
	Rows       int   // warehouse rows moved
	Reslotted  int   // rows that had to take another slot (two characters used the same one)
	Characters int   // characters whose warehouse or gold moved
	Accounts   int   // accounts that received something
	Gold       int64 // warehouse gold summed onto accounts
	Orphans    int   // legacy rows whose character no longer exists (left in place)
}

// MigrateToAccounts moves the per-character warehouse (LegacyWarehouseTable
// plus characters.storage_gold) into the account-owned one
// (inventory.WarehouseTable plus accounts.storage_gold), once. A row in
// schema_migrations records that it ran, so a restart does nothing.
//
// It is lossless by construction, which is what kept the game's rule from
// being applied earlier: a row keeps its slot when that slot is free in the
// account's warehouse and takes the lowest free slot otherwise; gold is
// summed; nothing is dropped. Everything runs in one transaction, and a
// legacy row is deleted only after its copy is written.
func MigrateToAccounts(ctx context.Context, db *sql.DB, logger *slog.Logger) (Migrated, error) {
	var out Migrated
	if _, err := db.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		name       TEXT PRIMARY KEY,
		applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
	)`); err != nil {
		return out, fmt.Errorf("storage: creating schema_migrations: %w", err)
	}

	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return out, fmt.Errorf("storage: beginning migration: %w", err)
	}
	defer tx.Rollback()

	var already bool
	if err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE name = $1)`, migrationName).Scan(&already); err != nil {
		return out, fmt.Errorf("storage: reading schema_migrations: %w", err)
	}
	if already {
		return out, nil
	}
	out.Applied = true

	touchedCharacters := map[int64]bool{}
	touchedAccounts := map[int64]bool{}

	// Items. The legacy table may not exist on a database that never ran
	// the per-character server; to_regclass answers NULL then.
	var legacy sql.NullString
	if err := tx.QueryRowContext(ctx, `SELECT to_regclass($1)::text`, LegacyWarehouseTable).Scan(&legacy); err != nil {
		return out, fmt.Errorf("storage: looking for %s: %w", LegacyWarehouseTable, err)
	}
	if legacy.Valid {
		type legacyRow struct {
			account, character int64
			slot               int
			item               int64
			quantity           int
			variance           int64
			durability         int
		}
		rows, err := tx.QueryContext(ctx, fmt.Sprintf(`
			SELECT c.account_id, s.character_id, s.slot, s.item_id, s.quantity, s.variance, s.durability
			FROM %s s JOIN characters c ON c.id = s.character_id
			ORDER BY c.account_id, s.character_id, s.slot`, LegacyWarehouseTable))
		if err != nil {
			return out, fmt.Errorf("storage: reading %s: %w", LegacyWarehouseTable, err)
		}
		var legacyRows []legacyRow
		for rows.Next() {
			var r legacyRow
			if err := rows.Scan(&r.account, &r.character, &r.slot, &r.item, &r.quantity, &r.variance, &r.durability); err != nil {
				rows.Close()
				return out, fmt.Errorf("storage: scanning %s: %w", LegacyWarehouseTable, err)
			}
			legacyRows = append(legacyRows, r)
		}
		rows.Close()
		if err := rows.Err(); err != nil {
			return out, fmt.Errorf("storage: reading %s: %w", LegacyWarehouseTable, err)
		}

		// Slots already used per account (an account may own rows in the
		// new table already if the migration is ever run against a
		// database that has been played on since the switch).
		used := map[int64]map[int]bool{}
		usedFor := func(account int64) (map[int]bool, error) {
			if m, ok := used[account]; ok {
				return m, nil
			}
			m := map[int]bool{}
			rs, err := tx.QueryContext(ctx, fmt.Sprintf(`SELECT slot FROM %s WHERE account_id = $1`, inventory.WarehouseTable), account)
			if err != nil {
				return nil, err
			}
			for rs.Next() {
				var slot int
				if err := rs.Scan(&slot); err != nil {
					rs.Close()
					return nil, err
				}
				m[slot] = true
			}
			rs.Close()
			used[account] = m
			return m, rs.Err()
		}

		for _, r := range legacyRows {
			taken, err := usedFor(r.account)
			if err != nil {
				return out, fmt.Errorf("storage: reading %s for account %d: %w", inventory.WarehouseTable, r.account, err)
			}
			slot := r.slot
			if taken[slot] {
				slot = 0
				for taken[slot] {
					slot++
				}
				out.Reslotted++
				if slot >= inventory.MaxStorageSlots && logger != nil {
					logger.Warn("warehouse migration: a row landed beyond the warehouse's slot count",
						"account", r.account, "character", r.character, "from_slot", r.slot, "to_slot", slot)
				}
			}
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(`INSERT INTO %s (account_id, slot, item_id, quantity, variance, durability) VALUES ($1, $2, $3, $4, $5, $6)`, inventory.WarehouseTable),
				r.account, slot, r.item, r.quantity, r.variance, r.durability); err != nil {
				return out, fmt.Errorf("storage: writing account %d slot %d: %w", r.account, slot, err)
			}
			taken[slot] = true
			if _, err := tx.ExecContext(ctx, fmt.Sprintf(`DELETE FROM %s WHERE character_id = $1 AND slot = $2`, LegacyWarehouseTable), r.character, r.slot); err != nil {
				return out, fmt.Errorf("storage: removing legacy row: %w", err)
			}
			out.Rows++
			touchedCharacters[r.character] = true
			touchedAccounts[r.account] = true
		}
		if err := tx.QueryRowContext(ctx, fmt.Sprintf(`SELECT count(*) FROM %s`, LegacyWarehouseTable)).Scan(&out.Orphans); err != nil {
			return out, fmt.Errorf("storage: counting orphans: %w", err)
		}
	}

	// Gold: each account receives the sum of its characters' stored gold.
	goldRows, err := tx.QueryContext(ctx, `SELECT id, account_id, storage_gold FROM characters WHERE storage_gold > 0`)
	if err != nil {
		return out, fmt.Errorf("storage: reading characters' stored gold: %w", err)
	}
	type goldRow struct {
		character, account, gold int64
	}
	var golds []goldRow
	for goldRows.Next() {
		var g goldRow
		if err := goldRows.Scan(&g.character, &g.account, &g.gold); err != nil {
			goldRows.Close()
			return out, fmt.Errorf("storage: scanning stored gold: %w", err)
		}
		golds = append(golds, g)
	}
	goldRows.Close()
	if err := goldRows.Err(); err != nil {
		return out, fmt.Errorf("storage: reading stored gold: %w", err)
	}
	for _, g := range golds {
		if _, err := tx.ExecContext(ctx, `UPDATE accounts SET storage_gold = storage_gold + $1 WHERE id = $2`, g.gold, g.account); err != nil {
			return out, fmt.Errorf("storage: crediting account %d: %w", g.account, err)
		}
		if _, err := tx.ExecContext(ctx, `UPDATE characters SET storage_gold = 0 WHERE id = $1`, g.character); err != nil {
			return out, fmt.Errorf("storage: clearing character %d stored gold: %w", g.character, err)
		}
		out.Gold += g.gold
		touchedCharacters[g.character] = true
		touchedAccounts[g.account] = true
	}

	if _, err := tx.ExecContext(ctx, `INSERT INTO schema_migrations (name) VALUES ($1)`, migrationName); err != nil {
		return out, fmt.Errorf("storage: recording migration: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return out, fmt.Errorf("storage: committing migration: %w", err)
	}
	out.Characters = len(touchedCharacters)
	out.Accounts = len(touchedAccounts)
	return out, nil
}
