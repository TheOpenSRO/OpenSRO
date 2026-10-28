extends RefCounted

## A server refusal code in words: the game's own message where the client
## has one, our own wording where it does not. Covers the four refusals this
## client shows today: a ground-item pick-up (World3D), an NPC repair
## (hud_panels' store status line), a guild level-up (World3D's Guild
## tab, round 528) and a gate teleport (World3D, round 576). The shop and
## warehouse results carry a
## reason string, not a code (server/internal/session/tradebusy.go,
## tradeBusyReason), so they do not come through here.
##
## The real client turns a refusal code into a UIIT_* message name in
## UI_SILKMALL::FUN_007b8b40, which switches on a category and then on the
## code, and shows that name's text from textuisystem.txt. This does the same
## for the codes in UIIT_BY_CODE, reading the text from the player's own
## archive through UiTextTable. Nothing from the archive is copied here.
##
## Every row is docs/protocol/error_codes.md's table (the rows for 0x1812,
## 0x1839, 0x1c07, 0x1c0b, 0x1c10, 0x1c11, 0x1c12 and 0x1c15), which was
## reproduced 605 of 605 in round 323. For rounds 515, 518 and 576 each row was
## also read through the dispatcher's own jump tables in sro_client.exe:
##   category 1, the storage switch (code - 0x180b, index bytes at 0x7bb6d4,
##   targets at 0x7bb438):
##     0x1812 -> 0x7b8fca  push 0xdc72c0  UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE
##     0x1839 -> 0x7b8e96  push 0xdc77f8  UIIT_MSG_STRGERR_CANNOT_BE_PICKED
##   category 0xd, the interaction switch (code - 0x1c07, targets at 0x7bbaac):
##     0x1c07 -> 0x7ba085  push 0xdc2518  UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY
##     0x1c0b -> 0x7ba09d  push 0xdc24d0  UIIT_MSG_INTERACTION_FAIL_IM_BUSY
##               (entry 4 of the table; round 518)
##     0x1c11 -> 0x7ba0e1  push 0xdc2320  UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REPAIRED
##     0x1c12 -> 0x7ba0f9  push 0xdc22c8  UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REVIVED
##   and, for the teleport's refusals (round 576; the table's raw words dumped
##   with objdump -s at 0x7bbaac..0x7bbaf0, the pushed names read as UTF-16
##   out of sro_client.exe):
##     0x1c10 -> entry 9,  0x7bbad0: 0x7ba0a7  push 0xdc2458
##               UIIT_MSG_INTERACTION_FAIL_CANT_USE_TELEPORT_WITH_TRADECART
##     0x1c15 -> entry 14, 0x7bbae4: 0x7ba111  push 0xdc4e88
##               UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT
##   category 0x10, the guild switch (category table 0x7bb378 entry 0x10 is
##   0x7ba32b; code - 0x4c06, index bytes at 0x7bbc80, targets at 0x7bbb78;
##   round 528):
##     0x4c07 -> 0x7ba359  push 0xdc1710  UIIT_MSG_GUILDERR_IM_DEAD
##     0x4c1e -> 0x7ba3db  push 0xdc5388  UIIT_MSG_GUILDERR_PERMISSION_DENIED
##     0x4c21 -> 0x7ba3e5  push 0xdc1378  UIIT_MSG_ERROR_GUILD_LEVEL_UP_FULL
##     0x4c31 -> 0x7ba449  push 0xdc1018  UIIT_MSG_ERROR_GUILD_LEVEL_UP_GOLD_DEFICIT
##     0x4c32 -> 0x7ba453  push 0xdc0fc0  UIIT_MSG_ERROR_GUILD_LEVEL_UP_GP_DEFICIT
## For these five the reply's category is READ, not assumed: the client's
## handler for the level-up reply 0xb0fa, Guild_OnLevelUpResult (0x881bd0),
## reads the u16 code on result 2 and calls FUN_00778190 with 0x10 as its
## first argument (0x881c53 push 0x10), and FUN_00778190 tail-jumps to the
## dispatcher (0x7781a5), which reads that argument as its category
## (0x7b8b90 movzx eax,BYTE PTR [esp+0x468]).
## For the teleport's codes the category is READ as well: the retail reply
## 0xb05a's handler, FUN_008809d0 (registered for 0xb05a in FUN_0086fbb0),
## reads a u8 result and, on 2, a u16 code, and calls FUN_00778190(0xd, code,
## ...) -- category 0xd, the table above (teleport_line).
## Showing 0x1812 and 0x1839 assumes the pick-up reply is dispatched under
## category 1. The real reply's category was not read. Showing 0x1c07, 0x1c0b,
## 0x1c11 and 0x1c12 likewise assumes the repair reply is dispatched under
## category 0xd, the only category whose table holds them; which category the
## real repair reply uses was not read either.
##
## Codes deliberately NOT in the table:
##   0x1813  another pick already running on the drop (GObjPC::CheckCanPickUp,
##           docs/protocol/ground_items.md). The storage table sends it to the
##           switch's default, 0x7b913a, which clears the string and leaves
##           with no message: the real client shows nothing. It is not
##           UIIT_MSG_STRGERR_BUSY, which is 0x181e (0x7b8d8b).
##   0x1c09  a repair with nothing to restore (GItemEquip::FUN_00496e60,
##           server/internal/repair). The interaction table sends it to the
##           same default, 0x7b913a.
##   4       too far. It depends on the category (round 518). error_codes.md
##           lists 0x0004 as UIIT_STT_ERR_COMMON_TOO_FAR, which is what four
##           of the dispatcher's jump tables give it. Category 0xd tests it in
##           a compare chain instead (0x7ba03b cmp eax,4, then 0x7ba044 push
##           0xdc2628 UIIT_MSG_INTERACTION_FAIL_TOO_FAR). The storage
##           category that holds 0x1812 and 0x1839 has no case for it: its
##           entry at 0x7b8c82 handles only 3 and 0x1807 below 0x180b and
##           sends the rest to the default. The real pick-up reply's category
##           was not read.
##   3       the drop is gone. One of error_codes.md's nine category-dependent
##           codes (PARTYERR_, STRGERR_ or ERR_COMMON_INVALID_TARGET). Under
##           category 1 it would be UIIT_MSG_STRGERR_INVALID_TARGET (0x7b8c9c
##           push 0xdc7ee0). Keeping our own wording for it is the
##           conservative side of the same category-1 assumption.
##   0x4c0d  a level-up by a guildless character (CGuild::HandleLevelUp,
##           server/internal/guild). The guild table's index byte for it
##           (0x7bbc87) is 0x41, the entry that sends it to the same default,
##           0x7b913a; error_codes.md has no row for it.
## Those codes keep our own wording, below.
## Category 0xd's message for code 4 (round 642's review; see teleport_line).
const TOO_FAR_KEY := "UIIT_MSG_INTERACTION_FAIL_TOO_FAR"

