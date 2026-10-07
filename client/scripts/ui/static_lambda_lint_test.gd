extends SceneTree

## Round 753: no lambda made in an instance context calls a static function of
## its own class by the bare name unless it also uses its instance. Run
## headless on the render box: `client/tools/remote_godot.sh tests`.
##
## Why (MEASURED, Godot 4.2.2, a bare project on the render box, round 752
## and round 753): a lambda captures `self` only when its body names something
## of the instance (`self`, an instance variable, function or signal, a native
## member such as `get_tree()` or `name`, `$Node`, `%Node`). A lambda that
## names only a static of its class is built with a null self, and a bare
## call to that static is compiled as a call on self. So
##
##     btn.pressed.connect(func() -> void: _spin_step(ctrl, step))
##
## made in an instance method, `_spin_step` a `static func`, fails on every
## call with `SCRIPT ERROR: Invalid call. Nonexistent function '_spin_step' in
## base 'Nil'`. That line left the party-match and warehouse page arrows dead
## (r752.md). The probes:
##
## | lambda | result |
## |---|---|
## | bare static call, made in an instance method | fails |
## | the same in a class-level `var` initialiser, or an inner class's method | fails |
## | a bare call to a static of a parent script class | fails |
## | the body also reads a `static var`, a `const` or a captured local | fails |
## | the body also writes a lua-style dict key that names a member | fails |
## | a nested lambda calls it, the outer one uses self | fails (the inner has none) |
## | made in a `static var` initialiser | works |
## | qualified `ClassName._f()` | works |
## | the body (or a lambda nested in it) uses self, a member, a native member, `$`, `%` | works |
## | made in a static func | works |
## | the static referenced, not called (`var c := _f`, `_f.call_deferred()`) | works |
##
## (An inner class's bare call to its outer class's static is a parse error
## in 4.2.2, so it never gets this far.)
##
## The rule this holds: every bare call of a static of the lambda's class (or
## of its script parents) from a lambda made in an
## instance context, in a lambda that names nothing of its instance, is a
## failure. Write `ClassName._f(...)`.
##
## NEGATIVE: the detector is run on snippets holding each banned form and
## must flag exactly those lines; with `_build_spin`'s arrow as it was before
## round 752 (`func() -> void: _spin_step(ctrl, step)`), this suite fails on
## ui_builder.gd.

const SCAN_DIRS := ["res://scripts"]

const KEYWORDS := ["if", "elif", "else", "for", "while", "match", "break", "continue", "pass", "return",
	"class", "class_name", "extends", "is", "in", "as", "self", "signal", "func", "static", "const", "enum",
	"var", "breakpoint", "preload", "await", "yield", "assert", "void", "true", "false", "null", "not", "and",
	"or", "PI", "TAU", "INF", "NAN", "super", "when"]

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_detector()
	_test_client_scripts()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

static var _res_cache := {}

static func _re(pattern: String) -> RegEx:
	if not _res_cache.has(pattern):
		var e := RegEx.new()
		e.compile(pattern)
		_res_cache[pattern] = e
	return _res_cache[pattern]

## `text` with every string's contents and every comment blanked to spaces:
## the same length, line for line, so offsets and line numbers still hold.
static func strip_code(text: String) -> String:
	var out := PackedStringArray()
	var triple := ""
	for ln in text.split("\n"):
		var res := ""
		var i := 0
		var n := ln.length()
		while i < n:
			if triple != "":
				var close := ln.find(triple, i)
				if close < 0:
					res += " ".repeat(n - i)
					i = n
					break
				res += " ".repeat(close - i) + triple
				i = close + 3
				triple = ""
				continue
			var j := -1
			for ch in ["#", "\"", "'"]:
				var k := ln.find(ch, i)
				if k >= 0 and (j < 0 or k < j):
					j = k
			if j < 0:
				res += ln.substr(i)
				break
			res += ln.substr(i, j - i)
			var c := ln[j]
			if c == "#":
				res += " ".repeat(n - j)
				break
			var q3 := ln.substr(j, 3)
			if q3 == "\"\"\"" or q3 == "'''":
				res += q3
				triple = q3
				i = j + 3
				continue
			var k := j + 1
			while k < n and ln[k] != c:
				if ln[k] == "\\":
					k += 1
				k += 1
			k = mini(k, n)
			res += c + " ".repeat(k - j - 1)
			if k < n:
				res += c
			i = k + 1
		out.append(res)
	return "\n".join(out)

