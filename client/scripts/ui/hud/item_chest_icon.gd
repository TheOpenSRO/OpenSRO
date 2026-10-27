extends TextureButton
class_name ItemChestIcon

## Round 837 (OURS): the item chest's button under the minimap (the user: "an
## item chest icon below the minimap that opens the item chest"). Not retail
## (ItemChestWindow's header). Labels: READ, MEASURED, INFERRED, OURS.
##
## **Art (MEASURED):** the player's Media.pk2 carries vPlus's
## `vplus\iconpng\chesticon_{normal,focus,press,disabled}.ddj` -- 40 x 40
## images that are **PNG files** under a `.ddj` name (their first bytes are
## the PNG signature, not "JMXVDDJ 1000"), so they are decoded as PNG here.
## Without them: MaxiGuard's `maxiguard\icon\chest\icon_default.png` /
## `_hover` / `_press` (40 x 40 PNG), then the retail item icon
## `icon\item\etc\e050618_treasurebox.ddj` (OURS choice).
##
## **Place (OURS, on the client's own grid):** retail's alarm column
## (CAlramGuideMgrWnd) is anchored at (screen width - 6, 180) with one 40 x 40
## icon every 42 px to the left (READ, QuestInfoGuide: 0x79f2a3..0x79f2b6,
## 0x65c430), just under the minimap's opaque art (rows 0..171, World3D.
## place_minimap). MaxiGuard places its own extra icons the same way
## (`maxiguard\menu\extraicons.json`: 40 x 40 at xpaddingright 46 / 88,
## ypaddingtop 176, MEASURED). How vPlus places its chest icon is in its
## packed DLL and not read. The chest takes the column's **second** slot,
## (width - 90, 180), so the quest-information icon keeps the first.
##
## **Alert (OURS):** while something new waits in the chest (0x00D6 heard
## with the window closed) the icon pulses -- its art and a brightened copy
## every 500 ms, the alarm icons' own cadence (QuestInfoGuide.FRAME_MS) --
## until the window is opened.

const ObjectLoader = preload("res://scripts/assets/object_loader.gd")

const VPLUS := ["vplus\\iconpng\\chesticon_normal.ddj", "vplus\\iconpng\\chesticon_focus.ddj",
	"vplus\\iconpng\\chesticon_press.ddj", "vplus\\iconpng\\chesticon_disabled.ddj"]
const MAXIGUARD := ["maxiguard\\icon\\chest\\icon_default.png", "maxiguard\\icon\\chest\\icon_hover.png",
	"maxiguard\\icon\\chest\\icon_press.png", ""]
const FALLBACK := "icon\\item\\etc\\e050618_treasurebox.ddj"
const ICON_SIZE := Vector2(40, 40)
## The alarm column's anchor (READ) and the slot this icon takes (OURS).
const ANCHOR_RIGHT_INSET := 6.0
const ANCHOR_Y := 180.0
const STEP_X := 42.0
const SLOT := 1
const BLINK_MS := 500
const GLOW := Color(1.6, 1.45, 1.0)
const TOOLTIP := ["VPLUS_UI_CHEST_CAPTION_TEXT", "Chest"]

## The window this icon opens (and whose alert it shows).
var window: ItemChestWindow
## The node the window opens under (HudPanels).
var host: Node
## Which art was found: "vplus", "maxiguard", "retail" or "".
var art_source := ""
var blink_on := false
var _s := 0.0

func _init(builder: UiBuilder = null) -> void:
	name = "ItemChestIcon"
	ignore_texture_size = true
	stretch_mode = TextureButton.STRETCH_SCALE
	focus_mode = Control.FOCUS_NONE
	mouse_filter = Control.MOUSE_FILTER_STOP
	size = ICON_SIZE
	custom_minimum_size = ICON_SIZE
	if builder != null:
		_load_art(builder)
		var table := builder.text_table()
		tooltip_text = table.get_text(TOOLTIP[0]) if table != null and table.has(TOOLTIP[0]) else TOOLTIP[1]
	else:
		tooltip_text = TOOLTIP[1]
	pressed.connect(_on_pressed)

## Connects the icon to its window: a press toggles it, the alert pulses it.
func bind(chest: ItemChestWindow, parent: Node) -> void:
	window = chest
	host = parent
	if chest != null and not chest.alert_changed.is_connected(set_alert):
		chest.alert_changed.connect(set_alert)
	set_alert(chest != null and chest.alert)

func _on_pressed() -> void:
	if window != null:
		window.toggle(host)

## Anchored to the top-right corner of a full-screen parent: the alarm
## column's slot SLOT, (width - 6 - 42 (SLOT + 1), 180), 40 x 40, in UI units.
static func place(icon: Control) -> void:
	icon.anchor_left = 1.0
	icon.anchor_right = 1.0
	icon.anchor_top = 0.0
	icon.anchor_bottom = 0.0
	icon.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	icon.grow_vertical = Control.GROW_DIRECTION_END
	var x := -ANCHOR_RIGHT_INSET - STEP_X * float(SLOT + 1)
	icon.offset_left = x
	icon.offset_right = x + ICON_SIZE.x
	icon.offset_top = ANCHOR_Y
	icon.offset_bottom = ANCHOR_Y + ICON_SIZE.y

## Where `place` puts it on a `view`-sized screen.
static func slot_position(view: Vector2) -> Vector2:
	return Vector2(view.x - ANCHOR_RIGHT_INSET - STEP_X * float(SLOT + 1), ANCHOR_Y)

func _load_art(builder: UiBuilder) -> void:
	var sets := [["vplus", VPLUS], ["maxiguard", MAXIGUARD]]
	for s in sets:
		var paths: Array = s[1]
		var normal := load_image_texture(builder, paths[0])
		if normal == null:
			continue
		texture_normal = normal
		texture_hover = load_image_texture(builder, paths[1])
		texture_pressed = load_image_texture(builder, paths[2])
		texture_disabled = load_image_texture(builder, paths[3])
		art_source = s[0]
		return
	var tex := builder.load_texture(FALLBACK)
	if tex != null:
		texture_normal = tex
		art_source = "retail"

## An archive file as a texture: PNG bytes (whatever the name says) through
## Godot's PNG loader, anything else through the DDJ reader.
static func load_image_texture(builder: UiBuilder, path: String) -> Texture2D:
	if builder == null or path == "":
		return null
	var pk2: Pk2Reader = builder.get("_media_pk2")
	if pk2 == null:
		return null
	var entry := ObjectLoader.find_file(pk2, path.to_lower())
	if entry == null:
		return null
	var data := pk2.read_file(entry)
	if data.size() >= 8 and data.slice(0, 8) == PackedByteArray([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]):
		var img := Image.new()
		if img.load_png_from_buffer(data) != OK:
			return null
		return ImageTexture.create_from_image(img)
	return builder.load_texture(path)

var alert := false

func _ready() -> void:
	set_process(alert)

func set_alert(on: bool) -> void:
	alert = on
	set_process(on)
	_s = 0.0
	blink_on = on
	_show_blink()

func alerting() -> bool:
	return alert

func _process(delta: float) -> void:
	advance_seconds(delta)

## `seconds` on: the glow flips every BLINK_MS.
func advance_seconds(seconds: float) -> void:
	if not alert:
		return
	_s += maxf(seconds, 0.0)
	var period := float(BLINK_MS) / 1000.0
	while _s >= period - 1e-9:
		_s = maxf(_s - period, 0.0)
		blink_on = not blink_on
	_show_blink()

func _show_blink() -> void:
	self_modulate = GLOW if alert and blink_on else Color(1, 1, 1)
