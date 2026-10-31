extends RefCounted
class_name NativeGuiCensus

## Round 848: what a running client shows of Godot's own GUI -- MEASURED from
## the live tree, not read off the source. `census(root)` walks every Control
## and every popup Window under `root` and returns one line for each that a
## player can see:
##
##   - a native widget (NATIVE_CLASSES, by exact class: a TextureButton is the
##     original's art and is not listed), with whether its look is Godot's
##     default theme (no stylebox override for "normal"/"panel"/"tab_selected")
##     or restyled;
##   - a text node (Label, RichTextLabel, Button, LineEdit) whose font resolves
##     to Godot's own (ThemeDB.fallback_font, through a FontVariation guard if
##     there is one) rather than the archive's face UiBuilder loads.
##
## Used by World3D's OPENSRO_QA_INPUT `nativecensus` action (QA only; it
## prints `QA NATIVE ...` lines) and by native_gui848_test.gd.

## Godot's own widgets, by get_class(). A popup Window (PopupMenu, the
## dialogs) is a Window, not a Control, and is walked separately.
const NATIVE_CLASSES := [
	"Button", "LineEdit", "TextEdit", "OptionButton", "ItemList", "SpinBox",
	"HSlider", "VSlider", "CheckBox", "CheckButton", "TabContainer", "TabBar",
	"ScrollContainer", "PanelContainer", "Panel", "MenuButton", "HScrollBar",
	"VScrollBar", "ColorPickerButton", "LinkButton",
]
const NATIVE_WINDOWS := ["PopupMenu", "ConfirmationDialog", "AcceptDialog", "PopupPanel", "Popup", "FileDialog"]

## The stylebox that says whether a widget was restyled: one of these with an
## override means somebody gave it art; none means Godot's default theme.
const _STYLE_NAMES := [&"normal", &"panel", &"tab_selected", &"background", &"slider", &"scroll"]

## The font a text node draws with, past UiBuilder's FontVariation guard.
static func base_font(f: Font) -> Font:
	var seen := 0
	while f is FontVariation and (f as FontVariation).base_font != null and seen < 8:
		f = (f as FontVariation).base_font
		seen += 1
	return f

## Whether `c` draws its text in Godot's own font.
static func uses_default_font(c: Control) -> bool:
	var font_name := &"normal_font" if c is RichTextLabel else &"font"
	var f := base_font(c.get_theme_font(font_name))
	return f == null or f == ThemeDB.fallback_font or f == base_font(ThemeDB.get_default_theme().default_font)

static func is_text(c: Control) -> bool:
	return c is Label or c is RichTextLabel or c is Button or c is LineEdit or c is TextEdit

## Whether `c` is drawn in Godot's default theme: no override of the
## stylebox its class draws its body with.
static func default_styled(c: Control) -> bool:
	for s in _STYLE_NAMES:
		if c.has_theme_stylebox_override(s):
			return false
	if c.theme != null:
		return false
	return true

static func _short(t: String) -> String:
	t = t.replace("\n", " / ")
	return t if t.length() <= 40 else t.substr(0, 37) + "..."

static func _text_of(c: Control) -> String:
	if c is Label:
		return (c as Label).text
	if c is RichTextLabel:
		return (c as RichTextLabel).get_parsed_text()
	if c is Button:
		return (c as Button).text
	if c is LineEdit:
		return (c as LineEdit).text if (c as LineEdit).text != "" else (c as LineEdit).placeholder_text
	return ""

## One line per native widget or default-font text a player can see under
## `root`. A Control counts when it is visible in the tree and its rect meets
## the viewport.
static func census(root: Node) -> PackedStringArray:
	var out := PackedStringArray()
	if root == null:
		return out
	var view := Rect2(Vector2.ZERO, Vector2(1e6, 1e6))
	if root.get_viewport() != null:
		view = root.get_viewport().get_visible_rect()
	for node in root.find_children("*", "Control", true, false):
		var c := node as Control
		if not c.is_visible_in_tree():
			continue
		var rect := c.get_global_rect()
		if rect.size.x <= 0.0 or rect.size.y <= 0.0 or not view.intersects(rect):
			continue
		var cls := c.get_class()
		var native := cls in NATIVE_CLASSES
		var default_font := is_text(c) and _text_of(c) != "" and uses_default_font(c)
		if not native and not default_font:
			continue
		out.append("%s<%s> rect=%s native=%s default_theme=%s default_font=%s text='%s'" % [
			c.get_path(), cls, rect, native, native and default_styled(c), default_font, _short(_text_of(c))])
	for node in root.find_children("*", "Window", true, false):
		var w := node as Window
		if w.visible and w.get_class() in NATIVE_WINDOWS:
			out.append("%s<%s> window at %s size %s" % [w.get_path(), w.get_class(), w.position, w.size])
	return out
