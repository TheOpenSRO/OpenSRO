extends RefCounted
class_name NpcServiceReader

## The talk menu's lines and an NPC's greeting. Since round 727 the lines come
## from the NPC's interaction-id set, which the server sends in the 0xB045
## select reply (services_from_ids, the client's own FUN_00700440 order); the
## greeting from the player's own Media.pk2.
##
## refshopgroup.txt (tab, 0-indexed): [3]=shop group code (GROUP_STORE_CH_SMITH),
##   [4]=the NPC codename that runs it (NPC_CH_SMITH). Id 1 (the store) is
##   now the server's (round 727, the NPC's own shop); the parse stays for
##   its tests and tools.
## npcchat.txt (tab): [1]=NPC codename, [2]/[3]=greeting string ids (SN_*),
##   resolved through the UI text table.

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
## A store line's key (round 725): this prefix and its tab group's code.
const SHOP_KEY_PREFIX := "shop:"

## Whether a talk-line key opens a store: one tab group's line, or the "Buy"
## stand-in.
static func is_shop_key(key: String) -> bool:
	return key == "shop" or key.begins_with(SHOP_KEY_PREFIX)

## The tab group a store line's key names; "" for the "Buy" stand-in.
static func tabgroup_of(key: String) -> String:
	return key.substr(SHOP_KEY_PREFIX.length()) if key.begins_with(SHOP_KEY_PREFIX) else ""
## The guild NPC's two lines OpenSRO offers (round 521). FUN_00700440's id
## 0x0f block (lookup `mov byte [esp+0x1c],0xf` at 0x70105e) emits item 0x12
## when FUN_009870e0 answers 0 (0x701096 `call 0x9870e0`, 0x70109d
## `je 0x701165`, then 0x701165-0x70116c `push 0; push 0x12; push ebx;
## call 0x6fcd60`), and item 0x1c when FUN_00989ce0 answers 0 (0x7010c4
## `call 0x989ce0`, 0x7010f6 `cmp byte [esp+0x14],0`, 0x7010ff `je 0x70112a`,
## 0x70112a `push 0x1c`). In FUN_006fcd60, item 0x12 takes index byte 0x0e
## (0x6fd394 + 0x12), whose jump-table entry (0x6fd310) is 0x6fd076
## `push 0xdad440`, and .rdata 0xdad440 is this string. Read with objdump -s
## from the render box's sro_client.exe.
const GUILD_CREATE_STRID := "UIIT_CTL_GUILD_CREATE"
## Item 0x1c takes index byte 0x17 (0x6fd394 + 0x1c), whose jump-table entry
## (0x6fd334) is 0x6fd0bc `push 0xdad2ec`, and .rdata 0xdad2ec is this string.
const GUILD_SECESSION_STRID := "UIIT_CTL_GUILD_SECESSION"

## The job guilds' join lines (round 526), by job kind: 1 Trader, 2 Thief
## ("Robber"), 3 Hunter (docs/protocol/jobs.md, "Three job kinds"). The real
## client writes the line as item 0x1e of FUN_006fcd60, whose third argument
## (`sub`, the byte at [esp+0x264], 0x6fce2c) picks the token: item 0x1e takes
## index byte 0x19 (0x6fd394 + 0x1e), whose jump-table entry (0x6fd33c) is
## 0x6fcf42, `cmp al,1` -> `push 0xdadad8`, `cmp al,2` -> `push 0xdada88`,
## `cmp al,3` -> `push 0xdada38`. objdump -s on the render box's
## /opt/sro-files/client/sro_client.exe reads those three .rdata strings as
## these tokens.
const JOB_JOIN_STRIDS := {
	1: "UIIT_STT_NPC_CHATTING_TRADERMENU_JOIN",
	2: "UIIT_STT_NPC_CHATTING_THIEFMENU_JOIN",
	3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_JOIN",
}
## The fallback labels are the player's own textuisystem.txt text for the
## three tokens, from the later 19-column rows ([9]), which UiTextTable keeps
## (/var/tmp/tables/textuisystem.txt on the render box). The earlier 16-column
## rows say "Join the Trader Job!" and so on; the talk window shows whichever
## the archive resolves, and these only when it has no text.
const JOB_FALLBACK_LABELS := {
	1: "Join merchant guild",
	2: "Join thief guild",
	3: "Join hunter guild",
}
## The order FUN_00700440 asks for the three ids, and the kind it passes each:
## id 0x14 (lookup 0x70120e) -> 0x701237 `push 1`, `call 0x6fdeb0`; id 0x16
## (0x701252) -> 0x70127b `push 3`; id 0x15 (0x701296) -> 0x7012bf `push 2`.
const JOB_KIND_ORDER := [1, 3, 2]

