extends Control
class_name PingFpsCounter

## The Ping / FPS box (round 832, OURS): a private-server add-on the user asked
## for, switched on from the Option window's Extra tab. Retail has no such
## box; every number below is OURS, measured off the user's reference video
## (a 2x capture of the private server: each of its pixels is two there).
##
## - The box is 87 x 54 with a three-line border -- dark, beige, dark, one
##   pixel each -- over a see-through dark fill (the fill's opacity is not
##   measurable off the video; 0.65 is OURS).
## - Two lines of the UI's own font in white: "Ping:" and "FPS:" 14 px in,
##   their values in a second column 46 px in; the lines' cap tops 15 and 33
##   px down.
## - A left press anywhere on it drags it; it stays where it is left (saved),
##   and inside the view.
## - FPS is counted over a half second and shown every half second (the
##   video's box changes about once a second; the user asked for a faster
##   refresh). Ping is the echo time of a request sent every PING_PERIOD_S.

const BOX_SIZE := Vector2(87, 54)
const BORDER_DARK := Color8(40, 40, 35)
const BORDER_LIGHT := Color8(185, 168, 115)
const FILL := Color(0, 0, 0, 0.65)
const TEXT_COLOR := Color(1, 1, 1)
const LABEL_X := 14.0
const VALUE_X := 46.0
const LINE_Y := [13.0, 31.0]
const LINE_H := 16.0
const FPS_PERIOD_S := 0.5
const PING_PERIOD_S := 5.0
## A ping not answered in this long shows as lost (OURS).
const PING_TIMEOUT_S := 15.0
## Where the box sits the first time, from the view's top-right (OURS).
const DEFAULT_FROM_TOP_RIGHT := Vector2(330, 70)

var _values: Array[Label] = []
var _frames := 0
var _fps_t := 0.0
var _ping_t := PING_PERIOD_S
var _token := 0
var _sent := {}   # token -> ticks_msec
var _ping_ms := -1
var _dragging := false
## The network node (NetClient), handed in by World3D -- or found at
## /root/NetClient when it is not; tests hand in their own.
var net: Object = null
var _grab := Vector2.ZERO

func _init() -> void:
	name = "PingFpsCounter"
	size = BOX_SIZE
	custom_minimum_size = BOX_SIZE
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_ARROW
	for i in 2:
		var name_label := _label(["Ping:", "FPS:"][i], LABEL_X, LINE_Y[i])
		add_child(name_label)
		var value := _label("-", VALUE_X, LINE_Y[i])
		add_child(value)
		_values.append(value)

func _label(text: String, x: float, y: float) -> Label:
	var l := Label.new()
	l.text = text
	l.position = Vector2(x, y)
	l.size = Vector2(BOX_SIZE.x - x - 3.0, LINE_H)
	l.add_theme_color_override("font_color", TEXT_COLOR)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _ready() -> void:
	if net == null:
		net = get_node_or_null("/root/NetClient")
	if net != null and not net.is_connected("ping_echo", _on_echo):
		net.connect("ping_echo", _on_echo)
	var saved = ClientSettings.get_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_PING_FPS_POS, null)
	var view := get_viewport_rect().size
	position = clamp_into(saved if saved is Vector2 else Vector2(view.x - DEFAULT_FROM_TOP_RIGHT.x, DEFAULT_FROM_TOP_RIGHT.y), view)
	_show()

func _exit_tree() -> void:
	if net != null and net.is_connected("ping_echo", _on_echo):
		net.disconnect("ping_echo", _on_echo)

func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r.grow(-3.0), FILL)
	draw_rect(Rect2(r.position + Vector2(0.5, 0.5), r.size - Vector2.ONE), BORDER_DARK, false, 1.0)
	draw_rect(Rect2(r.position + Vector2(1.5, 1.5), r.size - Vector2(3, 3)), BORDER_LIGHT, false, 1.0)
	draw_rect(Rect2(r.position + Vector2(2.5, 2.5), r.size - Vector2(5, 5)), BORDER_DARK, false, 1.0)

func _process(delta: float) -> void:
	_frames += 1
	_fps_t += delta
	if _fps_t >= FPS_PERIOD_S:
		_values[1].text = str(fps_of(_frames, _fps_t))
		_frames = 0
		_fps_t = 0.0
	_ping_t += delta
	if _ping_t >= PING_PERIOD_S:
		_ping_t = 0.0
		_ping()

## Frames over seconds, rounded (OURS).
static func fps_of(frames: int, seconds: float) -> int:
	return roundi(float(frames) / seconds) if seconds > 0.0 else 0

func _ping() -> void:
	var now := Time.get_ticks_msec()
	for t in _sent.keys():
		if now - int(_sent[t]) > int(PING_TIMEOUT_S * 1000.0):
			_sent.erase(t)
			_ping_ms = -1
	if net == null or not bool(net.call("is_connected_to_server")):
		_ping_ms = -1
		_show()
		return
	_token = (_token + 1) & 0x7fffffff
	_sent[_token] = now
	net.call("send_ping", _token)
	_show()

func _on_echo(token: int) -> void:
	if not _sent.has(token):
		return
	_ping_ms = Time.get_ticks_msec() - int(_sent[token])
	_sent.erase(token)
	_show()

func _show() -> void:
	_values[0].text = str(_ping_ms) if _ping_ms >= 0 else "-"

func ping_ms() -> int:
	return _ping_ms

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.button_index == MOUSE_BUTTON_LEFT:
		_dragging = mb.pressed
		_grab = mb.position
		if not mb.pressed:
			ClientSettings.set_value(ClientSettings.SECTION_EXTRA, ClientSettings.KEY_PING_FPS_POS, position)
		accept_event()
		return
	var mm := event as InputEventMouseMotion
	if mm != null and _dragging:
		position = clamp_into(position + mm.position - _grab, get_viewport_rect().size)
		accept_event()

## The box's top-left kept inside the view (OURS).
static func clamp_into(at: Vector2, view: Vector2) -> Vector2:
	return Vector2(clampf(at.x, 0.0, maxf(0.0, view.x - BOX_SIZE.x)), clampf(at.y, 0.0, maxf(0.0, view.y - BOX_SIZE.y)))
