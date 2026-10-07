package main

import (
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
)

func TestClassifyReadsTheSealFromTheCode(t *testing.T) {
	for code, want := range map[string]seal{
		"ITEM_CH_SPEAR_11_C_RARE":        sealSun,
		"ITEM_CH_SPEAR_11_A_RARE_ACTIVE": sealNova,
		"ITEM_CH_SPEAR_11_A_RARE":        sealStar,
		"ITEM_CH_BOW_10_B_RARE":          sealMoon,
		"ITEM_CH_TBLADE_11_SET_A_RARE":   sealEgypt,
		"ITEM_EU_SWORD_11_SET_B_RARE":    sealEgypt,
		"ITEM_EU_M_HEAVY_10_HA_C":        sealNone,
	} {
		got, _, ok := classify(code)
		if !ok || got != want {
			t.Errorf("classify(%s) = %v %v, want %v", code, got, ok, want)
		}
	}
	for _, code := range []string{"ITEM_CH_SPEAR_11_C_RARE_HONOR", "ITEM_CH_SPEAR_11_SET_A_RARE_SWITCH01", "ITEM_CH_SWORD_01_A_DEF",
		"ITEM_ETC_AMMO_ARROW_01", "ITEM_CH_SPEAR_C_RARE", "ITEM_MALL_X_11_A"} {
		if _, _, ok := classify(code); ok {
			t.Errorf("classify(%s) accepted", code)
		}
	}
}

// synthetic is a small made-up table (ids 900000+, except the two the user
// named), the shape of the real one.
func synthetic() *catalogue {
	c := newCatalogue()
	id := int64(900000)
	add := func(code string, fam, kind, country, gender int, two bool, fixed int64) {
		if fixed == 0 {
			fixed = id
			id++
		}
		c.add(gearItem{ID: fixed, Code: code, Family: fam, Kind: kind, Country: country, ReqGender: gender, TwoHanded: two})
	}
	add("ITEM_CH_SPEAR_11_C_RARE", 6, 4, 0, 2, true, itemSunSpear)
	add("ITEM_CH_SPEAR_11_A_RARE_ACTIVE", 6, 4, 0, 2, true, itemNovaSpear)
	add("ITEM_CH_SWORD_11_B_RARE", 6, 2, 0, 2, false, 0)
	add("ITEM_CH_SWORD_11_SET_A_RARE", 6, 2, 0, 2, false, 0)
	add("ITEM_CH_SWORD_11_A_RARE", 6, 2, 0, 2, false, 0)
	add("ITEM_CH_SHIELD_11_C_RARE", 4, 1, 0, 2, false, 0)
	add("ITEM_EU_SWORD_11_C_RARE", 6, 7, 1, 2, false, 0)
	add("ITEM_EU_TSWORD_11_A", 6, 8, 1, 2, true, 0)
	add("ITEM_EU_SHIELD_11_C_RARE", 4, 2, 1, 2, false, 0)
	for _, sx := range []struct {
		code   string
		gender int
	}{{"M", 1}, {"W", 0}} {
		for p, tok := range []string{"", "HA", "SA", "BA", "LA", "AA", "FA"} {
			if p == 0 {
				continue
			}
			add("ITEM_CH_"+sx.code+"_HEAVY_11_"+tok+"_C_RARE", 3, p, 0, sx.gender, false, 0)
			add("ITEM_EU_"+sx.code+"_HEAVY_11_"+tok+"_B_RARE", 11, p, 1, sx.gender, false, 0)
		}
	}
	c.finish()
	return c
}

func TestLoadoutsAreWearableAndSpreadThePluses(t *testing.T) {
	c := synthetic()
	plus := map[int]int{}
	seen := map[int64]int{}
	for i := 0; i < 2000; i++ {
		lk := lookFor(1, i)
		rows := c.loadout(1, i, lk.Race, lk.Sex)
		if len(rows) < 7 {
			t.Fatalf("bot %d: %d rows", i, len(rows))
		}
		slots := map[equipment.Slot]bool{}
		var weapon *gearItem
		for _, g := range rows {
			if slots[g.Slot] {
				t.Fatalf("bot %d: slot %d twice", i, g.Slot)
			}
			slots[g.Slot] = true
			if g.Item.Country != lk.Race {
				t.Fatalf("bot %d (%s) wears %s", i, lk.Gender(), g.Item.Code)
			}
			if g.Item.ReqGender != 2 && (g.Item.ReqGender == 1) != (lk.Sex == character.SexMan) {
				t.Fatalf("bot %d (%s) wears %s", i, lk.Gender(), g.Item.Code)
			}
			if g.Opt < 0 || g.Adv < 0 || g.Plus() > 14 {
				t.Fatalf("bot %d: %+v", i, g)
			}
			if g.Slot == equipment.SlotWeapon {
				weapon = g.Item
				plus[g.Plus()]++
			}
			seen[g.Item.ID]++
		}
		if weapon == nil {
			t.Fatalf("bot %d: no weapon", i)
		}
		if slots[equipment.SlotShield] && weapon.TwoHanded {
			t.Fatalf("bot %d: a shield with %s", i, weapon.Code)
		}
	}
	for p := 0; p <= 14; p++ {
		if plus[p] == 0 {
			t.Errorf("no weapon at +%d", p)
		}
	}
	for _, id := range []int64{itemSunSpear, itemNovaSpear} {
		if seen[id] == 0 {
			t.Errorf("%d never worn", id)
		}
	}
	// Deterministic.
	a, b := c.loadout(1, 42, 0, 1), c.loadout(1, 42, 0, 1)
	for i := range a {
		if a[i].Item.ID != b[i].Item.ID || a[i].Opt != b[i].Opt || a[i].Adv != b[i].Adv {
			t.Fatal("loadout is not deterministic")
		}
	}
}

func TestLooksMixRacesAndPassTheLobbyRules(t *testing.T) {
	races := map[string]int{}
	for i := 0; i < 400; i++ {
		lk := lookFor(1, i)
		races[lk.Gender()]++
		span := bodies[[2]int{lk.Race, lk.Sex}]
		if lk.RefObjID < span[0] || lk.RefObjID > span[1] || !character.ValidScale(int(lk.Scale)) || lk.Weapon == 0 || lk.Chest == 0 {
			t.Fatalf("bot %d: %+v", i, lk)
		}
	}
	if len(races) != 4 {
		t.Errorf("races and sexes: %v", races)
	}
}
