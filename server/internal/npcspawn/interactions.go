package npcspawn

import (
	"sort"
	"strings"
)

// The interaction ids an NPC's spawn record lists, as CGObjNPCNPC::Create
// (0x4c6350) assigns them. READ, with three parts labelled below.
//
// Create matches the NPC's code name against fixed lists with the CRT's
// strstr (FUN_009dddc0: a substring test, not an equality) and calls
// AddAvailableInteraction (slot 89, CGObjNPC 0x4c3f50) for each id of a
// matching rule; that call sets flag bit 1. The ids land in a std::set<u8> at
// +0x130 (CGObj::AddAvailableInteraction 0x484e40 inserts through
// FUN_00486fe0 after slot 0x390's "already there" test), which the record
// writes in set order -- ascending -- with its size as the count. READ (the
// order confirmed in round 708's review): 0x4c3cb0 starts at the header's
// _Left (the leftmost, smallest node), reads each value at node+0xc and steps
// with the in-order successor FUN_004885c0 -- MSVC's std::set iteration.
//
// Before the rules, Create copies the reference object's own list at
// ref+0x90 into the set WITHOUT setting bit 1 (0x4c641a..0x4c647a): the list
// RefTeleport_ExtractData (0x6a7be0) fills with 7 and 9 from the associated
// teleport row's two flags. So a teleport NPC matching no rule sends flags 0
// and no list.

type rule struct {
	needles []string
	ids     []byte
}

