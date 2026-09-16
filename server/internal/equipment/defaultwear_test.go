package equipment

import (
	"testing"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// packTypeWord builds the 16-bit packed TypeID the client and server both use
// to address an item type. The field layout is the one recovered from the
// server's RefItem_ReadTypeIDs bounds checks and used by every resolver since:
// bit 1 cash, bits 2-4 TypeID1, bits 5-6 TypeID2, bits 7-10 TypeID3, bits
// 11-15 TypeID4.
func packTypeWord(t1, t2, t3, t4 int) uint16 {
	return uint16(t1&7)<<2 | uint16(t2&3)<<5 | uint16(t3&0xf)<<7 | uint16(t4&0x1f)<<11
}

// TestDefaultWearTypeWords reproduces CObjCharacter::FUN_00a5c760 (`0x00a5c760`)
// from its own masks and checks that what this package says about the default
// wear lands on the same eight type words.
//
// The masks are applied here rather than the results being asserted directly,
// because the point is to catch a transcription error: the constants in the
// client are `0x80 0x100 0x480 0x500` for the family and `0x1800 0x2000` for
// the piece, and reading one of those wrong is exactly the mistake that has
// cost this project time before.
func TestDefaultWearTypeWords(t *testing.T) {
	const base = 0x2c // TypeID1 3, TypeID2 1, family and piece clear

	if got := packTypeWord(TypeItem, TypeEquipment, 0, 0); got != base {
		t.Fatalf("the client's starting word is %#x; packing 3/1/0/0 gives %#x", base, got)
	}

	// (mask, or) pairs straight out of the decompilation.
	family := map[int]map[bool][2]uint16{
		CountryChina: {
			false: {0xf8ff, 0x80},  // case 0: case 1:
			true:  {0xf97f, 0x100}, // case 2: case 3:
		},
		CountryEurope: {
			false: {0xfcff, 0x480},
			true:  {0xfd7f, 0x500},
		},
	}
	piece := [DefaultWearCount][2]uint16{
		{0x7ff, 0x1800}, // param_3 == 0
		{0x7ff, 0x2000}, // param_3 == 1
	}

	if len(DefaultWearSlots) != DefaultWearCount || len(DefaultWearPieces) != DefaultWearCount {
		t.Fatalf("DEFAULT_WEAR_NUM is %d, but there are %d slots and %d pieces",
			DefaultWearCount, len(DefaultWearSlots), len(DefaultWearPieces))
	}

	for _, country := range []int{CountryChina, CountryEurope} {
		for _, class := range []int{ArmorClassNone, ArmorClassGarment, ArmorClassProtector, ArmorClassArmor} {
			wantFamily, ok := DefaultWearFamily(country, class)
			if !ok {
				t.Fatalf("country %d has no default wear", country)
			}
			fm := family[country][class >= ArmorClassProtector]
			for n := 0; n < DefaultWearCount; n++ {
				w := (base & fm[0]) | fm[1]
				w = (w & piece[n][0]) | piece[n][1]

				want := packTypeWord(TypeItem, TypeEquipment, wantFamily, DefaultWearPieces[n])
				if w != want {
					t.Errorf("country %d class %d wear %d: client builds %#x, this package says %#x",
						country, class, n, w, want)
				}
				// Every default is the mail or the pants, and nothing else.
				if got := int(w>>11) & 0x1f; got != PieceMail && got != PiecePants {
					t.Errorf("country %d class %d wear %d: piece %d is neither mail nor pants",
						country, class, n, got)
				}
				if slot, ok := SlotFor(&refdata.Item{TypeID1: TypeItem, TypeID2: TypeEquipment,
					TypeID3: wantFamily, TypeID4: DefaultWearPieces[n]}); !ok || slot != DefaultWearSlots[n] {
					t.Errorf("wear %d resolves to slot %d (ok=%v), want %d", n, slot, ok, DefaultWearSlots[n])
				}
			}
		}
	}
}

// TestArmorClassOf holds the selector's three arms, and that a non-armour
// family falls through to none -- the client's loop simply keeps looking.
func TestArmorClassOf(t *testing.T) {
	for _, tc := range []struct {
		family int
		want   int
	}{
		{FamilyChinaGarment, ArmorClassGarment},
		{FamilyEuropeRobe, ArmorClassGarment},
		{FamilyChinaProtector, ArmorClassProtector},
		{FamilyEuropeLight, ArmorClassProtector},
		{FamilyChinaArmor, ArmorClassArmor},
		{FamilyEuropeHeavy, ArmorClassArmor},
		{FamilyWeapon, ArmorClassNone},
		{FamilyShield, ArmorClassNone},
		{FamilyJobSuit, ArmorClassNone},
		{FamilyChinaAccessory, ArmorClassNone},
		{FamilyEuropeAccessory, ArmorClassNone},
	} {
		if got := ArmorClassOf(tc.family); got != tc.want {
			t.Errorf("ArmorClassOf(%d) = %d, want %d", tc.family, got, tc.want)
		}
	}
	if _, ok := DefaultWearFamily(99, ArmorClassNone); ok {
		t.Error("a country the client has no arm for should report false")
	}
}

// TestStartingKitFillsTheDefaultWearSlots is the reason this was worth
// recovering. The client covers the mail and the pants by itself, so those are
// the two slots a kit does not strictly have to fill -- and the kit fills them
// anyway, with real items the inventory and the equipment window agree about.
// If the kit ever stops covering one, the character still looks dressed, which
// is exactly the silent disagreement GiveStartingKit was written to avoid.
func TestStartingKitFillsTheDefaultWearSlots(t *testing.T) {
	for _, gender := range []string{"man", "woman"} {
		kit := StartingKitFor(gender)
		for n, slot := range DefaultWearSlots {
			if _, ok := kit[slot]; !ok {
				t.Errorf("%s: the kit leaves slot %d (default wear %d) empty; the client would draw "+
					"a default garment there and the inventory would show nothing", gender, slot, n)
			}
		}
	}
}
