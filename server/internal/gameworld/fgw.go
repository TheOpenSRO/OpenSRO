package gameworld

// The Forgotten World's reference data (round 869, lane W3;
// docs/protocol/forgotten_world.md 11 SERVER item 1): what a Dimension hole
// item says, the gate it makes, the 22 INS_GOD_* worlds' themes and bands, the
// pillars of world 1 and the ENVY_DROP pillars' hole drops
// (_RefMonster_AssignedItemDrop). Labels as in the spec: READ (s: the game
// server, c: the client), MEASURED, INFERRED, OURS, OPEN.

import (
	"strconv"
	"strings"
	"time"
)

// The hole items' TypeID (MEASURED: 3/3/12/7, type word 0x3E6C, c:0x666f80).
const (
	HoleTypeID1, HoleTypeID2, HoleTypeID3, HoleTypeID4 = 3, 3, 12, 7
	HoleTypeWord                                       = 0x3E6C
)

// HoleCoolGroup / HoleCoolTime are every hole's reuse cool time (MEASURED
// Param10 / Desc10: 18,000,000 ms, COOLTIME:0x00000071 -- the group shared by
// every hole, the "Reuse time 16956Second" of another grade's tooltip).
const (
	HoleCoolGroup uint32 = 0x71
	HoleCoolTime         = 18_000_000 * time.Millisecond
)

// The gate (forgotten_world.md 4).
const (
	// GateRefObjID is INS_QUEST_TELEPORT, the holes' Desc8 (MEASURED
	// _RefObjCommon 19556, TypeID 4/1/2, quest\ins_quest_teleport.bsr).
	GateRefObjID uint32 = 19556
	// GateCode is its codename.
	GateCode = "INS_QUEST_TELEPORT"
	// GateInteraction is the gate's one interaction, a teleport (MEASURED
	// 0xB045 {.., 01, 1c, ..}).
	GateInteraction byte = 0x1c
	// GateDestinationKind is the kind of the gate's one destination: {region,
	// position} (MEASURED 0xB045 {.., 01, 02, u16 region, i32 x, y, z}).
	GateDestinationKind byte = 2
	// GateRange is how far the gate may be selected from (INFERRED: the
	// NPCs' IsWithinInteractionRange radius, 300, 3-D).
	GateRange = 300.0
)

// The access types of a gate (READ s:0x4865a0; the holes' Param6).
const (
	AccessOwner uint8 = 6 // only the creator's character
	AccessParty uint8 = 7 // the creator's party; the user must be its master to make one
)

// The hole's refusals, 0xB04C {2, code} (READ GObjPC::FUN_004a08e0;
// forgotten_world.md 3), in the order they are checked.
const (
	CodeHoleNotTown     uint16 = 0x184b // outside a safe zone (the client has no text for it)
	CodeHoleLevel       uint16 = 0x1851 // UIIT_MGS_ERR_GOD_LEVEL
	CodeHolePartyMaster uint16 = 0x184f // PARTYMATCH_RECORD_ERROR_PARTYLEADER (Param6 = 7 only)
	CodeHoleNoLayer     uint16 = 0x1852 // no free layer of the world
	CodeHoleOther       uint16 = 0x183e // any other failure of the world job
	// CodeHoleCoolTime is a hole used while the group runs: the client refuses
	// it itself with no packet (MEASURED "Still have time to reuse the
	// item."); the server's refusal, should one come, is the item use's
	// WAIT_FOR_REUSE_DELAY (READ 0x185b, Item_HandleUseItem's IsReady).
	CodeHoleCoolTime uint16 = 0x185b
)

