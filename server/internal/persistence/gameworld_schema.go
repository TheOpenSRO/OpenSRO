package persistence

// CharInstanceWorldSchema is OpenSRO's PostgreSQL table for a character's
// place in an instance (round 869, internal/gameworld's SQLCharStore): the
// columns of _CharInstanceWorldData (MEASURED: CharID, DungeonKeyID, WorldID,
// LayerID, OpenedTime, RegionID, PosX/Y/Z (int), IsActivated, EnterCount,
// LastEnterTime; written by AQ_GameWorld through
// _CharInstanceWorldDataUpdate, READ s:0x441b40, and deleted per character
// and world, s:0x602d50). OURS: the snake-case spellings and the key. The
// return point is not here: it stays on the character (game_worlds.md 6).
const CharInstanceWorldSchema = `
CREATE TABLE IF NOT EXISTS char_instance_world (
	char_id         BIGINT NOT NULL,
	dungeon_key_id  BIGINT NOT NULL,
	world_id        INTEGER NOT NULL,
	layer_id        INTEGER NOT NULL,
	opened_time     TIMESTAMPTZ NOT NULL,
	region_id       INTEGER NOT NULL,
	pos_x           INTEGER NOT NULL,
	pos_y           INTEGER NOT NULL,
	pos_z           INTEGER NOT NULL,
	is_activated    SMALLINT NOT NULL DEFAULT 1,
	enter_count     INTEGER NOT NULL DEFAULT 0,
	last_enter_time TIMESTAMPTZ NOT NULL,
	PRIMARY KEY (char_id, world_id)
);
`
