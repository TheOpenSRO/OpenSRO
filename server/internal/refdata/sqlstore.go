package refdata

import (
	"context"
	"database/sql"
	"fmt"

	_ "github.com/jackc/pgx/v5/stdlib" // driver registration ("pgx")
)

const schema = `
CREATE TABLE IF NOT EXISTS items (
	id                BIGINT PRIMARY KEY,
	max_stack         INTEGER NOT NULL,
	req_str           INTEGER NOT NULL,
	req_int           INTEGER NOT NULL,
	item_class        INTEGER NOT NULL,
	two_handed        BOOLEAN NOT NULL,
	durability_min    DOUBLE PRECISION NOT NULL,
	durability_max    DOUBLE PRECISION NOT NULL,
	phys_defense_min  DOUBLE PRECISION NOT NULL,
	phys_defense_max  DOUBLE PRECISION NOT NULL,
	mag_defense_min   DOUBLE PRECISION NOT NULL,
	mag_defense_max   DOUBLE PRECISION NOT NULL,
	phys_attack_min   DOUBLE PRECISION NOT NULL,
	phys_attack_max   DOUBLE PRECISION NOT NULL,
	mag_attack_min    DOUBLE PRECISION NOT NULL,
	mag_attack_max    DOUBLE PRECISION NOT NULL,
	hit_rate_min      DOUBLE PRECISION NOT NULL,
	hit_rate_max      DOUBLE PRECISION NOT NULL,
	critical_min      DOUBLE PRECISION NOT NULL,
	critical_max      DOUBLE PRECISION NOT NULL
);
ALTER TABLE items ADD COLUMN IF NOT EXISTS type_id1 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS type_id2 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS type_id3 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS type_id4 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS country INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_gender INTEGER NOT NULL DEFAULT 2;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level_type1 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level1 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS price BIGINT NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS sell_price BIGINT NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS block_ratio_min DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS block_ratio_max DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_phys_min DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_phys_max DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_mag_min DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_mag_max DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS set_id INTEGER NOT NULL DEFAULT 0;
-- The engine's item capability flags (itemdata columns 16, 17, 19). Default
-- TRUE, not false: an older import that never saw these columns must leave every
-- item unrestricted rather than silently forbidding trades on every row.
ALTER TABLE items ADD COLUMN IF NOT EXISTS can_trade BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE items ADD COLUMN IF NOT EXISTS can_sell BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE items ADD COLUMN IF NOT EXISTS can_drop BOOLEAN NOT NULL DEFAULT TRUE;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level_type2 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level2 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level_type3 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level3 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level_type4 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS req_level4 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS repair_cost INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS decay_time_ms INTEGER NOT NULL DEFAULT 0;
-- The weapon stats' per-instance high ends (round 244); zero on an older
-- import, which WeaponRange treats as "no hi end" and reads the lo alone.
ALTER TABLE items ADD COLUMN IF NOT EXISTS phys_attack_min_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS phys_attack_max_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS mag_attack_min_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS mag_attack_max_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_phys_min_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_phys_max_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_mag_min_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_mag_max_hi DOUBLE PRECISION NOT NULL DEFAULT 0;
-- The weapon's Range, itemdata column 94, world units (round 247).
ALTER TABLE items ADD COLUMN IF NOT EXISTS attack_range INTEGER NOT NULL DEFAULT 0;
-- An elixir's three packed reinforce success dwords, itemdata Param2/3/4
-- (round 262); BIGINT because the top byte can be set.
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_rate1 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_rate2 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS reinforce_rate3 BIGINT NOT NULL DEFAULT 0;
-- The reuse cooltime group and delay (ms) from the item's COOLTIME descriptor
-- (round 263).
ALTER TABLE items ADD COLUMN IF NOT EXISTS cooltime_group BIGINT NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS cooltime_ms INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS parry_ratio_min DOUBLE PRECISION NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS parry_ratio_max DOUBLE PRECISION NOT NULL DEFAULT 0;
-- CanUse, itemdata column 24 (round 489). Default TRUE for the same reason as
-- can_trade: an import that predates the column must leave every item usable
-- rather than refuse every potion.
ALTER TABLE items ADD COLUMN IF NOT EXISTS can_use BOOLEAN NOT NULL DEFAULT TRUE;
-- CanPick, itemdata column 21 (round 493). Default TRUE for the same reason:
-- an import that predates the column must leave every drop pickable.
ALTER TABLE items ADD COLUMN IF NOT EXISTS can_pick BOOLEAN NOT NULL DEFAULT TRUE;
-- CodeName, itemdata column 2 (round 497): the string GObjPC::CheckCanPickUp
-- compares to exempt ITEM_QNO_RM_ARCHEMY* from the quest-item pick exclusion.
-- Empty on an import that predates the column.
ALTER TABLE items ADD COLUMN IF NOT EXISTS code_name TEXT NOT NULL DEFAULT '';
-- The potion restore amounts. REAL and exported since the Param block was
-- decoded, and parsed by the CSV loader -- but there were no columns here, so
-- ImportItems dropped them and every potion failed useitem's "cannot be used"
-- guard on any SQL deployment. Found by the field-by-field round-trip audit in
-- roundtrip_test.go, 2026-09-15.
ALTER TABLE items ADD COLUMN IF NOT EXISTS restore_hp INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS restore_hp_pct INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS restore_mp INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN IF NOT EXISTS restore_mp_pct INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS skills (
	id                  BIGINT PRIMARY KEY,
	group_id            BIGINT NOT NULL,
	basic_code          TEXT NOT NULL,
	basic_name          TEXT NOT NULL,
	basic_level         INTEGER NOT NULL,
	basic_chain_code    BIGINT NOT NULL,
	basic_recycle_cost  INTEGER NOT NULL,
	preparing_time_ms   INTEGER NOT NULL,
	casting_time_ms     INTEGER NOT NULL,
	action_duration_ms  INTEGER NOT NULL,
	reuse_delay_ms      INTEGER NOT NULL,
	cool_time_ms        INTEGER NOT NULL,
	flying_speed        DOUBLE PRECISION NOT NULL,
	interruptable       BOOLEAN NOT NULL,
	overlap             BOOLEAN NOT NULL,
	auto_attack_type    INTEGER NOT NULL,
	range_              INTEGER NOT NULL,
	consume_hp          INTEGER NOT NULL,
	consume_mp          INTEGER NOT NULL,
	req_learn_sp        INTEGER NOT NULL,
	req_learn_race      INTEGER NOT NULL,
	ui_skill_name       TEXT NOT NULL,
	mastery1            BIGINT NOT NULL DEFAULT 0,
	mastery_level1      INTEGER NOT NULL DEFAULT 0
);
-- Added after the skills table first shipped; ADD COLUMN IF NOT EXISTS migrates
-- databases created before mastery1/mastery_level1 existed.
ALTER TABLE skills ADD COLUMN IF NOT EXISTS mastery1 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS mastery_level1 INTEGER NOT NULL DEFAULT 0;
-- The real skill damage (the 'att' parameter) and hit count (the 'mc'
-- parameter). The first three shipped in the CSV and the in-memory store but
-- were never added here, so every SQL deployment silently dropped them on
-- import and fell back to the disclosed per-level stand-in. Fixed 2026-09-15.
ALTER TABLE skills ADD COLUMN IF NOT EXISTS attack_percent INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS damage_min INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS damage_max INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS hit_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS attack_type INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_cast_weapon1 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_cast_weapon2 INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_cast_list_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_cast_list TEXT NOT NULL DEFAULT '';
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_cast_all BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS no_combat_param BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS zero_damage BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS floor_blow BOOLEAN NOT NULL DEFAULT FALSE;
-- The learn prerequisites, skilldata columns 40..45 (group id, level) x3; zero
-- on an older import, which means none.
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_learn_skill1 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_learn_skill_level1 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_learn_skill2 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_learn_skill_level2 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_learn_skill3 BIGINT NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS req_learn_skill_level3 BIGINT NOT NULL DEFAULT 0;
-- The flat HP/MP a self-heal restores to its caster (round 503); zero on an
-- older import, which means no heal.
ALTER TABLE skills ADD COLUMN IF NOT EXISTS self_heal_hp INTEGER NOT NULL DEFAULT 0;
ALTER TABLE skills ADD COLUMN IF NOT EXISTS self_heal_mp INTEGER NOT NULL DEFAULT 0;
-- The cooldown group, Action_Overlap's high byte (round 504); zero on an older
-- import, which means no shared timer.
ALTER TABLE skills ADD COLUMN IF NOT EXISTS cooldown_group INTEGER NOT NULL DEFAULT 0;
-- The skill gate's motion-state refusals (round 605); zero on an older import,
-- which means none.
ALTER TABLE skills ADD COLUMN IF NOT EXISTS sit_gate INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS monster_drops (
	monster_id      BIGINT NOT NULL,
	item_group_id   BIGINT NOT NULL,
	overlap         BOOLEAN NOT NULL,
	drop_amount_min INTEGER NOT NULL,
	drop_amount_max INTEGER NOT NULL,
	drop_ratio      DOUBLE PRECISION NOT NULL,
	PRIMARY KEY (monster_id, item_group_id)
);

CREATE TABLE IF NOT EXISTS drop_group_entries (
	group_id     BIGINT NOT NULL,
	code_name    TEXT NOT NULL,
	item_id      BIGINT NOT NULL,
	select_ratio DOUBLE PRECISION NOT NULL,
	PRIMARY KEY (group_id, item_id)
);
`

