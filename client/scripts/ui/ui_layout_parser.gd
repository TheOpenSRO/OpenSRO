extends RefCounted
class_name UiLayoutParser

## Parser for Silkroad Online UI layout definition files (Media.pk2\resinfo\*.txt).
##
## Parses the "Interface Text" DSL into structured SectionDef and ControlDef objects,
## preserving exact authored pixel positions, sizes, control types, textures, and properties.

class ControlDef:
	var name: String = ""
	var type: String = ""
	var id: int = 0
	var rect: Rect2i = Rect2i()
	var client_rect: Rect2i = Rect2i()
	var ddj: String = ""
	var text: String = ""
	var color: Color = Color.WHITE
	var font_color: Color = Color.WHITE
	var font_index: int = 0
	var halign: int = 0 # 0=left, 1=center, 2=right
	var valign: int = 0 # 0=top, 1=center, 2=bottom
	var style: int = 0
	var stretch_type: int = 0
	var uv_lt: Vector2 = Vector2.ZERO
	var uv_rt: Vector2 = Vector2(1, 0)
	var uv_lb: Vector2 = Vector2(0, 1)
	var uv_rb: Vector2 = Vector2(1, 1)
	var raw_properties: Dictionary = {}

class SectionDef:
	var name: String = ""
	var rect: Rect2i = Rect2i()
	## The trailing field of the section header, kept because it is the
	## only thing in a layout that could select one of `resinfo\base.txt`'s
	## window recipes. -1 when the header does not carry one.
	var base_type: int = -1
	var controls: Array[ControlDef] = []
	var control_by_name: Dictionary = {} # String -> ControlDef
	var control_by_id: Dictionary = {}   # int -> ControlDef

class LayoutDef:
	var sections: Dictionary = {} # String -> SectionDef

	func get_section(section_name: String = "Create") -> SectionDef:
		if sections.has(section_name):
			return sections[section_name]
		if sections.size() > 0:
			return sections.values()[0]
		return null

## Parses the raw text or bytes of a resinfo/*.txt file.
##
## A few layouts guard controls behind C-style `#ifdef` / `#else` / `#endif`
## for optional client features (ifstore's RENEWAL_SHOP_SYSTEM slot set,
## ifequipment's avatar system, ...). By default those directive lines are
## simply skipped and **both** branches are read -- which is what every window
## built so far relies on, since the client resolves the branches by which C++
## class binds each control. Pass `honor_ifdef` with the set of defined symbols
## to instead select branches like a preprocessor, so a window that must show
## exactly one branch (the store's 30-slot grid, not two overlaid) can.
static func parse(data: Variant, honor_ifdef: bool = false,
		defines: PackedStringArray = PackedStringArray()) -> LayoutDef:
	var text := ""
	if data is PackedByteArray:
		var raw: PackedByteArray = data
		if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
			text = raw.slice(2).get_string_from_utf16()
		else:
			text = raw.get_string_from_utf8()
			if text.is_empty() and raw.size() >= 2:
				text = raw.get_string_from_utf16()
	elif data is String:
		text = data

	var layout := LayoutDef.new()
	var lines := text.split("\n")

	var current_section: SectionDef = null
	var current_control: ControlDef = null
	var inside_section := false
	var inside_control := false
	# Preprocessor state, only used when honor_ifdef is on. Each entry:
	# {active, parent_active, seen_true}. `active` already folds in every
	# enclosing level, so a line is emitted when the stack is empty or its top
	# is active. Directive lines are always processed (never emitted) so the
	# stack stays balanced even inside a skipped branch.
	var if_stack: Array = []

	for line in lines:
		var trimmed := line.strip_edges()
		if honor_ifdef and trimmed.begins_with("#"):
			if trimmed.begins_with("#ifdef ") or trimmed.begins_with("#ifndef "):
				var negate := trimmed.begins_with("#ifndef")
				var symbol := trimmed.substr(trimmed.find(" ")).strip_edges()
				var parent_active: bool = if_stack.is_empty() or if_stack[-1]["active"]
				var cond := defines.has(symbol)
				if negate:
					cond = not cond
				var taken: bool = parent_active and cond
				if_stack.append({"active": taken, "parent_active": parent_active, "seen_true": taken})
			elif trimmed == "#else":
				if not if_stack.is_empty():
					var e: Dictionary = if_stack[-1]
					e["active"] = e["parent_active"] and not e["seen_true"]
					e["seen_true"] = e["seen_true"] or e["active"]
			elif trimmed.begins_with("#endif"):
				if not if_stack.is_empty():
					if_stack.pop_back()
			# Any other directive (#define, ...) is ignored, like a comment.
			continue
		if trimmed.is_empty() or trimmed.begins_with("//") or trimmed.begins_with("#"):
			continue
		if honor_ifdef and not (if_stack.is_empty() or if_stack[-1]["active"]):
			continue

		if trimmed.begins_with("Section =") or trimmed.begins_with("Section="):
			var sec := _parse_section_header(trimmed)
			if sec != null:
				current_section = sec
				layout.sections[sec.name] = sec
				inside_section = false
			continue

		if trimmed == "{":
			if current_control != null and not inside_control:
				inside_control = true
			elif current_section != null and not inside_section:
				inside_section = true
			continue

		if trimmed == "}":
			if inside_control:
				inside_control = false
				current_control = null
			elif inside_section:
				inside_section = false
				current_section = null
			continue

		if inside_section and not inside_control:
			# Potential control header: "GDR_NAME:ClassName"
			var colon_idx := trimmed.find(":")
			if colon_idx != -1:
				var c_name := trimmed.substr(0, colon_idx).strip_edges()
				var c_type := trimmed.substr(colon_idx + 1).strip_edges()
				var ctrl := ControlDef.new()
				ctrl.name = c_name
				ctrl.type = c_type
				current_control = ctrl
				current_section.controls.append(ctrl)
				current_section.control_by_name[c_name] = ctrl
			continue

		if inside_control and current_control != null:
			_parse_property(trimmed, current_control)

	return layout

