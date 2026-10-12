package session

// The 'efr' target collectors (round 785). Skill_CollectTargetsByEffect
// (0x58cb70) fills a cast's target vector from the row's 'efr' run;
// docs/protocol/skill_targets.md has the READ spec this follows, collector by
// collector.

import (
	"math"
	"sort"

	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skillparam"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// The efr flag bits (value[5], READ 0x58a020 and siblings).
const (
	efrSelf    = 0x01 // the caster itself
	efrOthers  = 0x02 // players outside the caster's party
	efrParty   = 0x04 // the caster's party
	efrHostile = 0x08 // hostile players (offensive rows)
	efrObjects = 0x10 // the object list: monsters
)

// efrCellRadius is the radius of the cells kinds 1-4 search around the caster
// (.rdata 0xb45c40 = 300.0, READ).
const efrCellRadius = 300.0

// efrChainCap bounds kind 6's search radius (0xb46140 / 0xb4613c = 450, READ).
const efrChainCap = 450.0

// efrRun is a row's collector run: the 'efr' whose value[0] is 1 (the only
// one the builders hand the collector, field +0x28c, READ 0x585a3e). The
// field keeps the LAST such run.
func efrRun(ref *refdata.Skill) ([]int32, bool) {
	if ref == nil || !ref.HasParams() {
		return nil, false
	}
	var out []int32
	found := false
	for _, v := range ref.Runs().All(skillparam.Code("efr")) {
		if len(v) >= 6 && v[0] == 1 {
			out, found = v, true
		}
	}
	return out, found
}

// efrShares returns the falloff sequence after the primary: b starts at
// 100 - falloff and each add stores b, then b = trunc((100-falloff) * b / 100)
// (0x58a0c7, 0x58a487..0x58a4af; the fldcw |0xc00 truncates, READ).
type efrShares struct{ next, keep int }

func newEfrShares(falloff int) *efrShares {
	return &efrShares{next: 100 - falloff, keep: 100 - falloff}
}

func (s *efrShares) take() int {
	b := s.next
	s.next = s.keep * s.next / 100
	return b
}

// collectSkillTargets is the cast's target list: the primary first (share
// 100; the action prep pushes it, GObjPC::FUN_0048d690 0x48d8de), then what
// the row's collector adds. weaponRange is the caster's weapon range, the
// line's length for a kind-3 row with no Action_Range (FUN_004ac890).
//
// OpenSRO has no player-versus-player outside duels, so the PC list (bits 1,
// 2, 4, 8) adds nobody to an attack (OURS); the object list (bit 0x10) is the
// zone's monsters. Retail adds in cell and list order; OpenSRO adds the
// nearest first (OURS stand-in, deterministic).
func collectSkillTargets(castRow *refdata.Skill, caster world.Entity, primary combat.Monster, monsters *combat.Hub, weaponRange int) []skillTarget {
	out := []skillTarget{{ID: primary.ID, Share: 100}}
	v, ok := efrRun(castRow)
	if !ok || monsters == nil {
		return out
	}
	kind, radius, maxN, falloff, flags := int(v[1]), float64(v[2]), int(v[3]), int(v[4]), uint32(v[5])
	if kind != 5 && kind != 6 && (flags == 4 || flags == 5) {
		kind = 5 // 0x58cb70 forces the party collector
	}
	if flags&efrObjects == 0 {
		return out // only the PC list is walked: no monster joins
	}
	full := func() bool { return maxN != 0 && len(out) >= maxN }
	if full() {
		return out
	}
	casterBC := float64(combat.PlayerBCRadius)
	cpos := caster.Pos
	ppos := world.Position{X: primary.X, Y: primary.Y, Z: primary.Z}
	var cands []combat.Monster
	for _, m := range monsters.InZone(caster.Zone) {
		if m.ID == primary.ID || m.HP <= 0 {
			continue
		}
		cands = append(cands, m)
	}
	mpos := func(m combat.Monster) world.Position { return world.Position{X: m.X, Y: m.Y, Z: m.Z} }
	byDistance := func(centre world.Position) {
		sort.Slice(cands, func(i, j int) bool {
			di, dj := dist3(mpos(cands[i]), centre), dist3(mpos(cands[j]), centre)
			if di != dj {
				return di < dj
			}
			return cands[i].ID < cands[j].ID
		})
	}
	shares := newEfrShares(falloff)
	add := func(m combat.Monster) {
		out = append(out, skillTarget{ID: m.ID, Share: shares.take()})
	}
	switch kind {
	case skillparam.EfrKindAreaCaster, skillparam.EfrKindAreaTarget:
		// Kind 1 (0x58a020): within casterBC + v2 + tBC of the caster, 3-D.
		// Kind 2 (0x58a7c0): the same circle around the primary -- with the
		// CASTER's BC (0x58a81c..0x58a834, READ).
		centre := cpos
		if kind == skillparam.EfrKindAreaTarget {
			centre = ppos
		}
		byDistance(centre)
		for _, m := range cands {
			if dist3(mpos(m), cpos) > efrCellRadius+float64(m.BCRadius) {
				continue // not in the caster's cells
			}
			if dist3(mpos(m), centre) <= casterBC+radius+float64(m.BCRadius) {
				add(m)
				if full() {
					break
				}
			}
		}
	case skillparam.EfrKindLineCaster, skillparam.EfrKindLineTarget:
		// Kind 3 (0x58b160): aim = primary - caster, y = 0, normalised and
		// scaled to Action_Range (the weapon's when 0). Kind 4 (0x58b870): aim
		// = primary - caster in full. Skill_WithinLine (0x58af60) from the
		// caster.
		ax, ay, az := ppos.X-cpos.X, ppos.Y-cpos.Y, ppos.Z-cpos.Z
		if kind == skillparam.EfrKindLineCaster {
			ay = 0
			l := math.Hypot(ax, az)
			length := float64(castRow.Range)
			if length == 0 {
				length = float64(weaponRange)
			}
			if l > 0 {
				ax, az = ax/l*length, az/l*length
			}
		}
		byDistance(cpos)
		for _, m := range cands {
			if dist3(mpos(m), cpos) > efrCellRadius+float64(m.BCRadius) {
				continue
			}
			if withinLine(cpos, ax, ay, az, mpos(m), casterBC, float64(m.BCRadius), radius) {
				add(m)
				if full() {
					break
				}
			}
		}
	case skillparam.EfrKindChain:
		// Kind 6 (0x58c170): candidates within R = min(v2 (v3+1), 450) of the
		// caster; then v3 - 1 times the candidate nearest the PRIMARY within
		// v2 (3-D), distances always measured to the primary.
		r := radius * float64(maxN+1)
		if r > efrChainCap {
			r = efrChainCap
		}
		var pool []combat.Monster
		for _, m := range cands {
			if dist3(mpos(m), cpos) <= r {
				pool = append(pool, m)
			}
		}
		for n := 0; n < maxN-1 && len(pool) > 0; n++ {
			best, bestD := -1, 10000.0 // 0xb46138
			for i, m := range pool {
				if d := dist3(mpos(m), ppos); d <= radius && d < bestD {
					best, bestD = i, d
				}
			}
			if best < 0 {
				break
			}
			add(pool[best])
			pool = append(pool[:best], pool[best+1:]...)
		}
	}
	return out
}

// withinLine is Skill_WithinLine (0x58af60, READ): d is the horizontal
// offset from the caster to the candidate; it passes when |d| <= |aim| (3-D)
// + casterBC + tBC and sin(theta) |d| < tBC + halfWidth, theta the angle
// between aim and d. There is no cos >= 0 test: a point straight behind the
// caster passes (retail's quirk, kept).
func withinLine(from world.Position, ax, ay, az float64, t world.Position, casterBC, tBC, halfWidth float64) bool {
	dx, dz := t.X-from.X, t.Z-from.Z
	dl := math.Hypot(dx, dz)
	al := math.Sqrt(ax*ax + ay*ay + az*az)
	if dl > al+casterBC+tBC {
		return false
	}
	if dl == 0 || al == 0 {
		return true
	}
	c := (ax*dx + az*dz) / (al * dl)
	c = math.Max(-1, math.Min(1, c))
	return math.Sin(math.Acos(c))*dl < tBC+halfWidth
}

// areaShare scales a hit by the target's share (Combat_ResolveDamage
// 0x58f590..0x58f5d2, READ): trunc(share x total / 100), then the floor of
// 1 for a hit that dealt anything.
func areaShare(dmg, share int) int {
	if dmg <= 0 || share >= 100 {
		return dmg
	}
	if share < 0 {
		share = 0
	}
	out := dmg * share / 100
	if out < 1 {
		out = 1
	}
	return out
}