const UIIT_BY_CODE := {
	0x1812: "UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE",
	0x1839: "UIIT_MSG_STRGERR_CANNOT_BE_PICKED",
	0x1c07: "UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY",
	0x1c0b: "UIIT_MSG_INTERACTION_FAIL_IM_BUSY",
	0x1c10: "UIIT_MSG_INTERACTION_FAIL_CANT_USE_TELEPORT_WITH_TRADECART",
	# Round 779: a scroll's cast refuses the NPC teleport (HandleTeleportUse
	# 0x513634); category 0xd's entry 13 -> 0x7ba0d7 push 0xdc2380.
	0x1c14: "UIIT_MSG_INTERACTION_FAIL_TELESCROLL_ALREADY_WORKING",
	0x1c11: "UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REPAIRED",
	0x1c12: "UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REVIVED",
	0x1c15: "UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT",
	0x4c07: "UIIT_MSG_GUILDERR_IM_DEAD",
	0x4c1e: "UIIT_MSG_GUILDERR_PERMISSION_DENIED",
	# Round 814: a grant name refused (FUN_005c7560; docs/protocol/
	# error_codes.md's row for the same switch).
	0x4c4d: "UIIT_MSG_GUILD_ERROR_NAME_GRANT_SPECIAL_LETTER",
	0x4c21: "UIIT_MSG_ERROR_GUILD_LEVEL_UP_FULL",
	0x4c31: "UIIT_MSG_ERROR_GUILD_LEVEL_UP_GOLD_DEFICIT",
	0x4c32: "UIIT_MSG_ERROR_GUILD_LEVEL_UP_GP_DEFICIT",
}

