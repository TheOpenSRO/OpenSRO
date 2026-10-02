package refdata

import (
	"bytes"
	"reflect"
	"strconv"
	"testing"
)

// synthRow builds a synthetic textdata row: n columns, the rule's fields set
// and everything else "0". No game data: the values are written here.
func synthRow(n int, service, id int, code string, t1, t2, t3, t4, country, sex, twoHanded, maxStack int) []string {
	cols := make([]string, n)
	for i := range cols {
		cols[i] = "0"
	}
	itoa := strconv.Itoa
	cols[cgService] = itoa(service)
	cols[cgID] = itoa(id)
	cols[cgCodeName] = code
	cols[cgTypeID1], cols[cgTypeID1+1], cols[cgTypeID1+2], cols[cgTypeID1+3] = itoa(t1), itoa(t2), itoa(t3), itoa(t4)
	cols[cgCountry] = itoa(country)
	cols[cgSex] = itoa(sex)
	cols[cgMaxStack] = itoa(maxStack)
	if n > cgTwoHanded {
		cols[cgTwoHanded] = itoa(twoHanded)
	}
	return cols
}

// TestCreatableRule: the rule of charselect.md section 6 on synthetic rows --
// sex 0/1/2, country, the _A_DEF suffix, equipment only, Service 0, and a
// duplicated id whose LAST definition wins. NEGATIVE: before round 682 there
// is no CreatableExtractor and this file does not compile.
func TestCreatableRule(t *testing.T) {
	ex := NewCreatableExtractor()
	const charCols, itemCols = 100, 120
	// Bodies: a China man, a Europe woman, a monster (TypeID2 2), a body with
	// Service 0, and a China woman defined twice -- first as Service 0, then 1.
	ex.AddCharacterRow(synthRow(charCols, 1, 1909, "CHAR_CH_MAN_FIGHTER", 1, 1, 0, 0, 0, 1, 0, 0))
	ex.AddCharacterRow(synthRow(charCols, 1, 14888, "CHAR_EU_WOMAN_NOBLE", 1, 1, 0, 0, 1, 0, 0, 0))
	ex.AddCharacterRow(synthRow(charCols, 1, 1954, "MOB_CH_TIGER", 1, 2, 1, 1, 0, 0, 0, 0))
	ex.AddCharacterRow(synthRow(charCols, 0, 1990, "CHAR_CH_MAN_OLD", 1, 1, 0, 0, 0, 1, 0, 0))
	ex.AddCharacterRow(synthRow(charCols, 0, 1923, "CHAR_CH_WOMAN_FIGHTER", 1, 1, 0, 0, 0, 0, 0, 0))
	ex.AddCharacterRow(synthRow(charCols, 1, 1923, "CHAR_CH_WOMAN_FIGHTER", 1, 1, 0, 0, 0, 0, 0, 0))
	// A row too short to carry the sex column is not recorded.
	if ex.AddCharacterRow([]string{"1", "77", "SHORT"}) {
		t.Error("a short characterdata row was recorded")
	}
	// Items: a man's chest, a woman's, a weapon for either sex (one-handed),
	// a bow (two-handed), a Europe shield; then rows the rule refuses: a
	// non-_A_DEF chest, a consumable ending _A_DEF, a Service 0 _A_DEF row;
	// and a weapon whose second definition drops the suffix.
	ex.AddItemRow(synthRow(itemCols, 1, 3643, "ITEM_CH_M_CLOTHES_01_BA_A_DEF", 3, 1, 1, 3, 0, 1, 0, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 3652, "ITEM_CH_W_CLOTHES_01_BA_A_DEF", 3, 1, 1, 3, 0, 0, 0, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 3632, "ITEM_CH_SWORD_01_A_DEF", 3, 1, 6, 2, 0, 2, 0, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 3636, "ITEM_CH_BOW_01_A_DEF", 3, 1, 6, 6, 0, 2, 1, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 10896, "ITEM_EU_SHIELD_01_A_DEF", 3, 1, 4, 2, 1, 2, 0, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 3700, "ITEM_CH_M_CLOTHES_01_BA_A", 3, 1, 1, 3, 0, 1, 0, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 4000, "ITEM_ETC_HP_POTION_01_A_DEF", 3, 3, 1, 1, 3, 2, 0, 50))
	ex.AddItemRow(synthRow(itemCols, 0, 3646, "ITEM_CH_W_HEAVY_01_BA_A_DEF", 3, 1, 3, 3, 0, 0, 0, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 3633, "ITEM_CH_BLADE_01_A_DEF", 3, 1, 6, 3, 0, 2, 0, 1))
	ex.AddItemRow(synthRow(itemCols, 1, 3633, "ITEM_CH_BLADE_01_A_RARE", 3, 1, 6, 3, 0, 2, 0, 1))
	// The two ammunition rows, by code name.
	ex.AddItemRow(synthRow(itemCols, 1, 3655, AmmoArrowCode, 3, 3, 4, 1, 3, 2, 0, 2500))
	ex.AddItemRow(synthRow(itemCols, 1, 10885, AmmoBoltCode, 3, 3, 4, 2, 3, 2, 0, 2500))

	s := ex.Set()
	want := map[int64]Creatable{
		1909:  {ID: 1909, Code: "CHAR_CH_MAN_FIGHTER", Kind: CreatableModel, Country: 0, Sex: 1, TypeID1: 1, TypeID2: 1},
		1923:  {ID: 1923, Code: "CHAR_CH_WOMAN_FIGHTER", Kind: CreatableModel, Country: 0, Sex: 0, TypeID1: 1, TypeID2: 1},
		14888: {ID: 14888, Code: "CHAR_EU_WOMAN_NOBLE", Kind: CreatableModel, Country: 1, Sex: 0, TypeID1: 1, TypeID2: 1},
		3643:  {ID: 3643, Code: "ITEM_CH_M_CLOTHES_01_BA_A_DEF", Kind: CreatableItem, Country: 0, Sex: 1, TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 3, MaxStack: 1},
		3652:  {ID: 3652, Code: "ITEM_CH_W_CLOTHES_01_BA_A_DEF", Kind: CreatableItem, Country: 0, Sex: 0, TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 3, MaxStack: 1},
		3632:  {ID: 3632, Code: "ITEM_CH_SWORD_01_A_DEF", Kind: CreatableItem, Country: 0, Sex: 2, TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, MaxStack: 1},
		3636:  {ID: 3636, Code: "ITEM_CH_BOW_01_A_DEF", Kind: CreatableItem, Country: 0, Sex: 2, TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 6, TwoHanded: true, MaxStack: 1},
		10896: {ID: 10896, Code: "ITEM_EU_SHIELD_01_A_DEF", Kind: CreatableItem, Country: 1, Sex: 2, TypeID1: 3, TypeID2: 1, TypeID3: 4, TypeID4: 2, MaxStack: 1},
	}
	if s.Len() != len(want) {
		t.Errorf("%d creatable ids, want %d: %+v", s.Len(), len(want), s.Rows())
	}
	for id, w := range want {
		got, ok := s.Get(id)
		if !ok || !reflect.DeepEqual(got, w) {
			t.Errorf("%d: %+v (%v), want %+v", id, got, ok, w)
		}
	}
	for _, id := range []int64{1954, 1990, 3700, 4000, 3646, 3633} {
		if _, ok := s.Get(id); ok {
			t.Errorf("%d is in the catalogue", id)
		}
	}
	if a, ok := s.Ammo(AmmoArrowCode); !ok || a.ID != 3655 || a.MaxStack != 2500 {
		t.Errorf("arrows %+v %v", a, ok)
	}
	if sh, ok := s.Shield(1); !ok || sh.ID != 10896 {
		t.Errorf("Europe's shield %+v %v", sh, ok)
	}
	if _, ok := s.Shield(0); ok {
		t.Error("a China shield where none was given")
	}
	bow, _ := s.Get(3636)
	sword, _ := s.Get(3632)
	chest, _ := s.Get(3643)
	if !bow.IsBow() || bow.IsCrossbow() || sword.IsBow() || sword.Piece() != PieceWeapon || chest.Piece() != PieceChest || chest.ArmourClass() != 1 {
		t.Error("piece readings")
	}

	// The CSV round trip.
	var buf bytes.Buffer
	if err := WriteCreatableCSV(&buf, s); err != nil {
		t.Fatal(err)
	}
	back, err := LoadCreatableCSV(bytes.NewReader(buf.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(back.Rows(), s.Rows()) {
		t.Errorf("round trip:\n%+v\n%+v", back.Rows(), s.Rows())
	}
	if _, err := LoadCreatableCSV(bytes.NewReader([]byte("ID,Code\n1,x\n"))); err == nil {
		t.Error("a wrong header loaded")
	}
}
