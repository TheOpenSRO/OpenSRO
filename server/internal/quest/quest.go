// Package quest implements this project's own quest system: a small fixed
// catalog of "kill N of monster X for gold" quests, with Postgres-backed
// per-character progress that survives disconnects/restarts (unlike
// party/combat, quest progress isn't something a player should lose on relog).
//
// CORRECTION 2026-09-16. This comment used to justify the invented catalog with
// "no real _RefQuest-equivalent data has been catalogued yet to import from".
// That is not true, and it was never checked -- Media.pk2 carries two quest
// tables:
//
//	questdata.txt          697 rows: quest id, code name (QNO_*), and the
//	                       SN_* localisation keys for its name, payment,
//	                       conditions and NPC
//	questcontentsdata.txt  989 rows: quest code, display name, a category
//	                       (0/1/3), a PREREQUISITE quest code on 373 of them,
//	                       up to eight SN_CON_* objective/step keys, and a
//	                       numeric field on 442 rows
//
// So the quest GRAPH is real and importable: ids, code names, prerequisites
// (QNO_CH_PRIEST_1 requires QNO_WC_PRIEST2_1) and how many steps a quest has
// (QNO_CH_PRIEST_1 has eight). The SN_* keys resolve to real text through the
// same textdata mechanism the NPC chat already uses.
//
// WHAT IS GENUINELY MISSING is the only part that would let the catalog below be
// replaced wholesale: the machine-readable objective TARGETS. A step is a
// localisation key pointing at human text ("bring me five wolf pelts"), not a
// (monster id, count) pair, so "kill N of monster X" cannot be imported from
// these tables. That part is server-side, like the drop tables.
//
// The numeric field on 442 rows runs 5..110, which is exactly this client's
// character level range (see leveldata.MaxCharacterLevel) and clusters at
// 101-110. A level requirement is the obvious reading and is NOT asserted here:
// it is a range argument with no use-site behind it, which is the shape that has
// been wrong twice on this project.
package quest

import (
	"context"
	"errors"
)

// Quest is one entry in Catalog.
type Quest struct {
	ID          int64
	Name        string
	MonsterName string
	TargetKills int
	GoldReward  int64
}

// LATENT ID COLLISION, recorded 2026-09-16 so it is not discovered the hard way.
//
// The ids below are 1 and 2, and the client's own questdata.txt gives those to
// real quests: id 1 is QEVENT_GUIDE and id 2 is QTUTORIAL_CH, the Chinese
// tutorial. Real quest ids run 1..1051 with no gap at the bottom, so ANY small
// invented id collides.
//
// This is not a bug today, because nothing imports real quests -- the objective
// TARGETS are not in the client tables (see the package comment), so there is no
// real quest data to shadow. It becomes one the moment the quest graph is
// imported.
//
// The identical shape WAS a live bug in skill.Catalog: its ids 1 and 2 are
// SKILL_PUNCH_01 and SKILL_CH_SWORD_BASE_01, and the skill-use path consulted
// the catalog before refdata, so players used an invented skill in place of the
// real basic swing. The fix there was ordering, not renumbering. Whoever wires
// real quests in should apply the same rule: try the real table first, fall back
// to this catalog.
// Catalog is the fixed set of quests available. Own design; monster names
// reference cmd/server's own placeholder monster content (monsterSpecs).
var Catalog = map[int64]Quest{
	// MonsterName must match cmd/server's monsterSpecs and combat.LootTables,
	// which use the species names the game's own tables know.
	1: {ID: 1, Name: "Mangyang Cull", MonsterName: "Mangyang", TargetKills: 3, GoldReward: 200},
	2: {ID: 2, Name: "Weasel Hunt", MonsterName: "Weasel", TargetKills: 5, GoldReward: 100},
}

// ErrAlreadyAccepted is returned by Store.Accept when the character has
// already accepted questID.
var ErrAlreadyAccepted = errors.New("quest: already accepted")

// ErrUnknownQuest is returned by Store.Accept when questID isn't in
// Catalog.
var ErrUnknownQuest = errors.New("quest: no such quest")

// Progress is one character's progress on one accepted quest.
type Progress struct {
	QuestID   int64
	Kills     int
	Completed bool
}

// Store persists quest acceptance and kill progress.
type Store interface {
	// Accept records that characterID has taken on questID. Returns
	// ErrUnknownQuest or ErrAlreadyAccepted as appropriate.
	Accept(ctx context.Context, characterID, questID int64) error

	// ListProgress returns characterID's progress on every quest they've
	// accepted.
	ListProgress(ctx context.Context, characterID int64) ([]Progress, error)

	// RecordKill increments progress for every one of characterID's
	// accepted, not-yet-completed quests whose MonsterName matches
	// monsterName. Returns the quests that just became completed as a
	// result of this kill (empty if none did), for the caller to grant
	// rewards and notify the client.
	RecordKill(ctx context.Context, characterID int64, monsterName string) ([]Quest, error)
}
