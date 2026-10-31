extends PartyMatchBox
class_name PartyMatchReqJoin

## The party leader's join-request popup, CIFPartyMatchReqJoin (round 714,
## lane C2; party_gui.md §4, the user's screenshot 08). READ (sro_client.exe):
## - GDR_PARTY_MATCH_REQ_JOIN in ginterface.txt: 360x315 on msgbox2_window_;
##   the caption static is set to UIIT_PAG_PARTYMATCH_JOINREQUEST by Create
##   (0x7400c0, string 0xd9d1c8) and the layout is ifpartymatchreqjoin.txt;
## - the fill (0x7403f0) from the server's 0x706d: the PML is
##   UIIT_STT_PARTYMATCH_JOIN_REQUEST with the requester's name; the two
##   mastery icons from the message's two mastery ids (0x73fed0); LEVEL `%d`;
##   RACE CHN / EUR from the model's race byte (0xd9d078 / 0xd9d028); POS the
##   region named through 0x740030 (`%d` of the region id, looked up as text:
##   textzonename's region key); GUILD only when the job state is 4
##   (0x74064d);
## - Confirm sends 1 (0x73fc40), Cancel 0 (0x73fc90), and timer 1, 10 000 ms
##   (0x7406de), sends 2 and closes (0x73fb70).
## Placement: shown through 0x79c330(1), which calls 0x79ac50(0x83) at
## 0x79c39b: window 0x83 centred on the screen (w/2 - ww/2, h/2 - wh/2), READ.

const SIZE := Vector2(360, 315)
const LAYOUT := "resinfo\\ifpartymatchreqjoin.txt"
const TIMEOUT_MS := 10000

## The answer to send: PartyMatchNet.ANSWER_*.
signal answered(code: int)

var request: PartyMatchNet.JoinRequest
var remaining_ms := TIMEOUT_MS
var _done := false

## `race_of_model`: Callable(ref_obj_id) -> 0 / 1 / -1; `zone_name`:
## Callable(region) -> String; `mastery_icon`: Callable(id) -> Texture2D.
func build(builder: UiBuilder, q: PartyMatchNet.JoinRequest, race_of_model: Callable = Callable(),
		zone_name: Callable = Callable(), mastery_icon: Callable = Callable()) -> bool:
	name = "PartyMatchReqJoin"
	request = q
	if not build_shell(builder, SIZE, "UIIT_PAG_PARTYMATCH_JOINREQUEST", "Join request sent", LAYOUT):
		return false
	var who := q.member.member_name if q.member != null else ""
	var line := text("UIIT_STT_PARTYMATCH_JOIN_REQUEST", "<sml2><font color=\"255,239,218,164\">[%s]</font>has requested to join this party.<br> Confirm?</sml2>")
	fill_pml("GDR_PARTYMATCH_REQ_JOIN_DESC_PML", line.replace("%s", who))
	set_static("GDR_PARTYMATCH_REQ_JOIN_LEVEL", "%d" % (q.member.level if q.member != null else 0))
	var race: int = race_of_model.call(q.member.ref_obj_id) if race_of_model.is_valid() and q.member != null else -1
	if race == 0 or race == 1:
		set_static("GDR_PARTYMATCH_REQ_JOIN_RACE", text(PartyMatchNet.RACE_KEYS[race], PartyMatchNet.RACE_FALLBACKS[race]))
	var zone: String = zone_name.call(q.member.region) if zone_name.is_valid() and q.member != null else ""
	set_static("GDR_PARTYMATCH_REQ_JOIN_POS", zone if zone != "" else "%d" % (q.member.region if q.member != null else 0))
	set_static("GDR_PARTYMATCH_REQ_JOIN_GUILD", q.member.guild if q.job_state == PartyNet.JOB_NONE and q.member != null else "")
	for pair in [["GDR_PARTYMATCH_REQ_JOIN_MASTERY_01", q.mastery1], ["GDR_PARTYMATCH_REQ_JOIN_MASTERY_02", q.mastery2]]:
		var holder := node(pair[0])
		var tex: Texture2D = mastery_icon.call(pair[1]) if mastery_icon.is_valid() and int(pair[1]) != 0 else null
		if holder != null and tex != null:
			var icon := TextureRect.new()
			icon.name = "Icon"
			icon.texture = tex
			icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
			icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
			holder.add_child(icon)
	var ok := button("GDR_PARTYMATCH_REQ_JOIN_OK_BTN")
	if ok != null:
		ok.pressed.connect(press_confirm)
	var cancel := button("GDR_PARTYMATCH_REQ_JOIN_CANCEL_BTN")
	if cancel != null:
		cancel.pressed.connect(press_cancel)
	return true

## Confirm sends only with a job id and a requester (0x73fc40 tests +0x7b8
## and +0x7bc); Cancel and the timer have no such test.
func press_confirm() -> void:
	if request == null or request.job_id == 0 or request.requester_jid == 0:
		return
	_answer(PartyMatchNet.ANSWER_CONFIRM)

func press_cancel() -> void:
	_answer(PartyMatchNet.ANSWER_CANCEL)

func _answer(code: int) -> void:
	if _done:
		return
	_done = true
	answered.emit(code)
	close()

func _process(delta: float) -> void:
	advance(int(delta * 1000.0))

## The 10 s timer (0x7406de): at 0, answer 2 and close (0x73fb70).
func advance(ms: int) -> void:
	if _done:
		return
	remaining_ms -= ms
	if remaining_ms <= 0:
		_answer(PartyMatchNet.ANSWER_CLOSED)
