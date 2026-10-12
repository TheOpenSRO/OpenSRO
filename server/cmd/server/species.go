package main

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/gm"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
)

// The monster species table (round 654). With -monsters-csv the server holds
// every characterdata monster row (internal/species), and:
//
//   - each roster species (monsterSpecs) takes its numbers from its row --
//     the same numbers the hand-typed roster carries, re-derived rather than
//     copied (TestSpeciesTableRederivesTheRoster) -- while keeping its zone,
//     anchor and placements: WHO spawns WHERE does not change this round;
//   - the GM console's /spawn and /goto know every species in the table, by
//     code name or characterdata id (gmSpeciesLookup).
//
// Without the flag monsterSpecs is the whole story, as before.

// specFromRow is base with the species numbers of row: identity, level,
// rarity, HP, the combat columns, collision radius, speeds, gold, and the
// attack list resolved through lookup. base supplies what the table does not
// decide -- the roster's zone, anchor and placements -- and, for a roster
// species, what the table cannot supply this time: the name when the export
// had no textdata_object, the gold when it had no levelgold, and the attack
// list when a skill does not resolve or its AI_AttackChance is unknown (a
// skill export from before round 654). kept names each field so kept.
func specFromRow(base monsterSpec, row species.Row, lookup species.SkillLookup) (spec monsterSpec, kept []string) {
	spec = base
	spec.CodeName, spec.RefObjID = row.CodeName, row.ID
	switch {
	case row.DisplayName() != row.CodeName:
		spec.Name = row.Name
	case spec.Name == "":
		spec.Name = row.CodeName // OURS: a species with no English name is named by its code
	default:
		kept = append(kept, "name")
	}
	spec.Level, spec.Rarity, spec.MaxHP = row.Level, row.Rarity, row.MaxHP
	spec.Defense, spec.Block, spec.Critical = row.Defense(), row.Block(), row.Critical()
	spec.BCRadius = row.BCRadius
	spec.WalkSpeed, spec.RunSpeed = row.WalkSpeed, row.RunSpeed
	spec.ExpToGive, spec.HasExpToGive = row.ExpToGive, row.HasExpToGive
	spec.Knockdown, spec.KORecoverMs, spec.HasKnockdown = row.Knockdown, row.KORecoverMs, row.HasKnockdown
	if row.GoldMax > 0 {
		spec.GoldMin, spec.GoldMax = row.GoldMin, row.GoldMax
	} else if base.GoldMax > 0 {
		kept = append(kept, "gold")
	} else {
		spec.GoldMin, spec.GoldMax = 0, 0
	}
	a := row.Attacks(lookup)
	switch {
	case a.WholeList && a.HasPrimary:
		spec.AttackReuseMs, spec.AttackRange = a.Primary.ReuseMs, a.Primary.Range
		spec.AttackMin, spec.AttackMax = a.Primary.AttMin, a.Primary.AttMax
		spec.Skills = a.Skills
	case len(base.Skills) > 0 || base.AttackMax > 0:
		// A roster species whose list the lookup cannot complete keeps the
		// hand-typed one, which is READ data too (round 554).
		kept = append(kept, "attacks")
	case a.HasPrimary:
		// Not on the roster: the primary skill's numbers (they need no
		// AI_AttackChance), and no list -- a species with none swings its
		// primary fields (combat.Species.Skills), where a list with unknown
		// chances would draw nothing at all.
		spec.AttackReuseMs, spec.AttackRange = a.Primary.ReuseMs, a.Primary.Range
		spec.AttackMin, spec.AttackMax = a.Primary.AttMin, a.Primary.AttMax
		spec.Skills = nil
	default:
		// No skill resolves: the disclosed flat curve (monsterStatsForLevel).
		spec.AttackReuseMs, spec.AttackRange, spec.AttackMin, spec.AttackMax = 0, 0, 0, 0
		spec.Skills = nil
	}
	return spec, kept
}

