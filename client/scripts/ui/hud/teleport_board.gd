extends RefCounted
class_name TeleportBoard

## The gate's destination list (round 603): the lines the retail client puts
## in the NPC talk box itself when 'Select teleport area' is chosen. There is
## no separate teleport window.
##
## Read from sro_client.exe (md5 2a5794b72c90908d945be8b3f3f2edd4;
## docs/RE_COMPLETION.md, round 603):
##
## - The talk box's click handler CIF_NPCTalk::FUN_007020c0 switches on the
##   clicked line's type. Type 10 (0xa, the line FUN_006fcd60 labels
##   UIIT_CTL_TELEPORT_TARGET) with sub-type 0 calls UI_TELEPORT::FUN_006fd3e0
##   on the talk box (`call 0x6fd3e0` at 0x702973), with a counter set to 1.
## - FUN_006fd3e0 clears the talk box's list and puts the box's own current
##   text back at the top (FUN_006fb530 with this+0x7d4: that text, then a
##   line of two spaces, both white and not clickable). Then, for each link of
##   the gate in the client's own link order, it adds one line
##   "%d. %s" (counter, then 1, 2, ...) whose %s is UIIT_CTL_TELEPORT_FREE_RESULT
##   (fee word 0) or UIIT_CTL_TELEPORT_RESULT (fee word, plus a surcharge),
##   filled with the destination's name. Each line is type 10, sub-type 1,
##   and carries the destination. Last it adds FUN_006fcd60(n, 0, 0): the
##   talk box's own "n. " end line.
## - A click on a type-10 sub-type-1 line sends the request at once
##   (`push 2; push [edi+0xc]; push npc; call 0x81ddf0` at 0x70293d..0x702946).
##   No confirmation box, no Move button, no pages, and the click path does
##   not close the talk box (0x6f74a0 / 0x6f74c0 after the send only store
##   zeros).
##
## So the destinations are talk lines, and a line is what the player clicks.
## The two layouts round 578 built a board from (resinfo\ifteleportboard.txt,
## ifteleportareaslot.txt) and their class, CIFTeleportAreaSlot, are not in the
## exe as ASCII or UTF-16, and no function in the decompile names them.
##
## Not reproduced, disclosed: the line colours (0xffefdaa4, 0xffff8a00 and
## 0xff969696 for a greyed line are read; the talk box draws every line in one
## colour today); the greying itself (only for STORE_TOMB_GATE_IN, a gate
## OpenSRO does not bind); the fee surcharge (FUN_006fc910; OpenSRO has no
## fortresses); the client-side checks before the send that end in messages
## 0x1c1c and 0x1c1e (0x702817..0x702916, not read further).

## The talk-line key of a destination line: this prefix and the destination's
## teleportdata id. HudPanels._on_npc_talk_choice emits teleport_requested
## for it.
const DEST_KEY_PREFIX := "teleport_dest:"
## The two list formats UI_TELEPORT::FUN_006fd3e0 (0x006fd3e0) chooses between
## (docs/protocol/teleport_network.md, "The client's list, read"):
## UIIT_CTL_TELEPORT_FREE_RESULT when the link's fee word is 0, else
## UIIT_CTL_TELEPORT_RESULT with the fee.
const RESULT_TOKEN := "UIIT_CTL_TELEPORT_RESULT"
const FREE_TOKEN := "UIIT_CTL_TELEPORT_FREE_RESULT"

## A destination's line text, in the archive's own list wording: the free
## format (UIIT_CTL_TELEPORT_FREE_RESULT; the 19-column row UiTextTable keeps
## reads "Teleport to [%s]area.") when the link's fee is 0 -- the retail
## dialog's rule -- or when `waived`, and the fee format
## (UIIT_CTL_TELEPORT_RESULT, "Teleport to [%s]area. [%d]gold") otherwise.
## Not UIIT_CTL_TELEPORT_RESULT_IMPROVE ("[%s]gold"): UI_TELEPORT::FUN_006fd3e0
## never asks for it. The fee is the raw link fee; the retail list adds a
## surcharge from a short at this+0x804 (FUN_006fc910, unread meaning; 0
## without fortresses) -- docs/protocol/teleport_network.md "The client's
## list, read". `waived` is OpenSRO's display of the
## engine's level waiver only (GObjPC::HandleTeleportUse, `cmp al,0x14; ja`
## at 0x5136de); the retail dialog does not apply it, and the GM and testing
## waivers are the server's to report in the receipt. A format that is not
## exactly those placeholders (TeleportNet._fits) falls back to OpenSRO's
## own wording (ours, not the archive's): "<place> -- <fee> gold" or
## "<place> -- No cost", keeping the place so the line still says where it
## goes; with no place, "<fee> gold" or "No cost".
static func price_text(place: String, fee: int, waived: bool, result_fmt: String, free_fmt: String) -> String:
	var free := fee <= 0 or waived
	if place != "":
		if free and TeleportNet._fits(free_fmt, false):
			return free_fmt % [place]
		if not free and TeleportNet._fits(result_fmt, true):
			return result_fmt % [place, fee]
	var cost := "No cost" if free else "%d gold" % fee
	return cost if place == "" else "%s -- %s" % [place, cost]

## The talk box's lines for a gate's destinations, as BBCode: one clickable
## "n. <price_text>" line per entry in the order given (the links' file
## order), numbered from 1, then the talk box's own end line with the next
## number (NpcServiceReader.TALKEND_STRID, as its menu ends). Each entry is a
## Dictionary {dest_id, place, fee, waived}. `resolve(token, fallback)` gives
## a UIIT token's text. Prints one NPCTALK line per line, as the menu does.
## The text's own square brackets are escaped ([lb]), so "[Donwhang]" is
## drawn, not read as a tag.
static func list_lines(gate_name: String, entries: Array, resolve: Callable) -> PackedStringArray:
	var result_fmt := str(resolve.call(RESULT_TOKEN, ""))
	var free_fmt := str(resolve.call(FREE_TOKEN, ""))
	var lines := PackedStringArray()
	var n := 1
	for entry_v in entries:
		var entry: Dictionary = entry_v
		var text := price_text(str(entry.get("place", "")), int(entry.get("fee", 0)), bool(entry.get("waived", false)), result_fmt, free_fmt)
		print("NPCTALK %s line %d: %d. %s" % [gate_name, n, n, text])
		lines.append("[url=%s%d]%d. %s[/url]" % [DEST_KEY_PREFIX, int(entry.get("dest_id", 0)), n, escape(text)])
		n += 1
	var end_text := str(resolve.call(NpcServiceReader.TALKEND_STRID, "End conversation."))
	print("NPCTALK %s line %d: %d. %s" % [gate_name, n, n, end_text])
	lines.append("[url=end]%d. %s[/url]" % [n, escape(end_text)])
	return lines

## Text made safe inside BBCode: every "[" becomes [lb].
static func escape(text: String) -> String:
	return text.replace("[", "[lb]")

## The destination id a talk-line key names, or -1 when it is not a
## destination line.
static func dest_from_key(key: String) -> int:
	if not key.begins_with(DEST_KEY_PREFIX):
		return -1
	var rest := key.substr(DEST_KEY_PREFIX.length())
	return int(rest) if rest.is_valid_int() else -1