## One service a talk window offers: a stable key (for wiring later), the
## label to fall back on, and -- when the client's own talk menu has a line
## for it -- that line's UIIT string id, resolved through the player's
## textuisystem.txt by the talk window. An empty strid means there is no
## grounded token and the label is shown as it is. `job_kind` is the job
## guild a "job_*" line belongs to (1 Trader, 2 Thief, 3 Hunter), 0 otherwise.
class Service:
	var key: String
	var label: String
	var strid: String
	var job_kind: int = 0

	func _init(k: String, l: String, s: String = "", jk: int = 0) -> void:
		key = k
		label = l
		strid = s
		job_kind = jk

## Parses refshopgroup.txt into a set of NPC codenames (upper-cased) that run a
## shop.
static func parse_shop_npcs(data: PackedByteArray) -> Dictionary:
	var _pp := ParseProfile.t0()
	var _out: Dictionary = _pp_parse_shop_npcs(data)
	ParseProfile.add("text.shop_npcs", _pp)
	return _out

## The body of parse_shop_npcs, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse_shop_npcs(data: PackedByteArray) -> Dictionary:
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
	var _pp := ParseProfile.t0()
	var _out: Dictionary = _pp_parse_greetings(data)
	ParseProfile.add("text.greetings", _pp)
	return _out

