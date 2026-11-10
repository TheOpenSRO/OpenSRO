package session

// Passive skills (round 785): a learned row with Basic_Activity 0 (744
// player rows, all action kind 4 -- 662 Europe, 82 China, MEASURED) acts
// with no cast: its stat runs are the character's ParamKeeper entries for as
// long as it is known (ApplySkillParamsToChar, 0x594ac0, READ -- 'cr' only
// on such a row), and its 'setv' runs file (key, value) variables in the
// book's map at +0x244 (FUN_005a02e0, READ) that other rows' 'getv' read
// (FUN_005a0330): the weapon roll FUN_0040dce0 multiplies a blow whose row
// carries getv DGHR, CBAT, E1SA, E2SA or E2AA (the first present) by
// (1 + value/100) -- e.g. a Europe sword base attack's 'getv E1SA' and the
// shield passive's 'setv E1SA 4'.
//
// Only a group's highest learned level counts (a group holds one learned
// level; the store keeps every id ever learned).
//
// Round 882: a passive whose row carries a 'reqi' list counts only while
// the list holds over what the character wears -- its stat runs, its 'real'
// resists and its 'setv' variables alike (gearreqs.go: ApplySkillParamsToChar's
// own gate at the engage, GObjPC::FUN_0059f0e0 at each change of a worn
// item). MEASURED: a character with rank 18 of the Warrior's one-handed-sword
// defence passive ('defp' 224, list 6:7) and a rank of the Cleric's
// light-armour defence passive ('defp' 168, list 10:0 AND 6:15), in a robe
// set, reads phy def 2590 bare-handed, 2590 with a cleric rod, 2814 with a
// one-handed sword and 2602 with a two-handed sword whose own options add
// 12.

import (
	"context"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skillparam"
)

// passiveTTL bounds how long a computed passive set is trusted (OURS: a
// learn invalidates it at once; the bound covers any other path that
// changes the known skills).
const passiveTTL = 30 * time.Second

type passiveState struct {
	totals map[int]buff.Totals
	// resists are the passives' state and elemental resists, each with the
	// 'reqi' list that gates it (round 881, resist.go).
	resists []passiveResist
	vars    map[skillparam.Code]int
	at      time.Time
}

var passives = struct {
	sync.Mutex
	m      map[int64]passiveState
	skills skill.Store
	ref    SkillRefStore
}{m: map[int64]passiveState{}}

// setPassiveSource gives the passive set its stores (the skill handlers'
// constructors call it).
func setPassiveSource(skills skill.Store, ref SkillRefStore) {
	if skills == nil || ref == nil {
		return
	}
	passives.Lock()
	passives.skills, passives.ref = skills, ref
	passives.Unlock()
}

// invalidatePassives forgets a character's passive set (a learn, a forget).
func invalidatePassives(characterID int64) {
	passives.Lock()
	delete(passives.m, characterID)
	passives.Unlock()
}

// passiveOf is characterID's passive set, computed when absent or stale.
func passiveOf(characterID int64) passiveState {
	passives.Lock()
	st, ok := passives.m[characterID]
	skills, ref := passives.skills, passives.ref
	passives.Unlock()
	if (ok && time.Since(st.at) < passiveTTL) || skills == nil || ref == nil || characterID == 0 {
		return st
	}
	// The set is counted over what is worn now; gearChanged forgets it at
	// each change of a worn item (round 882).
	ctx := context.Background()
	st = computePassives(ctx, skills, ref, characterID, wornGearOf(ctx, characterID))
	passives.Lock()
	passives.m[characterID] = st
	passives.Unlock()
	return st
}

func computePassives(ctx context.Context, skills skill.Store, ref SkillRefStore, characterID int64, g gearState) passiveState {
	st := passiveState{at: time.Now(), vars: map[skillparam.Code]int{}}
	known, err := skills.KnownSkills(ctx, characterID)
	if err != nil {
		return st
	}
	best := map[int64]*refdata.Skill{}
	for _, id := range known {
		row, err := ref.GetSkill(ctx, id)
		if err != nil || row == nil || row.Activity != 0 || !row.HasParams() {
			continue
		}
		if cur, ok := best[row.GroupID]; !ok || row.BasicLevel > cur.BasicLevel {
			best[row.GroupID] = row
		}
	}
	var stats []buff.Contribution
	for _, row := range best {
		r := row.Runs()
		// The row's own list (round 882): while it fails nothing of the row
		// is applied. Its resists stay listed with their list: the state
		// roll walks it over the gear it reads itself (resist.go).
		counts := gearReqsHold(combat.ParseCastRequirements(row.ReqCastList), row.ReqCastAll, g)
		cs, pr := splitPassiveResists(row, buff.StatContributions(r, row.ActionKind, row.Activity), buff.StateResists(r))
		if pr != nil {
			st.resists = append(st.resists, *pr)
		}
		if !counts {
			continue
		}
		stats = append(stats, cs...)
		for _, v := range r.All("setv") {
			if len(v) >= 2 {
				st.vars[skillparam.CodeOf(v[0])] += int(v[1])
			}
		}
	}
	if len(stats) > 0 {
		b := buff.NewBooks(0)
		b.Start(characterID, buff.Spec{SkillID: -1, CasterID: characterID, Stats: stats}, time.Now())
		st.totals = b.ParamTotals(characterID)
	}
	return st
}

// passiveVar is a 'getv' key's value for characterID (0 when no passive
// sets it).
func passiveVar(characterID int64, key skillparam.Code) int {
	return passiveOf(characterID).vars[key]
}

// getvDamageKeys are the keys FUN_0040dce0 multiplies a blow by, the first
// present on the row winning (READ).
var getvDamageKeys = []skillparam.Code{"DGHR", "CBAT", "E1SA", "E2SA", "E2AA"}

// applyGetvDamage multiplies dmg by (1 + v/100) for the first of the
// row's getv damage keys a passive of the caster sets.
func applyGetvDamage(characterID int64, row *refdata.Skill, dmg int) int {
	if row == nil || !row.HasParams() || dmg <= 0 {
		return dmg
	}
	r := row.Runs()
	for _, k := range getvDamageKeys {
		if _, ok := r.GetvValue(k); !ok {
			continue
		}
		if v := passiveVar(characterID, k); v != 0 {
			return int(float64(dmg) * (1 + float64(v)/100))
		}
		return dmg
	}
	return dmg
}
