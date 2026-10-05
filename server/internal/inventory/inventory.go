// Package inventory implements this project's own per-character item
// storage: a fixed number of slots, each holding a stack of one item type
// up to that item's MaxStack (from refdata). Independent design — nothing
// here is informed by or ported from any original inventory system.
package inventory

import (
	"context"
	"errors"
)

// SlotsPerCharacter is how many inventory slots each character has. STILL OWN
// DESIGN -- the game's own starting size has not been recovered -- but it is no
// longer an unbounded choice, which is what this comment used to imply with
// "easy to change later".
//
// The real engine's LIMITS are recovered, and this number now sits inside them.
// `CGObjPC::ExpandInventory` (0x004e1910, vtable slot 173 -- see
// docs/protocol/igobj_vtable.md) refuses an expansion unless BOTH hold:
//
//	count <= cap - size        and        size + count < 100
//
// so the size after any expansion is at most `cap` and never reaches 100. `cap`
// is 0x4d = 77, raised to 99 by a condition at GObjPC::FUN_004e13b0 -- a
// 1,359-byte function this project has not read, so what unlocks the larger cap
// is NOT claimed here.
//
// The character's live size lives at `this + 0x1c2c` and persists as the _CHAR
// column `InventorySize` at charData+0xac (CInstancePC::CharData_BindDBColumns).
//
// WHAT RAISES THE CAP is now read: see ExpansionQuestCodes below.
//
// WHY 50 STAYS OWN DESIGN, restated 2026-09-17 on better evidence. This note
// used to say "the write reaches it through a register", implying a write
// existed and had not been found. Searching the DISASSEMBLY rather than the
// decompiler's output shows there is no such write:
//
//   - all ten instructions referencing `+0x1c2c` are READS
//     (`mov reg, DWORD PTR [base+0x1c2c]`) -- in CGObjPC::ExpandInventory, the
//     trade and storage paths, and four others;
//   - no `lea reg,[base+0x1c2c]` exists, so nothing takes the field's address
//     to write through either.
//
// The live field is populated from the loaded _CHAR row, and expansion is
// accounted for separately: AQ_StorageExpander writes the persisted column at
// charData+0xac. So the STARTING value is set by whatever CREATES a character,
// and this binary does not -- it carries no `INSERT INTO _CHAR`, and no function
// body holds a character-creation string (AQ_CharDataLoader only loads an
// existing one).
//
// That RETIRES the probe rather than leaving it open: 50 is own design because
// the number is not in SR_GameServer.exe to recover, not because the search
// fell short.
//
// One loose end, recorded rather than assumed: `_charnamelist` and
// `_KeepDelCharName` do appear as strings, in a separate all-lowercase run of
// table names this project has not explained. Nothing was found that uses them,
// and no claim is made about what they are for.
const SlotsPerCharacter = 50

// HOW TO READ THE BOUNDS BELOW: the engine counts the EQUIPMENT SLOTS inside
// them. Recovered 2026-09-16, and it changes what 99 means without changing any
// number here.
//
// The original keeps equipment and backpack in ONE index space on the character's
// storage: slots 0..12 are the equipment slots and the backpack starts at 13.
// Two use-sites agree, neither aware of the other:
//
//   - the trade-offer handler (`0x00526910`) refuses `slot < 0xd` with 0x1806
//     UIIT_MSG_STRGERR_WRONG_POSITION before it even fetches the item, because
//     what is worn cannot be put into a trade;
//   - CGPCInventoryOP::CheckEquipsetIntegrity (`0x004bb020`) validates exactly
//     slots 0..12 of that same storage, calling CanBeEquipedAt on each.
//
// 0xd is equipment.MaxEquipSlots, recovered independently four times over.
//
// So the engine's "inventory size" of 77 or 99 is the whole array: **at most 86
// usable backpack slots, not 99.** OpenSRO models the two spaces separately --
// equipment.Slot is its own enum and inventory slots start at 0 -- which is a
// different design, not a wrong one, and it is why nothing here changes. What
// would be wrong is reading MaxSlotsExpanded as 99 free backpack slots.
// TestOpenSROSlotsFitTheEnginesCombinedArray (in the equipment package, which
// is the one that can see both) holds the two models to the engine's total.

