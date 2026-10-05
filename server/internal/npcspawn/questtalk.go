package npcspawn

// The NPCs the original server gives interaction id 2, "Talk to this person."
// (round 727). Not one rule in CGObjNPCNPC::Create (0x4c6350) pushes id 2
// (round 725's census of its [vtable+0x164] calls). The QUEST classes push
// it, through the same slot, AddAvailableInteraction, onto the NPC objects
// they name -- READ in srgs.asm, round 727:
//
//   - The generic path every CBasicQuest takes, FUN_00926ed0 / FUN_00927040
//     (quest vtable slots 72-74, hundreds of RTTI owners): when the quest's
//     mission-NPC block (quest+0x310, param_1[0xc4]) has bit 0 set, it walks
//     the block's count (+4) of codename pointers (+8, +0xc, ...), finds each
//     NPC object by codename (DAT_00c8277c slot 0x1c) and calls its
//     [vtable+0x164] with 2 (0x926f8e, 0x9270fe). Each quest's setup
//     (vslot_055) fills the block with string literals, e.g.
//     CQTUTORIAL2_CH_1::vslot_055: *(+4) = 2, *(+8) = "NPC_CH_GENARAL",
//     *(+0xc) = "NPC_CH_SOLDIER_SO1", and sets bit 0.
//   - Three hand-written classes push it directly:
//       * CQSP_ALL_POTION_3::vslot_017 (0x88ea5b; NPC_CH/WC/KT/EU/CA_POTION);
//       * CQNO_WC_PRIEST3_1::vslot_017 (0x898557; NPC_WC_PRIEST3);
//       * CQNO_WC_SOLDIER_SO_1 (0x89a36b). Its function names NPC_WC_SOLDIER_SO,
//         NPC_CH_ISLAM and NPC_KT_HORSE; that the push covers all three is
//         INFERRED from the loop it sits in.
//   - The event classes (CEventAType, GObjPC::FUN_0092f740) and FUN_00931f30
//     push it too, on NPCs looked up from data this project has not read.
//     They are not listed.
//
// The census is every `*(param_1[0xc4] + n) = "NPC_..."` store in the server
// decompile (184 setup functions, 86 codenames), plus the direct pushes'
// literals. A quest registers when it is set up. That every listed quest is
// set up (in service) in the original's _REFQUEST is INFERRED: OpenSRO loads
// no quest table, so it lists them all.
//
// The id goes into the NPC's own set (+0x130) through AddAvailableInteraction,
// which sets flag bit 1 (FlagInteractions). It therefore reaches both the
// spawn record and the 0xB045 select reply (PublishAvailableInteractions copies
// +0x130), for every player alike. The lookup is by exact codename
// (DAT_00c8277c slot 0x1c), not strstr.
var questTalkNPCs = map[string]bool{
	"NPC_AM_SPECIAL":        true,
	"NPC_CA_ACCESSORY":      true,
	"NPC_CA_ARMOR":          true,
	"NPC_CA_HORSE":          true,
	"NPC_CA_HUNTER":         true,
	"NPC_CA_MERCHANT":       true,
	"NPC_CA_POTION":         true,
	"NPC_CA_SMITH":          true,
	"NPC_CA_SOLDIER_EA1":    true,
	"NPC_CA_SPECIAL":        true,
	"NPC_CA_WAREHOUSE":      true,
	"NPC_CH_ACCESSORY":      true,
	"NPC_CH_BEGGARBOY":      true,
	"NPC_CH_BIGMAN":         true,
	"NPC_CH_DOCTOR":         true,
	"NPC_CH_EUROPE":         true,
	"NPC_CH_FERRY":          true,
	"NPC_CH_FERRY2":         true,
	"NPC_CH_GENARAL":        true,
	"NPC_CH_GENARAL_SP":     true,
	"NPC_CH_GENARAL_SW":     true,
	"NPC_CH_HORSE":          true,
	"NPC_CH_INDIA":          true,
	"NPC_CH_ISLAM":          true,
	"NPC_CH_KISAENG1":       true,
	"NPC_CH_KISAENG2":       true,
	"NPC_CH_KISAENG3":       true,
	"NPC_CH_KISAENG4":       true,
	"NPC_CH_KISAENG5":       true,
	"NPC_CH_KISAENG6":       true,
	"NPC_CH_LOTTERY":        true,
	"NPC_CH_MOONSHADOW":     true,
	"NPC_CH_POTION":         true,
	"NPC_CH_PRIEST":         true,
	"NPC_CH_QT_FLAMEMASTER": true,
	"NPC_CH_SHAMAN":         true,
	"NPC_CH_SINMU":          true,
	"NPC_CH_SOLDIER_SO1":    true,
	"NPC_CH_SPECIAL2":       true,
	"NPC_EU_ACCESSORY":      true,
	"NPC_EU_ADVENTURER":     true,
	"NPC_EU_ADVICE":         true,
	"NPC_EU_ADVICE2":        true,
	"NPC_EU_ADVICE3":        true,
	"NPC_EU_FERRY2":         true,
	"NPC_EU_GENERAL":        true,
	"NPC_EU_HUNTER":         true,
	"NPC_EU_MERCHANT":       true,
	"NPC_EU_POTION":         true,
	"NPC_EU_PRIEST":         true,
	"NPC_EU_SMITH":          true,
	"NPC_EU_SPECIAL":        true,
	"NPC_EU_UNION1":         true,
	"NPC_EU_UNION2":         true,
	"NPC_EU_WITCH":          true,
	"NPC_KT_ACCESSORY":      true,
	"NPC_KT_ARMOR":          true,
	"NPC_KT_HORSE":          true,
	"NPC_KT_MANAGER":        true,
	"NPC_KT_MINISTER":       true,
	"NPC_KT_POTION":         true,
	"NPC_KT_SMITH":          true,
	"NPC_KT_SPECIAL":        true,
	"NPC_RM_FLYSHIP1":       true,
	"NPC_RM_FLYSHIP2":       true,
	"NPC_RM_OLDWOMAN":       true,
	"NPC_RM_SLAVE1":         true,
	"NPC_RM_SLAVE2":         true,
	"NPC_RM_SLAVE3":         true,
	"NPC_RM_SPECIAL":        true,
	"NPC_RM_VILLAGECHIEF":   true,
	"NPC_RM_YOUNGWOMAN1":    true,
	"NPC_RM_YOUNGWOMAN2":    true,
	"NPC_TK_SPECIAL":        true,
	"NPC_WC_ACCESSORY":      true,
	"NPC_WC_ARMOR":          true,
	"NPC_WC_FERRY3":         true,
	"NPC_WC_GENARAL_SW":     true,
	"NPC_WC_HORSE":          true,
	"NPC_WC_POTION":         true,
	"NPC_WC_PRIEST1":        true,
	"NPC_WC_PRIEST3":        true,
	"NPC_WC_SMITH":          true,
	"NPC_WC_SOLDIER_EA2":    true,
	"NPC_WC_SOLDIER_SO":     true,
	"NPC_WC_SPECIAL":        true,
	"NPC_WC_SPECIAL2":       true,
	"NPC_WC_WAREHOUSE_M":    true,
	"NPC_WC_WAREHOUSE_W":    true,
}

// QuestTalk reports whether code is an NPC some quest registers id 2 on.
func QuestTalk(code string) bool { return questTalkNPCs[code] }
