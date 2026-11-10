package main

import (
	"fmt"
	"log/slog"
	"math"
	"sort"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/nest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
)

// The uniques on the full map (round 661). Each field unique -- rarity 3 --
// stands at one of its npcpos spots at a time: its DB hive (EXTERNAL, the
// Eternity shard) has a total cap of 1 over one nest per spot, and the READ
// rotation (internal/nest: PinAtBuild at build, Repin at each death) moves it
// to the next spot after a uniform wait in the nests' [min, max] window. It
// fights with its own skills (skilldata, READ) under its DB tactics row, and
// its selector (nest.SummonKindFor, READ ids) summons its minions from its
// summon skills' 'ssou' tuples (the DB's _RefSkill, EXTERNAL rows identical
// to the client's skilldata) and fires its _RefAISkill triggers (EXTERNAL).

// uniqueAI is what a unique species fights and summons with, built once per
// species.
type uniqueAI struct {
	kind     nest.SummonKind
	summon   *combat.SummonAI
	triggers []combat.AITrigger
	attacks  []combat.MonsterSkill
	// dropped is the summon skills Summon_A dropped for a taken slot, and
	// zeroCount how many tuples give 0..0 and so spawn nothing.
	dropped   []int64
	zeroCount int
	tuples    int
}

// minionCatalog builds each minion species once.
type minionCatalog struct {
	table  *species.Table
	lookup species.SkillLookup
	db     *nest.DB
	byID   map[int64]*combat.MinionSpec
}

func (c *minionCatalog) get(id int64) *combat.MinionSpec {
	if m, ok := c.byID[id]; ok {
		return m
	}
	var out *combat.MinionSpec
	if row, ok := c.table.ByID(id); ok && !nest.IsCustomSpecies(row.CodeName) {
		spec, _ := specFromRow(monsterSpec{}, row, c.lookup)
		d := hatchDataOf(spec)
		out = &combat.MinionSpec{Species: d.species, MaxHP: d.maxHP, Defense: d.defense, Attack: d.attack, Gold: d.gold,
			Tactics: combatTactics(c.db.OwnTactics(id), float64(session.MonsterRoamRadius))}
	}
	c.byID[id] = out
	return out
}

// buildUniqueAI files a unique's ten skill columns the way its selector's
// RegisterSkill does (AI::CTactics::BindSkillsAndRanges registers each
// column that resolves, in order, with its _RefAISkill row if the tactics
// has one for it):
//
//   - a skill with an AI row -> a trigger (every selector: the `param_3 != 0`
//     branch of 0x5614d0 / 0x562060 / 0x562470);
//   - else a skill with an 'ssou' block -> Summon_A's slot by AI_AttackChance
//     (nest.SummonASlot; a taken slot drops it) or Summon_B's list;
//   - else -> the attack list the draw reads.
//
// Every tuple keeps the count its row gives (READ executor, round 661's
// review): a 0..0 tuple spawns nothing -- 128 of the seven uniques' 130 --
// and only Cerberus's two Ladon tuples summon.
func buildUniqueAI(row species.Row, tac *nest.TacticsRow, db *nest.DB, lookup species.SkillLookup, minions *minionCatalog) *uniqueAI {
	u := &uniqueAI{kind: nest.SummonKindFor(tac.ID)}
	var ai map[string]nest.AISkillRow
	for _, r := range db.AISkills[tac.ID] {
		if ai == nil {
			ai = map[string]nest.AISkillRow{}
		}
		if _, dup := ai[r.SkillCode]; !dup {
			ai[r.SkillCode] = r
		}
	}
	var slots []combat.SummonSkill
	if u.kind == nest.SummonA {
		slots = make([]combat.SummonSkill, 4)
	}
	for _, id := range row.Skills {
		if id == 0 || lookup == nil {
			continue
		}
		sr, ok := lookup(id)
		if !ok {
			continue
		}
		ms := combat.MonsterSkill{ID: id, ReuseMs: sr.ReuseMs, Range: sr.Range, AttMin: sr.AttMin, AttMax: sr.AttMax, AttPercent: sr.AttPercent, AttType: sr.AttType, Hits: sr.Hits, Chance: sr.Chance, ActionMs: sr.ActionMs, HoldMs: sr.HoldMs}
		dbRow := db.Skills[id]
		if dbRow != nil {
			if r, ok := ai[dbRow.Code]; ok {
				u.triggers = append(u.triggers, combat.AITrigger{Skill: ms, Type: r.Type, Data: r.Data, Option: r.Option})
				continue
			}
		}
		if dbRow != nil && dbRow.Summon && (u.kind == nest.SummonA || u.kind == nest.SummonB) {
			k := -1
			if u.kind == nest.SummonA {
				if k = nest.SummonASlot(sr.Chance); slots[k].Skill.ID != 0 {
					u.dropped = append(u.dropped, id)
					continue
				}
			}
			ss := combat.SummonSkill{Skill: ms}
			for _, t := range dbRow.Tuples {
				if t.RefObjID == 0 {
					continue
				}
				ct := combat.SummonTuple{RefObjID: t.RefObjID, Class: t.Class, Min: t.Min, Max: t.Max, Minion: minions.get(t.RefObjID)}
				if t.Max <= 0 {
					u.zeroCount++ // READ: spawns nothing (n = min + rand % 1 = 0)
				}
				u.tuples++
				ss.Tuples = append(ss.Tuples, ct)
			}
			if k >= 0 {
				slots[k] = ss
			} else {
				slots = append(slots, ss)
			}
			continue
		}
		u.attacks = append(u.attacks, ms)
	}
	switch u.kind {
	case nest.SummonA:
		u.summon = &combat.SummonAI{Kind: combat.SummonKindA, Skills: slots}
	case nest.SummonB:
		if len(slots) > 0 {
			u.summon = &combat.SummonAI{Kind: combat.SummonKindB, Skills: slots}
		}
	}
	return u
}

