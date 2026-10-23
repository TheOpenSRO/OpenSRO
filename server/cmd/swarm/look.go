package main

// A bot's body and the starting kit it is created with through the retail
// lobby (0x7007 create). The ids are docs/protocol/charselect.md section 6's,
// MEASURED from characterdata / itemdata (the 52 bodies and the starting
// weapons and protector sets the create screen offers); the server accepts
// them only when its creatable catalogue (-chargen-csv) holds them, which an
// export of a retail archive does. The kit is replaced in Postgres by the
// bot's real gear before it enters the world (gear.go), so it only has to
// pass the lobby's checks.

import (
	"math/rand"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// look is what a bot is created as.
type look struct {
	Race, Sex                 int // character.RaceChina/RaceEurope, character.SexMan/SexWoman
	RefObjID                  uint32
	Scale                     uint8
	Chest, Legs, Feet, Weapon uint32
}

// Gender is the characters.gender value the server stores for the look.
func (l look) Gender() string { return character.GenderFor(l.Race, l.Sex) }

// bodies are the Figure slider's 13 ids per race and sex (charselect.md).
var bodies = map[[2]int][2]uint32{
	{character.RaceChina, character.SexMan}:    {1907, 1919},
	{character.RaceChina, character.SexWoman}:  {1920, 1932},
	{character.RaceEurope, character.SexMan}:   {14875, 14887},
	{character.RaceEurope, character.SexWoman}: {14888, 14900},
}

// China's starting weapons (any protector set) and sets (chest, legs, feet).
var (
	chinaWeapons = []uint32{3632, 3633, 3634, 3635, 3636}
	chinaSets    = map[int][][3]uint32{
		character.SexMan:   {{3637, 3638, 3639}, {3640, 3641, 3642}, {3643, 3644, 3645}},
		character.SexWoman: {{3646, 3647, 3648}, {3649, 3650, 3651}, {3652, 3653, 3654}},
	}
)

// Europe's starting weapons with the protector sets each allows (READ
// 0x853400 / 0x8531e0, charselect.md), and the sets.
const (
	euHeavy = iota
	euLight
	euRobe
)

var (
	europeWeapons = []struct {
		id   uint32
		sets []int
	}{
		{10887, []int{euLight}},          // dagger
		{10888, []int{euHeavy, euLight}}, // one-handed sword
		{10889, []int{euHeavy, euLight}}, // two-handed sword
		{10890, []int{euHeavy, euLight}}, // dual axe
		{10891, []int{euLight}},          // crossbow
		{10892, []int{euRobe}},           // warlock rod
		{10893, []int{euRobe}},           // staff
		{10894, []int{euRobe}},           // harp
		{10895, []int{euLight, euRobe}},  // cleric rod
	}
	europeSets = map[int][3][3]uint32{
		character.SexMan:   {euHeavy: {11617, 11618, 11619}, euLight: {11620, 11621, 11622}, euRobe: {11623, 11624, 11625}},
		character.SexWoman: {euHeavy: {11626, 11627, 11628}, euLight: {11629, 11630, 11631}, euRobe: {11632, 11633, 11634}},
	}
)

// lookFor is bot i's look: deterministic in (seed, i), half China and half
// Europe, half men and half women, any of the 13 figures, any height and
// volume (0..4 each), any starting weapon with a set it allows.
func lookFor(seed int64, i int) look {
	r := rand.New(rand.NewSource(seed*7919 + int64(i)))
	l := look{Race: r.Intn(2), Sex: r.Intn(2)}
	span := bodies[[2]int{l.Race, l.Sex}]
	l.RefObjID = span[0] + uint32(r.Intn(int(span[1]-span[0]+1)))
	l.Scale = uint8(r.Intn(5)<<4 | r.Intn(5))
	var set [3]uint32
	if l.Race == character.RaceChina {
		l.Weapon = chinaWeapons[r.Intn(len(chinaWeapons))]
		sets := chinaSets[l.Sex]
		set = sets[r.Intn(len(sets))]
	} else {
		w := europeWeapons[r.Intn(len(europeWeapons))]
		l.Weapon = w.id
		set = europeSets[l.Sex][w.sets[r.Intn(len(w.sets))]]
	}
	l.Chest, l.Legs, l.Feet = set[0], set[1], set[2]
	return l
}

// createRequest is the 0x7007 create for a look.
func (l look) createRequest(name string) *session.LobbyRequest {
	return &session.LobbyRequest{Action: session.LobbyCreate, Name: name, RefObjID: l.RefObjID, Scale: l.Scale,
		Chest: l.Chest, Legs: l.Legs, Feet: l.Feet, Weapon: l.Weapon}
}

// raceSexOfGender reads characters.gender back (character.GenderFor's values).
func raceSexOfGender(g string) (race, sex int) {
	switch g {
	case character.GenderEuropeMan:
		return character.RaceEurope, character.SexMan
	case character.GenderEuropeWoman:
		return character.RaceEurope, character.SexWoman
	case character.GenderFor(character.RaceChina, character.SexWoman):
		return character.RaceChina, character.SexWoman
	}
	return character.RaceChina, character.SexMan
}