## The client's message name for a refusal code, or "" when the client has no
## case for it (see UIIT_BY_CODE for which codes are left out, and why).
static func uiit_key(code: int) -> String:
	return UIIT_BY_CODE.get(code, "")

## The archive's text for a refusal code, or fallback. A missing key is
## checked with has(), because get_text() answers the raw token for one, and
## a row whose text the parser could not find also stores the token itself.
## Neither is ever shown. The text is stripped: some real rows end in a space.
## UiTextTable.parse already strips each field, so this strip matters only
## for a table filled some other way (error_text_test.gd builds one).
static func resolve(code: int, table: UiTextTable, fallback: String) -> String:
	var key := uiit_key(code)
	if key == "" or table == null or not table.has(key):
		return fallback
	var text := table.get_text(key).strip_edges()
	if text == "" or text == key:
		return fallback
	return text

## The pick-up refusal in words. The codes are the engine's own
## (internal/grounditem, GObjPC::CheckCanPickUp): 3 the drop is gone, 4 out of
## reach, 0x1812 someone else's drop inside its owner window, 0x1813 another
## pick already running on it, 0x1839 CanPick answered 0 -- which the server
## also answers for its own failures the engine has no code for, a bag with no
## room among them. The fallbacks are our own wording.
static func pick_up_line(code: int, table: UiTextTable) -> String:
	match code:
		GroundItemsNet.ERR_NOT_THERE:
			# A drop that is already gone -- someone took it, it expired, or
			# this is a duplicate request for one we just picked up ourselves.
			# It is NOT the bag being full, and saying so was a cause this
			# client invented and the server never gave (playtest 2026-09-20).
			# The server answered 0x1839 for this until round 493; it now
			# answers the engine's own 3.
			return resolve(code, table, "That drop is no longer there.")
		GroundItemsNet.ERR_CANNOT_PICK:
			return resolve(code, table, "That item cannot be picked up.")
		GroundItemsNet.ERR_NOT_OWNER:
			return resolve(code, table, "That drop still belongs to someone else.")
		GroundItemsNet.ERR_BUSY:
			return resolve(code, table, "Someone else is picking that up.")
		GroundItemsNet.ERR_TOO_FAR:
			return resolve(code, table, "That drop is out of reach.")
	return resolve(code, table, "Could not pick that up (code 0x%x)." % code)

## The repair refusal in words. The codes are server/internal/repair's
## (docs/protocol/durability.md): 0x1c07 not enough gold, 0x1c09 nothing
## missing, 0x1c11 an item that cannot be repaired, 0x1c12 one that cannot be
## revived. 0x1c0b is the busy refusal: server/internal/session/repair.go
## answers it while a trade holds the character (tradebusy.go,
## interactionBusyCode, round 499).
##
## The server also answers 0x1c11 for its own failures, which the engine has
## no code for: an undecodable request, an unknown character, no item table
## (items == nil), an error from eq.Get or chars.GetByID, and an error from
## eq.SetDurability. A DeductGold failure records 0x1c07, which goes out only
## when no slot was repaired and it was the last refusal. So the archive's
## "cannot be repaired" and "not enough gold" texts also cover those, as
## pick_up_line's 0x1839 does for the pick-up. The fallbacks are our own
## wording.
static func repair_line(code: int, table: UiTextTable) -> String:
	match code:
		0x1c07:
			return resolve(code, table, "Not enough gold.")
		0x1c0b:
			return resolve(code, table, "You are busy with something else.")
		0x1c09:
			return resolve(code, table, "Nothing needs repairing.")
		0x1c11:
			return resolve(code, table, "That item cannot be repaired.")
		0x1c12:
			return resolve(code, table, "That item cannot be revived.")
	return resolve(code, table, "Repair refused (code 0x%x)." % code)

