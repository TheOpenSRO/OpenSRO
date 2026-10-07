extends SceneTree

## Round 759: QaSwarmGear, the swarm's looks and gear for the offline lineup
## (OPENSRO_QA_LINEUP=swarm), against `server/cmd/swarm`'s rules (gear.go's
## classify, catalogue and loadout; look.go's lookFor). Run headless on the
## render box: `client/tools/remote_godot.sh tests`. The rows are synthetic
## (codes in the item table's spelling, no game data).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_classify()
	_test_loadout()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## gear.go classify's cases (gear_test.go has the same codes).
func _test_classify() -> void:
	_check(QaSwarmGear.classify("ITEM_CH_SPEAR_11_C_RARE") == [QaSwarmGear.SEAL_SUN, 11], "_C_RARE is Sun, degree 11")
	_check(QaSwarmGear.classify("ITEM_CH_SPEAR_11_A_RARE_ACTIVE") == [QaSwarmGear.SEAL_NOVA, 11], "_A_RARE_ACTIVE is Nova")
	_check(QaSwarmGear.classify("ITEM_EU_SWORD_10_B_RARE") == [QaSwarmGear.SEAL_MOON, 10], "_B_RARE is Moon")
	_check(QaSwarmGear.classify("ITEM_EU_SWORD_10_A_RARE") == [QaSwarmGear.SEAL_STAR, 10], "_A_RARE is Star")
	_check(QaSwarmGear.classify("ITEM_CH_M_HEAVY_11_SET_A_RARE_HA") == [QaSwarmGear.SEAL_EGYPT, 11], "_SET_A_RARE is the Egyptian set")
	_check(QaSwarmGear.classify("ITEM_CH_BLADE_05_B") == [QaSwarmGear.SEAL_NONE, 5], "a plain _B is normal")
	_check(QaSwarmGear.classify("ITEM_CH_SWORD_01_A_DEF").is_empty(), "the starting kit (_DEF) is junk")
	_check(QaSwarmGear.classify("ITEM_CH_SPEAR_11_C_RARE_MALL").is_empty(), "a mall copy is junk")
	_check(QaSwarmGear.classify("ITEM_ETC_HP_POTION_01").is_empty(), "not a CH/EU item")
	_check(QaSwarmGear.classify("ITEM_CH_SPEAR_C_RARE").is_empty(), "no degree")

func _ids(t1: int, t2: int, t3: int, t4: int) -> PackedInt32Array:
	return PackedInt32Array([t1, t2, t3, t4])

## A small catalogue: China spears (Sun, Nova, normal), a China sword (a
## one-handed weapon that takes a shield) with a shield, and one China
## protector family at degree 11 in Sun with all six pieces for men.
func _test_loadout() -> void:
	var g := QaSwarmGear.new()
	_check(g.add(4118, "ITEM_CH_SPEAR_11_C_RARE", _ids(3, 1, 6, 4), 0, 2), "the Sun spear is filed")
	_check(g.add(62607, "ITEM_CH_SPEAR_11_A_RARE_ACTIVE", _ids(3, 1, 6, 4), 0, 2), "the Nova spear is filed")
	_check(g.add(100, "ITEM_CH_SWORD_11_C_RARE", _ids(3, 1, 6, 2), 0, 2), "a Sun sword is filed")
	_check(g.add(101, "ITEM_CH_SHIELD_11_C_RARE", _ids(3, 1, 4, 1), 0, 2), "a Sun shield is filed")
	_check(not g.add(102, "ITEM_CH_SWORD_01_A_DEF", _ids(3, 1, 6, 2), 0, 2), "the _DEF sword is not")
	_check(not g.add(103, "ITEM_CH_RING_11_C_RARE", _ids(3, 1, 5, 3), 0, 2), "an accessory is not")
	for piece in range(1, 7):
		g.add(200 + piece, "ITEM_CH_M_LIGHT_11_C_RARE_%d" % piece, _ids(3, 1, 2, piece), 0, 1)
	# The suffix after _C_RARE makes the armour codes above unknown suffixes:
	# gear.go refuses them too. File proper ones.
	_check(g.armour.is_empty(), "a code with an unknown suffix is not armour")
	var codes := ["HA", "SA", "BA", "LA", "AA", "FA"]
	for piece in range(1, 7):
		g.add(300 + piece, "ITEM_CH_M_LIGHT_11_%s_C_RARE" % codes[piece - 1], _ids(3, 1, 2, piece), 0, 1)
	g.finish()
	_check(g.rows == 10, "10 rows filed (got %d)" % g.rows)
	var shields := 0
	var full := 0
	var plus8 := 0
	var favoured := 0
	var n := 400
	for i in range(n):
		var lo := g.loadout(i, QaSwarmGear.RACE_CHINA, QaSwarmGear.SEX_MAN)
		var eq: Dictionary = lo[0]
		var pl: Dictionary = lo[1]
		var w := int(eq.get(EquipmentNet.SLOT_WEAPON, 0))
		if w in [4118, 62607]:
			favoured += 1
		if w == 100:
			if eq.has(EquipmentNet.SLOT_SHIELD):
				shields += 1
		elif eq.has(EquipmentNet.SLOT_SHIELD):
			_check(false, "a spear carries no shield (body %d)" % i)
		var pieces := 0
		for slot in [EquipmentNet.SLOT_HELM, EquipmentNet.SLOT_SHOULDER_GUARD, EquipmentNet.SLOT_MAIL,
				EquipmentNet.SLOT_PANTS, EquipmentNet.SLOT_GAUNTLET, EquipmentNet.SLOT_BOOTS]:
			if eq.has(slot):
				pieces += 1
				if int(pl[slot]) < 0 or int(pl[slot]) > 9:
					_check(false, "armour at +0..9 (body %d: %d)" % [i, int(pl[slot])])
		if pieces == 6:
			full += 1
		if int(pl.get(EquipmentNet.SLOT_WEAPON, 0)) >= 8:
			plus8 += 1
	_check(full == n, "every man wears the six pieces (%d of %d)" % [full, n])
	_check(shields > 0, "a sword takes the shield (%d)" % shields)
	_check(plus8 > n * 45 / 100 and plus8 < n * 75 / 100, "about 60%% of weapons at +8 or more (%d of %d)" % [plus8, n])
	_check(favoured > n / 2, "the spears (the only Sun/Nova weapons but the sword) dominate (%d)" % favoured)
	var a := g.loadout(7, QaSwarmGear.RACE_CHINA, QaSwarmGear.SEX_MAN)
	var b := g.loadout(7, QaSwarmGear.RACE_CHINA, QaSwarmGear.SEX_MAN)
	_check(a == b, "a body's gear is deterministic")
	var woman := g.loadout(7, QaSwarmGear.RACE_CHINA, QaSwarmGear.SEX_WOMAN)
	_check(not (woman[0] as Dictionary).has(EquipmentNet.SLOT_MAIL), "a woman wears no men's armour")
	var eu := g.loadout(7, QaSwarmGear.RACE_EUROPE, QaSwarmGear.SEX_MAN)
	_check((eu[0] as Dictionary).is_empty(), "no Europe weapon in the table: no gear")
	var lk := g.look(3)
	_check(int(lk["scale"]) >> 4 <= 4 and int(lk["scale"]) & 0xF <= 4 and int(lk["figure"]) <= 12, "a look's nibbles 0..4 and figure 0..12")