// applyUniqueAI puts a unique's skills on its hatch data: the attack list
// without the summon and trigger skills, the selector and the triggers.
func applyUniqueAI(d *hatchData, u *uniqueAI) {
	d.species.Skills = u.attacks
	d.species.Summon = u.summon
	d.species.Triggers = u.triggers
	if len(u.attacks) > 0 {
		p := u.attacks[0]
		d.species.AttackReuseMs, d.species.AttackRange, d.species.AttackMin, d.species.AttackMax = p.ReuseMs, p.Range, p.AttMin, p.AttMax
	}
}

// nestHeading is a nest row's direction as a heading: the row's word read
// signed (`fild` of a word) / 65535.0 * 360.0 * pi / 180 (Nest_Hatch 0x5609bf;
// the doubles 0xb45c28, 0xb45c30, 0xb45e00 -- combat.SpawnHatched's note).
func nestHeading(dir uint16) float64 {
	return float64(int16(dir)) / 65535.0 * 360.0 * math.Pi / 180.0
}

// uniqueReport is one unique species' rotation, for the boot log and the
// round's evidence.
type uniqueReport struct {
	id                 int64
	name               string
	spots, minS, maxS  int
	kind               nest.SummonKind
	summonSkills       int
	triggers, attacks  int
	tuples, zeroCount  int
	dropped            []int64
	hive               int64
	missingMinionSpecs []int64
}

// logUniques writes the rotation's boot lines: one per unique species.
func logUniques(logger *slog.Logger, reps []uniqueReport, override time.Duration, withSkills bool) {
	if len(reps) == 0 {
		logger.Info("uniques: none placed -- the rotation needs -nest-db-dir (the shard's total-1 hives, EXTERNAL)")
		return
	}
	sort.Slice(reps, func(i, j int) bool { return reps[i].id < reps[j].id })
	for _, r := range reps {
		window := fmt.Sprintf("%d-%d s (EXTERNAL)", r.minS, r.maxS)
		if override > 0 {
			window = fmt.Sprintf("%v (OURS, -unique-respawn)", override)
		}
		logger.Info("unique rotation", "unique", r.name, "id", r.id, "hive", r.hive, "spots", r.spots, "window", window,
			"selector", r.kind.String(), "summon_skills", r.summonSkills, "tuples", r.tuples, "zero_count_tuples", r.zeroCount,
			"dropped_summons", r.dropped, "triggers", r.triggers, "attack_skills", r.attacks, "minions_unknown", r.missingMinionSpecs)
	}
	if !withSkills {
		logger.Warn("uniques: no " + nest.SkillFile + " / " + nest.AISkillFile + " in -nest-db-dir -- the uniques rotate " +
			"and fight, but summon nothing, fire no trigger, and draw their summon skills as zero-damage swings")
	}
}

// uniqueName is the species' display name, or its code.
func uniqueName(spec monsterSpec) string {
	if spec.Name != "" {
		return spec.Name
	}
	return strings.TrimPrefix(spec.CodeName, "MOB_")
}