## A guild level-up refusal in words (round 528). The codes are
## CGuild::HandleLevelUp's (0x5c63d0; server/internal/guild, CheckLevelUp):
## 0x4c07 dead, 0x4c0d no guild, 0x4c1e not the master, 0x4c21 already level
## 5, 0x4c31 not enough gold, 0x4c32 not enough guild points. fallback is the
## server's own wording, which the reply carries beside the code: it stands in
## for 0x4c0d (the real client shows nothing for it), for a key the archive
## lacks, and for the server's own failures, which carry code 0.
static func guild_level_up_line(code: int, table: UiTextTable, fallback: String) -> String:
	return resolve(code, table, fallback)

## A grant-name refusal in words (round 814; GuildPlateNet). The codes are
## FUN_005c7560's: 0x4c0d no guild (the client has no text for it), 0x4c51 a
## guild below level 4 (no name in the client's table), 0x4c1e another
## member's name (OURS: a member names only themselves), 0x4c4d too long or
## filtered. The archive's words where it has them, else ours.
static func grant_name_line(code: int, table: UiTextTable) -> String:
	match code:
		0x4c0d:
			return "You are not in a guild."
		0x4c51:
			return "A guild must be level 4 to grant names."
		0x4c1e:
			return resolve(code, table, "You can only set your own grant name.")
		0x4c4d:
			return resolve(code, table, "That grant name is not allowed.")
	return "The grant name was refused (code 0x%x)." % code

## A teleport refusal in words (round 576). The codes are the server's
## (server/internal/session/teleport.go): the engine's 0x1c07 not enough gold
## (GObjPC::HandleTeleportUse), 0x1c15 a level outside the link's range and
## 0x1c10 a trade cart (FUN_00513a70's arms), each shown in the archive's own
## words -- the reply's category, 0xd, is read (see UIIT_BY_CODE's header);
## 2, the engine's "no such link", which category 0xd shows no message for --
## its compare chain below 0x1c07 (0x7ba02e..0x7ba03e) tests 0x1c06, EBX
## (zeroed at the dispatcher's entry, 0x7b8b7b, and not written again in it)
## and 4, and sends 2 to the default, 0x7b913a -- so it keeps our own wording;
## and the server's own refusals (code 0: dead, not in the world, no network)
## and the codes UIIT_BY_CODE has no row for (0x1c19, 0x1c23, 0x1c24), which
## show `reason`, the server's own words.
static func teleport_line(code: int, table: UiTextTable, reason: String) -> String:
	match code:
		0x1c07:
			return resolve(code, table, "Not enough gold.")
		0x1c10:
			return resolve(code, table, "You cannot teleport with a trade cart.")
		0x1c14:
			return resolve(code, table, "A teleport scroll is already working.")
		0x1c15:
			return resolve(code, table, "Your level does not allow that destination.")
		2:
			return "No such destination."
		4:
			# Too far (round 642's review: the server's interaction range).
			# Category 0xd's compare chain gives 4 UIIT_MSG_INTERACTION_FAIL_TOO_FAR
			# (0x7ba03b cmp eax,4; 0x7ba044 push 0xdc2628) -- read by key,
			# since 4 means other things in other categories (UIIT_BY_CODE).
			if table != null and table.has(TOO_FAR_KEY):
				var text := table.get_text(TOO_FAR_KEY).strip_edges()
				if text != "" and text != TOO_FAR_KEY:
					return text
			return "You are too far away."
		3:
			# Not near the gate (the region test). Category 0xd sends 3 to its
			# default (0x7b913a): the real client shows nothing. Our words.
			return "You are not near that gate."
	if reason != "":
		return resolve(code, table, reason)
	return resolve(code, table, "Teleport refused (code 0x%x)." % code)