static func _indent(line: String) -> int:
	return line.length() - line.lstrip(" \t").length()

static func _new_class(key: String, name: String, parent: String, outer: String) -> Dictionary:
	return {"key": key, "name": name, "parent": parent, "outer": outer, "statics": {}, "members": {},
		"static_names": {}, "inner": {}}

## One script's classes and, per line, its context: [class key, "inst" or
## "static", the line of the declaration the line belongs to].
static func _parse(path: String, code: String, raw: String, classes: Dictionary, globals: Dictionary) -> Dictionary:
	var lines := code.split("\n")
	# A parent named by path is a string, blanked in `code`: it is read from
	# the raw line the stripped one locates.
	var raw_lines := raw.split("\n")
	var top := _new_class(path, "", "RefCounted", "")
	var m := _re("(?m)^class_name\\s+(\\w+)").search(code)
	if m != null:
		top["name"] = m.get_string(1)
		globals[m.get_string(1)] = path
	m = _re("(?m)^extends\\b").search(code)
	if m != null:
		var at := code.substr(0, m.get_start()).count("\n")
		var pm := _re("^extends\\s+([\\w.]+|\"[^\"]*\")").search(raw_lines[at])
		if pm != null:
			top["parent"] = pm.get_string(1)
	classes[path] = top
	var decl_func := _re("^(static\\s+)?func\\s+(\\w+)\\s*\\(")
	var decl_var := _re("^(?:@\\w+(?:\\([^)]*\\))?\\s+)*(static\\s+)?var\\s+(\\w+)")
	var decl_class := _re("^class\\s+(\\w+)(?:\\s+extends\\s+([\\w.]+|\"[^\"]*\"))?\\s*:")
	var stack: Array = [{"indent": -1, "type": "class", "cls": top}]
	var ctx: Array = []
	var decls := {}
	var depth := 0
	for i in lines.size():
		var ln: String = lines[i]
		var s := ln.strip_edges()
		var at_depth := depth
		depth += ln.count("(") + ln.count("[") + ln.count("{") - ln.count(")") - ln.count("]") - ln.count("}")
		depth = maxi(depth, 0)
		if s == "" or at_depth > 0:
			ctx.append(ctx[-1] if not ctx.is_empty() else [path, "static", 0])
			continue
		var ind := _indent(ln)
		while stack.size() > 1 and stack[-1]["indent"] >= ind:
			stack.pop_back()
		var cur: Dictionary = stack[-1]
		if cur["type"] == "func":
			ctx.append([cur["cls"]["key"], cur["kind"], cur["line"]])
			continue
		var cls: Dictionary = cur["cls"]
		m = decl_class.search(raw_lines[i].strip_edges()) if s.begins_with("class ") else null
		if m != null:
			var ic := _new_class(path + "::" + m.get_string(1), m.get_string(1),
				m.get_string(2) if m.get_string(2) != "" else "RefCounted", cls["key"])
			cls["inner"][m.get_string(1)] = ic["key"]
			classes[ic["key"]] = ic
			stack.append({"indent": ind, "type": "class", "cls": ic})
			ctx.append([ic["key"], "static", i])
			continue
		m = decl_func.search(s)
		if m != null:
			var kind := "static" if m.get_string(1) != "" else "inst"
			if kind == "static":
				cls["statics"][m.get_string(2)] = true
			else:
				cls["members"][m.get_string(2)] = true
			stack.append({"indent": ind, "type": "func", "cls": cls, "kind": kind, "line": i})
			ctx.append([cls["key"], kind, i])
			decls[i] = true
			continue
		m = decl_var.search(s)
		if m != null:
			var kind := "static" if m.get_string(1) != "" else "inst"
			if kind == "static":
				cls["static_names"][m.get_string(2)] = true
			else:
				cls["members"][m.get_string(2)] = true
			ctx.append([cls["key"], kind, i])
			continue
		m = _re("^signal\\s+(\\w+)").search(s)
		if m != null:
			cls["members"][m.get_string(1)] = true
		m = _re("^const\\s+(\\w+)").search(s)
		if m != null:
			cls["static_names"][m.get_string(1)] = true
		m = _re("^enum\\s+(\\w+)?\\s*\\{([^}]*)").search(s)
		if m != null:
			if m.get_string(1) != "":
				cls["static_names"][m.get_string(1)] = true
			for v in m.get_string(2).split(","):
				var vn := v.split("=")[0].strip_edges()
				if vn != "":
					cls["static_names"][vn] = true
		ctx.append([cls["key"], "static", i])
	return {"lines": lines, "ctx": ctx, "decls": decls}