// SQLStore is this project's own item reference-data store, backed by
// PostgreSQL (via the pgx driver).
type SQLStore struct {
	db *sql.DB
}

// OpenSQLStore opens a PostgreSQL database at dsn and ensures its schema
// exists.
func OpenSQLStore(dsn string) (*SQLStore, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, fmt.Errorf("refdata: opening postgres connection: %w", err)
	}
	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("refdata: connecting to postgres: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("refdata: creating schema: %w", err)
	}
	return &SQLStore{db: db}, nil
}

// Close closes the underlying database connection.
func (s *SQLStore) Close() error {
	return s.db.Close()
}

// ImportItems upserts every item in items (by ID), inside one transaction.
func (s *SQLStore) ImportItems(ctx context.Context, items []Item) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("refdata: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO items (
			id, max_stack, req_str, req_int, item_class, two_handed,
			durability_min, durability_max, phys_defense_min, phys_defense_max,
			mag_defense_min, mag_defense_max, phys_attack_min, phys_attack_max,
			mag_attack_min, mag_attack_max, hit_rate_min, hit_rate_max,
			critical_min, critical_max,
			type_id1, type_id2, type_id3, type_id4, country, req_gender, req_level_type1, req_level1,
			price, sell_price, block_ratio_min, block_ratio_max,
			reinforce_phys_min, reinforce_phys_max, reinforce_mag_min, reinforce_mag_max,
			restore_hp, restore_hp_pct, restore_mp, restore_mp_pct, set_id,
			can_trade, can_sell, can_drop,
			req_level_type2, req_level2, req_level_type3, req_level3,
			req_level_type4, req_level4, repair_cost, decay_time_ms,
			phys_attack_min_hi, phys_attack_max_hi, mag_attack_min_hi, mag_attack_max_hi,
			reinforce_phys_min_hi, reinforce_phys_max_hi, reinforce_mag_min_hi, reinforce_mag_max_hi,
			attack_range, reinforce_rate1, reinforce_rate2, reinforce_rate3, cooltime_group, cooltime_ms,
			parry_ratio_min, parry_ratio_max, can_use, can_pick, code_name
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$40,$41,$42,$43,$44,$45,$46,$47,$48,$49,$50,$51,$52,$53,$54,$55,$56,$57,$58,$59,$60,$61,$62,$63,$64,$65,$66,$67,$68,$69,$70,$71)
		ON CONFLICT (id) DO UPDATE SET
			type_id1=excluded.type_id1, type_id2=excluded.type_id2, type_id3=excluded.type_id3, type_id4=excluded.type_id4,
			country=excluded.country, req_gender=excluded.req_gender,
			req_level_type1=excluded.req_level_type1, req_level1=excluded.req_level1,
			price=excluded.price, sell_price=excluded.sell_price,
			max_stack=excluded.max_stack, req_str=excluded.req_str, req_int=excluded.req_int,
			item_class=excluded.item_class, two_handed=excluded.two_handed,
			durability_min=excluded.durability_min, durability_max=excluded.durability_max,
			phys_defense_min=excluded.phys_defense_min, phys_defense_max=excluded.phys_defense_max,
			mag_defense_min=excluded.mag_defense_min, mag_defense_max=excluded.mag_defense_max,
			phys_attack_min=excluded.phys_attack_min, phys_attack_max=excluded.phys_attack_max,
			mag_attack_min=excluded.mag_attack_min, mag_attack_max=excluded.mag_attack_max,
			hit_rate_min=excluded.hit_rate_min, hit_rate_max=excluded.hit_rate_max,
			critical_min=excluded.critical_min, critical_max=excluded.critical_max,
			block_ratio_min=excluded.block_ratio_min, block_ratio_max=excluded.block_ratio_max,
			reinforce_phys_min=excluded.reinforce_phys_min, reinforce_phys_max=excluded.reinforce_phys_max,
			reinforce_mag_min=excluded.reinforce_mag_min, reinforce_mag_max=excluded.reinforce_mag_max,
			restore_hp=excluded.restore_hp, restore_hp_pct=excluded.restore_hp_pct,
			restore_mp=excluded.restore_mp, restore_mp_pct=excluded.restore_mp_pct,
			set_id=excluded.set_id,
			can_trade=excluded.can_trade, can_sell=excluded.can_sell,
			can_drop=excluded.can_drop,
			req_level_type2=excluded.req_level_type2, req_level2=excluded.req_level2,
			req_level_type3=excluded.req_level_type3, req_level3=excluded.req_level3,
			req_level_type4=excluded.req_level_type4, req_level4=excluded.req_level4,
			repair_cost=excluded.repair_cost,
			decay_time_ms=excluded.decay_time_ms,
			phys_attack_min_hi=excluded.phys_attack_min_hi, phys_attack_max_hi=excluded.phys_attack_max_hi,
			mag_attack_min_hi=excluded.mag_attack_min_hi, mag_attack_max_hi=excluded.mag_attack_max_hi,
			reinforce_phys_min_hi=excluded.reinforce_phys_min_hi, reinforce_phys_max_hi=excluded.reinforce_phys_max_hi,
			reinforce_mag_min_hi=excluded.reinforce_mag_min_hi, reinforce_mag_max_hi=excluded.reinforce_mag_max_hi,
			attack_range=excluded.attack_range,
			reinforce_rate1=excluded.reinforce_rate1, reinforce_rate2=excluded.reinforce_rate2, reinforce_rate3=excluded.reinforce_rate3,
			cooltime_group=excluded.cooltime_group, cooltime_ms=excluded.cooltime_ms,
			parry_ratio_min=excluded.parry_ratio_min, parry_ratio_max=excluded.parry_ratio_max,
			can_use=excluded.can_use, can_pick=excluded.can_pick, code_name=excluded.code_name
	`)
	if err != nil {
		return fmt.Errorf("refdata: preparing insert: %w", err)
	}
	defer stmt.Close()

	for _, it := range items {
		if _, err := stmt.ExecContext(ctx,
			it.ID, it.MaxStack, it.ReqStr, it.ReqInt, it.ItemClass, it.TwoHanded,
			it.DurabilityMin, it.DurabilityMax, it.PhysDefenseMin, it.PhysDefenseMax,
			it.MagDefenseMin, it.MagDefenseMax, it.PhysAttackMin, it.PhysAttackMax,
			it.MagAttackMin, it.MagAttackMax, it.HitRateMin, it.HitRateMax,
			it.CriticalMin, it.CriticalMax,
			it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4, it.Country, it.ReqGender, it.ReqLevelType1, it.ReqLevel1,
			it.Price, it.SellPrice, it.BlockRatioMin, it.BlockRatioMax,
			it.ReinforcePhysMin, it.ReinforcePhysMax, it.ReinforceMagMin, it.ReinforceMagMax,
			it.RestoreHP, it.RestoreHPPct, it.RestoreMP, it.RestoreMPPct, it.SetID, it.CanTrade, it.CanSell, it.CanDrop,
			it.ReqLevelType2, it.ReqLevel2, it.ReqLevelType3, it.ReqLevel3, it.ReqLevelType4, it.ReqLevel4, it.RepairCost, it.DecayTimeMs,
			it.PhysAttackMinHi, it.PhysAttackMaxHi, it.MagAttackMinHi, it.MagAttackMaxHi,
			it.ReinforcePhysMinHi, it.ReinforcePhysMaxHi, it.ReinforceMagMinHi, it.ReinforceMagMaxHi,
			it.Range, int64(it.ReinforceRate1), int64(it.ReinforceRate2), int64(it.ReinforceRate3),
			int64(it.CooltimeGroup), it.CooltimeMs,
			it.ParryRatioMin, it.ParryRatioMax, it.CanUse, it.CanPick, it.CodeName,
		); err != nil {
			return fmt.Errorf("refdata: inserting item %d: %w", it.ID, err)
		}
	}
	return tx.Commit()
}

// GetItem looks up one item by ID.
func (s *SQLStore) GetItem(ctx context.Context, id int64) (*Item, error) {
	var it Item
	row := s.db.QueryRowContext(ctx, `
		SELECT id, max_stack, req_str, req_int, item_class, two_handed,
			durability_min, durability_max, phys_defense_min, phys_defense_max,
			mag_defense_min, mag_defense_max, phys_attack_min, phys_attack_max,
			mag_attack_min, mag_attack_max, hit_rate_min, hit_rate_max,
			critical_min, critical_max,
			type_id1, type_id2, type_id3, type_id4, country, req_gender, req_level_type1, req_level1,
			price, sell_price, block_ratio_min, block_ratio_max,
			reinforce_phys_min, reinforce_phys_max, reinforce_mag_min, reinforce_mag_max,
			restore_hp, restore_hp_pct, restore_mp, restore_mp_pct, set_id,
			can_trade, can_sell, can_drop,
			req_level_type2, req_level2, req_level_type3, req_level3,
			req_level_type4, req_level4, repair_cost, decay_time_ms,
			phys_attack_min_hi, phys_attack_max_hi, mag_attack_min_hi, mag_attack_max_hi,
			reinforce_phys_min_hi, reinforce_phys_max_hi, reinforce_mag_min_hi, reinforce_mag_max_hi,
			attack_range, reinforce_rate1, reinforce_rate2, reinforce_rate3, cooltime_group, cooltime_ms,
			parry_ratio_min, parry_ratio_max, can_use, can_pick, code_name
		FROM items WHERE id = $1`, id)
	var rr [3]int64
	var cg int64
	if err := row.Scan(
		&it.ID, &it.MaxStack, &it.ReqStr, &it.ReqInt, &it.ItemClass, &it.TwoHanded,
		&it.DurabilityMin, &it.DurabilityMax, &it.PhysDefenseMin, &it.PhysDefenseMax,
		&it.MagDefenseMin, &it.MagDefenseMax, &it.PhysAttackMin, &it.PhysAttackMax,
		&it.MagAttackMin, &it.MagAttackMax, &it.HitRateMin, &it.HitRateMax,
		&it.CriticalMin, &it.CriticalMax,
		&it.TypeID1, &it.TypeID2, &it.TypeID3, &it.TypeID4, &it.Country, &it.ReqGender, &it.ReqLevelType1, &it.ReqLevel1,
		&it.Price, &it.SellPrice, &it.BlockRatioMin, &it.BlockRatioMax,
		&it.ReinforcePhysMin, &it.ReinforcePhysMax, &it.ReinforceMagMin, &it.ReinforceMagMax,
		&it.RestoreHP, &it.RestoreHPPct, &it.RestoreMP, &it.RestoreMPPct, &it.SetID, &it.CanTrade, &it.CanSell, &it.CanDrop,
		&it.ReqLevelType2, &it.ReqLevel2, &it.ReqLevelType3, &it.ReqLevel3, &it.ReqLevelType4, &it.ReqLevel4, &it.RepairCost, &it.DecayTimeMs,
		&it.PhysAttackMinHi, &it.PhysAttackMaxHi, &it.MagAttackMinHi, &it.MagAttackMaxHi,
		&it.ReinforcePhysMinHi, &it.ReinforcePhysMaxHi, &it.ReinforceMagMinHi, &it.ReinforceMagMaxHi,
		&it.Range, &rr[0], &rr[1], &rr[2], &cg, &it.CooltimeMs,
		&it.ParryRatioMin, &it.ParryRatioMax, &it.CanUse, &it.CanPick, &it.CodeName,
	); err != nil {
		if err == sql.ErrNoRows {
			return nil, fmt.Errorf("refdata: querying item %d: %w", id, ErrItemNotFound)
		}
		return nil, fmt.Errorf("refdata: querying item %d: %w", id, err)
	}
	it.ReinforceRate1, it.ReinforceRate2, it.ReinforceRate3 = uint32(rr[0]), uint32(rr[1]), uint32(rr[2])
	it.CooltimeGroup = uint32(cg)
	return &it, nil
}

// ListAll returns every imported item, ordered by ID. Used by the shop to
// build its catalog -- with refdata being "bring your own data" (see
// docs/protocol/refdata_schema.md), a real deployment's catalog could be
// large, but this project's own placeholder/test data is small enough
// that a full listing is the simplest thing that works.
func (s *SQLStore) ListAll(ctx context.Context) ([]*Item, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, max_stack, req_str, req_int, item_class, two_handed,
			durability_min, durability_max, phys_defense_min, phys_defense_max,
			mag_defense_min, mag_defense_max, phys_attack_min, phys_attack_max,
			mag_attack_min, mag_attack_max, hit_rate_min, hit_rate_max,
			critical_min, critical_max,
			type_id1, type_id2, type_id3, type_id4, country, req_gender, req_level_type1, req_level1,
			price, sell_price, block_ratio_min, block_ratio_max,
			reinforce_phys_min, reinforce_phys_max, reinforce_mag_min, reinforce_mag_max,
			restore_hp, restore_hp_pct, restore_mp, restore_mp_pct, set_id,
			can_trade, can_sell, can_drop,
			req_level_type2, req_level2, req_level_type3, req_level3,
			req_level_type4, req_level4, repair_cost, decay_time_ms,
			phys_attack_min_hi, phys_attack_max_hi, mag_attack_min_hi, mag_attack_max_hi,
			reinforce_phys_min_hi, reinforce_phys_max_hi, reinforce_mag_min_hi, reinforce_mag_max_hi,
			attack_range, reinforce_rate1, reinforce_rate2, reinforce_rate3, cooltime_group, cooltime_ms,
			parry_ratio_min, parry_ratio_max, can_use, can_pick, code_name
		FROM items ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("refdata: listing items: %w", err)
	}
	defer rows.Close()

	var out []*Item
	for rows.Next() {
		var it Item
		var rr [3]int64
		var cg int64
		if err := rows.Scan(
			&it.ID, &it.MaxStack, &it.ReqStr, &it.ReqInt, &it.ItemClass, &it.TwoHanded,
			&it.DurabilityMin, &it.DurabilityMax, &it.PhysDefenseMin, &it.PhysDefenseMax,
			&it.MagDefenseMin, &it.MagDefenseMax, &it.PhysAttackMin, &it.PhysAttackMax,
			&it.MagAttackMin, &it.MagAttackMax, &it.HitRateMin, &it.HitRateMax,
			&it.CriticalMin, &it.CriticalMax,
			&it.TypeID1, &it.TypeID2, &it.TypeID3, &it.TypeID4, &it.Country, &it.ReqGender, &it.ReqLevelType1, &it.ReqLevel1,
			&it.Price, &it.SellPrice, &it.BlockRatioMin, &it.BlockRatioMax,
			&it.ReinforcePhysMin, &it.ReinforcePhysMax, &it.ReinforceMagMin, &it.ReinforceMagMax,
			&it.RestoreHP, &it.RestoreHPPct, &it.RestoreMP, &it.RestoreMPPct, &it.SetID, &it.CanTrade, &it.CanSell, &it.CanDrop,
			&it.ReqLevelType2, &it.ReqLevel2, &it.ReqLevelType3, &it.ReqLevel3, &it.ReqLevelType4, &it.ReqLevel4, &it.RepairCost, &it.DecayTimeMs,
			&it.PhysAttackMinHi, &it.PhysAttackMaxHi, &it.MagAttackMinHi, &it.MagAttackMaxHi,
			&it.ReinforcePhysMinHi, &it.ReinforcePhysMaxHi, &it.ReinforceMagMinHi, &it.ReinforceMagMaxHi,
			&it.Range, &rr[0], &rr[1], &rr[2], &cg, &it.CooltimeMs,
			&it.ParryRatioMin, &it.ParryRatioMax, &it.CanUse, &it.CanPick, &it.CodeName,
		); err != nil {
			return nil, fmt.Errorf("refdata: scanning item: %w", err)
		}
		it.ReinforceRate1, it.ReinforceRate2, it.ReinforceRate3 = uint32(rr[0]), uint32(rr[1]), uint32(rr[2])
		it.CooltimeGroup = uint32(cg)
		out = append(out, &it)
	}
	return out, rows.Err()
}

// Count returns how many items are stored.
func (s *SQLStore) Count(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM items`).Scan(&n)
	return n, err
}

