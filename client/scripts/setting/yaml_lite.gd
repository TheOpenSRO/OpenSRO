extends RefCounted
class_name YamlLite

## A small, strict reader for the subset of YAML the client's own
## `setting/` files use (round 679, OURS). It is not a YAML library: what it
## does not know it refuses, with the line number, rather than guessing.
##
## What it reads:
##   - block maps by indentation, spaces only:   `key: value` / `key:` + a
##     more-indented block;
##   - block lists of scalars or flow maps:      `- item`;
##   - one-line flow maps and lists:             `{ a: 1, b: x }`, `[1, 2]`
##     (nesting allowed, on the one line);
##   - scalars: "double" (\" \\ \n \t \/ escapes) and 'single' ('' is a quote)
##     quoted strings; plain words; integers (`15779`, `-3`); `true` /
##     `false`; `null` / `~` / nothing -> null;
##   - `#` comments, at the start of a line or after white space;
##   - an optional `---` first line and a UTF-8 byte-order mark.
##
## What it refuses (an error naming the line): tabs in indentation, a key
## given twice in one map, anchors/aliases/tags (`&`, `*`, `!`), multi-line
## strings (`|`, `>`), a flow collection left open at the end of its line,
## an indentation that matches no open block, more than MAX_DEPTH levels,
## and a file over MAX_BYTES.
##
## parse(text) -> {"data": Dictionary} on success, or
##                {"error": "line N: why", "line": N} on failure.
## Maps keep the file's key order (Godot's Dictionary keeps insertion order).

const MAX_BYTES := 256 * 1024
const MAX_DEPTH := 32

class _Line:
	var number := 0
	var indent := 0
	var text := ""

static func parse(text: String) -> Dictionary:
	if text.length() > MAX_BYTES:
		return _error(0, "the file is larger than %d bytes" % MAX_BYTES)
	if text.begins_with("﻿"):
		text = text.substr(1)
	var lines: Array = []
	var raw := text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
	for i in range(raw.size()):
		var s: String = raw[i]
		var number := i + 1
		var body := _strip_comment(s)
		if body.strip_edges() == "":
			continue
		if lines.is_empty() and body.strip_edges() == "---":
			continue
		var indent := 0
		while indent < body.length() and body[indent] == " ":
			indent += 1
		if indent < body.length() and body[indent] == "\t":
			return _error(number, "a tab in the indentation (use spaces)")
		var l := _Line.new()
		l.number = number
		l.indent = indent
		l.text = body.strip_edges()
		lines.append(l)
	if lines.is_empty():
		return {"data": {}}
	var state := {"i": 0, "error": "", "line": 0}
	var first: _Line = lines[0]
	if first.indent != 0:
		return _error(first.number, "the first entry is indented")
	if first.text.begins_with("- ") or first.text == "-":
		return _error(first.number, "the top level must be a map of keys, not a list")
	var data = _block(lines, state, 0, 0)
	if state["error"] != "":
		return {"error": state["error"], "line": state["line"]}
	if int(state["i"]) < lines.size():
		var l: _Line = lines[state["i"]]
		return _error(l.number, "this line's indentation matches no open block")
	return {"data": data}

static func _error(line: int, why: String) -> Dictionary:
	return {"error": ("line %d: %s" % [line, why]) if line > 0 else why, "line": line}

static func _fail(state: Dictionary, line: int, why: String) -> void:
	if state["error"] == "":
		state["error"] = "line %d: %s" % [line, why]
		state["line"] = line

## A block (map or list) whose lines are indented exactly `indent`.
static func _block(lines: Array, state: Dictionary, indent: int, depth: int):
	if depth > MAX_DEPTH:
		var l: _Line = lines[mini(int(state["i"]), lines.size() - 1)]
		_fail(state, l.number, "nested deeper than %d levels" % MAX_DEPTH)
		return null
	var first: _Line = lines[state["i"]]
	if first.text.begins_with("- ") or first.text == "-":
		return _list(lines, state, indent, depth)
	return _map(lines, state, indent, depth)

static func _map(lines: Array, state: Dictionary, indent: int, depth: int) -> Dictionary:
	var out := {}
	while int(state["i"]) < lines.size() and state["error"] == "":
		var l: _Line = lines[state["i"]]
		if l.indent < indent:
			break
		if l.indent > indent:
			_fail(state, l.number, "indented more than the key above it, which has a value already")
			break
		if l.text.begins_with("- ") or l.text == "-":
			_fail(state, l.number, "a list item where a key was expected")
			break
		var kv := _split_key(l.text)
		if kv.has("error"):
			_fail(state, l.number, kv["error"])
			break
		var key: String = kv["key"]
		if out.has(key):
			_fail(state, l.number, "the key '%s' is given twice" % key)
			break
		state["i"] = int(state["i"]) + 1
		var rest: String = kv["rest"]
		if rest == "":
			# A nested block, if the next line is indented further; else null.
			if int(state["i"]) < lines.size() and (lines[state["i"]] as _Line).indent > indent:
				out[key] = _block(lines, state, (lines[state["i"]] as _Line).indent, depth + 1)
			elif int(state["i"]) < lines.size() and (lines[state["i"]] as _Line).indent == indent \
					and ((lines[state["i"]] as _Line).text.begins_with("- ") or (lines[state["i"]] as _Line).text == "-"):
				# YAML lets a map's list sit at the key's own indentation.
				out[key] = _list(lines, state, indent, depth + 1)
			else:
				out[key] = null
		else:
			var v = _value(rest, l.number, state)
			out[key] = v
	return out

