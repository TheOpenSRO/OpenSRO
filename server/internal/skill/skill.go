// Package skill implements a small, own-designed skill system: a static
// catalog of a few skills a character can learn and then use in combat for
// bonus damage on a cooldown. This catalog is entirely invented placeholder
// content, not derived from the original -- refdata.Skill now exists as a
// real, importable schema for the real _RefSkill table (all 118 columns
// confirmed, see docs/protocol/refdata_schema.md), including real resource
// costs (ConsumeHP/ConsumeMP) and requirements now that a full pass has been
// done -- but even with every column catalogued, none of them encodes a
// skill's actual damage/effect, so importing real skills would only replace
// part of what Skill needs here (identity/cost/timing/requirements, not
// combat behavior). See docs/protocol/refdata_schema.md's status section.
package skill

import (
	"context"
	"errors"
	"time"
)

// Skill is one usable skill.
type Skill struct {
	ID              int64
	Name            string
	DamageBonus     int
	CooldownSeconds int
}

// Catalog is this project's own small, fixed skill list. Extend once real
// game-design work (or imported _RefSkill data) informs what should
// actually exist.
var Catalog = map[int64]Skill{
	1: {ID: 1, Name: "Power Strike", DamageBonus: 15, CooldownSeconds: 5},
	2: {ID: 2, Name: "Whirlwind", DamageBonus: 10, CooldownSeconds: 3},
}

// ErrUnknownSkill is returned when a skill ID isn't in Catalog.
var ErrUnknownSkill = errors.New("skill: unknown skill")

// ErrAlreadyKnown is returned by Store.Learn when the character already
// knows the skill.
var ErrAlreadyKnown = errors.New("skill: already known")

// ErrNotKnown is returned by Store.RecordUse (via the session handler) when
// a character tries to use a skill they haven't learned.
var ErrNotKnown = errors.New("skill: not known")

// ErrOnCooldown is returned when a skill was used too recently to use
// again.
var ErrOnCooldown = errors.New("skill: on cooldown")

// Store tracks which skills each character knows and when they last used
// each one (for cooldowns).
type Store interface {
	// Learn adds skillID to characterID's known skills. Returns
	// ErrAlreadyKnown if already known.
	Learn(ctx context.Context, characterID, skillID int64) error

	// Knows reports whether characterID has learned skillID.
	Knows(ctx context.Context, characterID, skillID int64) (bool, error)

	// KnownSkills returns every skill ID characterID has learned.
	KnownSkills(ctx context.Context, characterID int64) ([]int64, error)

	// LastUsed returns when characterID last used skillID, and whether
	// they've ever used it at all.
	LastUsed(ctx context.Context, characterID, skillID int64) (time.Time, bool, error)

	// RecordUse marks skillID as used by characterID at usedAt (for
	// cooldown tracking).
	RecordUse(ctx context.Context, characterID, skillID int64, usedAt time.Time) error
}
