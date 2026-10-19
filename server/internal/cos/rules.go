package cos

import (
	"sort"
	"strconv"
	"strings"
	"time"
)

// Round 795: the rules a summoned COS lives by, READ from SR_GameServer.exe
// and sro_client.exe (docs/protocol/pets.md, "Round 795" has the addresses
// and the wire tables). Labels: READ, MEASURED, INFERRED, OURS.

// The kinds by the summoned row's TypeID4, under the names the rest of the
// server uses.
const (
	KindRide      = KindCOS_C    // COS_C_*: IsVehicle (IGObj slot 13, s:0x482840)
	KindTransport = KindCOS_T    // COS_T_*: IsCart (slot 12, s:0x4827f0)
	KindGrowth    = KindPetWolf  // CGObjCOS_GoldPet: growth and fellow pets
	KindAbility   = KindPetSmall // CGObjCOS_SilkPet: the ability ("silk") pets
	KindSoldier   = KindGuildCOS
)

// ClientKind is the client's COS kind byte (COSData +0x14, set by
// COSDataMgr::FUN_009a1900 c:0x9a19ee..0x9a1aa8, READ): 0 ride, 1 transport,
// 2 ability pet, 3 growth pet, 4 guild soldier -- the two pets the other way
// round from TypeID4.
func ClientKind(typeID4 int) int {
	switch typeID4 {
	case KindRide:
		return 0
	case KindTransport:
		return 1
	case KindAbility:
		return 2
	case KindGrowth:
		return 3
	}
	return 4
}

// IsPetKind reports a growth or ability pet (s:FUN_0044b460).
func IsPetKind(typeID4 int) bool { return typeID4 == KindGrowth || typeID4 == KindAbility }

// The summoner items (MEASURED on itemdata, READ by the classes that use them):
//   - 3/2/1/1 growth and fellow pet items, 3/2/1/2 ability pet items --
//     CGItemCOSSummoner, never consumed (its DoJob forces the remaining count
//     to 1, s:0x493070);
//   - 3/3/3/2 ride and transport scrolls -- CGItemExpendable, consumed one a
//     summon (s:0x49aca0 -> vslot_307 0x49b9f0 case 2).
func IsPetItem(t1, t2, t3, t4 int) bool {
	return t1 == 3 && t2 == 2 && t3 == 1 && (t4 == 1 || t4 == 2)
}

// IsRideScroll reports a ride or transport scroll.
func IsRideScroll(t1, t2, t3, t4 int) bool { return t1 == 3 && t2 == 3 && t3 == 3 && t4 == 2 }

// The COS record's state flags (_CHARCOS.State, record +0x38, READ).
const (
	StateAlive    = 1
	StateSummoned = 2
)

// The summoner item's state byte -- the item record's first COS byte and
// 0x3040 mask 0x40's value (CGItemCOSSummoner::vslot_328 s:0x492d20, READ).
const (
	ItemStateNone     = 1 // never summoned: no COS record
	ItemStateSummoned = 2 // alive and out
	ItemStateStored   = 3 // alive, in the item
	ItemStateDead     = 4 // dead (a growth pet), or an ability pet's rent run out
)

// ItemState is the byte for a record's flags, or ItemStateNone for no record.
func ItemState(has bool, flags uint8) uint8 {
	switch {
	case !has:
		return ItemStateNone
	case flags&StateAlive == 0:
		return ItemStateDead
	case flags&StateSummoned != 0:
		return ItemStateSummoned
	}
	return ItemStateStored
}

// The hunger gauge (HGP), growth pets only (pets.md rounds 299/300, and
// round 795's decay).
const (
	HGPFull = 10000
	// HGPLow is the 30 % line under which the pet's stats are halved
	// (s:0x4d5d50; the client's 0x99dd40 tests HGP <= 3000).
	HGPLow = 3000
	// HGPRevived is what a revival sets a starved gauge to (s:0x49d617).
	HGPRevived = 3000
	// HGPFeedRefusePercent: a feed at 99 % or more is refused 0x18b3.
	HGPFeedRefusePercent = 99
	// HungerMinutesPerPercent is every growth row's Except_4 (MEASURED: 5 on
	// all of them), which RefObjChar_ExtractData turns into
	// 100 / (Except_4 * 60) HGP a second (s:0x6a6022..0x6a605f).
	HungerMinutesPerPercent = 5
)

// HungerPerSecond is the gauge's loss a second: 1/3 HGP, 1 % every 5
// minutes, 8 h 20 min from full to empty.
func HungerPerSecond() float64 { return 100.0 / (HungerMinutesPerPercent * 60) }