static func _list(lines: Array, state: Dictionary, indent: int, depth: int) -> Array:
	var out: Array = []
	while int(state["i"]) < lines.size() and state["error"] == "":
		var l: _Line = lines[state["i"]]
		if l.indent < indent:
			break
		if l.indent > indent:
			_fail(state, l.number, "indented more than the list item above it")
			break
		if not (l.text.begins_with("- ") or l.text == "-"):
			break
		state["i"] = int(state["i"]) + 1
		var rest := l.text.substr(1).strip_edges()
		if rest == "":
			if int(state["i"]) < lines.size() and (lines[state["i"]] as _Line).indent > indent:
				out.append(_block(lines, state, (lines[state["i"]] as _Line).indent, depth + 1))
			else:
				out.append(null)
		elif _split_key(rest).has("key") and not rest.begins_with("{") and not rest.begins_with("[") \
				and not rest.begins_with("\"") and not rest.begins_with("'"):
			_fail(state, l.number, "a map inside a list item: write it as a flow map, - { key: value }")
			break
		else:
			out.append(_value(rest, l.number, state))
	return out

## "key: rest" -> {"key", "rest"}, or {"error"}. The key may be quoted.
static func _split_key(s: String) -> Dictionary:
	var key := ""
	var i := 0
	if s.begins_with("\"") or s.begins_with("'"):
		var q := _quoted(s, 0)
		if q.has("error"):
			return q
		key = q["value"]
		i = int(q["end"])
	else:
		var colon := -1
		for j in range(s.length()):
			if s[j] == ":" and (j + 1 == s.length() or s[j + 1] == " "):
				colon = j
				break
		if colon <= 0:
			return {"error": "expected 'key: value'"}
		key = s.substr(0, colon).strip_edges()
		i = colon
		if _bad_start(key):
			return {"error": "'%s' is not a plain key (anchors, aliases and tags are not read)" % key}
	while i < s.length() and s[i] == " ":
		i += 1
	if i >= s.length() or s[i] != ":":
		return {"error": "expected ':' after the key"}
	if i + 1 < s.length() and s[i + 1] != " ":
		return {"error": "expected a space after ':'"}
	return {"key": key, "rest": s.substr(i + 1).strip_edges()}

static func _bad_start(s: String) -> bool:
	return s.begins_with("&") or s.begins_with("*") or s.begins_with("!") or s.begins_with("%") \
		or s.begins_with("@") or s.begins_with("`")

## A value on one line: a flow collection or a scalar.
static func _value(s: String, line: int, state: Dictionary):
	if s.begins_with("{") or s.begins_with("["):
		var r := _flow(s, 0, line, state, 0)
		if state["error"] != "":
			return null
		var end := int(r["end"])
		if s.substr(end).strip_edges() != "":
			_fail(state, line, "unexpected text after the closing bracket")
			return null
		return r["value"]
	if s.begins_with("|") or s.begins_with(">"):
		_fail(state, line, "multi-line strings ('|' and '>') are not read")
		return null
	var sc = _scalar(s, line, state)
	return sc

static func _scalar(s: String, line: int, state: Dictionary):
	if s.begins_with("\"") or s.begins_with("'"):
		var q := _quoted(s, 0)
		if q.has("error"):
			_fail(state, line, q["error"])
			return null
		if s.substr(int(q["end"])).strip_edges() != "":
			_fail(state, line, "unexpected text after the closing quote")
			return null
		return q["value"]
	if _bad_start(s):
		_fail(state, line, "'%s': anchors, aliases and tags are not read (quote it to mean the text)" % s)
		return null
	return _plain(s)

static func _plain(s: String):
	if s == "" or s == "~" or s == "null" or s == "Null" or s == "NULL":
		return null
	if s == "true" or s == "True" or s == "TRUE":
		return true
	if s == "false" or s == "False" or s == "FALSE":
		return false
	if s.is_valid_int() and not (s.length() > 1 and s.begins_with("0")) and not s.begins_with("+"):
		return s.to_int()
	return s

