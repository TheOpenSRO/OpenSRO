// Package quest implements this project's own quest system: a small fixed
// catalog of "kill N of monster X for gold" quests (own design, like
// skill.Catalog -- no real _RefQuest-equivalent data has been catalogued
// yet to import from), with Postgres-backed per-character progress that
// survives disconnects/restarts (unlike party/combat, quest progress isn't
// something a player should lose on relog).
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

// Catalog is the fixed set of quests available. Own design; monster names
// reference cmd/server's own placeholder monster content.
var Catalog = map[int64]Quest{
	1: {ID: 1, Name: "Golem Cull", MonsterName: "Stone Golem", TargetKills: 3, GoldReward: 200},
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
