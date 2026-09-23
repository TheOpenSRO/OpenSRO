extends RefCounted
class_name NpcServiceReader

## Reads, from the player's own Media.pk2, what services an NPC offers and its
## greeting -- so the talk window lists the real options, not a placeholder.
## All grounded in the client's own textdata; nothing invented.
##
## refshopgroup.txt (tab, 0-indexed): [3]=shop group code (GROUP_STORE_CH_SMITH),
##   [4]=the NPC codename that runs it (NPC_CH_SMITH). An NPC that appears here
##   sells a shop -> the "Buy" service.
## npcchat.txt (tab): [1]=NPC codename, [2]/[3]=greeting string ids (SN_*),
##   resolved through the UI text table.
## Storage / guild / stable / special are named by the NPC's own codename
## (NPC_*_WAREHOUSE, _GUILD, _HORSE, _SPECIAL) -- the game's own self-describing
## codes, not a guess.

const SHOP_TABLE := "server_dep\\silkroad\\textdata\\refshopgroup.txt"
const CHAT_TABLE := "server_dep\\silkroad\\textdata\\npcchat.txt"

const SHOP_NPC_COL := 4
const CHAT_CODE_COL := 1
const CHAT_MSG1_COL := 2
const CHAT_MSG2_COL := 3

## The client's own talk-menu string ids (round 513). The real client builds
## each numbered talk line in FUN_006fcd60: `_swprintf_s(L"%d. ")` (the format
## at .rdata 0xdace24, pushed at 0x6fcdd5), then the text of one UIIT token
## chosen by a switch on the item id.
##
## Item 3 -- case 3 pushes .rdata 0xdadcd8, this string. FUN_00700440 emits
## item 3 for an NPC whose interaction set holds id 3: it looks id 3 up at
## 0x700b48 (`mov byte [esp+0x1c],3`), tests membership at 0x700b60-0x700b71,
## then calls 0x700b73-0x700b7a `push 0; push 3; push ebx; call 0x6fcd60`. The
## server registers id 3 on WAREHOUSE codenames (docs/protocol/
## character_state.md, the interaction-id vocabulary, round 455).
const STOREHOUSE_STRID := "UIIT_STT_NPC_CHATTING_WND_STOREHOUSE"
## Item 0, the end line -- case 0 pushes .rdata 0xdadd28, this string, unless
## the NPC's set holds id 0x1f (0x6fce7e), which only the siege structure
## STRUCTURE_GATE_PULLEY_* is registered with (character_state.md, round 455).
## That pulley-only case picks ..._TALKEND2 instead, so it is not carried
## here. FUN_00701540 builds the menu as FUN_00700440 and then
## FUN_007001a0(n), which emits item 0 as the last numbered line when the
## talk object's +0x7f1 flag is set (0x7001a3-0x7001b5).
const TALKEND_STRID := "UIIT_STT_NPC_CHATTING_WND_TALKEND"

## One service a talk window offers: a stable key (for wiring later), the
## label to fall back on, and -- when the client's own talk menu has a line
## for it -- that line's UIIT string id, resolved through the player's
## textuisystem.txt by the talk window. An empty strid means there is no
## grounded token and the label is shown as it is.
class Service:
	var key: String
	var label: String
	var strid: String

	func _init(k: String, l: String, s: String = "") -> void:
		key = k
		label = l
		strid = s