// GetMaxStack implements inventory.MaxStackLookup.
func (s *SQLStore) GetMaxStack(ctx context.Context, itemID int64) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT max_stack FROM items WHERE id = $1`, itemID).Scan(&n)
	if err == sql.ErrNoRows {
		// No row means no configured stack limit, which the inventory
		// already reads as "this does not stack" -- same as a row that
		// says zero. Returning an error instead made an item with no
		// reference data impossible to *hold*, which cost a new character
		// their starting kit on any deployment that had not imported those
		// five items: "adding item 4734 for slot 1: querying max stack:
		// not found". Refusing to store an item because its stack size is
		// unknown loses the item; storing it one to a slot does not.
		return 0, nil
	}
	if err != nil {
		return 0, fmt.Errorf("refdata: querying max stack for item %d: %w", itemID, err)
	}
	return n, nil
}

// ImportSkills upserts every skill in skills (by ID), inside one
// transaction.
func (s *SQLStore) ImportSkills(ctx context.Context, skills []Skill) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("refdata: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO skills (
			id, group_id, basic_code, basic_name, basic_level, basic_chain_code,
			basic_recycle_cost, preparing_time_ms, casting_time_ms, action_duration_ms,
			reuse_delay_ms, cool_time_ms, flying_speed, interruptable, overlap, auto_attack_type,
			range_, consume_hp, consume_mp, req_learn_sp, req_learn_race, ui_skill_name,
			mastery1, mastery_level1,
			attack_percent, damage_min, damage_max, hit_count, attack_type,
			req_cast_weapon1, req_cast_weapon2, req_cast_list_count,
			req_cast_list, req_cast_all, no_combat_param, zero_damage, floor_blow,
			req_learn_skill1, req_learn_skill_level1, req_learn_skill2, req_learn_skill_level2, req_learn_skill3, req_learn_skill_level3,
			self_heal_hp, self_heal_mp, cooldown_group, sit_gate
		) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22,$23,$24,$25,$26,$27,$28,$29,$30,$31,$32,$33,$34,$35,$36,$37,$38,$39,$40,$41,$42,$43,$44,$45,$46,$47)
		ON CONFLICT (id) DO UPDATE SET
			group_id=excluded.group_id, basic_code=excluded.basic_code, basic_name=excluded.basic_name,
			basic_level=excluded.basic_level, basic_chain_code=excluded.basic_chain_code,
			basic_recycle_cost=excluded.basic_recycle_cost, preparing_time_ms=excluded.preparing_time_ms,
			casting_time_ms=excluded.casting_time_ms, action_duration_ms=excluded.action_duration_ms,
			reuse_delay_ms=excluded.reuse_delay_ms, cool_time_ms=excluded.cool_time_ms,
			flying_speed=excluded.flying_speed, interruptable=excluded.interruptable,
			overlap=excluded.overlap, auto_attack_type=excluded.auto_attack_type,
			range_=excluded.range_, consume_hp=excluded.consume_hp, consume_mp=excluded.consume_mp,
			req_learn_sp=excluded.req_learn_sp, req_learn_race=excluded.req_learn_race,
			ui_skill_name=excluded.ui_skill_name, mastery1=excluded.mastery1,
			mastery_level1=excluded.mastery_level1,
			attack_percent=excluded.attack_percent, damage_min=excluded.damage_min,
			damage_max=excluded.damage_max, hit_count=excluded.hit_count,
			attack_type=excluded.attack_type,
			req_cast_weapon1=excluded.req_cast_weapon1, req_cast_weapon2=excluded.req_cast_weapon2,
			req_cast_list_count=excluded.req_cast_list_count,
			req_cast_list=excluded.req_cast_list, req_cast_all=excluded.req_cast_all,
			no_combat_param=excluded.no_combat_param, zero_damage=excluded.zero_damage,
			floor_blow=excluded.floor_blow,
			req_learn_skill1=excluded.req_learn_skill1, req_learn_skill_level1=excluded.req_learn_skill_level1,
			req_learn_skill2=excluded.req_learn_skill2, req_learn_skill_level2=excluded.req_learn_skill_level2,
			req_learn_skill3=excluded.req_learn_skill3, req_learn_skill_level3=excluded.req_learn_skill_level3,
			self_heal_hp=excluded.self_heal_hp, self_heal_mp=excluded.self_heal_mp,
			cooldown_group=excluded.cooldown_group, sit_gate=excluded.sit_gate
	`)
	if err != nil {
		return fmt.Errorf("refdata: preparing insert: %w", err)
	}
	defer stmt.Close()

	for _, sk := range skills {
		if _, err := stmt.ExecContext(ctx,
			sk.ID, sk.GroupID, sk.BasicCode, sk.BasicName, sk.BasicLevel, sk.BasicChainCode,
			sk.BasicRecycleCost, sk.PreparingTimeMs, sk.CastingTimeMs, sk.ActionDurationMs,
			sk.ReuseDelayMs, sk.CoolTimeMs, sk.FlyingSpeed, sk.Interruptable, sk.Overlap, sk.AutoAttackType,
			sk.Range, sk.ConsumeHP, sk.ConsumeMP, sk.ReqLearnSP, sk.ReqLearnRace, sk.UISkillName,
			sk.Mastery1, sk.MasteryLevel1,
			sk.AttackPercent, sk.DamageMin, sk.DamageMax, sk.HitCount, sk.AttackType,
			sk.ReqCastWeapon1, sk.ReqCastWeapon2, sk.ReqCastListCount,
			sk.ReqCastList, sk.ReqCastAll, sk.NoCombatParam, sk.ZeroDamage, sk.FloorBlow,
			sk.ReqLearnSkill1, sk.ReqLearnSkillLevel1, sk.ReqLearnSkill2, sk.ReqLearnSkillLevel2, sk.ReqLearnSkill3, sk.ReqLearnSkillLevel3,
			sk.SelfHealHP, sk.SelfHealMP, sk.CooldownGroup, sk.SitGate,
		); err != nil {
			return fmt.Errorf("refdata: inserting skill %d: %w", sk.ID, err)
		}
	}
	return tx.Commit()
}

