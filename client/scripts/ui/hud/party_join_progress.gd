extends PartyMatchBox
class_name PartyJoinProgress

## The requester's joining window, CIFPartyJoinProgress (round 714, lane C2;
## party_gui.md §5, the user's screenshot 09). READ (sro_client.exe):
## - child 100 of the matching window (ifpartymatch.txt's JoinProgress
##   section): 365x149 on msgbox2_window_, caption
##   UIIT_PAG_PARTYMATCH_JOINPROGRESS, layout ifpartyjoinprogress.txt; it is
##   centred on the screen when made (0x7390b0 -> 0x798b70);
## - the text (0x732000, kind 1): UIIT_STT_PARTYMATCH_JOIN_PROGRESS with
##   (the player's own name, the party's name), each `*`-prefixed for a
##   Trade or Thief party (0x739500);
## - timer 1 every 200 ms (0xc8); the gauge is elapsed / 10000.0 ms (the
##   double at 0xdb3720); at 10 s it is full, the timer stops and the window
##   closes (0x7322e0 -> 0x7390b0(0)). A 0xb06d result closes it too
##   (0x8847d0 ends in 0x7390b0 at 0x884a0c; the 0 READ: `push ebx` at 0x884a01, ebx the null tested at 0x8849b8).

const SIZE := Vector2(365, 149)
const LAYOUT := "resinfo\\ifpartyjoinprogress.txt"
const DURATION_MS := 10000.0
const TICK_MS := 200

signal finished

var elapsed_ms := 0
var _tick_acc := 0
var _gauge: TextureProgressBar
var _done := false

func build(builder: UiBuilder, own_name: String, party_name: String) -> bool:
	name = "PartyJoinProgress"
	if not build_shell(builder, SIZE, "UIIT_PAG_PARTYMATCH_JOINPROGRESS", "Joining", LAYOUT):
		return false
	var line := text("UIIT_STT_PARTYMATCH_JOIN_PROGRESS", "<sml2><font color=\"255,239,218,164\">[%s]</font>You <font color=\"255,239,218,164\">[%s]</font> has requested to join this party. </sml2>")
	var bb := _fill_two(sml2_to_bbcode(line).replace("%s", "\u0003"), own_name, party_name)
	fill_pml("GDR_PARTY_JOIN_PROGRESS_DESC_PML", bb)
	_gauge = node("GDR_PARTY_JOIN_PROGRESS_BAR") as TextureProgressBar
	_set_gauge(0.0)
	return true

static func _fill_two(bb: String, a: String, b: String) -> String:
	var i := bb.find("\u0003")
	if i >= 0:
		bb = bb.substr(0, i) + a + bb.substr(i + 1)
	i = bb.find("\u0003")
	if i >= 0:
		bb = bb.substr(0, i) + b + bb.substr(i + 1)
	return bb

func ratio() -> float:
	return clampf(float(elapsed_ms) / DURATION_MS, 0.0, 1.0)

func _set_gauge(r: float) -> void:
	if _gauge != null:
		_gauge.min_value = 0.0
		_gauge.max_value = 1.0
		_gauge.step = 0.0
		_gauge.value = r

func _process(delta: float) -> void:
	advance(int(delta * 1000.0))

## Counts in 200 ms ticks as the client's timer does.
func advance(ms: int) -> void:
	if _done:
		return
	_tick_acc += ms
	while _tick_acc >= TICK_MS and not _done:
		_tick_acc -= TICK_MS
		elapsed_ms += TICK_MS
		_set_gauge(ratio())
		if float(elapsed_ms) >= DURATION_MS:
			finish()

func finish() -> void:
	if _done:
		return
	_done = true
	finished.emit()
	close()