// specNumbers is a spec's species numbers as one comparable string, for the
// boot log's drift report: everything specFromRow sets.
func specNumbers(s monsterSpec) string {
	var b strings.Builder
	fmt.Fprintf(&b, "name=%s code=%s id=%d level=%d rarity=%d hp=%d def=%d block=%d crit=%d bc=%d speed=%g/%g gold=%d-%d attack=%d-%d/%dms/%d skills=",
		s.Name, s.CodeName, s.RefObjID, s.Level, s.Rarity, s.MaxHP, s.Defense, s.Block, s.Critical, s.BCRadius,
		s.WalkSpeed, s.RunSpeed, s.GoldMin, s.GoldMax, s.AttackMin, s.AttackMax, s.AttackReuseMs, s.AttackRange)
	for i, sk := range s.Skills {
		if i > 0 {
			b.WriteByte(';')
		}
		fmt.Fprintf(&b, "%d:%d:%d:%d:%d:%d", sk.ID, sk.ReuseMs, sk.Range, sk.AttMin, sk.AttMax, sk.Chance)
	}
	return b.String()
}

// rosterOverlay is what overlaySpeciesTable did, for the boot log.
type rosterOverlay struct {
	Overlaid int
	Missing  []string // roster species whose id the table does not hold
	Changed  []string // "Name: old -> new" where the table's numbers differ
	Kept     []string // "Name: field,field" kept from the hand-typed roster
}

// overlaySpeciesTable replaces each roster spec's species numbers with its
// table row's (specFromRow), in place. A species the table does not hold keeps
// its hand-typed numbers.
func overlaySpeciesTable(specs []monsterSpec, t *species.Table, lookup species.SkillLookup) rosterOverlay {
	var out rosterOverlay
	for i := range specs {
		row, ok := t.ByID(specs[i].RefObjID)
		if !ok {
			out.Missing = append(out.Missing, specs[i].Name)
			continue
		}
		next, kept := specFromRow(specs[i], row, lookup)
		if before, after := specNumbers(specs[i]), specNumbers(next); before != after {
			out.Changed = append(out.Changed, fmt.Sprintf("%s: %s -> %s", specs[i].Name, before, after))
		}
		if len(kept) > 0 {
			out.Kept = append(out.Kept, specs[i].Name+": "+strings.Join(kept, ","))
		}
		specs[i] = next
		out.Overlaid++
	}
	return out
}

// gmSpeciesOf is the GM console's view of one spec: its combat species with
// the stats maintainMonster hands a live spawn (monsterStatsForLevel plus the
// spec's own HP and defence, each floored as maintainMonster floors it).
func gmSpeciesOf(spec monsterSpec) gm.Species {
	attack, gold := monsterStatsForLevel(spec.Level, spec.Rarity)
	defense := spec.Defense
	if defense < 1 {
		defense = 1 + spec.Level/3
	}
	maxHP := spec.MaxHP
	if maxHP < 1 {
		maxHP = 1
	}
	return gm.Species{Species: combatSpeciesOf(spec), Zone: spec.Zone, MaxHP: maxHP, Defense: defense, Attack: attack, Gold: gold}
}

// gmSpeciesLookup resolves a lower-cased code name, characterdata id or
// display name to a table species for /spawn -- Unplaced, since the server
// keeps none of them anywhere this round. A display name several rows share
// resolves to the first in the table's order; the code name and id are
// unique. Attacks resolve at the lookup, so a /spawn reads the skill store
// then and not the whole table at boot.
func gmSpeciesLookup(t *species.Table, lookup species.SkillLookup) func(want string) (gm.Species, bool) {
	byName := map[string]int64{}
	for _, r := range t.Rows {
		if n := strings.ToLower(r.DisplayName()); n != "" {
			if _, seen := byName[n]; !seen {
				byName[n] = r.ID
			}
		}
	}
	return func(want string) (gm.Species, bool) {
		want = strings.TrimSpace(want)
		row, ok := t.ByCode(want)
		if !ok {
			if id, err := strconv.ParseInt(want, 10, 64); err == nil {
				row, ok = t.ByID(id)
			}
		}
		if !ok {
			if id, found := byName[strings.ToLower(want)]; found {
				row, ok = t.ByID(id)
			}
		}
		if !ok {
			return gm.Species{}, false
		}
		spec, _ := specFromRow(monsterSpec{}, row, lookup)
		sp := gmSpeciesOf(spec)
		sp.Unplaced = true
		return sp, true
	}
}