// GetSkill looks up one skill by ID.
func (s *SQLStore) GetSkill(ctx context.Context, id int64) (*Skill, error) {
	var sk Skill
	row := s.db.QueryRowContext(ctx, `
		SELECT id, group_id, basic_code, basic_name, basic_level, basic_chain_code,
			basic_recycle_cost, preparing_time_ms, casting_time_ms, action_duration_ms,
			reuse_delay_ms, cool_time_ms, flying_speed, interruptable, overlap, auto_attack_type,
			range_, consume_hp, consume_mp, req_learn_sp, req_learn_race, ui_skill_name,
			mastery1, mastery_level1,
			attack_percent, damage_min, damage_max, hit_count, attack_type,
			req_cast_weapon1, req_cast_weapon2, req_cast_list_count,
			req_cast_list, req_cast_all, no_combat_param, zero_damage, floor_blow,
			req_learn_skill1, req_learn_skill_level1, req_learn_skill2, req_learn_skill_level2, req_learn_skill3, req_learn_skill_level3,
			self_heal_hp, self_heal_mp, cooldown_group, sit_gate
		FROM skills WHERE id = $1`, id)
	if err := row.Scan(
		&sk.ID, &sk.GroupID, &sk.BasicCode, &sk.BasicName, &sk.BasicLevel, &sk.BasicChainCode,
		&sk.BasicRecycleCost, &sk.PreparingTimeMs, &sk.CastingTimeMs, &sk.ActionDurationMs,
		&sk.ReuseDelayMs, &sk.CoolTimeMs, &sk.FlyingSpeed, &sk.Interruptable, &sk.Overlap, &sk.AutoAttackType,
		&sk.Range, &sk.ConsumeHP, &sk.ConsumeMP, &sk.ReqLearnSP, &sk.ReqLearnRace, &sk.UISkillName,
		&sk.Mastery1, &sk.MasteryLevel1,
		&sk.AttackPercent, &sk.DamageMin, &sk.DamageMax, &sk.HitCount, &sk.AttackType,
		&sk.ReqCastWeapon1, &sk.ReqCastWeapon2, &sk.ReqCastListCount,
		&sk.ReqCastList, &sk.ReqCastAll, &sk.NoCombatParam, &sk.ZeroDamage, &sk.FloorBlow,
		&sk.ReqLearnSkill1, &sk.ReqLearnSkillLevel1, &sk.ReqLearnSkill2, &sk.ReqLearnSkillLevel2, &sk.ReqLearnSkill3, &sk.ReqLearnSkillLevel3,
		&sk.SelfHealHP, &sk.SelfHealMP, &sk.CooldownGroup, &sk.SitGate,
	); err != nil {
		return nil, fmt.Errorf("refdata: querying skill %d: %w", id, err)
	}
	return &sk, nil
}