// The engine's own inventory bounds, RECOVERED from CGObjPC::ExpandInventory.
// CONFIRMED AT INSTRUCTION LEVEL 2026-09-16 -- the decompiler's constants were
// re-read in the disassembly rather than trusted:
//
//	4e1960  call 0x4e13b0                 <- the condition, unread
//	4e1965  mov  ecx,[ebx+0x1c2c]         <- current size
//	4e196d  mov  eax,0x4d                 <- cap 77
//	4e1974  mov  eax,0x63                 <- cap 99 when the call returned non-zero
//	4e197e  sub  eax,ecx ; cmp eax,esi    <- count <= cap - size
//
// Nothing enforces these at runtime here; they exist so that a later change to
// SlotsPerCharacter is checked against the real game rather than against
// nothing. TestSlotsPerCharacterFitsTheEngine holds it to them.
const (
	// MaxSlotsExpanded is the largest inventory the engine will ever produce:
	// the raised cap, 99.
	MaxSlotsExpanded = 99
	// MaxSlotsDefault is the cap before the expansion quest: 0x4d. What
	// GObjPC::FUN_004e13b0 tests for is READ as of 2026-09-17 -- see
	// ExpansionQuestCodes.
	MaxSlotsDefault = 77
	// SlotsHardLimit is the second, independent condition -- `size + count <
	// 100` -- so an inventory never reaches this value.
	SlotsHardLimit = 100

	// MaxSlotsByQuestReward is the cap of the OTHER inventory expansion path,
	// and it is an INVENTORY cap after all (round 270, 2026-09-19): the
	// slot-174 overload of ExpandInventory (0x004e19d0) tests
	// `[esi+0x1c2c] + amount <= 0x70` -- the same InventorySize field the item
	// path uses -- and its callers are the quest-reward appliers
	// (GObjPC::FUN_0092ee90's reward byte at +0x4d1, the CQTUTORIAL2_* rewards'
	// +0x3db), never an item. A quest can therefore take a bag to 112 where
	// the expansion item stops at 77 (99 with the quest flag). This constant
	// was called MaxStorageSlots until the callers were read; the warehouse's
	// ceiling is MaxStorageExpansionSlots below.
	MaxSlotsByQuestReward = 112

	// MaxThirdContainerSlots is a THIRD cap, on the container ExpandInventory
	// reaches when its `kind` argument is 3 -- a pointer at `this + 0x21d8`
	// whose current count is a BYTE at `+0x1c`:
	//
	//	4e192c  mov eax,[ebx+0x21d8] ; mov al,[eax+0x1c]
	//	4e194d  cmp ecx,0xd2 ; jle ok
	//	4e1957  mov ax,0x18fe                <- refused
	//
	// so current + count must be at most 0xd2 = 210, and the refusal is error
	// 0x18fe.
	//
	// NAMED 2026-09-16, and not by guessing. An earlier version of this comment
	// said "WHICH container kind 3 is has NOT been identified". The CLIENT
	// answers it: `0x18fe` is `UIIT_STT_STORAGE_EXPANSION_USE_ERORR` (the game's
	// own typo), recovered from the client's error dispatcher --
	// docs/protocol/error_codes.md. So kind 3 is the STORAGE EXPANSION path, and
	// the "USE" in the name fits its shape: it is reached by using an expansion
	// item.
	//
	// That is two binaries agreeing without either being consulted about the
	// other -- the server returning 0x18fe from this path, the client calling
	// 0x18fe a storage-expansion-use error -- which is the standard this project
	// accepts for a name.
	//
	// RESOLVED (round 270): the 112 cap belongs to the quest-reward INVENTORY
	// path (MaxSlotsByQuestReward); THIS is the warehouse's ceiling. The item
	// that reaches it is ITEM_MALL_WAREHOUSE_ADDITION (24366): the expendable
	// use switch (CGItemExpendable::vslot_309, case 0x11) passes the row's
	// Param1 as the amount -- 30 slots -- and maps Param2 (0 = inventory,
	// 1 = warehouse; the row's own Desc128 lists "0 = ..., 1 = ...") to the
	// container kind, 1 -> 3. ITEM_MALL_INVENTORY_ADDITION (24365) is the
	// Param2 = 0 sibling: +32 bag slots against the 77/99 cap. Both routes go
	// through AQ_StorageExpander, the engine's generic container-resize job.
	MaxStorageExpansionSlots = 210

	// The two mall items' increments, itemdata Param1 (column 118).
	InventoryAdditionSlots = 32
	WarehouseAdditionSlots = 30
)

