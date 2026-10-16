// Package avatar is the avatar inventory (round 789): the five slots a
// character wears its avatars and its devil's spirit in, and the rules
// SR_GameServer.exe applies to them. Everything is READ from the binaries
// unless labelled; the research is /root/opensro-pk3av789/AVATAR_RESEARCH.md
// and docs/protocol/avatars.md has the wire.
//
// The storage (READ s:0x4e1340): a storage of type 5 and size 5 on the PC
// (+0x1c34), persisted as _InventoryForAvatar (CharID, Slot 0..4, ItemID). It
// holds only 3/1/13 (avatars: TypeID4 1 hat, 2 dress, 3 attachment, 4 flag)
// and 3/1/14 (the devil's spirit). The slot IS the storage index: no slot is
// fixed by type (s:0x523f70 takes the client's slot when it is empty, else the
// first empty one). The DISPLAY position is the client's, by type.
//
// OpenSRO keeps it as one more inventory container (internal/inventory, the
// bag's own store) on its own table, avatar_inventory_slots, with the bag's
// columns: the item instance -- variance, plus, blue options, the advanced
// elixir and the serial -- moves between the bag and the avatar slots
// unchanged. OURS: the container type, the table name.
package avatar

import (
	"context"
	"database/sql"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Slots is the avatar storage's size (READ s:0x4e1340: created with size 5;
// the 0x3013 and spawn blocks write it, s:0x4ba720).
const Slots = 5

// Table is the avatar inventory's table (OURS: the name; the columns are the
// bag's, inventory.schemaFor, keyed by the character as _InventoryForAvatar
// is by CharID).
const Table = "avatar_inventory_slots"

// OpenSQL opens the avatar inventory on db, creating or migrating its table
// as the bag's store does (the same schema, serial included).
func OpenSQL(db *sql.DB, maxStacks inventory.MaxStackLookup) (*inventory.SQLStore, error) {
	s, err := inventory.NewSQLStoreOwned(db, maxStacks, Table, inventory.DefaultOwnerColumn)
	if err != nil {
		return nil, err
	}
	s.SetCapacity(Slots)
	return s, nil
}

// NewMem is the in-memory avatar inventory.
func NewMem(maxStacks inventory.MaxStackLookup) *inventory.MemStore {
	m := inventory.NewMemStore(maxStacks)
	m.SetCapacity(Slots)
	return m
}

// The kinds (READ: the engine's predicates test `!(w&2) && TypeID1 == 3 &&
// TypeID2 == 1` and TypeID3; +0x454 is 13, +0x470 is 14, +0x464 13/2, +0x468
// 13/3).
const (
	TypeAvatar      = 13
	TypeDevilSpirit = 14

	KindHat        = 1
	KindDress      = 2
	KindAttachment = 3
	KindFlag       = 4
)

func equipment31(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == 3 && it.TypeID2 == 1
}

// IsAvatar is 3/1/13 (vslot +0x454, s:0x483b70).
func IsAvatar(it *refdata.Item) bool { return equipment31(it) && it.TypeID3 == TypeAvatar }

// IsDevilSpirit is 3/1/14 (vslot +0x470, s:0x483cc0).
func IsDevilSpirit(it *refdata.Item) bool { return equipment31(it) && it.TypeID3 == TypeDevilSpirit }

// IsAvatarItem is either: what the avatar storage may hold.
func IsAvatarItem(it *refdata.Item) bool { return IsAvatar(it) || IsDevilSpirit(it) }

// IsDress is 3/1/13/2 (vslot +0x464).
func IsDress(it *refdata.Item) bool { return IsAvatar(it) && it.TypeID4 == KindDress }

// IsAttachment is 3/1/13/3 (vslot +0x468).
func IsAttachment(it *refdata.Item) bool { return IsAvatar(it) && it.TypeID4 == KindAttachment }

// SameTID is FindItemHasSameTID's comparison (READ s:0x4ba130): TypeID1..4,
// not the cash or bionic bits.
func SameTID(a, b *refdata.Item) bool {
	return a != nil && b != nil && a.TypeID1 == b.TypeID1 && a.TypeID2 == b.TypeID2 &&
		a.TypeID3 == b.TypeID3 && a.TypeID4 == b.TypeID4
}

// The refusal codes of the avatar moves (READ, AVATAR_RESEARCH.md 1.3-1.7;
// the names are error_codes.md's where it has one).
const (
	CodeDead          uint16 = 2      // StorageOperation: the PC is dead (vslot 0xf8 == 2)
	CodeInvalidTarget uint16 = 3      // UIIT_MSG_STRGERR_INVALID_TARGET
	CodeWrongPosition uint16 = 0x1806 // CanBeEquipedAt: the slot past 12 (no name in error_codes.md)
	CodeFull          uint16 = 0x1807 // UIIT_MSG_STRGERR_INVENTORY_FULL
	CodeEmpty         uint16 = 0x1809 // the source is empty (no name in error_codes.md)
	CodeEquipItem     uint16 = 0x180e // UIIT_MSG_STRGERR_EQUIPITEM
	CodeGender        uint16 = 0x1816 // UIIT_MSG_STRGERR_GENDER_MISMATCH
	CodeCountry       uint16 = 0x182f // UIIT_MSG_STRGERR_COUNTRY_MISMATCH
	CodeStr           uint16 = 0x1830 // UIIT_MSG_STRGERR_HIGHER_STRENGTH_REQUIRED
	CodeInt           uint16 = 0x1831 // UIIT_MSG_STRGERR_HIGHER_INTELLECT_REQUIRED
	CodeBlocked       uint16 = 0x1834 // UIIT_MSG_STRGERR_STORAGE_OPERATION_BLOCKED
	CodeLevel         uint16 = 0x186c // UIIT_MSG_..._HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM
	CodeNotAwake      uint16 = 0x18f9 // UIIT_MSG_NASRUN_NOT_AWAKE_WEAR_ERROR
)

// MaxEquipPosition is CanBeEquipedAt's slot bound: a position past 12 is
// refused 0x1806 before any item rule (READ s:0x497070).
const MaxEquipPosition = 12

// CanBeEquipedAt is CGItemEquip::CanBeEquipedAt (s:0x497070) for an avatar
// item, in its order: the position (0x1806), the rental (not modelled:
// OpenSRO has no rentals), ReqGender (0x1816; 2 is either), the razed flag
// (not modelled), the four requirement pairs (0x186c, equipment.Check
// Requirements: the character level; masteries and tiers are carried, not
// enforced, as for equipment), ReqStr (0x1830), ReqInt (0x1831), the Country
// (0x182f; 3 is either). 0 when every rule passes. c nil skips the
// character's rules.
func CanBeEquipedAt(c *character.Character, it *refdata.Item, position int) uint16 {
	if position < 0 || position > MaxEquipPosition {
		return CodeWrongPosition
	}
	if c == nil || it == nil {
		return 0
	}
	if it.ReqGender != equipment.ReqGenderAny && it.ReqGender != character.SexOf(c.Gender) {
		return CodeGender
	}
	if err := equipment.CheckRequirements(equipment.RequirementsOf(it), c.Level, nil, nil); err != nil {
		return CodeLevel
	}
	if it.ReqStr > c.TotalStr() {
		return CodeStr
	}
	if it.ReqInt > c.TotalInt() {
		return CodeInt
	}
	if it.Country != equipment.CountryAny && it.Country != character.RaceOf(c.Gender) {
		return CodeCountry
	}
	return 0
}

// The devil's spirit's expiry. Retail keeps it in the instance's Data word
// (+0x38: the same field a weapon keeps its durability in; time32, 0 = never
// awakened; READ s:0x42e5c3, s:0x498060). OpenSRO keeps it the same way, in
// the instance's Durability: the unix second it expires, and 0 or
// durability.Untracked (-1) for one never awakened (OURS: the encoding of
// "never" as either; a 3/1/14 row has no durability, MEASURED Dur 0).

// Awake reports whether a devil's spirit with this Data word is active at
// now: the expiry set and not passed (READ FUN_00498610 s:0x498610: an unset
// expiry counts as expired).
func Awake(data int, now time.Time) bool {
	return data > 0 && now.Unix() < int64(data)
}

// PeriodWord is the record's word after the variance for a 3/1/14 (READ
// s:0x42e5c3..0x42e63f): bit 31 set when the expiry is set, the low 31 bits
// the seconds left (0 once passed).
func PeriodWord(data int, now time.Time) uint32 {
	if data <= 0 {
		return 0
	}
	left := int64(data) - now.Unix()
	if left < 0 {
		left = 0
	}
	if left > 0x7fffffff {
		left = 0x7fffffff
	}
	return 1<<31 | uint32(left)
}

// Awaken is CGItemEquip::vslot_325 (s:0x498060): an expiry already set
// refuses (2); else the expiry is now + the row's Param1 seconds (MEASURED
// 2,419,200 = 28 days on 22 rows, 604,800 on 4). ok false for the refusal.
func Awaken(data int, period uint32, now time.Time) (int, bool) {
	if data > 0 {
		return data, false
	}
	return int(now.Unix() + int64(period)), true
}

// Extend is the Nasrun extension's effect (CGItemExpendable::UseByKind case
// 0x10, s:0x49c2b0): the expiry moves by the extension's Param1. From the old
// expiry while it is ahead, from now once it has passed (INFERRED: the two
// branches after FUN_00498610 at s:0x49c8xx were not traced). ok false for a
// spirit never awakened (0x18f8 UIIT_MSG_NASRUN_EXTENSION_ITEM_USE_AFTER_AWAKE).
func Extend(data int, period uint32, now time.Time) (int, bool) {
	if data <= 0 {
		return data, false
	}
	base := int64(data)
	if now.Unix() >= base {
		base = now.Unix()
	}
	return int(base + int64(period)), true
}

// MaxOptLevel is CheckAvatarsetIntegrity's bound: an OptLevel of 251 or more
// fails it (READ s:0x4bb8a0, `>= 0xfb`).
const MaxOptLevel = 250

// Held is one occupied avatar slot with its reference row (nil: an id the
// item table does not know).
type Held struct {
	Slot inventory.Slot
	Item *refdata.Item
}

// IntegrityFailure is CGAvatarInventoryOP::CheckAvatarsetIntegrity
// (s:0x4bb8a0) on one slot, in its order: not an avatar item ("Item is not
// AvatarItem but exist in AvatarInventory!"), the other gender ("Equiped wrong
// sexual Item"), a TID already seen in an earlier slot ("Same TID Avatar Item
// is already exist!!"), OptLevel 251 or more. "" when the slot passes. seen
// is the slots before it, in storage order. The Country and the other
// CanBeEquipedAt refusals do not fail it (READ: only 0x180e does, which an
// avatar item cannot get).
func IntegrityFailure(c *character.Character, h Held, seen []Held) string {
	if !IsAvatarItem(h.Item) {
		return "not an avatar item"
	}
	if c != nil && h.Item.ReqGender != equipment.ReqGenderAny && h.Item.ReqGender != character.SexOf(c.Gender) {
		return "the other gender's"
	}
	for _, s := range seen {
		if SameTID(s.Item, h.Item) {
			return "a second item of the same type"
		}
	}
	if h.Slot.OptLevel > MaxOptLevel {
		return "plus over 250"
	}
	return ""
}

// List reads characterID's avatar slots with their reference rows, in
// storage order.
func List(ctx context.Context, st inventory.Store, items interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
}, characterID int64) ([]Held, error) {
	slots, err := st.List(ctx, characterID)
	if err != nil {
		return nil, err
	}
	out := make([]Held, 0, len(slots))
	for _, s := range slots {
		h := Held{Slot: s}
		if items != nil {
			if it, err := items.GetItem(ctx, s.ItemID); err == nil {
				h.Item = it
			}
		}
		out = append(out, h)
	}
	return out, nil
}