// The party recall (forgotten_world.md 8; READ s:0x51bb70, s:0x51bd60,
// s:0x51bf10; MEASURED round 869).
const (
	// RecallInteraction / ExitInteraction are the recall and exit NPCs'
	// interactions (READ 0x27, 0x29).
	RecallInteraction byte = 0x27
	ExitInteraction   byte = 0x29
	// RecallJobTimeout is the 0x7519 handler's overlapped job (0x7d1b) and
	// its 15.0 s (READ s:0xb45f08). MEASURED: the list came back 113 ms after
	// the request, so the 15 s is the job's limit, not a wait; OpenSRO
	// answers at once.
	RecallJobTimeout = 15 * time.Second
	// SummonWait is how long a summon stays open: the master's slot waits
	// 20,000 ms and the member's confirm box closes itself after 20,000 ms
	// (READ c:0x823350, c:0x608a60); INFERRED that the server's request lives
	// as long.
	SummonWait = 20 * time.Second
	// SummonDelay is the accepted member's wait before the warp (MEASURED:
	// the member's 0x751A carries u32 5 and the warp came 5.4 s after its
	// Yes; INFERRED that the 5 is these seconds).
	SummonDelay = 5 * time.Second
)

// The recall list's member states (READ c:0x89a590: 1 "Completed", 2
// "Possible", 3 "Impossible"; MEASURED 2 for a member in Jangan).
const (
	RecallInside     uint8 = 1
	RecallPossible   uint8 = 2
	RecallImpossible uint8 = 3
)

// The recall's refusals (READ s:0x51bb70 / s:0x51bd60; the summon's
// category-0x23 texts, forgotten_world.md 8).
const (
	CodeNotParty     uint16 = 0x1c33 // UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_PARTY
	CodeNotMaster    uint16 = 0x1c34 // PARTYMATCH_RECORD_ERROR_PARTYLEADER
	CodeOtherWorld   uint16 = 0x1c35 // UIIT_MGS_ERR_GOD_INS_WORLD
	CodeBusy         uint16 = 0x1c0b // INTERACTION_FAIL_IM_BUSY
	CodeNotTown      uint16 = 0x1c37 // UIIT_MGS_ERR_GOD_TELEPORT_HOLE_NOT_TOWN
	CodeGuildWar     uint16 = 0x1c39 // UIIT_MGS_ERR_GOD_GUILD
	CodeSummonWait   uint16 = 0x1c3a // PARTY_SUMMON_WAIT_ERR
	CodeRecallPlain  uint16 = 2
	CodeRecallTarget uint16 = 3
)

// Hole is what a Dimension hole item says (MEASURED _RefObjItem params,
// forgotten_world.md 2).
type Hole struct {
	RefID uint32
	Code  string
	// World is Desc2, the world's codename (INS_GOD_...).
	World string
	// Grade is Param1, the stars.
	Grade int
	// LevelMin / LevelMax are Param3 / Param4, checked at the use (0x1851).
	// MEASURED: equal to the world's ENTER_LIMIT band on every row (the Wreck
	// 100_110 holes say 101).
	LevelMin, LevelMax int
	// MaxPlayers is Param5 (INFERRED; "Number of Players Allowed: 1-4").
	MaxPlayers int
	// Access is Param6: 6 or 7 (READ s:0x4865a0). Every measured row is 6.
	Access uint8
	// CoolGroup / CoolTime are the item's reuse cool time.
	CoolGroup uint32
	CoolTime  time.Duration
}

// HoleItem is the item fields a Hole is read from: the item table's TypeIDs,
// code, Desc2, Param1, Param3..Param6 and its COOLTIME descriptor.
type HoleItem struct {
	ID                                 int64
	TypeID1, TypeID2, TypeID3, TypeID4 int
	Code, Desc2                        string
	Param1, Param3, Param4             int
	Param5, Param6                     uint32
	CoolGroup                          uint32
	CoolMs                             int
}

// IsHoleType reports the hole's TypeID 3/3/12/7.
func IsHoleType(t1, t2, t3, t4 int) bool {
	return t1 == HoleTypeID1 && t2 == HoleTypeID2 && t3 == HoleTypeID3 && t4 == HoleTypeID4
}

// HoleOf reads a Hole from an item row; ok is false for an item that is not
// a hole or names no world.
func HoleOf(it HoleItem) (Hole, bool) {
	if !IsHoleType(it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4) {
		return Hole{}, false
	}
	world := strings.TrimSpace(it.Desc2)
	if world == "" || world == "xxx" {
		return Hole{}, false
	}
	h := Hole{RefID: uint32(it.ID), Code: it.Code, World: world, Grade: it.Param1, LevelMin: it.Param3, LevelMax: it.Param4,
		MaxPlayers: int(it.Param5), Access: uint8(it.Param6), CoolGroup: it.CoolGroup,
		CoolTime: time.Duration(it.CoolMs) * time.Millisecond}
	if h.Access != AccessParty {
		// Anything but 7 admits the owner only (READ s:0x4865a0's two cases;
		// every measured row is 6).
		h.Access = AccessOwner
	}
	return h, true
}