// ListAllSkills returns every imported skill, ordered by ID. See
// ListAll's doc comment for the same "small enough to list in full" caveat.
func (s *SQLStore) ListAllSkills(ctx context.Context) ([]*Skill, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT id, group_id, basic_code, basic_name, basic_level, basic_chain_code,
			basic_recycle_cost, preparing_time_ms, casting_time_ms, action_duration_ms,
			reuse_delay_ms, cool_time_ms, flying_speed, interruptable, overlap, auto_attack_type,
			range_, consume_hp, consume_mp, req_learn_sp, req_learn_race, ui_skill_name,
			mastery1, mastery_level1,
			attack_percent, damage_min, damage_max, hit_count, attack_type,
			req_cast_weapon1, req_cast_weapon2, req_cast_list_count,
			req_cast_list, req_cast_all, no_combat_param, zero_damage, floor_blow,
			req_learn_skill1, req_learn_skill_level1, req_learn_skill2, req_learn_skill_level2, req_learn_skill3, req_learn_skill_level3,
			self_heal_hp, self_heal_mp, cooldown_group, sit_gate
		FROM skills ORDER BY id`)
	if err != nil {
		return nil, fmt.Errorf("refdata: listing skills: %w", err)
	}
	defer rows.Close()

	var out []*Skill
	for rows.Next() {
		var sk Skill
		if err := rows.Scan(
			&sk.ID, &sk.GroupID, &sk.BasicCode, &sk.BasicName, &sk.BasicLevel, &sk.BasicChainCode,
			&sk.BasicRecycleCost, &sk.PreparingTimeMs, &sk.CastingTimeMs, &sk.ActionDurationMs,
			&sk.ReuseDelayMs, &sk.CoolTimeMs, &sk.FlyingSpeed, &sk.Interruptable, &sk.Overlap, &sk.AutoAttackType,
			&sk.Range, &sk.ConsumeHP, &sk.ConsumeMP, &sk.ReqLearnSP, &sk.ReqLearnRace, &sk.UISkillName,
			&sk.Mastery1, &sk.MasteryLevel1,
			&sk.AttackPercent, &sk.DamageMin, &sk.DamageMax, &sk.HitCount, &sk.AttackType,
			&sk.ReqCastWeapon1, &sk.ReqCastWeapon2, &sk.ReqCastListCount,
			&sk.ReqCastList, &sk.ReqCastAll, &sk.NoCombatParam, &sk.ZeroDamage, &sk.FloorBlow,
			&sk.ReqLearnSkill1, &sk.ReqLearnSkillLevel1, &sk.ReqLearnSkill2, &sk.ReqLearnSkillLevel2, &sk.ReqLearnSkill3, &sk.ReqLearnSkillLevel3,
			&sk.SelfHealHP, &sk.SelfHealMP, &sk.CooldownGroup, &sk.SitGate,
		); err != nil {
			return nil, fmt.Errorf("refdata: scanning skill: %w", err)
		}
		out = append(out, &sk)
	}
	return out, rows.Err()
}

// CountSkills returns how many skills are stored.
func (s *SQLStore) CountSkills(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM skills`).Scan(&n)
	return n, err
}

