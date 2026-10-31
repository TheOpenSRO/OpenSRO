extends RefCounted
class_name MdToPml

## Our bundled Markdown docs as the client's PML markup (round 848, lane H),
## for the Help window's CIFPML (HelpWindow, PmlText). OURS throughout: the
## original's game guide drew its own authored PML pages, and these documents
## are this project's. The markup uses only what PmlText draws (READ in round
## 845: `<sml2>`, `<br>`, `<strong>`, `<font color>`), in the original's own
## style -- headings in the quest texts' header orange, `<strong>` and
## (226, 74, 0) (MEASURED in textquest_otherstring's markup, round 845).
##
## - `#`..`######` headings: one bold orange line;
## - `**bold**` / `__bold__`: `<strong>`; `*italic*` / `_italic_`, `` `code` ``
##   and fenced code: their text, plain (PML has no italic or monospace);
## - `- `, `* `, `+ ` bullets: "· " and the text; `1. ` items kept as written;
## - `[text](url)`: "text (url)";
## - tables: one line a row, its cells two spaces apart, the separator row
##   dropped (a proportional face cannot line columns up);
## - a horizontal rule: an empty line.
## A `<` or `>` in the text would open a PML tag, so they become `‹` and `›`.

const HEADING_COLOUR := "255,226,74,0"

## A paragraph's lines are joined with a space (Markdown's soft breaks), so
## the PML wraps the text at its own width; a blank line ends a paragraph.
static func convert(md: String) -> String:
	# Arrays, not PackedStringArrays: _flush changes them in place, and a
	# packed array is passed by value.
	var out: Array[String] = []
	var para: Array[String] = []
	var in_fence := false
	for raw in md.replace("\r\n", "\n").replace("\r", "\n").split("\n"):
		var line := raw as String
		if line.strip_edges().begins_with("```"):
			_flush(out, para)
			in_fence = not in_fence
			continue
		if in_fence:
			out.append(_escape(line))
			continue
		var stripped := line.strip_edges()
		if stripped == "":
			_flush(out, para)
			out.append("")
			continue
		if stripped.begins_with("|"):
			_flush(out, para)
			if _is_table_separator(stripped):
				continue
			var cells: PackedStringArray = []
			for cell in stripped.trim_prefix("|").trim_suffix("|").split("|"):
				cells.append(_inline((cell as String).strip_edges()))
			out.append("  ".join(cells))
			continue
		if stripped.begins_with("#"):
			# A heading is a line of its own.
			_flush(out, para)
			out.append(_line(stripped))
			continue
		if _starts_block(stripped):
			_flush(out, para)
		para.append(_line(stripped))
	_flush(out, para)
	return "<sml2>" + "<br>".join(PackedStringArray(out)) + "</sml2>"

## A heading, a list item or a rule starts a line of its own.
static func _starts_block(s: String) -> bool:
	if s.begins_with("#") or s.begins_with("- ") or s.begins_with("* ") or s.begins_with("+ "):
		return true
	if s == "---" or s == "***" or s == "___":
		return true
	var dot := s.find(". ")
	return dot > 0 and dot <= 3 and s.substr(0, dot).is_valid_int()

static func _flush(out: Array[String], para: Array[String]) -> void:
	if not para.is_empty():
		out.append(" ".join(PackedStringArray(para)))
		para.clear()

static func _line(stripped: String) -> String:
	var hashes := 0
	while hashes < stripped.length() and stripped[hashes] == "#":
		hashes += 1
	if hashes > 0 and hashes <= 6 and hashes < stripped.length() and stripped[hashes] == " ":
		return "<strong><font color=\"%s\">%s</font></strong>" % [HEADING_COLOUR, _inline(stripped.substr(hashes + 1).strip_edges())]
	if stripped.begins_with("- ") or stripped.begins_with("* ") or stripped.begins_with("+ "):
		return "· " + _inline(stripped.substr(2))
	if stripped == "---" or stripped == "***" or stripped == "___":
		return ""
	return _inline(stripped)

## Inline spans: code first (its text kept as is), then links, bold, italic.
static func _inline(text: String) -> String:
	var out := ""
	var i := 0
	while i < text.length():
		var c := text[i]
		if c == "`":
			var close := text.find("`", i + 1)
			if close > i:
				out += _escape(text.substr(i + 1, close - i - 1))
				i = close + 1
				continue
		elif c == "[":
			var end_txt := text.find("]", i + 1)
			if end_txt > i and end_txt + 1 < text.length() and text[end_txt + 1] == "(":
				var end_url := text.find(")", end_txt + 2)
				if end_url > end_txt:
					out += "%s (%s)" % [_inline(text.substr(i + 1, end_txt - i - 1)), _escape(text.substr(end_txt + 2, end_url - end_txt - 2))]
					i = end_url + 1
					continue
		elif (c == "*" or c == "_") and i + 1 < text.length() and text[i + 1] == c:
			var close := text.find(c + c, i + 2)
			if close > i:
				out += "<strong>%s</strong>" % _inline(text.substr(i + 2, close - i - 2))
				i = close + 2
				continue
		elif c == "*" or (c == "_" and (i == 0 or text[i - 1] == " ")):
			var close := text.find(c, i + 1)
			if close > i + 1:
				out += _inline(text.substr(i + 1, close - i - 1))
				i = close + 1
				continue
		out += _escape(c)
		i += 1
	return out

static func _is_table_separator(line: String) -> bool:
	if not line.contains("-"):
		return false
	for c in line:
		if c != "-" and c != ":" and c != "|" and c != " ":
			return false
	return true

static func _escape(text: String) -> String:
	return text.replace("<", "‹").replace(">", "›")