## The body of parse_greetings, timed by its wrapper above (ParseProfile, round 667).
static func _pp_parse_greetings(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= CHAT_MSG1_COL:
			continue
		var code := cols[CHAT_CODE_COL].strip_edges()
		# Every owner, not only NPC_ codes (round 725): the gates' rows
		# (STORE_CH_GATE -> STORE_CH_GATE_BS) carry the greeting the original
		# talk box shows for a Dimensional Gate (the user's 1llywhJ/hWWsCP0).
		if code == "":
			continue
		var m1 := cols[CHAT_MSG1_COL].strip_edges()
		var m2 := cols[CHAT_MSG2_COL].strip_edges() if cols.size() > CHAT_MSG2_COL else ""
		out[code.to_upper()] = [m1, m2]
	return out

## The talk menu's lines for an NPC's interaction-id set (round 727): the
## set the server sends in the 0xB045 select reply (NpcTalkNet), walked in
## the client's own order. READ from FUN_00700440 (the builder) and
## FUN_006fcd60 (the line adder, a switch on the item with one token each);
## docs/protocol/npc_gui.md §1, "Which lines". The end line is not here:
## talk_menu_lines adds it.
##
## Until round 727 the client derived the lines from the NPC's codename and
## refshopgroup.txt (services_for, OURS). Which lines an NPC shows is server
## data in the original, and now in OpenSRO too: the server's
## npcspawn.Interactions builds each NPC's set (CGObjNPCNPC::Create's
## codename rules, shop ownership for id 1, the quest census for id 2, the
## teleport columns for 7, 9 and 8).
##
## In order, each `id -> item token`:
##   * 2 -> item 4, TALKSTART_STRID, "Talk to this person.";
##   * 1 -> item 1, the store lines (FUN_006fb630, one per tab group, worded
##     by the group's own name; `store_lines`, round 725). Gated:
##       - with 0x0f in the set, only when FUN_009870e0() is non-zero (a guild
##         NPC; read as "the player is in a guild", guild_services): a
##         `guild_id` of 0 drops the lines, -1 (not known yet) keeps them;
##       - with 3 and no 0x0f (a warehouse keeper), only when FUN_00989d20
##         answers true (0x700a71): a compare of the player's string at
##         +0x84c (0x9d6580 on [0xeef5ec]) with the string at +0x26c of the
##         object at 0xeeebd8 (FUN_00987130 is its +0x268 block, whose +0x20
##         byte the academy line below tests). If +0x84c is the character's
##         name, as guild_services infers, the keeper's store would show only
##         to one player; neither string's writer is read (OPEN), so the
##         keeper's store lines are kept, as round 513 kept them (OURS);
##     an NPC with no tab group writes no line: FUN_006fb630 walks the NPC's
##     shops and writes one per group, so none gives none (a keeper the
##     player's refshopgroup.txt does not list, NPC_WC_WAREHOUSE_M). Round
##     725's one "Buy" stand-in for that case is gone;
##   * 3 -> item 3, STOREHOUSE_STRID; then item 0x2d, UIIT_STT_TC_OPEN, when
##     the byte at +0x20 of that block is 0 and the player's level
##     (+0x868) is above 0x3b, and item 0x2e, UIIT_STT_TC_HONOR_RANKING,
##     always (0x700b73..0x700bb4). OpenSRO has no academy, so the +0x20 byte
##     is taken as 0 (OURS: the block's writer is not read);
##   * 0x20 -> item 0x2f, UIIT_STT_AVATAR_MAGICOPTION_ENCHANT_MAGIC_PARAM;
##   * 7 -> item 9 (the lookup of 5 before it only positions the iterator);
##     9 -> item 0x10; 8 -> item 10 (gate_services' three);
##   * 6 -> item 0xb, which FUN_006fcd60 writes no text for; not offered;
##   * 0x1e -> UI_ITEM::FUN_006f98d0's lines when the talk target's class
##     test FUN_00b94b90(0xef1ac4) passes. What it adds is not read (OPEN);
##     not offered;
##   * 0x0f -> the guild lines (guild_services);
##   * 0x13 -> item 0x15, UIIT_MSG_XMAS_EVENT_CHANGE;
##   * 10 -> item 0x16, UIIT_MSG_CIRCULATION_WITHDRAW_SKILL, "Withdrawing
##     Skill";
##   * 0x14, 0x16, 0x15 -> the job guilds' join lines, kinds 1, 3, 2
##     (IF_NPCTalk::FUN_006fdeb0), only for a player with no job;
##   * 0x11 -> item 0x27, SN_TALK_CH_GACHA_MACHINE_2; 0x12 -> item 0x28,
##     SN_TALK_CH_GACHA_OPERATOR_2; 0x23 -> item 0x3f,
##     SN_NPC_OPEN_MARKET_START; 0x0c -> item 0x39,
##     UIIT_PAG_SPECIAL_PRICE_CONDITION_INFO; 0x1c -> item 0x2a at a teleport
##     gate only, which has no text either (not offered); 0x27 -> item 0x3d,
##     UIIT_PAG_PARTY_SUMMON; 0x29 -> item 0x3e, UIIT_STT_DUNGEON_EXIT.
## Ids the builder never asks for (4, 0x0b, 0x0d, 0x0e, 0x17-0x19, 0x1b,
## 0x1f, 0x21, 0x22, 0x28, ...) add no line: id 4 is the store's repair
## buttons (offers_repair), 0x1f picks the end line's TALKEND2.
##
## The fallback labels are the stock textuisystem.txt English for each token
## (the 19-column rows, /var/tmp/tables/textuisystem.txt on the render box);
## the SN_ tokens live in the NPC text tables, so their fallback is the token
## and World3D resolves them (_resolve_any_text).
static func services_from_ids(ids: PackedByteArray, store_lines: Array = [], guild_id: int = -1,
		guild_master: bool = false, player_job_kind: int = 0, player_level: int = 0, job_alias_empty: bool = true) -> Array:
	var out: Array = []
	if ids.has(2):
		out.append(Service.new("talk", "Talk to this person.", TALKSTART_STRID))
	if ids.has(1) and not (ids.has(0x0f) and guild_id == 0):
		for line_v in store_lines:
			var line: Dictionary = line_v
			out.append(Service.new("%s%s" % [SHOP_KEY_PREFIX, str(line.get("tabgroup", ""))], "Buy",
				str(line.get("name_strid", ""))))
	if ids.has(3):
		out.append(Service.new("storage", "Storage", STOREHOUSE_STRID))
		if player_level > ACADEMY_OPEN_ABOVE_LEVEL:
			out.append(Service.new("academy_open", "Academy Establishment", ACADEMY_OPEN_STRID))
		out.append(Service.new("honor_rank", "Honor Rank", HONOR_RANKING_STRID))
	if ids.has(0x20):
		out.append(Service.new("avatar_magic_option", "Grant magic option on avatar item", AVATAR_MAGIC_OPTION_STRID))
	out.append_array(gate_services(ids.has(8), ids.has(7), ids.has(9)))
	if ids.has(0x0f):
		out.append_array(guild_services(guild_id, guild_master))
	if ids.has(0x13):
		out.append(Service.new("xmas_change", "Give the socks and receive a gift.", XMAS_CHANGE_STRID))
	if ids.has(10):
		out.append(Service.new("withdraw_skill", "Withdrawing Skill", WITHDRAW_SKILL_STRID))
	for pair in JOB_IDS:
		if ids.has(int(pair[0])):
			out.append_array(job_services(int(pair[1]), player_job_kind, job_alias_empty))
	for row in TAIL_LINES:
		if ids.has(int(row[0])):
			out.append(Service.new(str(row[1]), str(row[3]), str(row[2])))
	return out

## Round 799: a job guild's block, IF_NPCTalk::FUN_006fdeb0(n, sub) (READ):
## with no job the join line (0x1e); at the player's own guild (its kind ==
## sub) leave (0x1f), the alias's create (0x20, no alias) or change (0x21),
## and for a thief or hunter the week's outcome (0x24); then always the
## donation / contribution ranking (0x23), the activity ranking (0x22) and
## the previous job's information (0x26, sub 0). Each line's token is
## FUN_006fcd60's case for (item, sub), read through its jump table (index
## bytes 0x6fd394 + item, entries 0x6fd2d8): JOB_LINE_STRIDS. The keys are
## this client's: "job_<line>:<sub>", the sub also in `job_kind`.
const JOB_LINE_STRIDS := {
	"join": {1: "UIIT_STT_NPC_CHATTING_TRADERMENU_JOIN", 2: "UIIT_STT_NPC_CHATTING_THIEFMENU_JOIN",
		3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_JOIN"},
	"withdraw": {1: "UIIT_STT_NPC_CHATTING_TRADERMENU_WITHD", 2: "UIIT_STT_NPC_CHATTING_THIEFMENU_WITHD",
		3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_WITHD"},
	"alias_create": {1: "UIIT_STT_NPC_CHATTING_TRADERMENU_ALIASCREATE", 2: "UIIT_STT_NPC_CHATTING_THIEFMENU_ALIASCREATE",
		3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_ALIASCREATE"},
	"alias_modify": {1: "UIIT_STT_NPC_CHATTING_TRADERMENU_ALIASMODIFY", 2: "UIIT_STT_NPC_CHATTING_THIEFMENU_ALIASMODIFY",
		3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_ALIASMODIFY"},
	"rank_activity": {1: "UIIT_STT_NPC_CHATTING_TRADERMENU_JOBRANK", 2: "UIIT_STT_NPC_CHATTING_THIEFMENU_JOBRANK",
		3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_JOBRANK"},
	"rank_contribution": {1: "UIIT_STT_NPC_CHATTING_TRADERMENU_DONATIONRANK", 2: "UIIT_STT_NPC_CHATTING_HUNTERMENU_CONTRIBUTERANK",
		3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_CONTRIBUTERANK"},
	"outcome": {2: "UIIT_STT_NPC_CHATTING_HUNTERMENU_OUTCOME", 3: "UIIT_STT_NPC_CHATTING_HUNTERMENU_OUTCOME"},
}
## Item 0x25 (the outcome reply's collect line) and 0x26.
const JOB_COLLECT_STRID := "UIIT_STT_NPC_CHATTING_HUNTERMENU_OUTCOME"
const JOB_PREV_STRID := "UIIT_STT_NPC_CHATTING_JOBINFO_OLD"
## The stock English (textuisystem's later rows), shown only when the
## archive has no text for a token.
const JOB_LINE_FALLBACKS := {
	"join": "Join the job league", "withdraw": "Leave the job league", "alias_create": "Create your job alias.",
	"alias_modify": "Modify your job alias.", "rank_activity": "Ranking - activity",
	"rank_contribution": "Ranking - weekly contribution", "outcome": "Collect this week's outcome",
}

static func _job_line(line: String, sub: int) -> Service:
	var strid := String((JOB_LINE_STRIDS[line] as Dictionary).get(sub, ""))
	var label := String(JOB_LINE_FALLBACKS[line])
	if line == "join" and JOB_FALLBACK_LABELS.has(sub):
		label = String(JOB_FALLBACK_LABELS[sub])
	return Service.new("job_%s:%d" % [line, sub], label, strid, sub)

## FUN_006fdeb0 for one guild id (`sub` its kind).
static func job_services(sub: int, player_kind: int, alias_empty: bool) -> Array:
	var out: Array = []
	if player_kind == 0:
		out.append(_job_line("join", sub))
	elif player_kind == sub:
		out.append(_job_line("withdraw", sub))
		out.append(_job_line("alias_create" if alias_empty else "alias_modify", sub))
		if sub == 2 or sub == 3:
			out.append(_job_line("outcome", sub))
	out.append(_job_line("rank_contribution", sub))
	out.append(_job_line("rank_activity", sub))
	out.append(Service.new("job_prev:%d" % sub, "Check previous job information", JOB_PREV_STRID, sub))
	return out

## Item 4's token (FUN_006fcd60 case 4).
const TALKSTART_STRID := "UIIT_STT_NPC_CHATTING_WND_TALKSTART"
## Item 0x16's token (case 0x16).
const WITHDRAW_SKILL_STRID := "UIIT_MSG_CIRCULATION_WITHDRAW_SKILL"
## Items 0x2d, 0x2e and 0x2f (cases 0x2d-0x2f), and 0x15.
const ACADEMY_OPEN_STRID := "UIIT_STT_TC_OPEN"
const HONOR_RANKING_STRID := "UIIT_STT_TC_HONOR_RANKING"
const AVATAR_MAGIC_OPTION_STRID := "UIIT_STT_AVATAR_MAGICOPTION_ENCHANT_MAGIC_PARAM"
const XMAS_CHANGE_STRID := "UIIT_MSG_XMAS_EVENT_CHANGE"
## The academy line wants a level of 0x3c or more (0x700b96 `cmp byte
## [eax+0x868],0x3c`, 0x700b9d `jb` past it; READ).
const ACADEMY_OPEN_ABOVE_LEVEL := 0x3b
## The job ids in the order FUN_00700440 asks for them, with the kind it
## hands FUN_006fdeb0: 0x14 -> 1, 0x16 -> 3, 0x15 -> 2.
const JOB_IDS := [[0x14, 1], [0x16, 3], [0x15, 2]]
## The builder's last rows, in its order: [id, key, token, fallback label].
const TAIL_LINES := [
	[0x11, "gacha_machine", "SN_TALK_CH_GACHA_MACHINE_2", "SN_TALK_CH_GACHA_MACHINE_2"],
	[0x12, "gacha_operator", "SN_TALK_CH_GACHA_OPERATOR_2", "SN_TALK_CH_GACHA_OPERATOR_2"],
	[0x23, "open_market", "SN_NPC_OPEN_MARKET_START", "SN_NPC_OPEN_MARKET_START"],
	[0x0c, "special_price", "UIIT_PAG_SPECIAL_PRICE_CONDITION_INFO", "Trade Export Details"],
	[0x27, "party_summon", "UIIT_PAG_PARTY_SUMMON", "Summon Party member"],
	[0x29, "dungeon_exit", "UIIT_STT_DUNGEON_EXIT", "Exit Dungeon"],
]

## The ids a teleport gate's own point gives it (round 577's reading, READ:
## RefTeleport_ExtractData registers 7 and 9 from teleportdata columns 10
## and 11; id 8 stands in from `has_links`, disclosed at gate_services). The
## client-placed gates have no server uid, so their set is built here (OURS:
## the original's comes in the 0xB045 reply like an NPC's).
static func gate_ids(has_links: bool, designate: bool, recall: bool) -> PackedByteArray:
	var out := PackedByteArray()
	if designate:
		out.append(7)
	if has_links:
		out.append(8)
	if recall:
		out.append(9)
	return out

## The guild NPC's lines for the player's guild state (round 521): `guild_id`
## -1 unknown, 0 no guild, else the guild's id; `is_master` whether the player
## leads it.
##
## The real client's id 0x0f block in FUN_00700440 (0x70105e-0x70116c; docs/
## protocol/character_state.md, the talk-menu table's order-15 row):
##   * FUN_009870e0() == 0 -> item 0x12 alone, GUILD_CREATE_STRID.
##     FUN_009870e0 returns the byte at +4 of FUN_009870d0's +0x148 block of
##     the object at 0xeeebd8 (0x9870e0 `call 0x9870d0; mov al,[eax+4]`).
##     That this byte means "in a guild" is inferred from what it gates, not
##     read from a writer: its zero branch offers only the create line, and
##     its non-zero branch only lines for a member.
##   * otherwise FUN_00989ce0(name) == 0 -> item 0x1c, GUILD_SECESSION_STRID;
##     non-zero -> items 0x17, 0x14, 0x18, 0x1b (GUILD_LEVEL_UP, GUILD_BREAK,
##     MASTERLEAVE, GUILD_COMPENSATION). Then both get 0x19 or 0x1a (by
##     FUN_0099da70), 0x1d and 0x43. FUN_00989ce0 compares its argument with
##     the string at +0x34 of the same +0x148 block (0x989cec `add eax,0x34`,
##     then 0x989d05 `mov ecx,eax; call 0x47ec20` and 0x989d0e `sete al`, so
##     true when the compare gives 0, i.e. equal). Its argument is
##     FUN_009d6580's copy of the string at +0x84c of
##     the object at [0xeef5ec] (0x7010a3-0x7010ae). That this is "the player
##     is the guild master" is also inferred: UI_GUILD::FUN_005b5150 looks the
##     player's member record up by the same string (FUN_009960a0 walks a
##     list comparing names) and, on the same test, shows
##     UIIT_CTL_GUILD_UNION_CHAT_GRANT instead of ..._CONFIRM; and its
##     non-zero branch is the one with GUILD_BREAK and MASTERLEAVE.
## So guildless -> "guild_create", a member -> "guild_leave". A master is
## never offered secession (the 0x1c push is only in the zero branch), and
## the master's own items have no server in OpenSRO, so a master keeps the
## "Guild" placeholder. Items 0x19/0x1a (MASTERRELEASE / MRELEASE_VOTE), 0x1d
## (GUILD_WAREHOUSE) and 0x43 (GP_HISTORY), which a member also gets, have no
## server either and are not offered -- this project's choice, not a claim
## that the real client lacks them.
##
## The same FUN_009870e0 test gates item 1 (the store lines) at a guild NPC,
## which the server also gives id 1 (0x4c6a4f): 0x7009fc `call 0x9870e0`,
## 0x700a03 `je 0x700b10`. services_from_ids applies it (round 524, round 727): at a guild
## NPC a guildless player (guild_id 0) gets no "Buy", so the create line is
## numbered 1, as in the real client (character_state.md, "The guild NPC's
## lines (round 521)").
##
## The fallback labels are the player's own textuisystem.txt text for the two
## tokens, the same in both of its layouts (the 16-column row's [8] and the
## 19-column row's [9]; /var/tmp/tables/textuisystem.txt on the render box):
## "Create a new guild" and "Leave guild.".
static func guild_services(guild_id: int, is_master: bool) -> Array:
	if guild_id < 0:
		return [Service.new("guild", "Guild")]
	if guild_id == 0:
		return [Service.new("guild_create", "Create a new guild", GUILD_CREATE_STRID)]
	if not is_master:
		return [Service.new("guild_leave", "Leave guild.", GUILD_SECESSION_STRID)]
	return [Service.new("guild", "Guild")]

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

## The numbered, clickable lines of the talk menu, built from services_from_ids's
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

## A teleport gate's lines (round 577), in the order the real client asks for
## their interaction ids in FUN_00700440 (docs/protocol/character_state.md,
## "Interaction id to menu item", rows 10-12, re-read in sro_client.asm):
##   * id 7 (lookup `mov byte [esp+0x1c],0x7` at 0x700c57) -> 0x700c86-0x700c8d
##     `push 0; push 9; push ebx; call 0x6fcd60`, item 9;
##   * id 9 (0x700ca7) -> 0x700cda-0x700ce1 `push 0x10`, item 0x10;
##   * id 8 (0x700cfb) -> after the desert-gate company lines, item 0xa.
## In FUN_006fcd60's switch (index bytes at 0x6fd394, jump table at 0x6fd2d8)
## item 9 takes index 8 -> 0x6fcf10 `push 0xdadc38`, item 0x10 index 0xd ->
## 0x6fcf1a `push 0xdadbf0`, item 0xa index 9 -> 0x6fcf24 `push 0xdadbb8`;
## those .rdata strings, read as UTF-16 out of the render box's
## sro_client.exe, are the three tokens below.
##
## Which ids a gate has: 7 and 9 are registered from teleportdata columns 10
## and 11 (`designate`, `recall`; the server's RefTeleport_ExtractData
## 0x6a7be0, round 454 -- town gates carry (1, 0), GATE_TD (0, 1)). Id 8's
## registrar (0x6a7f70) reads a table this project has not attributed
## (character_state.md, "One discrepancy left open"), so `has_links` -- the
## gate has outgoing teleportlink rows -- STANDS IN for it, disclosed. Whether
## a gate also has id 2 ("Talk to this person.", item 4) is not read, and that
## line is not offered.
##
## The fallback labels are the player's own textuisystem.txt text for the
## three tokens from the later 19-column rows ([9]), which UiTextTable keeps
## (/var/tmp/tables/textuisystem.txt on the render box); the earlier
## 16-column rows say "Designate this region as your return & recall point!",
## "Teleport to your return point." and "Select a teleport area:". The talk
## window shows whichever the archive resolves, and these only when it has
## no text.
static func gate_services(has_links: bool, designate: bool, recall: bool) -> Array:
	var out: Array = []
	if designate:
		out.append(Service.new("recall_designate", "Designate as return/recall point", RECALL_POSITION_STRID))
	if recall:
		out.append(Service.new("recall_return", "Teleport to return point.", TELEPORT_TO_RESURRECT_STRID))
	if has_links:
		out.append(Service.new("teleport", "Select teleport area", TELEPORT_TARGET_STRID))
	return out

## The gate lines' tokens (gate_services): items 9, 0x10 and 0xa of
## FUN_006fcd60.
const RECALL_POSITION_STRID := "UIIT_CTL_RECALL_POSITION"
const TELEPORT_TO_RESURRECT_STRID := "UIIT_CTL_TELEPORT_TO_RESURRECT_POS"
const TELEPORT_TARGET_STRID := "UIIT_CTL_TELEPORT_TARGET"

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
## The fortress smiths are kept although OpenSRO has no fortress, because
## this list is the id-4 set and not a list of the NPCs OpenSRO spawns.
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
	var _pp := ParseProfile.t0()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := TextDecode.utf16(raw)
	if text.is_empty():
		text = raw.get_string_from_utf8()
	var _out := text.replace("\r", "").split("\n")
	ParseProfile.add("text.decode_split", _pp, data.size())
	return _out