static func _resolve(ref: String, from_key: String, classes: Dictionary, globals: Dictionary) -> String:
	if ref.begins_with("\""):
		var p := ref.trim_prefix("\"").trim_suffix("\"")
		return p if classes.has(p) else ""
	var parts := ref.split(".")
	var c := from_key
	while c != "":
		if classes[c]["inner"].has(parts[0]):
			var r: String = classes[c]["inner"][parts[0]]
			for k in range(1, parts.size()):
				r = classes[r]["inner"].get(parts[k], "") if r != "" else ""
			return r
		c = classes[c]["outer"]
	if globals.has(parts[0]):
		var r: String = globals[parts[0]]
		for k in range(1, parts.size()):
			r = classes[r]["inner"].get(parts[k], "") if r != "" else ""
		return r
	return ""

## The class and its script parents, nearest first; the last entry's
## "parent" is the native base.
static func _chain(key: String, classes: Dictionary, globals: Dictionary) -> Array:
	var out: Array = []
	var c := key
	while c != "" and not out.has(c):
		out.append(c)
		var cls: Dictionary = classes[c]
		c = _resolve(cls["parent"], cls["outer"] if cls["outer"] != "" else c, classes, globals)
	return out

static var _native_cache := {}

## Every method, property and signal name of a native class, inherited ones
## included: naming any of them in a lambda captures self.
static func _native_members(cls: String) -> Dictionary:
	if _native_cache.has(cls):
		return _native_cache[cls]
	var names := {}
	if ClassDB.class_exists(cls):
		for mi in ClassDB.class_get_method_list(cls):
			names[mi["name"]] = true
		for pi in ClassDB.class_get_property_list(cls):
			if pi["usage"] & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP | PROPERTY_USAGE_CATEGORY):
				continue
			names[pi["name"]] = true
		for si in ClassDB.class_get_signal_list(cls):
			names[si["name"]] = true
	_native_cache[cls] = names
	return names

## The end of the bracketed text opened at `open` (the index just past it).
static func _close(code: String, open: int) -> int:
	var d := 0
	var q := open
	while q < code.length():
		var ch := code[q]
		if ch == "(" or ch == "[" or ch == "{":
			d += 1
		elif ch == ")" or ch == "]" or ch == "}":
			d -= 1
			if d == 0:
				return q + 1
		q += 1
	return q

static func _names_in(params: String) -> Dictionary:
	var out := {}
	for p in _re("(?:^|,)\\s*(\\w+)").search_all(params):
		out[p.get_string(1)] = true
	return out