## The alchemy window's refusals (round 768). The client's replies 0xB150 /
## 0xB151 (0x8729e0 / 0x872cd0) hand a refusal's code to FUN_00778190 under
## category 0x12 (READ), and the dispatcher's alchemy cases give these names
## (docs/protocol/error_codes.md's rows, decoded from the same 643-case
## switch). 0x5423, a stone's lost roll, never comes here: the window shows
## it as a failure (AlchemyWindow). The codes without a row -- 2 (the magic
## option table has no such option, or the item is full), 3 (an empty slot)
## and 0x5406 -- keep our own wording.
const ALCHEMY_UIIT_BY_CODE := {
	0x5407: "UIIT_MSG_REINFORCERR_RECIPE_NOT_LOADED",
	0x5408: "UIIT_MSG_REINFORCERR_ONLY_EQUIPITEM_CAN_BE_REINFORCED",
	0x5409: "UIIT_MSG_REINFORCERR_RECIPE_MISMATCH",
	0x540a: "UIIT_MSG_REINFORCERR_EQUIPCLASS_MISMATCH_PROB_UP",
	0x540f: "UIIT_MSG_REINFORCERR_TARGETEQUIP_CANT_BE_REINFORCED",
	0x5410: "UIIT_MSG_REINFORCERR_IS_NOT_REINFORCE_STUFF",
	0x5412: "UIIT_MSG_REINFORCERR_STUFF_CANT_BE_LOADED_MULTIPLE_TIME",
	0x5414: "UIIT_MSG_REINFORCERR_INVALID_ITEM_SLOT",
	0x5420: "UIIT_MSG_STRGERR_ASTRAL",
	0x5421: "UIIT_MSG_ENCHANT_EQUIPCLASS_MISMATCH",
	0x5422: "UIIT_MSG_STRGERR_MAGICSTONE2_MAX",
	0x5423: "UIIT_MSG_ENCHANT_FAILED",
	0x5424: "UIIT_MSG_STRGERR_ASTRAL",
	0x5425: "UIIT_MSG_TC_ERROR_ENCHANT_HONOR_ITEM",
	0x5426: "UIIT_MSG_REINFORCERR_ALREADY_DONE",
}

static func alchemy_line(code: int, table: UiTextTable) -> String:
	var key: String = ALCHEMY_UIIT_BY_CODE.get(code, "")
	if key != "" and table != null and table.has(key):
		var text := table.get_text(key).strip_edges()
		if text != "" and text != key:
			return text
	match code:
		2:
			return "The stone's option cannot be added to this item."
		3:
			return "That slot is empty."
	return "Alchemy refused (code 0x%x)." % code

## The use-item reply's refusals (round 778): the client's handler for 0xb04c,
## Item_OnUseItemResult (0x87a7b0), reads a u16 code on a result other than 1
## and calls FUN_00778190(1, code, ...) -- category 1 (READ, 0x87b665..
## 0x87b689). The names are category 1's cases, decoded through its jump table
## (code - 0x180b, index bytes 0x7bb6d4, targets 0x7bb438; the first push at
## each target): 0x185b 0x7b9064, 0x185d 0x7b9038, 0x185e 0x7b906e, 0x185f
## 0x7b919f, 0x1875 0x7b916f, 0x187a 0x7b8d3e, 0x1885 0x7b924d, 0x1886
## 0x7b9257, 0x1889 0x7b9275, 0x18e9 0x7b956a, 0x18f2 0x7b95a6, 0x18f5
## 0x7b95b0, 0x18fd 0x7b95fe. 2, outside the switch (below 0x180b), goes to
## its default: the real client shows nothing, and this shows the server's
## own words.
const SCROLL_UIIT_BY_CODE := {
	0x185b: "UIIT_MSG_STRGERR_WAIT_FOR_REUSE_DELAY",
	0x185d: "UIIT_MSG_STRGERR_PREV_TELESCROLL_ALREADY_WORKING",
	0x185e: "UIIT_MSG_STRGERR_CANT_TELEPORT_WITH_CART",
	0x185f: "UIIT_MSG_STRGERR_REQUESTED_JOB_BLOCKED_BY_QUEST",
	# Round 779: the thief-den scroll for one not in job state 2 (FUN_004a0380
	# 0x4a04e6); the table's index 0x3f -> 0x7b90c7.
	0x186a: "UIIT_MSG_STRGERR_ONLY_ROBBER_CAN_USE_THIS_ITEM",
	0x1875: "UIIT_MSG_STRGERR_MURDERER_CANT_USE_PORTAL_SCROLL",
	0x187a: "UIIT_MSG_COSPETERR_CANT_USEITEM",
	0x1885: "UIIT_MSG_STRGERR_CANT_FIND_LAST_TELEPOS",
	0x1886: "UIIT_MSG_STRGERR_CANT_FIND_LAST_DIEDPOS",
	# Round 838: the repair hammer with nothing to mend (UseByKind case 7).
	0x1888: "UIIT_MSG_STRGERR_THERE_IS_NO_ITEM_TO_REPAIR",
	0x1889: "UIIT_SKILL_USE_FAIL_CHAR_DEAD",
	# Round 838: the skin change of sex with gear on (UpdateCharRefObjIDAndScale
	# 0x4efe50; shown under category 1 as the client's own pre-check shows it,
	# SendItem_HandleUseItem case 9).
	0x1892: "UIIT_MSG_CHAR_SKIN_ERR_ARMOR",
	0x18e9: "UIIT_MSG_FORT_PORTALSTONE_FAIL_02",
	0x18f2: "UIIT_MSG_FORT_ETC_ERROR_WRONGACTION_FORTWAR",
	0x18f5: "UIIT_MSG_ITEM_USE_REVERSE_PORTAL_RETRUN_TO_INS",
	0x18fd: "UIIT_MSG_INTERACTION_FAIL_OUT_OF_REQUIRED_LEVEL_FOR_TELEPORT",
}

