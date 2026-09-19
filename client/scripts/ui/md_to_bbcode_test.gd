extends SceneTree

## Tests for the Help window's Markdown -> BBCode converter. Headless: the
## conversion is pure string work, so it needs no window and no render.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _has(haystack: String, needle: String, msg: String) -> void:
	_check(haystack.contains(needle), "%s -- got: %s" % [msg, haystack])

func _test_headings() -> void:
	var out := MdToBbcode.convert("# Title")
	_has(out, "[b]Title[/b]", "h1 is bold")
	_has(out, "[font_size=26]", "h1 is the largest size")
	_has(MdToBbcode.convert("### Sub"), "[font_size=19]", "h3 is a middle size")
	# A '#' not followed by a space is not a heading.
	_check(not MdToBbcode.convert("#nothash").contains("[b]"), "no space after # is not a heading")

func _test_inline() -> void:
	_has(MdToBbcode.convert("a **bold** b"), "[b]bold[/b]", "bold")
	_has(MdToBbcode.convert("a __bold__ b"), "[b]bold[/b]", "bold with underscores")
	_has(MdToBbcode.convert("a *it* b"), "[i]it[/i]", "italic")
	_has(MdToBbcode.convert("run `code` span"), "[code]code[/code]", "inline code")
	# Code contents are not re-parsed as markdown.
	_has(MdToBbcode.convert("`**not bold**`"), "[code]**not bold**[/code]", "code is verbatim")

func _test_links() -> void:
	var out := MdToBbcode.convert("see [the docs](http://x/y) now")
	_has(out, "the docs", "link label kept")
	_has(out, "http://x/y", "link url kept as text")
	_check(not out.contains("[url"), "no [url] tag (links are plain text)")

func _test_lists() -> void:
	_has(MdToBbcode.convert("- one"), "• one", "bullet with dash")
	_has(MdToBbcode.convert("* two"), "• two", "bullet with star")
	_has(MdToBbcode.convert("1. first"), "1. first", "numbered list kept")

func _test_fence() -> void:
	var out := MdToBbcode.convert("before\n```\nline a\nline b\n```\nafter")
	_has(out, "[code]line a\nline b[/code]", "fenced block wrapped in one code tag")
	_has(out, "before", "text before the fence kept")
	_has(out, "after", "text after the fence kept")
	# Markdown inside a fence is verbatim.
	_check(not MdToBbcode.convert("```\n# not a heading\n```").contains("[font_size"), "no headings inside a fence")

func _test_table() -> void:
	var md := "| Command | Effect |\n|---|---|\n| /heal | full HP |\n| /gold 5 | more gold |"
	var out := MdToBbcode.convert(md)
	_has(out, "[code]", "table rendered as monospace code")
	_has(out, "Command", "table header kept")
	_has(out, "/heal", "table row kept")
	_check(not out.contains("---"), "separator row dropped")
	# Columns are padded to a common width (monospace alignment): the header
	# 'Command' (7) is the widest first column, so '/heal' is padded to 7+.
	_has(out, "/heal  ", "first column padded for alignment")

func _test_bracket_escape() -> void:
	# A stray bracket in code must not open a BBCode tag.
	var out := MdToBbcode.convert("`a[b]c`")
	_has(out, "[lb]b[rb]", "brackets inside code are escaped")

func _init() -> void:
	_test_headings()
	_test_inline()
	_test_links()
	_test_lists()
	_test_fence()
	_test_table()
	_test_bracket_escape()

	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
