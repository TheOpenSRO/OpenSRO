extends RefCounted

## A server refusal code in words: the game's own message where the client
## has one, our own wording where it does not. Covers the three refusals this
## client shows today: a ground-item pick-up (World3D), an NPC repair
## (hud_panels' store status line) and a guild level-up (World3D's Guild
## tab, round 528). The shop and warehouse results carry a
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
## 0x1839, 0x1c07, 0x1c0b, 0x1c11 and 0x1c12), which was reproduced 605 of 605
## in round 323. For rounds 515 and 518 each row was also read through the
## dispatcher's own jump tables in sro_client.exe:
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
const UIIT_BY_CODE := {
	0x1812: "UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE",
	0x1839: "UIIT_MSG_STRGERR_CANNOT_BE_PICKED",
	0x1c07: "UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY",
	0x1c0b: "UIIT_MSG_INTERACTION_FAIL_IM_BUSY",
	0x1c11: "UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REPAIRED",
	0x1c12: "UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REVIVED",
	0x4c07: "UIIT_MSG_GUILDERR_IM_DEAD",
	0x4c1e: "UIIT_MSG_GUILDERR_PERMISSION_DENIED",
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