// ImportMonsterDrops upserts every drop in drops (by MonsterID+ItemGroupID),
// inside one transaction.
func (s *SQLStore) ImportMonsterDrops(ctx context.Context, drops []MonsterDrop) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("refdata: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO monster_drops (
			monster_id, item_group_id, overlap, drop_amount_min, drop_amount_max, drop_ratio
		) VALUES ($1,$2,$3,$4,$5,$6)
		ON CONFLICT (monster_id, item_group_id) DO UPDATE SET
			overlap=excluded.overlap, drop_amount_min=excluded.drop_amount_min,
			drop_amount_max=excluded.drop_amount_max, drop_ratio=excluded.drop_ratio
	`)
	if err != nil {
		return fmt.Errorf("refdata: preparing insert: %w", err)
	}
	defer stmt.Close()

	for _, d := range drops {
		if _, err := stmt.ExecContext(ctx,
			d.MonsterID, d.ItemGroupID, d.Overlap, d.DropAmountMin, d.DropAmountMax, d.DropRatio,
		); err != nil {
			return fmt.Errorf("refdata: inserting monster drop (%d, %d): %w", d.MonsterID, d.ItemGroupID, err)
		}
	}
	return tx.Commit()
}

// GetMonsterDrops returns every real drop assignment for monsterID, ordered
// by item group ID.
func (s *SQLStore) GetMonsterDrops(ctx context.Context, monsterID int64) ([]*MonsterDrop, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT monster_id, item_group_id, overlap, drop_amount_min, drop_amount_max, drop_ratio
		FROM monster_drops WHERE monster_id = $1 ORDER BY item_group_id`, monsterID)
	if err != nil {
		return nil, fmt.Errorf("refdata: querying monster drops for %d: %w", monsterID, err)
	}
	defer rows.Close()

	var out []*MonsterDrop
	for rows.Next() {
		var d MonsterDrop
		if err := rows.Scan(
			&d.MonsterID, &d.ItemGroupID, &d.Overlap, &d.DropAmountMin, &d.DropAmountMax, &d.DropRatio,
		); err != nil {
			return nil, fmt.Errorf("refdata: scanning monster drop: %w", err)
		}
		out = append(out, &d)
	}
	return out, rows.Err()
}