// ErrNoRoom is returned by Store.AddItem when there's no slot available to
// hold the item (all slots full, and no existing stack has spare capacity).
//
// The game makes the same refusal and names it: engine code `0x281c`,
// `UIIT_MSG_STRGERR_INVENTORY_FULL` (docs/protocol/error_codes.md). OpenSRO
// arrived at this independently; the name is recorded so the two can be
// compared.
var ErrNoRoom = errors.New("inventory: no room for item")

// ErrInvalidSlot is returned when a requested slot index is out of range
// for SlotsPerCharacter.
var ErrInvalidSlot = errors.New("inventory: invalid slot index")

// ErrSlotEmpty is returned by Store.RemoveItem when the target slot has
// nothing in it.
var ErrSlotEmpty = errors.New("inventory: slot is empty")

// ErrInvalidQuantity is returned when an operation is given a quantity of zero
// or less.
//
// The game makes the same refusal and names it: engine code `0x1829`,
// `UIIT_MSG_STRGERR_SPECIFY_POSITIVE_NUMBER_ONLY`, raised from three separate
// storage handlers (`00480f30`, `004b2450`, `005243d0`). Its companion `0x1814`
// `..._ENABLEINPUT_FEWERTHAN_REMAIN` is the upper bound, which OpenSRO already
// had as ErrInsufficientQuantity -- so the engine guards both ends of the range
// and OpenSRO was guarding only one.
//
// THIS WAS A DUPLICATION BUG, not a tidiness issue. RemoveItem checked only
// `quantity > slot.Quantity`, so a negative quantity passed every guard and
// reached `slot.Quantity -= quantity`, which ADDS. internal/storage already
// rejected non-positive amounts; inventory did not.
var ErrInvalidQuantity = errors.New("inventory: quantity must be positive")

// ErrInsufficientQuantity is returned by Store.RemoveItem when asked to
// remove more than the slot currently holds.
var ErrInsufficientQuantity = errors.New("inventory: not enough quantity in slot")

// Slot is one occupied inventory slot.
type Slot struct {
	Index    int
	ItemID   int64
	Quantity int
	// Variance is the instance's 64-bit white-stat field: twelve 5-bit groups,
	// group 0 being durability's (docs/protocol/durability.md). Rolled once,
	// when the item is created, and carried wherever the item goes.
	Variance uint64
	// Durability is the instance's current durability: durability.Untracked
	// (-1) for an item that has none or was created before this existed,
	// 0 when broken, otherwise the points left of its max.
	Durability int
	// OptLevel, MagParams and AdvElixir are the rest of the instance (round
	// 732; see Instance).
	OptLevel  uint8
	MagParams []uint64
	AdvElixir uint8
}

// Instance is what makes one item different from another of the same id:
// the fields a transfer between containers must carry along unchanged.
//
// Round 732 added the rest of the retail item instance (docs/protocol/
// item_tooltip.md "The item instance on the wire"), each READ from the
// client's item parser SOItem::FUN_008be4f0 and the server's item record:
//   - OptLevel: the plus (+N), the record's OptLevel, the u8 the parser reads
//     into the item at +0x8c;
//   - MagParams: the blue options, at most 12 (MAX_MAGPARAM_PER_ITEM,
//     c:0x8bcdf0; "Item's MagParamNum(%d) is out of range", gs:0x459d30),
//     each a packed u64 -- low u16 the magicoption.txt id, high u32 the
//     value (c:0x8bcdf0; gs Item_DecodeMagicOption 0x4904f2);
//   - AdvElixir: the advanced-elixir plus, the binding-option block of type
//     2 the parser adds onto the plus (c:0x8bb070).
type Instance struct {
	Variance   uint64
	Durability int
	OptLevel   uint8
	MagParams  []uint64
	AdvElixir  uint8
}

// MaxMagParams is the cap on an item's blue options (READ: c:0x8bcdf0's
// "m_btMagicParamNum <= MAX_MAGPARAM_PER_ITEM" against 0xc).
const MaxMagParams = 12

// Instance returns the slot's per-instance fields.
func (s Slot) Instance() Instance {
	return Instance{Variance: s.Variance, Durability: s.Durability, OptLevel: s.OptLevel,
		MagParams: cloneParams(s.MagParams), AdvElixir: s.AdvElixir}
}

// Equal reports whether two instances are the same in every field.
func (i Instance) Equal(o Instance) bool {
	if i.Variance != o.Variance || i.Durability != o.Durability || i.OptLevel != o.OptLevel ||
		i.AdvElixir != o.AdvElixir || len(i.MagParams) != len(o.MagParams) {
		return false
	}
	for k := range i.MagParams {
		if i.MagParams[k] != o.MagParams[k] {
			return false
		}
	}
	return true
}