static func _parse_section_header(line: String) -> SectionDef:
	# e.g.: Section = Create,"0,0,0,0","0"
	var eq_idx := line.find("=")
	if eq_idx == -1:
		return null
	var rest := line.substr(eq_idx + 1).strip_edges()
	var parts := rest.split(",")
	if parts.size() == 0:
		return null

	var sec := SectionDef.new()
	sec.name = parts[0].strip_edges().trim_prefix("\"").trim_suffix("\"")
	if parts.size() >= 5:
		var x: int = parts[1].trim_prefix("\"").to_int()
		var y: int = parts[2].to_int()
		var w: int = parts[3].to_int()
		var h: int = parts[4].trim_suffix("\"").to_int()
		sec.rect = Rect2i(x, y, w, h)
	if parts.size() >= 6:
		var tail := parts[5].strip_edges().trim_prefix("\"").trim_suffix("\"")
		if tail.is_valid_int():
			sec.base_type = tail.to_int()
	return sec

static func _parse_property(line: String, ctrl: ControlDef) -> void:
	var eq_idx := line.find("=")
	if eq_idx == -1:
		return
	var key := line.substr(0, eq_idx).strip_edges()
	var val_str := line.substr(eq_idx + 1).strip_edges()

	var comma_idx := val_str.find(",")
	if comma_idx == -1:
		ctrl.raw_properties[key] = val_str
		return

	var type_name := val_str.substr(0, comma_idx).strip_edges()
	var payload := val_str.substr(comma_idx + 1).strip_edges()
	if payload.begins_with("\"") and payload.ends_with("\""):
		payload = payload.substr(1, payload.length() - 2)

	match type_name:
		"RECT":
			var parts := payload.split(",")
			if parts.size() >= 4:
				var r := Rect2i(parts[0].to_int(), parts[1].to_int(), parts[2].to_int(), parts[3].to_int())
				ctrl.raw_properties[key] = r
				if key == "Rect":
					ctrl.rect = r
				elif key == "ClientRect":
					ctrl.client_rect = r
		"POINT":
			var parts := payload.split(",")
			if parts.size() >= 2:
				var p := Vector2(parts[0].to_float(), parts[1].to_float())
				ctrl.raw_properties[key] = p
				match key:
					"UV_LT": ctrl.uv_lt = p
					"UV_RT": ctrl.uv_rt = p
					"UV_LB": ctrl.uv_lb = p
					"UV_RB": ctrl.uv_rb = p
		"COLOR":
			var parts := payload.split(",")
			if parts.size() >= 4:
				# Format in SRO is A, R, G, B
				var a := parts[0].to_int() / 255.0
				var r := parts[1].to_int() / 255.0
				var g := parts[2].to_int() / 255.0
				var b := parts[3].to_int() / 255.0
				var col := Color(r, g, b, a)
				ctrl.raw_properties[key] = col
				if key == "Color":
					ctrl.color = col
				elif key == "FontColor":
					ctrl.font_color = col
		"INTEGER":
			var iv: int = payload.to_int()
			ctrl.raw_properties[key] = iv
			match key:
				"ID":
					ctrl.id = iv
				"FontIndex":
					ctrl.font_index = iv
				"HAlign":
					ctrl.halign = iv
				"VAlign":
					ctrl.valign = iv
				"Style":
					ctrl.style = iv
				"StretchType":
					ctrl.stretch_type = iv
		"STRING":
			ctrl.raw_properties[key] = payload
			match key:
				"DDJ":
					ctrl.ddj = payload.replace("\\\\", "\\")
				"Text":
					ctrl.text = payload
		_:
			ctrl.raw_properties[key] = payload

	if key == "ID" and ctrl.id != 0:
		pass
