package main

// A bot's worn gear, picked from the reference data in the target database's
// `items` table (cmd/import-refdata wrote it from the operator's own archive;
// nothing here is game data) and written straight into equipment_slots with
// a plus (opt_level, adv_elixir) before the bot enters the world.
//
// The seal of an item is read from its code name, as the client's effect
// tables key on it (docs/rounds/r740.md, r741.md, r746.md): _A_RARE is the
// Seal of Star (system_raretype_*_step1), _B_RARE Moon (step2), _C_RARE Sun
// (step3), _A_RARE_ACTIVE Nova (eternity_11_nova_*), _SET_A_RARE /
// _SET_B_RARE the Egyptian sets (eternity_11_egya / egyb). 4118 is
// ITEM_CH_SPEAR_11_C_RARE (Sun) and 62607 ITEM_CH_SPEAR_11_A_RARE_ACTIVE
// (Nova); both are favoured when the table has them. The plus spread (0..14,
// most at 8 and over, where the particles start) is this tool's own choice.

import (
	"context"
	"database/sql"
	"fmt"
	"math/rand"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

type seal int

const (
	sealNone seal = iota
	sealStar
	sealMoon
	sealSun
	sealNova
	sealEgypt
	numSeals
)

func (s seal) String() string {
	return [...]string{"normal", "Star", "Moon", "Sun", "Nova", "Egyptian"}[s]
}

// Ids the user named; favoured when present.
const (
	itemSunSpear  = 4118  // ITEM_CH_SPEAR_11_C_RARE
	itemNovaSpear = 62607 // ITEM_CH_SPEAR_11_A_RARE_ACTIVE
)

// junkTokens mark rows that are not ordinary drops: honour, event, mall,
// arena and test copies, the starting kit, and the alternate-model rows.
var junkTokens = []string{"_HONOR", "_SWITCH", "_EVENT", "_MALL", "_TEST", "_ARENA", "_FRPVP", "_PREMIUM", "_TRADE", "_DEF", "_QUEST", "_GM"}

var (
	degreeRE = regexp.MustCompile(`_(\d{2})_`)
	normalRE = regexp.MustCompile(`_[ABC]$`)
)

// classify reads an item code's seal and degree; ok is false for a code this
// tool does not wear (junk, or a suffix it does not know).
func classify(code string) (s seal, degree int, ok bool) {
	if !strings.HasPrefix(code, "ITEM_CH_") && !strings.HasPrefix(code, "ITEM_EU_") {
		return 0, 0, false
	}
	for _, t := range junkTokens {
		if strings.Contains(code, t) {
			return 0, 0, false
		}
	}
	m := degreeRE.FindStringSubmatch(code)
	if m == nil {
		return 0, 0, false
	}
	degree, _ = strconv.Atoi(m[1])
	switch {
	case strings.Contains(code, "_SET_A_RARE") || strings.Contains(code, "_SET_B_RARE"):
		s = sealEgypt
	case strings.HasSuffix(code, "_A_RARE_ACTIVE"):
		s = sealNova
	case strings.HasSuffix(code, "_C_RARE"):
		s = sealSun
	case strings.HasSuffix(code, "_B_RARE"):
		s = sealMoon
	case strings.HasSuffix(code, "_A_RARE"):
		s = sealStar
	case normalRE.MatchString(code):
		s = sealNone
	default:
		return 0, 0, false
	}
	return s, degree, true
}

// gearItem is one wearable row of the items table.
type gearItem struct {
	ID        int64
	Code      string
	Family    int // TypeID3
	Kind      int // TypeID4
	Country   int
	ReqGender int
	TwoHanded bool
	Seal      seal
	Degree    int
	Slot      equipment.Slot
	reqLevel  int
	isArmour  bool
	isShield  bool
	isWeapon  bool
	sexes     []int
}

type armourKey struct {
	country, sex, family, degree int
	seal                         seal
}

// catalogue is every wearable row, indexed for the picks.
type catalogue struct {
	byID    map[int64]*gearItem
	weapons map[int][numSeals][]*gearItem // country ->
	shields map[int][numSeals][]*gearItem
	armour  map[armourKey]*[7][]*gearItem // piece (TypeID4 1..6) ->
	// armourKeys per (country, sex, seal), sorted, for a deterministic pick.
	armourKeys map[[3]int][]armourKey
	rows       int
}

func newCatalogue() *catalogue {
	return &catalogue{byID: map[int64]*gearItem{}, weapons: map[int][numSeals][]*gearItem{},
		shields: map[int][numSeals][]*gearItem{}, armour: map[armourKey]*[7][]*gearItem{}, armourKeys: map[[3]int][]armourKey{}}
}

var armourFamilies = map[int]bool{
	equipment.FamilyChinaGarment: true, equipment.FamilyChinaProtector: true, equipment.FamilyChinaArmor: true,
	equipment.FamilyEuropeRobe: true, equipment.FamilyEuropeLight: true, equipment.FamilyEuropeHeavy: true,
}

// add files one row; false when the tool does not wear it.
func (c *catalogue) add(it gearItem) bool {
	s, deg, ok := classify(it.Code)
	if !ok || (it.Country != character.RaceChina && it.Country != character.RaceEurope) {
		return false
	}
	ref := &refdata.Item{TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment, TypeID3: it.Family, TypeID4: it.Kind}
	slot, ok := equipment.SlotFor(ref)
	if !ok {
		return false
	}
	it.Seal, it.Degree, it.Slot = s, deg, slot
	switch {
	case it.Family == equipment.FamilyWeapon:
		it.isWeapon = true
	case it.Family == equipment.FamilyShield && (it.Kind == 1 || it.Kind == 2):
		it.isShield = true
	case armourFamilies[it.Family] && it.Kind >= 1 && it.Kind <= 6:
		it.isArmour = true
	default:
		return false
	}
	switch it.ReqGender {
	case equipment.ReqGenderMan:
		it.sexes = []int{character.SexMan}
	case equipment.ReqGenderWoman:
		it.sexes = []int{character.SexWoman}
	default:
		it.sexes = []int{character.SexMan, character.SexWoman}
	}
	p := &it
	c.byID[it.ID] = p
	c.rows++
	switch {
	case it.isWeapon:
		w := c.weapons[it.Country]
		w[s] = append(w[s], p)
		c.weapons[it.Country] = w
	case it.isShield:
		w := c.shields[it.Country]
		w[s] = append(w[s], p)
		c.shields[it.Country] = w
	case it.isArmour:
		for _, sex := range it.sexes {
			k := armourKey{country: it.Country, sex: sex, family: it.Family, degree: deg, seal: s}
			pieces := c.armour[k]
			if pieces == nil {
				pieces = &[7][]*gearItem{}
				c.armour[k] = pieces
				ck := [3]int{it.Country, sex, int(s)}
				c.armourKeys[ck] = append(c.armourKeys[ck], k)
			}
			pieces[it.Kind] = append(pieces[it.Kind], p)
		}
	}
	return true
}

// finish sorts every list, so the picks depend only on the seed and the table.
func (c *catalogue) finish() {
	byID := func(l []*gearItem) { sort.Slice(l, func(i, j int) bool { return l[i].ID < l[j].ID }) }
	for _, m := range []map[int][numSeals][]*gearItem{c.weapons, c.shields} {
		for _, w := range m {
			for _, l := range w {
				byID(l)
			}
		}
	}
	for _, p := range c.armour {
		for _, l := range p {
			byID(l)
		}
	}
	for _, ks := range c.armourKeys {
		sort.Slice(ks, func(i, j int) bool {
			a, b := ks[i], ks[j]
			if a.family != b.family {
				return a.family < b.family
			}
			return a.degree < b.degree
		})
	}
}

// loadCatalogue reads the wearable rows of the items table.
func loadCatalogue(ctx context.Context, db *sql.DB) (*catalogue, error) {
	rows, err := db.QueryContext(ctx, `SELECT id, code_name, type_id3, type_id4, country, req_gender, two_handed, req_level1
		FROM items WHERE type_id1 = 3 AND type_id2 = 1 AND type_id3 IN (1, 2, 3, 4, 6, 9, 10, 11)`)
	if err != nil {
		return nil, fmt.Errorf("reading the items table: %w", err)
	}
	defer rows.Close()
	c := newCatalogue()
	for rows.Next() {
		var it gearItem
		if err := rows.Scan(&it.ID, &it.Code, &it.Family, &it.Kind, &it.Country, &it.ReqGender, &it.TwoHanded, &it.reqLevel); err != nil {
			return nil, err
		}
		c.add(it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	c.finish()
	return c, nil
}

// gearRow is one equipment_slots row to write.
type gearRow struct {
	Slot     equipment.Slot
	Item     *gearItem
	Opt, Adv int
}

// Plus is the effective plus a client is sent (OptLevel + advanced elixir).
func (g gearRow) Plus() int { return g.Opt + g.Adv }

// sealWeights is the weapon seal mix (OURS): most bots carry a glowing seal.
var sealWeights = [numSeals]int{sealNone: 12, sealStar: 14, sealMoon: 14, sealSun: 22, sealNova: 19, sealEgypt: 19}

// shieldHands are the one-handed weapons a shield is worn with (TypeID4:
// China sword and blade, Europe sword, warlock rod, cleric rod).
var shieldHands = map[int]bool{2: true, 3: true, 7: true, 10: true, 15: true}

// weaponPlus is a weapon's effective plus: 10% 0..2, 30% 3..7 (the glow),
// 60% 8..14 (the particles).
func weaponPlus(r *rand.Rand) int {
	switch x := r.Intn(100); {
	case x < 10:
		return r.Intn(3)
	case x < 40:
		return 3 + r.Intn(5)
	default:
		return 8 + r.Intn(7)
	}
}

// split is an effective plus as opt_level and adv_elixir: a quarter of the
// items take 1 or 2 of it from an advanced elixir.
func split(r *rand.Rand, plus int) (opt, adv int) {
	if plus > 0 && r.Intn(4) == 0 {
		adv = 1 + r.Intn(2)
		if adv > plus {
			adv = plus
		}
	}
	return plus - adv, adv
}

func pick(r *rand.Rand, l []*gearItem) *gearItem {
	if len(l) == 0 {
		return nil
	}
	return l[r.Intn(len(l))]
}

// loadout is bot i's gear for its race and sex: a weapon (and a shield with a
// one-handed weapon that takes one) and six armour pieces, each with a plus.
// Deterministic in (seed, i) and the table.
func (c *catalogue) loadout(seed int64, i, race, sex int) []gearRow {
	r := rand.New(rand.NewSource(seed*104729 + int64(i)*31 + 7))
	var out []gearRow
	ws := c.weapons[race]
	total := 0
	for s := seal(0); s < numSeals; s++ {
		if len(ws[s]) > 0 {
			total += sealWeights[s]
		}
	}
	if total == 0 {
		return nil
	}
	x, cat := r.Intn(total), seal(0)
	for s := seal(0); s < numSeals; s++ {
		if len(ws[s]) == 0 {
			continue
		}
		if x < sealWeights[s] {
			cat = s
			break
		}
		x -= sealWeights[s]
	}
	w := pick(r, ws[cat])
	if race == character.RaceChina && r.Intn(2) == 0 {
		fav := map[seal]int64{sealSun: itemSunSpear, sealNova: itemNovaSpear}[cat]
		if it, ok := c.byID[fav]; ok && it.isWeapon && it.Country == race {
			w = it
		}
	}
	wp := weaponPlus(r)
	o, a := split(r, wp)
	out = append(out, gearRow{Slot: w.Slot, Item: w, Opt: o, Adv: a})

	if !w.TwoHanded && shieldHands[w.Kind] {
		ss := c.shields[race]
		sh := pick(r, ss[cat])
		for _, s := range []seal{sealSun, sealMoon, sealStar, sealNone, sealEgypt, sealNova} {
			if sh != nil {
				break
			}
			sh = pick(r, ss[s])
		}
		if sh != nil {
			p := wp + r.Intn(5) - 2
			p = max(0, min(14, p))
			o, a := split(r, p)
			out = append(out, gearRow{Slot: sh.Slot, Item: sh, Opt: o, Adv: a})
		}
	}

	// Armour: the weapon's seal when the table has armour of it for this race
	// and sex, else the first that has any.
	acat := cat
	keys := c.armourKeys[[3]int{race, sex, int(acat)}]
	for _, s := range []seal{sealSun, sealMoon, sealStar, sealEgypt, sealNova, sealNone} {
		if len(keys) > 0 {
			break
		}
		acat = s
		keys = c.armourKeys[[3]int{race, sex, int(acat)}]
	}
	if len(keys) == 0 {
		return out
	}
	// The family: one of those available; the degree: the weapon's if that
	// family has it in this seal, else a random one of the family's.
	fams := map[int][]armourKey{}
	var famIDs []int
	for _, k := range keys {
		if fams[k.family] == nil {
			famIDs = append(famIDs, k.family)
		}
		fams[k.family] = append(fams[k.family], k)
	}
	fam := famIDs[r.Intn(len(famIDs))]
	choice := fams[fam][r.Intn(len(fams[fam]))]
	for _, k := range fams[fam] {
		if k.degree == w.Degree {
			choice = k
		}
	}
	pieces := c.armour[choice]
	for piece := 1; piece <= 6; piece++ {
		it := pick(r, pieces[piece])
		if it == nil {
			// The same family and seal at another degree.
			for _, k := range fams[fam] {
				if it = pick(r, c.armour[k][piece]); it != nil {
					break
				}
			}
		}
		if it == nil {
			continue
		}
		o, a := split(r, r.Intn(10))
		out = append(out, gearRow{Slot: it.Slot, Item: it, Opt: o, Adv: a})
	}
	return out
}

// summary describes the catalogue: how many rows of each kind and seal.
func (c *catalogue) summary() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%d wearable rows", c.rows)
	for _, race := range []int{character.RaceChina, character.RaceEurope} {
		name := map[int]string{character.RaceChina: "China", character.RaceEurope: "Europe"}[race]
		fmt.Fprintf(&b, "; %s weapons", name)
		for s := seal(0); s < numSeals; s++ {
			fmt.Fprintf(&b, " %s %d", s, len(c.weapons[race][s]))
		}
		n := 0
		for s := seal(0); s < numSeals; s++ {
			n += len(c.shields[race][s])
		}
		fmt.Fprintf(&b, ", shields %d", n)
	}
	if it, ok := c.byID[itemSunSpear]; ok {
		fmt.Fprintf(&b, "; %d %s (%s)", it.ID, it.Code, it.Seal)
	}
	if it, ok := c.byID[itemNovaSpear]; ok {
		fmt.Fprintf(&b, "; %d %s (%s)", it.ID, it.Code, it.Seal)
	}
	return b.String()
}
