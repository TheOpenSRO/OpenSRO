package equipment

// What a character is drawn wearing in a slot that has nothing in it.
//
// This is a CLIENT rule, recovered whole from the client binary. The server
// never sends it and never needs to: the client builds the type of a default
// garment itself, from the character's race and what armour they have on, and
// draws it with no item id involved. It is recorded here because this is where
// the rest of the slot model lives, and because it settles a question
// `GiveStartingKit` had to guess at -- see the note there.
//
// CObjCharacter::FUN_00a5cca0 (`0x00a5cca0`) is the setter. It asserts both its
// arguments through the game's own source:
//
//	CObjCharacter.cpp:770  "(nEquipSlot >=0 ) && ( nEquipSlot < EQUIP_VISUAL_COUNT)"
//	CObjCharacter.cpp:771  "(nDefaultWearNum >=0 ) && ( nDefaultWearNum < DEFAULT_WEAR_NUM)"
//
// with guards `p < 0 || 8 < p` and `p < 0 || 1 < p`, so EQUIP_VISUAL_COUNT is 9
// (see EquipVisualCount) and DEFAULT_WEAR_NUM is 2. It keeps the two results in
// a two-entry array at `this + 0x11c`, eight bytes apart.
//
// CObjCharacter::FUN_00a5c760 (`0x00a5c760`) builds the type word, and it is an
// ordinary packed TypeID of the kind itemdata carries. It starts at 0x2c --
// TypeID1 3, TypeID2 1, item and equipment, with the family and piece fields
// clear -- then fills the family from the race and the piece from the wear
// number. The eight reachable words decode as:
//
//	China   garment/none  wear 0 -> 0x18ac  3/1/1/3      wear 1 -> 0x20ac  3/1/1/4
//	China   protector/up  wear 0 -> 0x192c  3/1/2/3      wear 1 -> 0x212c  3/1/2/4
//	Europe  robe/none     wear 0 -> 0x1cac  3/1/9/3      wear 1 -> 0x24ac  3/1/9/4
//	Europe  light/up      wear 0 -> 0x1d2c  3/1/10/3     wear 1 -> 0x252c  3/1/10/4
//
// Every one is TypeID4 3 or 4 -- the mail and the pants. Those are the two
// slots a character is never seen bare in, and nothing else gets a default.
//
// TestDefaultWearTypeWords recomputes all eight from the masks rather than
// trusting the table above; hand-transcribing a constant has been wrong three
// times in this project.

// DefaultWearCount is the client's DEFAULT_WEAR_NUM.
const DefaultWearCount = 2

// DefaultWearSlots are the slots the client covers by itself, in wear-number
// order: wear 0 is the mail, wear 1 is the pants.
var DefaultWearSlots = []Slot{SlotMail, SlotPants}

// DefaultWearPieces are the TypeID4 values the client asks for, in the same
// order -- PieceMail then PiecePants. They are what puts DefaultWearSlots in
// that order rather than the reverse.
var DefaultWearPieces = []int{PieceMail, PiecePants}

// The armour classes, as the client's own selector ranks them. Each covers one
// family per race, and the pairing is positional: China's garment/protector/
// armour against Europe's robe/light/heavy.
const (
	ArmorClassNone      = 0
	ArmorClassGarment   = 1 // China garment (1), Europe robe (9)
	ArmorClassProtector = 2 // China protector (2), Europe light (10)
	ArmorClassArmor     = 3 // China armour (3), Europe heavy (11)
)

// ArmorClassOf reports which class an armour family belongs to, or
// ArmorClassNone for a family that is not armour.
//
// This is CObjCharacter::FUN_00a5c670 (`0x00a5c670`), which walks the
// character's nine visual slots and returns the class of the first armour it
// finds -- 1 for TypeID3 1 or 9, 2 for 2 or 10, 3 for 3 or 11, and 0 if it
// reaches the end. (Its loop bound, `8 < i`, is a fourth independent witness
// for EquipVisualCount.)
func ArmorClassOf(family int) int {
	switch family {
	case FamilyChinaGarment, FamilyEuropeRobe:
		return ArmorClassGarment
	case FamilyChinaProtector, FamilyEuropeLight:
		return ArmorClassProtector
	case FamilyChinaArmor, FamilyEuropeHeavy:
		return ArmorClassArmor
	}
	return ArmorClassNone
}

// DefaultWearFamily reports the TypeID3 the client draws a bare slot in, given
// the character's country and the class of armour they are wearing.
//
// THE THREE CLASSES COLLAPSE INTO TWO. A character wearing armour or heavy
// (class 3) gets the same default as one wearing protector or light (class 2),
// and a character wearing nothing (class 0) gets the same as one in garment or
// robe (class 1). The client's switch groups them `case 0: case 1:` and
// `case 2: case 3:` exactly so, which is why this is a comparison against
// ArmorClassProtector rather than a four-way table.
//
// Reports false for a country the client has no arm for.
func DefaultWearFamily(country, armorClass int) (int, bool) {
	heavier := armorClass >= ArmorClassProtector
	switch country {
	case CountryChina:
		if heavier {
			return FamilyChinaProtector, true
		}
		return FamilyChinaGarment, true
	case CountryEurope:
		if heavier {
			return FamilyEuropeLight, true
		}
		return FamilyEuropeRobe, true
	}
	return 0, false
}