var interactionRules = []rule{
	{[]string{"WAREHOUSE", "warehouse", "NPC_SD_M_AREA_WAREHOUSE", "NPC_SD_T_AREA_WAREHOUSE2"}, []byte{3, 1}},
	{[]string{"NPC_CH_SMITH", "NPC_CH_ARMOR", "NPC_WC_SMITH", "NPC_WC_ARMOR", "NPC_KT_SMITH", "NPC_KT_ARMOR",
		"NPC_EU_SMITH", "NPC_EU_ARMOR", "NPC_CA_SMITH", "NPC_CA_ARMOR", "NPC_SD_M_AREA_SMITH", "NPC_SD_M_AREA_ARMOR",
		"NPC_SD_T_AREA_SMITH", "NPC_SD_T_AREA_ARMOR"}, []byte{4}},
	{[]string{"NPC_CH_SMITH", "NPC_WC_SMITH", "NPC_KT_SMITH", "NPC_EU_SMITH", "NPC_CA_SMITH", "NPC_SD_M_AREA_SMITH",
		"NPC_SD_T_AREA_SMITH"}, []byte{0x20}},
	{[]string{"NPC_CH_HORSE", "NPC_WC_HORSE", "NPC_KT_HORSE", "NPC_EU_HORSE", "NPC_CA_HORSE", "NPC_SD_M_AREA_HORSE"}, []byte{1, 0x0b}},
	{[]string{"NPC_CH_GENARAL_SP", "NPC_WC_GUILD", "NPC_KT_GUILD", "NPC_EU_GUILD", "NPC_CA_GUILD", "NPC_SD_M_AREA_GUILD",
		"NPC_SD_T_AREA_GUILD2"}, []byte{0x0f, 1}},
	{[]string{"NPC_CH_SOLDIER_EM1", "NPC_EU_ADVICE3"}, []byte{0x1e}},
	{[]string{"NPC_TD_THIEF_BUY"}, []byte{0x0c, 0x0d}},
	{[]string{"NPC_CH_GENARAL_SW", "NPC_WC_GENARAL_SW", "NPC_KT_MINISTER"}, []byte{0x0e}},
	{[]string{"NPC_CH_DOCTOR", "NPC_WC_DOCTOR", "NPC_KT_DESIGNER", "NPC_EU_MERCHANT", "NPC_CA_MERCHANT",
		"NPC_SD_M_AREA_MERCHANT"}, []byte{0x14}},
	{[]string{"NPC_CH_GENARAL_SW", "NPC_WC_GENARAL_SW", "NPC_KT_MINISTER", "NPC_EU_HUNTER", "NPC_CA_HUNTER",
		"NPC_SD_M_AREA_HUNTER"}, []byte{0x16}},
	{[]string{"NPC_TD_THIEF_SELL", "NPC_SD_T_AREA_THIEF"}, []byte{0x15}},
	// NPC_SD_THIEF_AGENT_CHANGER / NPC_SD_GUILD_AGENT* set a state (slot
	// 0x318) under a world-config byte, no interaction.
	{[]string{"NPC_CH_SPECIAL2", "NPC_WC_SPECIAL2", "NPC_TK_SPECIAL", "NPC_RM_SPECIAL", "NPC_EU_SPECIAL", "NPC_CA_SPECIAL",
		"NPC_SD_M_AREA_SPECIAL", "NPC_SD_M_AREA_SPECIAL2", "NPC_SD_M_AREA_SPECIAL3"}, []byte{0x0c}},
	{[]string{"NPC_CH_FORTRESS_OFFICIAL", "NPC_WC_FORTRESS_OFFICIAL", "NPC_KT_FORTRESS_OFFICIAL", "NPC_EU_FORTRESS_OFFICIAL",
		"NPC_CA_FORTRESS_OFFICIAL"}, []byte{0x18, 1}},
	{[]string{"NPC_CH_FORTRESS_MANAGER1", "NPC_CH_FORTRESS_MANAGER2", "NPC_WC_FORTRESS_MANAGER1", "NPC_WC_FORTRESS_MANAGER2",
		"NPC_KT_FORTRESS_MANAGER", "NPC_EU_FORTRESS_MANAGER", "NPC_CA_FORTRESS_MANAGER1", "NPC_CA_FORTRESS_MANAGER2"}, []byte{0x17}},
	{[]string{"NPC_CH_FORTRESS_BATTLEAIDE1", "NPC_CH_FORTRESS_BATTLEAIDE2", "NPC_WC_FORTRESS_BATTLEAIDE1",
		"NPC_WC_FORTRESS_BATTLEAIDE2", "NPC_KT_FORTRESS_BATTLEAIDE", "NPC_EU_FORTRESS_BATTLEAIDE",
		"NPC_CA_FORTRESS_BATTLEAIDE1", "NPC_CA_FORTRESS_BATTLEAIDE2"}, []byte{0x19, 1}},
	{[]string{"NPC_CH_FORTRESS_SMITH1", "NPC_CH_FORTRESS_SMITH2", "NPC_WC_FORTRESS_SMITH1", "NPC_WC_FORTRESS_SMITH2",
		"NPC_KT_FORTRESS_SMITH", "NPC_EU_FORTRESS_SMITH", "NPC_CA_FORTRESS_SMITH1", "NPC_CA_FORTRESS_SMITH2"}, []byte{0x1a, 4}},
	{[]string{"NPC_CH_FORTRESS_TRAINER1", "NPC_CH_FORTRESS_TRAINER2", "NPC_WC_FORTRESS_TRAINER1", "NPC_WC_FORTRESS_TRAINER2",
		"NPC_KT_FORTRESS_TRAINER", "NPC_EU_FORTRESS_TRAINER", "NPC_CA_FORTRESS_TRAINER1", "NPC_CA_FORTRESS_TRAINER2"}, []byte{0x1b}},
	{[]string{"STRUCTURE_GATE_PULLEY_JA_01", "STRUCTURE_GATE_PULLEY_JA_02", "STRUCTURE_GATE_PULLEY_JA_03",
		"STRUCTURE_GATE_PULLEY_BJ_01", "STRUCTURE_GATE_PULLEY_BJ_02", "STRUCTURE_GATE_PULLEY_HT_01",
		"STRUCTURE_GATE_PULLEY_HT_02", "STRUCTURE_GATE_PULLEY_HT_03"}, []byte{0x1f}},
	{[]string{"NPC_OPEN_MARKET_JUEL"}, []byte{0x23}},
	{[]string{"NPC_FWORLD_RECALL_PARTY"}, []byte{0x27}},
	{[]string{"NPC_INS_EXIT_TELEPORT"}, []byte{0x29}},
}