## A use-item refusal in words: the archive's text for the code's category-1
## name, else `reason` (the server's own words).
static func scroll_line(code: int, table: UiTextTable, reason: String) -> String:
	var key: String = SCROLL_UIIT_BY_CODE.get(code, "")
	if key != "" and table != null and table.has(key):
		var text := table.get_text(key).strip_edges()
		if text != "" and text != key:
			return text
	if reason != "":
		return reason
	return "That cannot be used (code 0x%x)." % code

## Round 799: the job guild's refusals. READ: every job reply's handler shows
## a refusal through FUN_00778190(0x18, code, ...) (0xb0e1 c:0x889100, 0xb0e2,
## 0xb0e3 c:0x889370, 0xb0e5 c:0x8830f0 ...), the error dispatcher; the rows
## are docs/protocol/error_codes.md's for the job codes. Codes with no row
## (2, 3, 0x4807, 0x480f, 0x4828, 0x482a) take the dispatcher's default,
## which shows nothing: "" here.
const JOB_UIIT_BY_CODE := {
	0x4810: "UIIT_MSG_INTERACTION_FAIL_CANT_USE_TELEPORT_WITH_TRADECART",
	0x4817: "UIIT_MSG_INTERACTION_FAIL__REQUESTED_JOB_BLOCKED_BY_QUEST",
	0x4818: "UIIT_INTERACTION_FAIL_ONLY_ROBBER_CAN_TELEPORT_TO_THIEFDEN",
	0x4819: "UIIT_MSG_JOBGUILD_JOIN_ERR_LEVEL",
	0x4820: "UIIT_MSG_JOBGUILD_JOIN_ERR_OVERLAP",
	0x4821: "UIIT_MSG_JOBITEM_WEAR_ERR_NOGUILD",
	0x4822: "UIIT_CTL_JOBGUILD_WITHD_ERR_WEARITEM",
	0x4823: "UIIT_MSG_ALIAS_CREATE_ERR_NOTRULE",
	0x4824: "UIIT_MSG_JOBGUILD_JOIN_ERR_EXPIRE",
	0x4825: "UIIT_MSG_ALIAS_CREATE_ERR_NAMEDULPLICATE",
	0x4826: "UIIT_MSG_ALIAS_CREATE_ERR_NAMEDULPLICATE",
	0x4829: "UIIT_MSG_JOBINFO_OLD_NOTEXIST",
	0x482b: "UIIT_MSG_PARTYMATCH_RECORD_ERROR_JOBWITHDRAW",
	0x482e: "UIIT_MSG_JOBGUILD_WITHD_ERR_QUEST",
}

static func job_line(code: int, table: UiTextTable) -> String:
	var key := String(JOB_UIIT_BY_CODE.get(code, ""))
	if key == "" or table == null or not table.has(key):
		return ""
	var text := table.get_text(key).strip_edges()
	return "" if text == "" or text == key else text