// Theme is a Forgotten World theme (UIIT_STT_GOD_*).
type Theme string

const (
	ThemeTogui    Theme = "TOGUI"
	ThemeFlame    Theme = "FLAME"
	ThemeWreckIn  Theme = "WRECK_IN"
	ThemeWreckOut Theme = "WRECK_OUT"
)

// GodWorld is an INS_GOD_<theme>_<lo>_<hi>_LEVEL_<grade> codename read.
type GodWorld struct {
	Theme  Theme
	Lo, Hi int
	Grade  int
}

// ParseGodWorld reads a Forgotten World codename (MEASURED form,
// forgotten_world.md 1).
func ParseGodWorld(code string) (GodWorld, bool) {
	rest, ok := strings.CutPrefix(strings.ToUpper(strings.TrimSpace(code)), "INS_GOD_")
	if !ok {
		return GodWorld{}, false
	}
	var th Theme
	for _, t := range []Theme{ThemeWreckOut, ThemeWreckIn, ThemeTogui, ThemeFlame} {
		if p, ok := strings.CutPrefix(rest, string(t)+"_"); ok {
			th, rest = t, p
			break
		}
	}
	if th == "" {
		return GodWorld{}, false
	}
	f := strings.Split(rest, "_")
	if len(f) != 4 || f[2] != "LEVEL" {
		return GodWorld{}, false
	}
	lo, e1 := strconv.Atoi(f[0])
	hi, e2 := strconv.Atoi(f[1])
	g, e3 := strconv.Atoi(f[3])
	if e1 != nil || e2 != nil || e3 != nil {
		return GodWorld{}, false
	}
	return GodWorld{Theme: th, Lo: lo, Hi: hi, Grade: g}, true
}

// IsGodWorld reports a Forgotten World (an INS_GOD_* world).
func (w *WorldRef) IsGodWorld() bool {
	if w == nil {
		return false
	}
	_, ok := ParseGodWorld(w.Code)
	return ok
}

// The pillars (forgotten_world.md 2).
const (
	// PillarPrefix is the pillars the world-1 triggers load
	// (MOB_GOD_PILLAR_<theme>_<band>); EnvyDropPrefix the ones whose
	// assigned drops are the holes; EnvyPrefix the rarity-1 ones with none.
	PillarPrefix   = "MOB_GOD_PILLAR_"
	EnvyDropPrefix = "MOB_GOD_PILLAR_ENVY_DROP_"
	EnvyPrefix     = "MOB_GOD_PILLAR_ENVY_"
)

// IsPillar reports a dimension pillar's codename (not an Envy of one).
func IsPillar(code string) bool {
	return strings.HasPrefix(code, PillarPrefix) && !strings.HasPrefix(code, EnvyPrefix)
}

// AssignedDrop is one _RefMonster_AssignedItemDrop row: an item a monster
// drops by itself (READ s:0x724a00, CRefDropData::AddAssignedItemDrop: the
// record's +0 item, +6 / +7 the attempts' ends, +8 the float ratio).
type AssignedDrop struct {
	Monster   int64
	Item      int64
	AmountMin int
	AmountMax int
	Ratio     float64
}

// TableAssignedDrop is the assigned drops' table.
const TableAssignedDrop = "_RefMonster_AssignedItemDrop"

// fgwDropScope is which monsters' assigned drops the Forgotten World data
// carries (OURS scope: the table's 190 other rows belong to monsters outside
// this lane and stay unserved, OPEN).
const fgwDropScope = "MOB_GOD_"

// InFGWDropScope reports whether a monster's assigned drops are served from
// the game-world data.
func InFGWDropScope(code string) bool { return strings.HasPrefix(code, fgwDropScope) }