## A quoted string starting at s[i]: {"value", "end"} or {"error"}.
static func _quoted(s: String, i: int) -> Dictionary:
	var q := s[i]
	var out := ""
	var j := i + 1
	while j < s.length():
		var c := s[j]
		if q == "'" and c == "'":
			if j + 1 < s.length() and s[j + 1] == "'":
				out += "'"
				j += 2
				continue
			return {"value": out, "end": j + 1}
		if q == "\"" and c == "\\":
			if j + 1 >= s.length():
				break
			var e := s[j + 1]
			match e:
				"\"": out += "\""
				"\\": out += "\\"
				"/": out += "/"
				"n": out += "\n"
				"t": out += "\t"
				_:
					return {"error": "unknown escape '\\%s' in a quoted string" % e}
			j += 2
			continue
		if q == "\"" and c == "\"":
			return {"value": out, "end": j + 1}
		out += c
		j += 1
	return {"error": "a quoted string is not closed on its line"}

## A flow map or list starting at s[i]: {"value", "end"}.
static func _flow(s: String, i: int, line: int, state: Dictionary, depth: int) -> Dictionary:
	if depth > MAX_DEPTH:
		_fail(state, line, "nested deeper than %d levels" % MAX_DEPTH)
		return {"value": null, "end": s.length()}
	var is_map := s[i] == "{"
	var close := "}" if is_map else "]"
	var out_map := {}
	var out_list: Array = []
	var j := i + 1
	var expect_item := true
	while true:
		while j < s.length() and s[j] == " ":
			j += 1
		if j >= s.length():
			_fail(state, line, "'%s' is not closed on its line" % s[i])
			return {"value": null, "end": j}
		if s[j] == close:
			return {"value": out_map if is_map else out_list, "end": j + 1}
		if not expect_item:
			if s[j] != ",":
				_fail(state, line, "expected ',' or '%s'" % close)
				return {"value": null, "end": j}
			j += 1
			expect_item = true
			continue
		if is_map:
			# key
			var key := ""
			if s[j] == "\"" or s[j] == "'":
				var q := _quoted(s, j)
				if q.has("error"):
					_fail(state, line, q["error"])
					return {"value": null, "end": j}
				key = q["value"]
				j = int(q["end"])
			else:
				var k := j
				while k < s.length() and s[k] != ":" and s[k] != "," and s[k] != close:
					k += 1
				key = s.substr(j, k - j).strip_edges()
				j = k
				if key == "" or _bad_start(key):
					_fail(state, line, "expected a key in the flow map")
					return {"value": null, "end": j}
			while j < s.length() and s[j] == " ":
				j += 1
			if j >= s.length() or s[j] != ":":
				_fail(state, line, "expected ':' after '%s' in the flow map" % key)
				return {"value": null, "end": j}
			j += 1
			if out_map.has(key):
				_fail(state, line, "the key '%s' is given twice" % key)
				return {"value": null, "end": j}
			var v := _flow_item(s, j, close, line, state, depth)
			if state["error"] != "":
				return {"value": null, "end": s.length()}
			out_map[key] = v["value"]
			j = int(v["end"])
		else:
			var v := _flow_item(s, j, close, line, state, depth)
			if state["error"] != "":
				return {"value": null, "end": s.length()}
			out_list.append(v["value"])
			j = int(v["end"])
		expect_item = false
	return {"value": null, "end": j}

## One value inside a flow collection, ending before ',' or the closer.
static func _flow_item(s: String, j: int, close: String, line: int, state: Dictionary, depth: int) -> Dictionary:
	while j < s.length() and s[j] == " ":
		j += 1
	if j < s.length() and (s[j] == "{" or s[j] == "["):
		return _flow(s, j, line, state, depth + 1)
	if j < s.length() and (s[j] == "\"" or s[j] == "'"):
		var q := _quoted(s, j)
		if q.has("error"):
			_fail(state, line, q["error"])
			return {"value": null, "end": s.length()}
		return {"value": q["value"], "end": q["end"]}
	var k := j
	while k < s.length() and s[k] != "," and s[k] != close:
		if s[k] == "{" or s[k] == "[" or s[k] == "}" or s[k] == "]":
			_fail(state, line, "unexpected '%s' in a flow value" % s[k])
			return {"value": null, "end": s.length()}
		k += 1
	var word := s.substr(j, k - j).strip_edges()
	if _bad_start(word):
		_fail(state, line, "'%s': anchors, aliases and tags are not read (quote it to mean the text)" % word)
		return {"value": null, "end": s.length()}
	return {"value": _plain(word), "end": k}

## The line without its comment: a '#' at the start or after white space,
## outside quotes.
static func _strip_comment(s: String) -> String:
	var in_q := ""
	var i := 0
	while i < s.length():
		var c := s[i]
		if in_q != "":
			if c == "\\" and in_q == "\"":
				i += 2
				continue
			if c == in_q:
				in_q = ""
			i += 1
			continue
		if c == "\"" or c == "'":
			# A quote opens a string only where a value can start.
			if i == 0 or s[i - 1] in [" ", ":", "{", "[", ",", "-"]:
				in_q = c
		elif c == "#" and (i == 0 or s[i - 1] == " " or s[i - 1] == "\t"):
			return s.substr(0, i)
		i += 1
	return s