// InteractionInputs is what the rules need besides the code name.
type InteractionInputs struct {
	// Teleport7/Teleport9 are the associated teleport row's two flags
	// (teleportdata Interaction7/Interaction9), when the NPC is a row's
	// AssocRefObj.
	Teleport7, Teleport9 bool
	// Teleport8 (round 727) is id 8, "Select teleport area": the teleport
	// row's link registrar (0x6a7f70, round 642) puts 8 in the source
	// point's ref list when the row's last byte is 1. That byte has no
	// column in the client's teleportdata.txt, so "the point has outgoing
	// links" STANDS IN for it (INFERRED; the client's round-642 gate lines
	// use the same stand-in). Like 7 and 9 it is copied from the ref list,
	// without flag bit 1.
	Teleport8 bool
	// OwnsShop (round 727) is id 1, the store. READ: the NPC's init at
	// 0x4c7920 looks its ref id up in the reference manager's shop map
	// (0x4ccaa0), and when it finds one builds the NPC's store object
	// (0x411bc0, kept at +0x1d1c) and calls AddAvailableInteraction(1)
	// (0x4c7996), then 0xc when the store passes 0x867850 (not modelled).
	// That the map is refshopgroup's AssocNPC -> group is INFERRED from it
	// building the store (RefShopGroup_ExtractData 0x6a9fb0 stores the
	// group's NPC id, "can't find assoc NPC with this shop").
	//
	// Until round 727 this field was HasShop and added 0x11. Id 0x11 is
	// registered from a different map (FUN_004ccb70 on refmgr+0x110, while
	// the world-config byte +0x42404 is 0; round 523 found the gacha NPC map
	// a candidate, not a finding), so a shop NPC is NOT given 0x11 any more.
	// The client turns 0x11 into its gacha/open-market line, which the
	// herbalist does not show.
	OwnsShop bool
}

// Interactions is the flag byte and the interaction list of code's spawn
// record.
func Interactions(code string, in InteractionInputs) (flags byte, ids []byte) {
	set := map[byte]bool{}
	if in.Teleport7 {
		set[7] = true
	}
	if in.Teleport9 {
		set[9] = true
	}
	if in.Teleport8 {
		set[8] = true
	}
	add := func(v ...byte) {
		flags |= FlagInteractions
		for _, b := range v {
			set[b] = true
		}
	}
	for _, r := range interactionRules {
		for _, n := range r.needles {
			if strings.Contains(code, n) {
				add(r.ids...)
				break
			}
		}
	}
	// The arena pair: MANAGER is tested first, EXCHANGER only when it fails.
	switch {
	case strings.Contains(code, "NPC_BATTLE_ARENA_MANAGER"):
		add(0x21)
	case strings.Contains(code, "NPC_BATTLE_ARENA_EXCHANGER"):
		add(0x22)
	}
	// CompareStringA(.., NORM_IGNORECASE ..) == 2: an equality, not strstr.
	if strings.EqualFold(code, "NPC_SIEGE_DUNGEON_TELEPORT") {
		add(0x28)
	}
	// The shop init (0x4c7920) and the quests (questtalk.go) run after Create
	// in the original; the set is ordered on the wire, so the order of these
	// adds does not show.
	if in.OwnsShop {
		add(1)
	}
	if QuestTalk(code) {
		add(2)
	}
	if strings.Contains(code, "NPC_CH_GACHA_OPERATOR") {
		add(0x12)
	}
	if flags&FlagInteractions == 0 {
		return 0, nil
	}
	for b := range set {
		ids = append(ids, b)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	return flags, ids
}