// CountMonsterDrops returns how many monster-drop rows are stored.
func (s *SQLStore) CountMonsterDrops(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM monster_drops`).Scan(&n)
	return n, err
}

// ImportDropGroupEntries upserts every entry in entries (by GroupID+ItemID),
// inside one transaction.
func (s *SQLStore) ImportDropGroupEntries(ctx context.Context, entries []DropGroupEntry) error {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("refdata: beginning transaction: %w", err)
	}
	defer tx.Rollback()

	stmt, err := tx.PrepareContext(ctx, `
		INSERT INTO drop_group_entries (group_id, code_name, item_id, select_ratio)
		VALUES ($1,$2,$3,$4)
		ON CONFLICT (group_id, item_id) DO UPDATE SET
			code_name=excluded.code_name, select_ratio=excluded.select_ratio
	`)
	if err != nil {
		return fmt.Errorf("refdata: preparing insert: %w", err)
	}
	defer stmt.Close()

	for _, e := range entries {
		if _, err := stmt.ExecContext(ctx,
			e.GroupID, e.CodeName, e.ItemID, e.SelectRatio,
		); err != nil {
			return fmt.Errorf("refdata: inserting drop group entry (%d, %d): %w", e.GroupID, e.ItemID, err)
		}
	}
	return tx.Commit()
}

// GetDropGroupEntries returns every real item in groupID, ordered by item
// ID.
func (s *SQLStore) GetDropGroupEntries(ctx context.Context, groupID int64) ([]*DropGroupEntry, error) {
	rows, err := s.db.QueryContext(ctx, `
		SELECT group_id, code_name, item_id, select_ratio
		FROM drop_group_entries WHERE group_id = $1 ORDER BY item_id`, groupID)
	if err != nil {
		return nil, fmt.Errorf("refdata: querying drop group entries for %d: %w", groupID, err)
	}
	defer rows.Close()

	var out []*DropGroupEntry
	for rows.Next() {
		var e DropGroupEntry
		if err := rows.Scan(&e.GroupID, &e.CodeName, &e.ItemID, &e.SelectRatio); err != nil {
			return nil, fmt.Errorf("refdata: scanning drop group entry: %w", err)
		}
		out = append(out, &e)
	}
	return out, rows.Err()
}

// CountDropGroupEntries returns how many drop-group-entry rows are stored.
func (s *SQLStore) CountDropGroupEntries(ctx context.Context) (int, error) {
	var n int
	err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM drop_group_entries`).Scan(&n)
	return n, err
}