// HungerCrossedTen reports whether the gauge going from old to now fell
// below a 10 % mark -- when CGObjCOS_GoldPet::Update (s:0x4d5e00) saves it
// and tells the owner (0x30C9 type 4).
func HungerCrossedTen(old, now int) bool {
	return old/100%10 == 0 && now/100%10 != 0 && now < old
}

// FeedAmount is an HGP potion's gain: Param1 x 100 (s:0x49d782..0x49d7d5),
// the result clamped into 1..10000.
func FeedAmount(hgp, param1 int) int {
	n := hgp + param1*100
	if n < 1 {
		n = 1
	}
	if n > HGPFull {
		n = HGPFull
	}
	return n
}

// The regeneration: every character's slot 362 on a 4 s timer (s:0x4a6dc0),
// a COS's being GObjPC::FUN_004c3e70 -- 1.6 % of its max HP (and MP) while
// alive and standing or sitting (READ).
const (
	RegenPeriod   = 4 * time.Second
	RegenFraction = 0.016
)

// RegenAmount is one regen step's HP for a max of maxHP (ftol: truncated).
func RegenAmount(maxHP int) int { return int(float64(maxHP) * RegenFraction) }

// RentCheckPeriod is how often a summoned ability pet's rent is checked
// (CGObjCOS_SilkPet::vslot_368 s:0x4d6ff0 on a 30 s timer, READ).
const RentCheckPeriod = 30 * time.Second

// RentEnd is an ability pet's rent end for a summon item whose Param1 is
// minutes (READ s:0x4403a9..0x4403c8; MEASURED 4320 = 3 days, 40320 = 28).
func RentEnd(now time.Time, param1Minutes int64) time.Time {
	return now.Add(time.Duration(param1Minutes) * time.Minute)
}

// RentSecondsLeft is the item record's and 0x3040 mask 0x80's u32: the
// seconds to end, clamped to 0..0x7fffffff (s:0x492e2d..0x492eaa).
func RentSecondsLeft(end, now time.Time) uint32 {
	left := end.Unix() - now.Unix()
	if left < 0 {
		return 0
	}
	if left > 0x7fffffff {
		left = 0x7fffffff
	}
	return uint32(left)
}

// The inventory a COS is created with (_AddNewCOS's ninth argument, READ
// s:0x440300..): 28 slots for an ability pet (0x1c), none for a growth pet;
// a ride or transport takes its row's InventorySize (not modelled: OpenSRO
// has no trade goods, OURS).
const AbilityPetSlots = 28

// PetOption is _CHARCOS.PetOption at creation: 1 for a growth pet, 7 for an
// ability pet, 0 otherwise (READ). The client reads the growth pet's as the
// AI mode and the ability pet's as the pickup flags below.
func PetOption(typeID4 int) uint32 {
	switch typeID4 {
	case KindGrowth:
		return 1
	case KindAbility:
		return 7
	}
	return 0
}

// The ability pet's pickup flags (the client's Setting page, CIFCOSSetup
// c:0x7a8290/0x7a83e0/0x7a84c0, READ): what 0x7420 type 2 sends.
const (
	PickGold      = 0x01
	PickEquipment = 0x02
	PickOther     = 0x04
	PickAll       = 0x40 // grab every item, not only the owner's
	PickOn        = 0x80
)

// The growth pet's AI mode (0x7420 type 1, the PgDn toggle, READ
// c:0x81ea70): 1 offensive, 0 defensive.
const (
	AIDefensive = 0
	AIOffensive = 1
)

// Ranges (READ, both doubles in .rdata).
const (
	// RecallRange: unsummoning (0x7116), or using the item on an out pet,
	// needs the pet within 100.0 of its owner (s:0x511a60, s:0x4e8fc0;
	// 0xb45af0).
	RecallRange = 100.0
	// MountRange: mounting needs the COS within 30.0 (s:0x4fc4d0;
	// 0xb45e58).
	MountRange = 30.0
)

// RideRow is the characterdata code a ride or transport scroll summons for
// an owner of level ownerLevel (CGItemExpendable::vslot_307 case 2,
// s:0x49bbc1..0x49bc98, READ): with a level list in desc2 (Desc128_2, e.g.
// "5,10,20,30,45,60,75,90,105,120"), the set of those bytes plus 1 and 255,
// the largest element <= ownerLevel, and the code desc1 + "_<that>"; with
// none ("xxx"), desc1 itself. ok is false when desc1 names nothing (the
// engine's code 5).
func RideRow(desc1, desc2 string, ownerLevel int) (code string, ok bool) {
	desc1 = strings.TrimSpace(desc1)
	if desc1 == "" || desc1 == "xxx" {
		return "", false
	}
	levels := RideLevels(desc2)
	if len(levels) == 0 {
		return desc1, true
	}
	// upper_bound(set, level), then one back: the largest <= level.
	i := sort.SearchInts(levels, ownerLevel+1)
	if i == 0 || i == len(levels) {
		return "", false
	}
	return desc1 + "_" + strconv.Itoa(levels[i-1]), true
}

