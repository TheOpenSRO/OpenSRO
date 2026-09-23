extends RefCounted

## A server refusal code in words: the game's own message where the client
## has one, our own wording where it does not. Covers the two refusals this
## client shows today: a ground-item pick-up (World3D) and an NPC repair
## (hud_panels' store status line).
##
## The real client turns a refusal code into a UIIT_* message name in
## UI_SILKMALL::FUN_007b8b40, which switches on a category and then on the
## code, and shows that name's text from textuisystem.txt. This does the same
## for the codes in UIIT_BY_CODE, reading the text from the player's own
## archive through UiTextTable. Nothing from the archive is copied here.
##
## Every row is docs/protocol/error_codes.md's table (the rows for 0x1812,
## 0x1839, 0x1c07, 0x1c11 and 0x1c12), which was reproduced 605 of 605 in
## round 323. For round 515 each row was also read through the dispatcher's
## own jump tables in sro_client.exe:
##   category 1, the storage switch (code - 0x180b, index bytes at 0x7bb6d4,
##   targets at 0x7bb438):
##     0x1812 -> 0x7b8fca  push 0xdc72c0  UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE
##     0x1839 -> 0x7b8e96  push 0xdc77f8  UIIT_MSG_STRGERR_CANNOT_BE_PICKED
##   category 0xd, the interaction switch (code - 0x1c07, targets at 0x7bbaac):
##     0x1c07 -> 0x7ba085  push 0xdc2518  UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY
##     0x1c11 -> 0x7ba0e1  push 0xdc2320  UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REPAIRED
##     0x1c12 -> 0x7ba0f9  push 0xdc22c8  UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REVIVED
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
##   4       too far. error_codes.md lists 0x0004 as UIIT_STT_ERR_COMMON_TOO_FAR,
##           but the storage category that holds 0x1812 and 0x1839 has no case
##           for it: its entry at 0x7b8c82 handles only 3 and 0x1807 below
##           0x180b and sends the rest to the default. Which message 4 gets
##           depends on the category the reply is dispatched under, and the
##           real pick-up reply's category was not read.
##   3       the drop is gone. One of error_codes.md's nine category-dependent
##           codes (PARTYERR_, STRGERR_ or ERR_COMMON_INVALID_TARGET), so the
##           same unread category decides it.
## Those codes keep our own wording, below.
const UIIT_BY_CODE := {
	0x1812: "UIIT_MSG_STRGERR_LOCKED_BY_OTHER_ONE",
	0x1839: "UIIT_MSG_STRGERR_CANNOT_BE_PICKED",
	0x1c07: "UIIT_MSG_INTERACTION_FAIL_NOT_ENOUGH_MONEY",
	0x1c11: "UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REPAIRED",
	0x1c12: "UIIT_MSG_INTERACTION_FAIL_CANNOT_BE_REVIVED",
}

## The client's message name for a refusal code, or "" when the client has no
## case for it (see UIIT_BY_CODE for which codes are left out, and why).
static func uiit_key(code: int) -> String:
	return UIIT_BY_CODE.get(code, "")

## The archive's text for a refusal code, or fallback. A missing key is
## checked with has(), because get_text() answers the raw token for one, and
## a row whose text the parser could not find also stores the token itself.
## Neither is ever shown. The text is stripped: some real rows end in a space.
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
## revived. The fallbacks are our own wording.
static func repair_line(code: int, table: UiTextTable) -> String:
	match code:
		0x1c07:
			return resolve(code, table, "Not enough gold.")
		0x1c09:
			return resolve(code, table, "Nothing needs repairing.")
		0x1c11:
			return resolve(code, table, "That item cannot be repaired.")
		0x1c12:
			return resolve(code, table, "That item cannot be revived.")
	return resolve(code, table, "Repair refused (code 0x%x)." % code)