## The lambdas of one parsed script: [start, body start, end, line, params].
static func _lambdas(code: String, lines: PackedStringArray, offs: PackedInt32Array, decls: Dictionary) -> Array:
	var out: Array = []
	for m in _re("(?<![\\w.])func\\b").search_all(code):
		var p := m.get_start()
		var li := offs.bsearch(p, false) - 1
		var col := p - offs[li]
		if decls.has(li) and lines[li].substr(0, col).strip_edges() in ["", "static"]:
			continue
		var hm := _re("func\\s*(\\w+)?\\s*\\(").search(code, p)
		if hm == null or hm.get_start() != p:
			continue
		var q := _close(code, hm.get_end() - 1)
		var params := code.substr(hm.get_end(), q - 1 - hm.get_end())
		var rm := _re("\\s*(->\\s*[\\w\\[\\]. ]+?)?\\s*:").search(code, q)
		if rm == null or rm.get_start() != q:
			continue
		q = rm.get_end()
		var eol := code.find("\n", q)
		if eol < 0:
			eol = code.length()
		var e := q
		if code.substr(q, eol - q).strip_edges() != "":
			var d := 0
			while e < code.length():
				var ch := code[e]
				if ch == "(" or ch == "[" or ch == "{":
					d += 1
				elif ch == ")" or ch == "]" or ch == "}":
					if d == 0:
						break
					d -= 1
				elif (ch == "," or ch == "\n") and d == 0:
					break
				e += 1
		else:
			var base := _indent(lines[li])
			var last := li
			for j in range(li + 1, lines.size()):
				if lines[j].strip_edges() == "":
					continue
				if _indent(lines[j]) <= base:
					break
				last = j
			e = offs[last + 1] - 1
		out.append([p, q, e, li, _names_in(params)])
	return out

