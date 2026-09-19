extends RefCounted
class_name MdToBbcode

## A small, deliberately limited Markdown -> BBCode converter for the in-client
## Help window's RichTextLabel. It covers what our bundled help docs actually
## use -- headings, bold/italic, inline and fenced code, bullet/numbered
## lists, links (as plain "text (url)"), and tables (as monospace rows) --
## and nothing more. It is srrevamp's own code; the original client showed
## help through an embedded Internet Explorer control, which Godot has no
## equivalent for, so this renders our Markdown natively instead.
##
## Kept pure and static so it is tested headless (md_to_bbcode_test.gd).

## Converts markdown to BBCode for a RichTextLabel with bbcode_enabled.
static func convert(md: String) -> String:
	var out: PackedStringArray = []
	var lines := md.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	var in_fence := false
	var fence: PackedStringArray = []
	var table: PackedStringArray = []

	for raw in lines:
		var line := raw as String

		# Fenced code blocks: everything between ``` lines is verbatim.
		if line.strip_edges().begins_with("```"):
			if in_fence:
				out.append("[code]%s[/code]" % _escape("\n".join(fence)))
				fence = []
				in_fence = false
			else:
				in_fence = true
			continue
		if in_fence:
			fence.append(line)
			continue

		# Tables: consecutive lines that start with "|". Rendered as aligned
		# monospace rows, the separator row (---) dropped.
		if line.strip_edges().begins_with("|"):
			table.append(line)
			continue
		elif not table.is_empty():
			out.append(_render_table(table))
			table = []

		out.append(_convert_line(line))

	if not table.is_empty():
		out.append(_render_table(table))
	if in_fence:
		# An unterminated fence still shows its content rather than vanishing.
		out.append("[code]%s[/code]" % _escape("\n".join(fence)))

	return "\n".join(out)

## One non-fence, non-table line.
static func _convert_line(line: String) -> String:
	var trimmed := line.strip_edges(true, false) # keep trailing, trim leading
	var stripped := line.strip_edges()

	# Headings: # .. ###### -> a sized, bold line.
	var hashes := 0
	while hashes < stripped.length() and stripped[hashes] == "#":
		hashes += 1
	if hashes > 0 and hashes <= 6 and hashes < stripped.length() and stripped[hashes] == " ":
		var text := stripped.substr(hashes + 1).strip_edges()
		var sizes := [26, 22, 19, 17, 16, 15]
		return "[font_size=%d][b]%s[/b][/font_size]" % [sizes[hashes - 1], _inline(text)]

	# Bullet list: -, * or + followed by a space.
	if stripped.begins_with("- ") or stripped.begins_with("* ") or stripped.begins_with("+ "):
		return "  • " + _inline(stripped.substr(2))

	# Numbered list: "1. text".
	var dot := stripped.find(". ")
	if dot > 0 and dot <= 3 and stripped.substr(0, dot).is_valid_int():
		return "  %s. %s" % [stripped.substr(0, dot), _inline(stripped.substr(dot + 2))]

	# Horizontal rule.
	if stripped == "---" or stripped == "***" or stripped == "___":
		return "[color=#666666]────────────────────[/color]"

	if stripped == "":
		return ""
	return _inline(trimmed)

## Inline spans within a line: code, bold, italic, links. Order matters --
## code first so its contents are not re-parsed.
static func _inline(text: String) -> String:
	var out := ""
	var i := 0
	while i < text.length():
		var c := text[i]
		if c == "`":
			var close := text.find("`", i + 1)
			if close > i:
				out += "[code]%s[/code]" % _escape(text.substr(i + 1, close - i - 1))
				i = close + 1
				continue
		elif c == "[":
			# A link [text](url) -> "text (url)"; a bare [ is escaped.
			var end_txt := text.find("]", i + 1)
			if end_txt > i and end_txt + 1 < text.length() and text[end_txt + 1] == "(":
				var end_url := text.find(")", end_txt + 2)
				if end_url > end_txt:
					var label := text.substr(i + 1, end_txt - i - 1)
					var url := text.substr(end_txt + 2, end_url - end_txt - 2)
					out += "%s ([color=#8fb7ff]%s[/color])" % [_inline(label), _escape(url)]
					i = end_url + 1
					continue
			out += "[lb]"
			i += 1
			continue
		elif c == "]":
			out += "[rb]"
			i += 1
			continue
		elif (c == "*" or c == "_") and i + 1 < text.length() and text[i + 1] == c:
			# Bold: **x** or __x__.
			var marker := c + c
			var close := text.find(marker, i + 2)
			if close > i:
				out += "[b]%s[/b]" % _inline(text.substr(i + 2, close - i - 2))
				i = close + 2
				continue
		elif c == "*" or c == "_":
			# Italic: *x* or _x_ (single marker).
			var close := text.find(c, i + 1)
			if close > i:
				out += "[i]%s[/i]" % _inline(text.substr(i + 1, close - i - 1))
				i = close + 1
				continue
		out += c
		i += 1
	return out

## Renders a run of "| a | b |" lines as aligned monospace rows. The
## separator row (all dashes/colons/pipes/spaces) is dropped.
static func _render_table(rows: PackedStringArray) -> String:
	var grid: Array = []
	for row in rows:
		var trimmed := (row as String).strip_edges()
		if _is_table_separator(trimmed):
			continue
		# Drop the leading/trailing pipe, then split.
		if trimmed.begins_with("|"):
			trimmed = trimmed.substr(1)
		if trimmed.ends_with("|"):
			trimmed = trimmed.substr(0, trimmed.length() - 1)
		var cells: PackedStringArray = []
		for cell in trimmed.split("|"):
			cells.append((cell as String).strip_edges())
		grid.append(cells)
	if grid.is_empty():
		return ""

	var widths: PackedInt32Array = []
	for cells in grid:
		for ci in range((cells as PackedStringArray).size()):
			var w := (cells[ci] as String).length()
			if ci >= widths.size():
				widths.append(w)
			elif w > widths[ci]:
				widths[ci] = w

	var out: PackedStringArray = []
	for cells in grid:
		var parts: PackedStringArray = []
		for ci in range((cells as PackedStringArray).size()):
			parts.append((cells[ci] as String).rpad(widths[ci]))
		out.append("  " + "  ".join(parts).strip_edges(false, true))
	return "[code]%s[/code]" % _escape("\n".join(out))

static func _is_table_separator(line: String) -> bool:
	if not line.contains("-"):
		return false
	for c in line:
		if c != "-" and c != ":" and c != "|" and c != " ":
			return false
	return true

## Escapes text that must appear verbatim (code spans, urls) so a stray
## bracket is not read as BBCode. One pass, so the "[" in an inserted "[lb]"
## is not itself re-escaped (the reason a two-replace version is wrong).
static func _escape(text: String) -> String:
	var out := ""
	for c in text:
		if c == "[":
			out += "[lb]"
		elif c == "]":
			out += "[rb]"
		else:
			out += c
	return out