// RideLevels is desc2's byte set with the engine's 1 and 255 added, sorted;
// nil for none.
func RideLevels(desc2 string) []int {
	desc2 = strings.TrimSpace(desc2)
	if desc2 == "" || desc2 == "xxx" {
		return nil
	}
	seen := map[int]bool{1: true, 255: true}
	for _, p := range strings.Split(desc2, ",") {
		if n, err := strconv.Atoi(strings.TrimSpace(p)); err == nil && n >= 0 && n <= 255 {
			seen[n] = true
		}
	}
	out := make([]int, 0, len(seen))
	for n := range seen {
		out = append(out, n)
	}
	sort.Ints(out)
	return out
}

// DeathExpLoss is a growth pet's EXP loss when it dies
// (GObjCOS_Pet::FUN_004d6c80, READ): min(unit*k, floor(next*p)/2), none when
// floor(next*p)/2 < 1; next is the level's ExpToNext, unit its exp unit
// (leveldata row +0x1c), and k, p by who killed it and whether the owner is
// a murderer.
func DeathExpLoss(next, unit int64, killedByPlayer, ownerMurderer bool) int64 {
	k, p := int64(100), 0.02
	switch {
	case killedByPlayer && ownerMurderer:
		k, p = 100, 0.02
	case killedByPlayer:
		k, p = 20, 0.004
	case ownerMurderer:
		k, p = 300, 0.06
	}
	half := int64(float64(next)*p) / 2
	if half < 1 {
		return 0
	}
	if byUnit := unit * k; byUnit < half {
		return byUnit
	}
	return half
}

// ValidPetName is HandleNameCOS's test (s:0x511bb0, READ): 1..12 bytes and
// no space; the forbidden-word filters (FUN_007312f0 / FUN_00987770) are the
// server's name filter, applied by the caller.
func ValidPetName(name string) bool {
	return ValidName(name) && !strings.Contains(name, " ")
}

// The refusal codes round 795 uses, by the client's names
// (docs/protocol/error_codes.md) where it has them.
const (
	ErrCannotBeUsed          = 0x183e // STRGERR_CANNOT_BE_USED
	ErrCOSNotSummonable      = 0x18a4 // COS_STATE_IS_NOT_SUMMONABLE (dead, or rent run out)
	ErrCOSInBattle           = 0x1878 // COS_CAN_NOT_CREATE_BATTLE
	ErrCOSDungeon            = 0x1879 // COS_CREATE_DUNGEON
	ErrMurdererVehicle       = 0x1876 // MURDERER_CANT_SUMMON_VEHICLE
	ErrPetCantUseItem        = 0x187a // COSPETERR_CANT_USEITEM
	ErrHGPFull               = 0x18b3 // COSPETERR_HGPFULL_NODRINK
	ErrNotYourCOS            = 0x1871
	ErrExtensionNotAbility   = 0x18b8
	ErrCharDead              = 0x1889 // SKILL_USE_FAIL_CHAR_DEAD
	ErrPetUnsummonInBattle   = 0x440d // COSPETERR_CANT_PETRE_BATTLE
	ErrPetUnsummonDead       = 0x4411 // COSPETERR_CANT_DEACTIVATE_IN_DEADSTATE
	ErrPetNameNotAllowed     = 0x440e // COSPETERR_PETNAME_NOTPUT
	ErrPetNameTaken          = 0x440f // COSPETERR_PETNAME_SUMENESS
	ErrRecallTooFar          = 0x1897 // no client name (OPEN): the out pet is past RecallRange
	ErrRecallRidden          = 0x1896 // no client name (OPEN): the item's COS is being ridden
	ErrRideGeneric           = 5
	ErrRideNotFound          = 7
	ErrRideAlready           = 5
	ErrRideNotRideable       = 8
	ErrRideTooFar            = 4
	ErrRideInBattle          = 0xb
	ErrRideNothingRidden     = 3
	ErrCOSCommandNoSuchCOS   = 3
	ErrCOSCommandTooFar      = 4
	ErrCOSTerminateNotFound  = 5
	ErrCOSUnsummonItemAbsent = 2
)