// SetInstance writes inst's fields onto the slot.
func (s *Slot) SetInstance(inst Instance) {
	s.Variance, s.Durability = inst.Variance, inst.Durability
	s.OptLevel, s.MagParams, s.AdvElixir = inst.OptLevel, cloneParams(inst.MagParams), inst.AdvElixir
}

func cloneParams(p []uint64) []uint64 {
	if len(p) == 0 {
		return nil
	}
	return append([]uint64(nil), p...)
}

// MagParam packs one blue option as the wire and the record carry it: the
// low u16 the magicoption.txt id, the high u32 the value (READ, c:0x8bcdf0:
// `uVar2 & 0xffff` names the option, the high dword is its value). Bits
// 16..31 of the low dword are not used by OpenSRO (OPEN, gs 0x4904f2 hands
// them back separately).
func MagParam(optionID uint16, value uint32) uint64 {
	return uint64(value)<<32 | uint64(optionID)
}

// MagParamOption and MagParamValue split a packed option.
func MagParamOption(p uint64) uint16 { return uint16(p) }
func MagParamValue(p uint64) uint32  { return uint32(p >> 32) }

// EncodeMagParams packs the options for a BYTEA column: 8 little-endian
// bytes each. DecodeMagParams reverses it, dropping a trailing partial entry
// and anything past MaxMagParams.
func EncodeMagParams(p []uint64) []byte {
	out := make([]byte, 0, 8*len(p))
	for _, v := range p {
		for i := 0; i < 8; i++ {
			out = append(out, byte(v>>(8*i)))
		}
	}
	return out
}

func DecodeMagParams(b []byte) []uint64 {
	var out []uint64
	for len(b) >= 8 && len(out) < MaxMagParams {
		var v uint64
		for i := 0; i < 8; i++ {
			v |= uint64(b[i]) << (8 * i)
		}
		out = append(out, v)
		b = b[8:]
	}
	return out
}

// DurabilityLookup answers, for an item id, the reference row's durability
// range (itemdata columns 63/64, Dur_L/Dur_U). ok is false for an item that
// has no durability -- a consumable, a quest item, an unknown id. Stores that
// hold one roll a fresh instance on every new grant and initialise legacy
// rows on first read; stores without one leave durability Untracked.
type DurabilityLookup interface {
	DurabilityRange(ctx context.Context, itemID int64) (durMin, durMax float64, ok bool, err error)
}

// MaxStackLookup resolves an item's max stack size, so Store.AddItem knows
// how many can go in one slot before it needs a new one. Satisfied by
// refdata.SQLStore in production; tests can use a trivial stub.
//
// Zero (or less) means "no configured limit", which AddItem reads as an
// item that does not stack -- one to a slot. An item the lookup has never
// heard of must answer zero rather than an error: an error makes the item
// impossible to hold at all, and a deployment that has not imported
// reference data for a given item should still be able to store it.
// Errors are for a lookup that actually failed.
type MaxStackLookup interface {
	GetMaxStack(ctx context.Context, itemID int64) (int, error)
}