## Every bare call of a static from a lambda that would run with a null
## self, over `sources` ({res path: text}): [[path, line, callee, line text]].
static func findings(sources: Dictionary) -> Array:
	var classes := {}
	var globals := {}
	var parsed := {}
	var codes := {}
	for path in sources:
		codes[path] = strip_code(sources[path])
		parsed[path] = _parse(path, codes[path], sources[path], classes, globals)
	var out: Array = []
	var ident := _re("(?<![\\w.$%&^])([A-Za-z_]\\w*)")
	var call := _re("(?<![\\w.$%&^])([A-Za-z_]\\w*)\\s*\\(")
	var explicit_self := _re("\\bself\\b|\\bsuper\\b|\\$|(?:^|[(\\[{,=:!<>+\\-*/]|\\b(?:return|and|or|not|in|if|else|elif|while|await))\\s*%[A-Za-z_]")
	for path in sources:
		var code: String = codes[path]
		var lines: PackedStringArray = parsed[path]["lines"]
		var ctx: Array = parsed[path]["ctx"]
		var offs := PackedInt32Array([0])
		for ln in lines:
			offs.append(offs[-1] + ln.length() + 1)
		var lams := _lambdas(code, lines, offs, parsed[path]["decls"])
		for lam in lams:
			var li: int = lam[3]
			if ctx[li][1] != "inst":
				continue
			var chain := _chain(ctx[li][0], classes, globals)
			var statics := {}
			var members := {}
			var static_names := {}
			for c in chain:
				statics.merge(classes[c]["statics"])
				members.merge(classes[c]["members"])
				static_names.merge(classes[c]["static_names"])
				static_names.merge(classes[c]["inner"])
			# An enclosing class's names: its constants and classes are
			# visible here. Its statics are not -- an inner class's bare call
			# to one is a parse error (MEASURED), so the compiler holds that.
			var outer: String = classes[ctx[li][0]]["outer"]
			while outer != "":
				for c in _chain(outer, classes, globals):
					static_names.merge(classes[c]["static_names"])
					static_names.merge(classes[c]["inner"])
					static_names.merge(classes[c]["statics"])
				outer = classes[outer]["outer"]
			var native := _native_members(classes[chain[-1]]["parent"])
			var nested: Array = []
			for l in lams:
				if l != lam and l[0] >= lam[1] and l[2] <= lam[2]:
					nested.append(l)
			var calls: Array = []
			for cm in call.search_all(code, lam[1], lam[2]):
				var inner := false
				for l in nested:
					if cm.get_start() >= l[0] and cm.get_start() < l[2]:
						inner = true
				if not inner and statics.has(cm.get_string(1)):
					calls.append([cm.get_string(1), offs.bsearch(cm.get_start(), false) - 1])
			if calls.is_empty():
				continue
			var body := code.substr(lam[1], lam[2] - lam[1])
			if explicit_self.search(body) != null:
				continue
			# Locals shadow members: the enclosing function's parameters and
			# vars, the lambda's own and its nested lambdas'. Taking too many
			# only flags more.
			var fstart: int = offs[ctx[li][2]]
			var ftxt := code.substr(fstart, lam[2] - fstart)
			var locals: Dictionary = lam[4].duplicate()
			for l in nested:
				locals.merge(l[4])
			for vm in _re("\\b(?:var|for|const)\\s+(\\w+)").search_all(ftxt):
				locals[vm.get_string(1)] = true
			var fm := _re("^\\s*(?:static\\s+)?func\\s+\\w+\\s*\\(").search(ftxt)
			if fm != null:
				locals.merge(_names_in(ftxt.substr(fm.get_end(), _close(ftxt, fm.get_end() - 1) - 1 - fm.get_end())))
			var uses_self := false
			for im in ident.search_all(code, lam[1], lam[2]):
				var nm := im.get_string(1)
				if nm in KEYWORDS or locals.has(nm) or statics.has(nm) or static_names.has(nm) \
						or globals.has(nm) or ClassDB.class_exists(nm):
					continue
				if not members.has(nm) and not native.has(nm):
					continue
				# A lua-style dictionary key (`{name = 1}`) names nothing
				# (MEASURED: it does not capture self).
				var after := code.substr(im.get_end(), 3).strip_edges()
				var before := code.substr(maxi(0, im.get_start() - 64), mini(64, im.get_start())).strip_edges()
				if after.begins_with("=") and not after.begins_with("==") and (before.ends_with("{") or before.ends_with(",")):
					continue
				# A named lambda's own name.
				if before.ends_with("func"):
					continue
				uses_self = true
				break
			if uses_self:
				continue
			for c in calls:
				out.append([path, c[1] + 1, c[0], sources[path].split("\n")[c[1]].strip_edges()])
	return out