## Round 801: the specialty trade's refusals -- 0xB034's for a transport buy,
## sale or pick, and the transport summon's -- through category 1, the
## storage switch (code - 0x180b, index bytes 0x7bb6d4, targets 0x7bb438; the
## first push at each target), READ for each code below: 0x180b 0x7b8fb2,
## 0x180f 0x7b8d56, 0x1814 / 0x1815 0x7b8d6e, 0x1829 0x7b8de3, 0x183b
## 0x7b8ec1, 0x1845 0x7b8f39, 0x1849 0x7b8f86, 0x184e 0x7b9653, 0x185c
## 0x7b8d05, 0x1860 0x7b8ed9, 0x1861 0x7b8ee3, 0x1863 0x7b9082, 0x1865
## 0x7b908c, 0x1868 0x7b90aa, 0x186f 0x7b90ef, 0x1872 0x7b9148, 0x1878
## 0x7b91ca, 0x1895 0x7b92a7, 0x18af 0x7b9445, 0x18b0 0x7b944f, 0x18d1
## 0x7b93f5. 0x1864's target (0x7b913a) pushes no text: nothing is shown.
## Codes below 0x180b (2, 3, 5, 0x1806, 0x1807, 0x1809) are outside the
## switch; 0x1807 is ItemOpNet's INVENTORY_FULL line.
const TRADE_UIIT_BY_CODE := {
	0x180b: "UIIT_MSG_STRGERR_CANT_BE_STORED",
	0x180f: "UIIT_MSG_STRGERR_NOT_ENOUGH_GOLD",
	0x1814: "UIIT_MSG_STRGERR_ENABLEINPUT_FEWERTHAN_REMAIN",
	0x1815: "UIIT_MSG_STRGERR_ENABLEINPUT_FEWERTHAN_REMAIN",
	0x1829: "UIIT_MSG_STRGERR_SPECIFY_POSITIVE_NUMBER_ONLY",
	0x183b: "UIIT_MSG_STRGERR_CANNOT_DEAL_AT_SHOP",
	0x1845: "UIIT_MSG_STRGERR_DEALER_DONT_TREAT_THIS_ITEM",
	0x1849: "UIIT_MSG_STRGERR_YOU_CANT_ACTIVATE_CART",
	0x184e: "UIIT_MSG_SPECIALTY_ERR_NOTTRADE",
	0x185c: "UIIT_MSG_STRGERR_CANT_SUMMON_MULTIPLE_COSOBJ",
	0x1860: "UIIT_MSG_STRGERR_ONLY_TRADER_CAN_BUY_SPECIALTY",
	0x1861: "UIIT_MSG_STRGERR_DONT_HAVE_ANY_TRADECART_TO_PICK_SPECIALTY",
	0x1863: "UIIT_MSG_STRGERR_YOU_ARENT_BUYER_OF_THIS_SPECIALTY",
	0x1865: "UIIT_MSG_STRGERR_CANT_DEAL_SPECIALTY_SINCE_TOO_FAR_FROM_CART",
	0x1868: "UIIT_MSG_STRGERR_DEALER_DONT_TREAT_STOLEN_ITEM",
	0x186f: "UIIT_MSG_STRGERR_ROBBER_CANT_PICK_HIS_ITEM",
	0x1872: "UIIT_MSG_STRGERR_POSSESSION_LIMIT_EXCEEDED",
	0x1878: "UIIT_MSG_COS_CAN_NOT_CREATE_BATTLE",
	0x1895: "UIIT_MSG_STRGERR_ROBBER_CANT_SUMMON_CART_IN_TOWN",
	0x18af: "UIIT_MSG_SPECIALTY_ERR_NOTSELL",
	0x18b0: "UIIT_MSG_SPECIALTY_ERR_QUEST_NOTCOMPLETE",
	0x18d1: "UIIT_MSG_SPECIALTY_ERR_TRADESHOP",
	0x1807: "UIIT_MSG_STRGERR_INVENTORY_FULL",
}

## A trade refusal in words, "" when the client shows nothing for it.
static func trade_line(code: int, table: UiTextTable) -> String:
	var key := String(TRADE_UIIT_BY_CODE.get(code, ""))
	if key == "" or table == null or not table.has(key):
		return ""
	var text := table.get_text(key).strip_edges()
	return "" if text == "" or text == key else text
