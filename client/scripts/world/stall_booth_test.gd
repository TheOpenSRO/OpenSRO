extends SceneTree

## StallBooth's model choice (round 838; c:0x9dd040): the decoration item's
## own .bsr, else the race's default stall.

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	var deco := ItemTableReader.Item.new()
	deco.id = 3847
	deco.model_path = "item\\Avatar\\booth_mob_mangyang.bsr"
	_check(StallBooth.model_path(deco, 0) == "res\\item\\Avatar\\booth_mob_mangyang.bsr",
		"a decoration draws its own AssocFileObj under res\\")
	_check(StallBooth.model_path(deco, 1) == "res\\item\\Avatar\\booth_mob_mangyang.bsr",
		"a decoration is the same for either race")
	_check(StallBooth.model_path(null, 0) == "res\\item\\china\\item\\cj_store.bsr", "no decoration, China: cj_store")
	_check(StallBooth.model_path(null, 1) == "res\\item\\europe\\item\\euro_streetstall01.bsr",
		"no decoration, Europe: euro_streetstall01")
	_check(StallBooth.model_path(null, 2) == "", "no other race has a default")
	var bare := ItemTableReader.Item.new()
	_check(StallBooth.model_path(bare, 1) == StallBooth.EUROPE_DEFAULT, "an item with no model falls back to the default")
	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