func _test_detector() -> void:
	var parent := "\n".join(PackedStringArray([
		"class_name LintParent",
		"extends Control",
		"static func from_parent() -> void:",
		"\tpass",
	]))
	var snippet := "\n".join(PackedStringArray([
		"class_name LintSnippet",                                                          # 1
		"extends \"res://lint_parent.gd\"",                                                # 2
		"static var counter := 0",                                                         # 3
		"const K := 1",                                                                    # 4
		"var member := 0",                                                                 # 5
		"signal changed",                                                                  # 6
		"var on_init := func() -> void: _step(1)",                                         # 7 banned
		"static var on_static := func() -> void: _step(1)",                                # 8
		"static func _step(n: int) -> int:",                                               # 9
		"\treturn n",                                                                      # 10
		"func _build_spin(ctrl: Control, btn: Button, step: int) -> void:",                # 11
		"\tbtn.pressed.connect(func() -> void: _spin_step(ctrl, step))",                   # 12 banned (r752)
		"\tbtn.pressed.connect(func() -> void: LintSnippet._spin_step(ctrl, step))",       # 13
		"\tbtn.pressed.connect(func() -> void:",                                           # 14
		"\t\tcounter += K",                                                                # 15
		"\t\t_step(counter))",                                                             # 16 banned
		"\tbtn.pressed.connect(func() -> void:",                                           # 17
		"\t\tmember += 1",                                                                 # 18
		"\t\t_step(member))",                                                              # 19
		"\tbtn.pressed.connect(func() -> void: changed.emit(_step(1)))",                   # 20
		"\tbtn.pressed.connect(func() -> void: _step(get_index()))",                       # 21
		"\tbtn.pressed.connect(func() -> void: _step(1 if visible else 0))",               # 22
		"\tbtn.pressed.connect(func() -> void: from_parent())",                            # 23 banned
		"\tvar ok := [3, 1].filter(func(v): return _step(v) > 1 and self != null)",        # 24
		"\tvar bad := [3, 1].map(func(v): return {member = _step(v)})",                    # 25 banned
		"\tvar text := \"func(): _step(1)\" % [1]  # func(): _step(2)",                    # 26
		"\tvar fmt := func(v): return _step(\"%d\" %v)",                                   # 27 banned
		"\tvar ref := func(): return _step",                                               # 28
		"\tbtn.pressed.connect(func() -> void:",                                           # 29
		"\t\tvar _x := [1].map(func(v): return v + member)",                               # 30
		"\t\t_step(2))",                                                                   # 31
		"\tbtn.pressed.connect(func() -> void:",                                           # 32
		"\t\tvar _n := name",                                                              # 33
		"\t\t(func() -> void: _step(3)).call())",                                          # 34 banned
		"\tbtn.pressed.connect(func() -> void: $Kid.set_meta(\"n\", _step(1)))",           # 35
		"\tbtn.pressed.connect(func() -> void: %Kid.set_meta(\"n\", _step(1)))",           # 36
		"static func _spin_step(ctrl: Control, step: int) -> void:",                       # 37
		"\tctrl.pressed.connect(func() -> void: _spin_step(ctrl, step))",                  # 38
		"func _local_shadow(visible: bool) -> void:",                                      # 39
		"\tvar cb := func() -> void: _step(1 if visible else 0)",                          # 40 banned
		"class Inner:",                                                                    # 41
		"\tstatic func inner_step() -> void:",                                             # 42
		"\t\tpass",                                                                        # 43
		"\tfunc run() -> void:",                                                           # 44
		"\t\t(func() -> void: inner_step()).call()",                                       # 45 banned
		"\t\t(func() -> void: Inner.inner_step()).call()",                                 # 46
	]))
	var found := findings({"res://lint_snippet.gd": snippet, "res://lint_parent.gd": parent})
	var at := []
	for f in found:
		if f[0] == "res://lint_snippet.gd":
			at.append(f[1])
	at.sort()
	_check(at == [7, 12, 16, 23, 25, 27, 34, 40, 45], ("the detector flags each banned form (an instance " +
		"var's initialiser, r752's spin arrow, a static var and a const only, a parent's static, a lua-style key, " +
		"a %%-format, a nested lambda, a shadowed member, an inner class) and nothing that names self, a member, " +
		"a native member, $ or %%, nor a qualified call, a static func's lambda, a reference, a string or a " +
		"comment (lines %s)") % str(at))
	var callee := ""
	for f in found:
		if f[1] == 12:
			callee = f[2]
	_check(callee == "_spin_step", "it names the static the line calls (%s)" % callee)

func _test_client_scripts() -> void:
	var paths: Array = []
	for d in SCAN_DIRS:
		_collect(d, paths)
	var sources := {}
	for p in paths:
		sources[p] = FileAccess.get_file_as_string(p)
	var t0 := Time.get_ticks_msec()
	var found := findings(sources)
	for f in found:
		print("  %s:%d calls static %s from a lambda with no self: %s" % f)
	_check(found.is_empty(), ("no lambda made in an instance context calls a static by its bare name with no " +
		"self, in %d scripts (%d found, %d ms; write ClassName._f(...))") % [paths.size(), found.size(),
		Time.get_ticks_msec() - t0])
	_check(paths.size() > 400, "the scan saw the client's scripts (%d)" % paths.size())

static func _collect(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