## Parses refshopgroup.txt into a set of NPC codenames (upper-cased) that run a
## shop.
static func parse_shop_npcs(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= SHOP_NPC_COL:
			continue
		var npc := cols[SHOP_NPC_COL].strip_edges()
		if npc.begins_with("NPC_"):
			out[npc.to_upper()] = true
	return out

## Parses npcchat.txt into NPC codename (upper) -> [msg1_strid, msg2_strid].
static func parse_greetings(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= CHAT_MSG1_COL:
			continue
		var code := cols[CHAT_CODE_COL].strip_edges()
		if not code.begins_with("NPC_"):
			continue
		var m1 := cols[CHAT_MSG1_COL].strip_edges()
		var m2 := cols[CHAT_MSG2_COL].strip_edges() if cols.size() > CHAT_MSG2_COL else ""
		out[code.to_upper()] = [m1, m2]
	return out

## The services an NPC offers, from its codename + the shop set. Which services
## an NPC has is GROUNDED (shop = refshopgroup membership; the rest are named by
## the NPC's own self-describing codename).
##
## Labels (round 513): storage carries the client's own string id,
## STOREHOUSE_STRID, which the talk window resolves through the player's
## textuisystem.txt. The talk window adds the end line from TALKEND_STRID. The
## other labels are this project's plain-English text with no strid:
##   * "Buy" -- the real client has no single shop line. Item 1 runs
##     FUN_006fb630, which formats its own "%d. " line per store, and those
##     lines are not built here. A town warehouse keeper usually gets "Buy"
##     too: the player's refshopgroup.txt lists 8 of the 9 keepers npcpos
##     spawns as running a GROUP_STORE_*_HONOR store (measured round 513,
##     dump_text_table.gd on Media.pk2), so their menu is "1. Buy",
##     "2. <storage>", "3. <end>". NPC_WC_WAREHOUSE_M is the exception: WC's
##     second HONOR row names NPC_WC_WAREHOUSE_W again, so the _M keeper runs
##     no store and its menu is "1. <storage>", "2. <end>". The
##     real client shows item 1 for a keeper (ids 1 and 3, no 0xf) only if
##     FUN_00989d20 answers nonzero (call at 0x700a71). That call is in the
##     branch for id 0xf absent and id 3 present (0x7009f5 `je 0x700a0e`
##     skips to it when 0xf is absent); with 0xf present, FUN_009870e0
##     decides instead (0x7009fc).
##   * "Guild" -- the guild's real lines (FUN_00700440 id 0x0f -> items 0x12,
##     0x14, 0x17-0x1d, 0x43) depend on the player's guild membership, which
##     this reader does not know.
## The real client also adds two more lines after the storage line for id 3,
## and neither is listed here: item 0x2d UIIT_STT_TC_OPEN, behind two tests
## (0x700b7f-0x700b9d), and item 0x2e UIIT_STT_TC_HONOR_RANKING (pushes from
## 0x700bad, call at 0x700bb4).
## See docs/protocol/character_state.md, "The client's first talk menu".
static func services_for(code: String, shop_npcs: Dictionary) -> Array:
	var out: Array = []
	var up := code.to_upper()
	# A shop (buy) -- grounded by refshopgroup membership.
	if shop_npcs.has(up):
		out.append(Service.new("shop", "Buy"))
	# The rest match the NPC's codename the way the SERVER does -- see
	# GUILD_PATTERNS below for where these patterns come from.
	if up.contains("WAREHOUSE"):
		# The server's own pattern for this one is the bare word too. Its
		# talk line is the client's item 3 (STOREHOUSE_STRID above).
		out.append(Service.new("storage", "Storage", STOREHOUSE_STRID))
	for pattern in GUILD_PATTERNS:
		if up.contains(pattern):
			out.append(Service.new("guild", "Guild"))
			break
	# Town smiths get NO Repair talk line (round 512). The server
	# registers interactions 4 and 0x20 on NPC_*_SMITH (CGObjNPCNPC::Create;
	# docs/protocol/character_state.md, the interaction-id table), and the
	# client's talk-menu builder adds nothing for id 4: FUN_00700440 looks id 4
	# up at LAB_00700b10 (0x700b12-0x700b37: `mov byte [esp+0x14],4; call
	# 0x534ef0`, then only the iterator checks) with no membership branch and
	# no item -- unlike id 3 right after it (0x700b60-0x700b71 `cmp [eax+4]`,
	# then item 3). The item switch FUN_006fcd60 (cases 0..0x43) has no repair
	# label, and the set-membership test UI_SILKMALL::FUN_00676390 is never
	# asked about id 4 at any of its 15 direct call sites.
	#
	# The client does read id 4, but not for a talk line: it decides whether
	# the store window shows its Repair and Repair All buttons. The chain is
	# cited on offers_repair below (verified round 514). So repair is the store
	# window's two buttons (hud_panels.gd, _wire_repair_buttons), reached
	# through "Buy", and id 4 is what shows them.
	#
	# Id 0x20 does add a line in the real client -- FUN_00700440 -> item 0x2f,
	# UIIT_STT_AVATAR_MAGICOPTION_ENCHANT_MAGIC_PARAM -- which this talk window
	# likewise does not offer.
	#
	# The FORTRESS smith (NPC_*_FORTRESS_SMITH*) does have a real repair line:
	# interaction 0x1a -> FUN_00700200 -> IF_NPCTalk::FUN_006fe030 case 0x36
	# adds SN_FORTRESS_SMITH_REPAIR (beside SN_FORTRESS_SMITH_PRODUCT), behind
	# a gate that is not named. srrevamp has no fortress system, so it is
	# deliberately not offered here -- a choice of this project, not a claim
	# that the real client lacks it.
	#
	# NPC_*_ARMOR gets no repair talk line either: no NPC does. Round 458's
	# "id 4 has no reader" holds for the SERVER only. The armour merchants
	# carry id 4 like the smiths (REPAIR_PATTERNS below), so their store window
	# shows the repair buttons too (offers_repair, round 514).
	return out

## Whether the store window shows Repair and Repair All for the NPC with this
## codename (round 514). True exactly when the server registers interaction
## id 4 on it, which is REPAIR_PATTERNS. HudPanels.open_shop calls this and
## hides both buttons when it is false.
##
## The client's side, read from sro_client.exe (dump + sro_client.asm):
##   * The 0xb045 NPC-select reply handler NetProcessInInterface::FUN_0088b200
##     looks id 4 up in the NPC's interaction set (talk object +0x7c0):
##     0x88b8c5 `mov byte [esp+0x1c],4`, 0x88b8ca `call 0x534ef0`, then
##     0x88b8d9 `cmp [eax+0x4],edi ; je ; mov esi,1`, so esi = has id 4.
##   * It then calls FUN_006d2840(0) and FUN_006d2840(esi) on child 0xf of the
##     interface ([0x110f80c], FUN_007994b0 = FUN_008b51f0(0xf, 1)).
##     FUN_006d2840 calls vtable +0x5c on the controls at +0x25e4 and +0x25e8:
##     with 0 when its argument is 0, with 1 when bit 0 is set. So both are
##     hidden, then shown again only for an NPC with id 4. FUN_006d2840 has no
##     other caller (0x88b8f2 and 0x88b905 are the only two).
##   * +0x25e4 and +0x25e8 are written only by CIFStoreForPackage::vslot_010,
##     from its children 0xb and 0xc (0x6d2ce3-0x6d2d03). FUN_008b51f0(id, 1)
##     adds the window's base id, the same base FUN_008b5580 adds to each
##     authored ID (0x8b5634). The player's Media.pk2 authors
##     resinfo\ifstore.txt ID 11 as GDR_STORE_BTN_REPAIR and ID 12 as
##     GDR_STORE_BTN_REPAIRALL, both CIFButton (client/tools/dump_layout.gd
##     --file=ifstore on the render box).
##   * Vtable +0x5c is slot 23, SHOW/HIDE, not enable. CIFButton's vtable
##     (0xd9e9ac, set by its constructor at 0x6564c6) holds 0x656040 there,
##     which jumps to CIFWnd's 0x652b70. That calls 0xb8f500, which writes
##     the byte at +0x61. +0x61 gates drawing: CGWndBase::vslot_013 (0xb8f213)
##     and 0xb9d853 draw only when it is set. The input path
##     CGWndBase::vslot_017 (0xb91446) needs +0x61 and also +0x62, and +0x62
##     is the separate enable byte (its setter is 0xb8f540).
##   * The block runs behind the class test at 0x88b78b,
##     FUN_00b94b90(0xef1ac4) on the selected object (the FindObjectByID
##     result, [esp+0x24] from 0x88b29c). FUN_00b94b90 is IsKindOf: it walks
##     the runtime class's +0xc base chain (0xb94b40). 0xef1ac4 is the runtime
##     class registered at 0xd764f0 with the name "CICNPC" (.rdata 0xde2a18),
##     based on CICNonuser. So the rule holds for every NPC selection and every
##     store an NPC opens, not only some store kinds.
## Matched with `contains` and case-sensitive, because the server's matcher is
## the C runtime's strstr (FUN_009dddc0).
static func offers_repair(code: String) -> bool:
	for pattern in REPAIR_PATTERNS:
		if code.contains(pattern):
			return true
	return false

## The numbered, clickable lines of the talk menu, built from services_for's
## list: one line per service, then the end line. `resolve` is the talk
## window's (token, fallback) -> text resolver (HudPanels._resolve_ui, which
## reads the player's own textuisystem.txt). It is passed in so that this
## composition can be tested without the HUD. hud_panels.gd compiles only once
## the NetClient autoload is registered, which in a --script suite is its
## _initialize, not its _init (measured, round 514).
##
## Numbering and text follow the client's own menu (round 513). FUN_006fcd60
## writes "%d. " and then the text of a UIIT token. FUN_00701540 ends the menu
## with item 0 through FUN_007001a0. A service's strid is that token where one
## is grounded (storage = STOREHOUSE_STRID). Otherwise its label is shown. The
## end line is TALKEND_STRID. The English fallbacks are used only when the
## archive has no text for the token.
##
## Each line is also printed as `NPCTALK <npc> line <n>: <n>. <text>`. A
## QA_TALK run reads those lines as the measurement. At most town warehouse
## keepers there are three: "1. Buy", "2. <storage text>" and "3. <end text>",
## because the player's refshopgroup.txt lists 8 of the 9 spawned keepers as
## running a GROUP_STORE_*_HONOR store; NPC_WC_WAREHOUSE_M is not listed and
## gets two (see "Buy" above; npc_service_reader_test.gd check (h)).
static func talk_menu_lines(npc_name: String, services: Array, resolve: Callable) -> PackedStringArray:
	var lines := PackedStringArray()
	var n := 1
	for svc in services:
		# Each service is a clickable link keyed by its stable key.
		var text := str(resolve.call(str(svc.strid), str(svc.label)))
		print("NPCTALK %s line %d: %d. %s" % [npc_name, n, n, text])
		lines.append("[url=%s]%d. %s[/url]" % [str(svc.key), n, text])
		n += 1
	var end_text := str(resolve.call(TALKEND_STRID, "End conversation."))
	print("NPCTALK %s line %d: %d. %s" % [npc_name, n, n, end_text])
	lines.append("[url=end]%d. %s[/url]" % [n, end_text])
	return lines

## The guild NPCs, as the SERVER identifies them. `CGObjNPCNPC::Create`
## (0x4c6350) registers interaction id 0x0f -- the guild service, confirmed by
## its reader `CGuildManager::HandleCreateGuild` -- on exactly these seven
## codename patterns, tested with `strstr`. Recovered round 455, verified round
## 458; see docs/protocol/character_state.md.
##
## A bare "GUILD" token, which this used to use, is wrong in BOTH directions:
##   * it misses NPC_CH_GENARAL_SP, the Chinese guild NPC, whose codename has no
##     "GUILD" in it at all -- it heads the server's own list;
##   * it wrongly matches NPC_SD_GUILD_AGENT/2/3, on which no codename test in
##     the server registers any interaction id (round 520; round 458 said 0x0c,
##     a misreading). Their strstr chain (0x4c6d6b-0x4c6ddb, which also tests
##     NPC_SD_THIEF_AGENT_CHANGER) ends at 0x4c6ddd in vtable slot 198 (+0x318,
##     IGObj::SetBodyMode; docs/protocol/igobj_vtable.md, the table), called
##     with (4, 0xff, 0, 0) only when the byte at CMainProcess (DAT_00d6a8dc)
##     +0x42404 is 1 (`cmp esi,1`; esi loaded at 0x4c6494). It never reaches
##     slot 89 (+0x164, AddAvailableInteraction). The 0x0c registration is the
##     NEXT chain, the NPC_*_SPECIAL literals (0x4c6f39). The data-driven paths
##     are covered in docs/protocol/character_state.md, "One misattribution,
##     corrected (round 520)".
const GUILD_PATTERNS := [
	"NPC_CH_GENARAL_SP",
	"NPC_WC_GUILD",
	"NPC_KT_GUILD",
	"NPC_EU_GUILD",
	"NPC_CA_GUILD",
	"NPC_SD_M_AREA_GUILD",
	"NPC_SD_T_AREA_GUILD2",
]

## The NPCs the SERVER gives interaction id 4, which offers_repair reads
## (round 514). `CGObjNPCNPC::Create` (0x4c6350) registers id 4 through
## vtable +0x164 (AddAvailableInteraction) at exactly two sites. Each is behind
## `strstr(codename, pattern)` (FUN_009dddc0) on these literals:
##   * 0x4c677f, id 4 alone: the fourteen town smiths and armour merchants,
##     pushed in this order from .rdata 0xaeeae0 to 0xaeebbc;
##   * 0x4c736f, id 4 right after id 0x1a (0x4c7361): the eight fortress
##     smiths, .rdata 0xaef11c to 0xaef1c4.
## Every slot-0x164 call in the server that pushes a literal 4 was listed, and
## there are only these two. The two other `push 4` calls in the function
## (0x4c6df7, 0x4c775c) go through slot 0x318 instead. The refdata-driven
## inserts register only ids 7, 8 and 9 (character_state.md, rounds 454-455).
## The fortress smiths are kept although srrevamp has no fortress, because
## this list is the id-4 set and not a list of the NPCs srrevamp spawns.
const REPAIR_PATTERNS := [
	"NPC_CH_SMITH",
	"NPC_CH_ARMOR",
	"NPC_WC_SMITH",
	"NPC_WC_ARMOR",
	"NPC_KT_SMITH",
	"NPC_KT_ARMOR",
	"NPC_EU_SMITH",
	"NPC_EU_ARMOR",
	"NPC_CA_SMITH",
	"NPC_CA_ARMOR",
	"NPC_SD_M_AREA_SMITH",
	"NPC_SD_M_AREA_ARMOR",
	"NPC_SD_T_AREA_SMITH",
	"NPC_SD_T_AREA_ARMOR",
	"NPC_CH_FORTRESS_SMITH1",
	"NPC_CH_FORTRESS_SMITH2",
	"NPC_WC_FORTRESS_SMITH1",
	"NPC_WC_FORTRESS_SMITH2",
	"NPC_KT_FORTRESS_SMITH",
	"NPC_EU_FORTRESS_SMITH",
	"NPC_CA_FORTRESS_SMITH1",
	"NPC_CA_FORTRESS_SMITH2",
]

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text.replace("\r", "").split("\n")
