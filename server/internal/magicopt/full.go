package magicopt

import "strings"

// Full blue (round 786, OURS: the user's request for the Test Items NPC's
// goods). Retail has no such roll; this builds the best item the tables
// allow: every option the item kind can drop with (the assign list's '+'
// options, the ones RollDrop draws from) that the option's own row allows
// on the item, at the item's degree, with the row's highest value. No rand.

// SpecialStones are the options a "full blue" item leaves out: the special
// alchemy stones (Immortal, Steady, Lucky, Astral), which guard the
// reinforce rather than add stats, and the durability repair option (its
// drop weighting is 0 in the measured table, so no drop ever carries it).
// OURS: the player's usual meaning of "full blue".
var SpecialStones = map[string]bool{
	"MATTR_ATHANASIA": true, "MATTR_SOLID": true, "MATTR_LUCK": true, "MATTR_ASTRAL": true, "MATTR_REPAIR": true,
}

// MaxValue is the highest value the row's generator can give: the six-value
// pool's largest, the range's max (column 10), the single value (column 9).
func (r *Row) MaxValue() uint32 {
	switch r.Generator() {
	case GenSixValues:
		var m uint32
		for _, v := range r.Values() {
			m = max(m, v)
		}
		return m
	case GenRange:
		return max(r.Params[1], r.Params[2])
	case GenSingle:
		return r.Params[1]
	}
	return 0
}

// recordAtMost is the group's row for level, or else its highest level below
// it; nil when the group has none at or below level.
func (t *Table) recordAtMost(code string, level int) *Row {
	var best *Row
	for _, r := range t.Group(code) {
		if r.Level <= level && (best == nil || r.Level > best.Level) {
			best = r
		}
	}
	return best
}

// FullBlue is every standard option it can carry, each at degree's row (or
// the highest below it) and that row's MaxValue, in the assign list's order,
// no more than it.MaxOptions (column 158, the item's base option cap). An
// option whose value would be 0 is left out.
func FullBlue(t *Table, a *AssignTable, it DropItem, degree int) []Rolled {
	if t == nil || a == nil || it.MaxOptions <= 0 {
		return nil
	}
	var out []Rolled
	seen := map[string]bool{}
	for _, n := range a.Names(it.Race, it.TypeID3, it.TypeID4) {
		code := strings.ToUpper(strings.TrimSpace(n))
		if seen[code] || SpecialStones[code] || !t.GroupDrops(code) {
			continue
		}
		seen[code] = true
		rec := t.recordAtMost(code, degree)
		if rec == nil || rec.Tag == PackTag("nrep") || !rec.AllowedOn(it.TypeID3, it.TypeID4, it.Code) {
			continue
		}
		v := rec.MaxValue()
		if v == 0 {
			continue
		}
		out = append(out, Rolled{ID: rec.ID, Value: v})
		if len(out) == it.MaxOptions {
			break
		}
	}
	return out
}
