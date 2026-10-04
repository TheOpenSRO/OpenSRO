extends PartyMatchBox
class_name PartyMatchAuto

## The auto-match dialog, CIFPartyMatchAuto (round 714, lane C2; party_gui.md
## §3 "The auto-match dialog"). READ (sro_client.exe, Create 0x73e790):
## - child 110 of the matching window (the AutoMatch section): 314x337 on
##   msgbox2_window_, caption UIIT_PAG_PARTYMATCH_AUTOMATCH, layout
##   ifpartymatchauto.txt; centred on the screen when made (0x739400 ->
##   0x798b70);
## - the objective radio (ID 35): origin (0, 0), pitch 0x42, label x 0x16,
##   width 0x32, 4 items across, and the same job restriction as the
##   register dialog;
## - the race radio (ID 37): origin (0, 0), pitch 0x5b, label x 0x16, width
##   0x64, 3 items across: CHN, EUR, Open (0xd9d078, 0xd9d028, 0xdb3cf8);
## - the exp and item radios (IDs 39 / 40): origin (2, 2), pitch 0x14, label
##   x 0x14, centred, width 0x64, 2 items down: SHARE, SELF;
## - OK (0x73ebc0) picks candidates from the records the window holds
##   (PartyMatchNet.auto_candidate) and queues up to 10 of them.
## OURS: the starting choices (the objective the job allows first, race
## Open, both radios as the party settings block) -- the dialog's own
## defaults were not read.

const SIZE := Vector2(314, 337)
const LAYOUT := "resinfo\\ifpartymatchauto.txt"

## OK: the choices (purpose, race 0 CHN / 1 EUR / 2 Open, the flags byte).
signal submitted(purpose: int, race_choice: int, flags: int)

var _anyone := 0

func build(builder: UiBuilder, job: int, party: PartyState) -> bool:
	name = "PartyMatchAuto"
	if not build_shell(builder, SIZE, "UIIT_PAG_PARTYMATCH_AUTOMATCH", "Auto matching", LAYOUT):
		return false
	var labels: Array = []
	for i in 4:
		labels.append(text(PartyMatchNet.PURPOSE_KEYS[i], PartyMatchNet.PURPOSE_FALLBACKS[i]))
	build_radio(node("GDR_PARTYMATCH_REGISTER_OBJECT_RBTN"), "object", labels, Vector2.ZERO, 66, 22, 50, true, false)
	var allowed := PartyMatchNet.allowed_purposes(job)
	for i in 4:
		set_radio_enabled("object", i, allowed.has(i))
	choose("object", allowed[0])
	build_radio(node("GDR_PARTYMATCH_REGISTER_RACE_RBTN"), "race",
		[text(PartyMatchNet.RACE_KEYS[0], "CHN"), text(PartyMatchNet.RACE_KEYS[1], "EUR"),
		text("UIIT_CTL_PARTYMATCH_AUTOMATCH_RACE_ANYTHING", "Open")], Vector2.ZERO, 91, 22, 100, true, false)
	choose("race", 2)
	build_radio(node("GDR_PARTYMATCH_REGISTER_EXP_RBTN"), "exp",
		[text("UIIT_STT_PARTY_EXP_SHARE", "Exp Auto Share"), text("UIIT_STT_PARTY_EXP_SELF", "Exp Free-For-All")],
		Vector2(2, 2), 20, 20, 100, false, true)
	build_radio(node("GDR_PARTYMATCH_REGISTER_ITEM_RBTN"), "item",
		[text("UIIT_STT_PARTY_ITEM_SHARE", "Item Auto Share"), text("UIIT_STT_PARTY_ITEM_SELF", "Item Free-For-All")],
		Vector2(2, 2), 20, 20, 100, false, true)
	if party != null:
		choose("exp", 0 if party.exp_share == 1 else 1)
		choose("item", 0 if party.item_share == 1 else 1)
		_anyone = party.anyone_invite
	var ok := button("GDR_PARTYMATCH_REGISTER_OK_BTN")
	if ok != null:
		ok.pressed.connect(press_ok)
	var cancel := button("GDR_PARTYMATCH_REGISTER_CANCEL_BTN")
	if cancel != null:
		cancel.pressed.connect(close)
	return true

## The flags the candidates must carry: exp bit 0, item bit 1, and bit 2 from
## the player's own "anyone may invite" (0x73ebc0).
func flags() -> int:
	var f := 0
	if choice("exp") == 0:
		f |= PartyNet.FLAG_EXP_SHARE
	if choice("item") == 0:
		f |= PartyNet.FLAG_ITEM_SHARE
	if _anyone == 1:
		f |= PartyNet.FLAG_ANYONE_INVITE
	return f

func press_ok() -> void:
	submitted.emit(choice("object"), choice("race"), flags())
	close()
