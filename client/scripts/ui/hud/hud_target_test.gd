extends SceneTree

## Headless checks for HudTarget's recovered rules -- the ones that do not
## need an archive: the level-difference classifier from the client's
## FUN_007780c0 (gem art and name colour), the rank-icon switch, and that a
## window built without an archive stays empty rather than inventing one.

const HudTarget = preload("res://scripts/ui/hud/hud_target.gd")

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _init() -> void:
	var hud := HudTarget.new(null)

	# Unknown player level: neutral class, never a guess.
	_check(hud.difficulty_class(1) == 2, "no player level -> normal")

	# FUN_007780c0: d = target - player; d < -6 -> 0, d < -3 -> 1, d < 1 -> 2,
	# d <= 5 -> 3, else 4. Player 10, every boundary from both sides.
	hud.set_player_level(10)
	var cases := {3: 0, 4: 1, 6: 1, 7: 2, 10: 2, 11: 3, 15: 3, 16: 4, 40: 4}
	for target_level in cases:
		_check(hud.difficulty_class(target_level) == cases[target_level],
			"player 10 vs target %d -> class %d" % [target_level, cases[target_level]])

	# Class -> art and colour tables line up (weak2, weak1, normal, strong1, strong2).
	_check(HudTarget.GEM_BY_CLASS.size() == 5 and HudTarget.COLOUR_BY_CLASS.size() == 5, "five classes")
	_check(HudTarget.GEM_BY_CLASS[2] == "tw_gem_normal.ddj" and HudTarget.COLOUR_BY_CLASS[2] == Color.WHITE,
		"class 2 is the white normal gem")
	_check(HudTarget.GEM_BY_CLASS[4] == "tw_gem_strong2.ddj", "class 4 is strong2")

	# The rank-icon switch (FUN_0069b4c0): 0/7 normal, 1 champion, 3/8 unique,
	# 4 giant, 5 titan, 6 elite, anything else none.
	_check(HudTarget.rank_icon_path(0).ends_with("tw_icon_normal.ddj"), "rarity 0 -> normal icon")
	_check(HudTarget.rank_icon_path(7).ends_with("tw_icon_normal.ddj"), "rarity 7 -> normal icon")
	_check(HudTarget.rank_icon_path(1).ends_with("tw_icon_champion.ddj"), "rarity 1 -> champion")
	_check(HudTarget.rank_icon_path(8).ends_with("tw_icon_unique.ddj"), "rarity 8 -> unique")
	_check(HudTarget.rank_icon_path(5).ends_with("tw_icon_titan.ddj"), "rarity 5 -> titan")
	_check(HudTarget.rank_icon_path(2) == "", "rarity 2 -> no icon")

	# No archive: setup() says so and the window stays hidden and harmless.
	_check(hud.setup() == false, "setup without an archive returns false")
	hud.show_target("Mangyang", 1, 0, 54, 54)
	hud.set_hp(10, 54)
	hud.clear()
	_check(not hud.visible, "stays hidden without an archive")
	hud.free()

	if _failures == 0:
		print("ALL PASS")
	else:
		print("%d FAILURE(S)" % _failures)
	quit(1 if _failures > 0 else 0)
