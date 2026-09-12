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

// ErrInsufficientSkillPoints is returned by RaiseMastery when the character
// does not have enough skill points to pay the cost.
var ErrInsufficientSkillPoints = errors.New("skill: insufficient skill points")

// ErrMasteryCapped is returned by RaiseMastery when the mastery is already at
// the level cap the caller passed.
var ErrMasteryCapped = errors.New("skill: mastery at level cap")

// Store tracks which skills each character knows and when they last used
// each one (for cooldowns), plus the character's skill points and per-mastery
// trained levels (the skill economy: points are earned from mob kills and
// spent raising masteries, which is what unlocks skills in the skill window).
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

	// SkillPoints returns characterID's unspent skill points (0 if never
	// earned any).
	SkillPoints(ctx context.Context, characterID int64) (int, error)

	// AddSkillPoints changes characterID's skill points by delta (positive
	// from a mob kill; negative to spend), never letting the total go below
	// zero, and returns the new total.
	AddSkillPoints(ctx context.Context, characterID int64, delta int) (int, error)

	// MasteryLevels returns characterID's trained level for each mastery it
	// has raised (masteryID -> level); masteries never raised are absent.
	MasteryLevels(ctx context.Context, characterID int64) (map[int64]int, error)

	// RaiseMastery raises masteryID's level by one for characterID, spending
	// cost skill points -- but only if the character has at least cost points
	// and the mastery's current level is below levelCap. Returns the new
	// mastery level, or ErrInsufficientSkillPoints / ErrMasteryCapped.
	RaiseMastery(ctx context.Context, characterID, masteryID int64, cost, levelCap int) (newLevel int, err error)
}