// Store is anything that can list, add to, and remove from a character's
// inventory.
type Store interface {
	// List returns every occupied slot for characterID, in slot-index
	// order.
	List(ctx context.Context, characterID int64) ([]Slot, error)

	// AddItem adds quantity of itemID to characterID's inventory, filling
	// any existing under-full stack of the same item first, then using
	// empty slots as needed. Returns ErrNoRoom if it doesn't fit anywhere.
	AddItem(ctx context.Context, characterID, itemID int64, quantity int) error

	// RemoveItem removes quantity from the given slot. If that empties the
	// slot exactly, the slot becomes free again.
	RemoveItem(ctx context.Context, characterID int64, slot int, quantity int) error

	// MoveItem is what dragging a stack from one bag slot onto another
	// does. `from` must hold something (ErrSlotEmpty otherwise); both
	// indices must be in range (ErrInvalidSlot). Then, in order:
	//
	//   - `to` empty: the stack moves there and `from` becomes free;
	//   - `to` holds the SAME item and it stacks: as much as fits is merged
	//     into `to` (up to its MaxStack) and the rest stays in `from`;
	//   - anything else (a different item, or a full stack of the same one):
	//     the two slots swap.
	//
	// Moving a slot onto itself is a no-op that succeeds. Quantities are
	// conserved in every branch -- nothing is created or destroyed.
	MoveItem(ctx context.Context, characterID int64, from, to int) error

	// AddItemInstance is AddItem for an item that already EXISTS somewhere
	// -- coming back from the worn slots, across a trade or the warehouse,
	// or up off the ground -- so its instance travels with it instead of
	// being rolled afresh. Same room and stacking rules as AddItem; a
	// stackable that merges into an existing stack keeps that stack's
	// instance (stackables carry none that matters).
	AddItemInstance(ctx context.Context, characterID, itemID int64, quantity int, inst Instance) error

	// SetDurability writes one slot's current durability (a loss, a repair,
	// a break). It does not clamp or refuse -- durability.Apply decides the
	// value, this stores it. ErrSlotEmpty when nothing is there.
	SetDurability(ctx context.Context, characterID int64, slot int, durability int) error

	// SetInstance writes one slot's whole instance: variance, durability,
	// plus, blue options and advanced elixir (round 732; the GM tools set
	// a test item's plus and options through it). ErrSlotEmpty when nothing
	// is there.
	SetInstance(ctx context.Context, characterID int64, slot int, inst Instance) error

	// Capacity is this container's slot count: how many indices AddItem may
	// use and List may report. The bag's is SlotsPerCharacter; the warehouse
	// has its own (storage.DefaultCapacity), which the client needs to page
	// the authored 30-slot lattice.
	Capacity() int
}

// CapacityFunc answers one owner's slot count, for a container whose size is
// per owner: the warehouse's is the account's `_ChestInfo.ChestSize`, which
// an expansion item grows (storage.CapacityOf, round 498). An answer of zero
// or less means "the container's own Capacity()". A store given one bounds
// every per-owner operation by it; the bag has none.
type CapacityFunc func(ctx context.Context, owner int64) int

// ExpansionQuestCodes is what raises the inventory cap from MaxSlotsDefault to
// MaxSlotsExpanded. Read 2026-09-17 from GObjPC::FUN_004e13b0, the 1,359-byte
// function `CGObjPC::ExpandInventory` consults, which this package had recorded
// as unread and deliberately made no claim about.
//
// The function builds these six quest codes, looks each up in the character's
// quest container at `this + 0x1d98`, and returns 1 on the first one that
// matches (`mov eax,0x1` at 0x004e1833). Two conditions count as a match:
//
//	4e1758  call 0x570c90 ; cmp al,0x8    <- the quest's status byte (record +0x20)
//	4e177a  call 0x5713d0 ; test ax,ax    <- its 16-bit field (record +0x22), non-zero
//
// The prefixes are the engine's race and region tags, the same shape as its
// other quest codes.
//
// A SECOND, INDEPENDENT SOURCE for the same six: the server carries an RTTI
// class per quest, and their names are these codes with a C in front --
// CQSP_CH_EXINVENTORY_1, CQSP_WC_EXINVENTORY_2 and so on. There are nine such
// CQSP_ classes: these six and CQSP_ALL_POTION_1..3.
//
// CORRECTED 2026-09-17, the same day it was written. This comment first said
// "only nine quests in the whole binary are classes rather than data", which
// was a fact about a grep for `^CQSP_`, not about the binary. There are **162
// quest classes**: 9 `CQSP_` and 153 `CQNO_`, each deriving
// CBasicQuest : CQuestBase : IQuest. What is true of the six is that they are
// the ones an ENGINE LIMIT consults, which is why they turned up here.
//
// NOT READ: what status 8 means. "Completed" is the obvious reading and is not
// recorded as fact. Three sibling functions (0x005703b0, 0x00570650,
// 0x00570960) accept exactly {1, 7, 8} as a group, so 8 is one of three live
// states rather than a unique terminal one, and the write that sets it was not
// found -- it goes through a computed pointer, not a literal `[reg+0x20]`.
//
// OpenSRO has no quests yet, so nothing consumes this. It is recorded because
// "the cap is 77 or 99" was in this package for a week without the reason.
var ExpansionQuestCodes = []string{
	"QSP_CH_EXINVENTORY_1",
	"QSP_EU_EXINVENTORY_1",
	"QSP_WC_EXINVENTORY_2",
	"QSP_CA_EXINVENTORY_2",
	"QSP_KT_EXINVENTORY_3",
	"QSP_RM_EXINVENTORY_4",
}
