package session

import "github.com/OpenSRO/OpenSRO/server/internal/refdata"

// testCatalogue is a synthetic creatable set for the lobby tests: real ids
// as references, with the type, country and sex fields the rule reads (the
// values charselect.md section 4 lists). No game data: the rows are written
// out here, not read from an archive.
func testCatalogue() *refdata.CreatableSet {
	model := func(id int64, country, sex int) refdata.Creatable {
		return refdata.Creatable{ID: id, Kind: refdata.CreatableModel, Country: country, Sex: sex, TypeID1: 1, TypeID2: 1}
	}
	item := func(id int64, country, sex, t3, t4 int, twoHanded bool) refdata.Creatable {
		return refdata.Creatable{ID: id, Kind: refdata.CreatableItem, Country: country, Sex: sex,
			TypeID1: 3, TypeID2: 1, TypeID3: t3, TypeID4: t4, TwoHanded: twoHanded, MaxStack: 1}
	}
	return refdata.NewCreatableSet([]refdata.Creatable{
		model(1909, 0, 1), model(1923, 0, 0), model(14875, 1, 1), model(14888, 1, 0),
		// China man: Clothes (class 1) and Light (class 2); woman: Clothes.
		item(3643, 0, 1, 1, 3, false), item(3644, 0, 1, 1, 4, false), item(3645, 0, 1, 1, 6, false),
		item(3640, 0, 1, 2, 3, false), item(3641, 0, 1, 2, 4, false), item(3642, 0, 1, 2, 6, false),
		item(3652, 0, 0, 1, 3, false), item(3653, 0, 0, 1, 4, false), item(3654, 0, 0, 1, 6, false),
		// China weapons: sword (one-handed), spear and bow (two-handed).
		item(3632, 0, 2, 6, 2, false), item(3634, 0, 2, 6, 4, true), item(3636, 0, 2, 6, 6, true),
		item(10886, 0, 2, 4, 1, false),
		// Europe man: Light (class 10); sword, crossbow; the shield.
		item(11620, 1, 1, 10, 3, false), item(11621, 1, 1, 10, 4, false), item(11622, 1, 1, 10, 6, false),
		item(10888, 1, 2, 6, 7, false), item(10891, 1, 2, 6, 12, true),
		item(10896, 1, 2, 4, 2, false),
		{ID: 3655, Code: refdata.AmmoArrowCode, Kind: refdata.CreatableAmmo, Country: 3, Sex: 2, TypeID1: 3, TypeID2: 3, TypeID3: 4, TypeID4: 1, MaxStack: 250},
		{ID: 10885, Code: refdata.AmmoBoltCode, Kind: refdata.CreatableAmmo, Country: 3, Sex: 2, TypeID1: 3, TypeID2: 3, TypeID3: 4, TypeID4: 2, MaxStack: 250},
	})
}

// chinaManCreate is a valid create: China man 1909, the Clothes set, the
// Copper Sword, scale 0x22.
func chinaManCreate(name string) *LobbyRequest {
	return &LobbyRequest{Action: LobbyCreate, Name: name, RefObjID: 1909, Scale: 0x22,
		Chest: 3643, Legs: 3644, Feet: 3645, Weapon: 3632}
}
