extends RefCounted
class_name QaSwarmGear

## QA only (round 759): the live swarm's bodies and gear for the offline
## lineup (QaLineup, OPENSRO_QA_LINEUP=swarm), so the crowd the user stood in
## -- 7,000 `cmd/swarm` bots in real gear -- can be measured without the
## server. Never used in play.
##
## The rules are `server/cmd/swarm`'s (READ, look.go and gear.go), applied to
## the client's own item table (World3D._item_rows: the same itemdata the
## server's `items` table is imported from):
## - **the look** (lookFor): race and sex half and half, any of the 13
##   figures of the pair, height and volume each 0..4 (the scale byte's
##   nibbles);
## - **the catalogue** (classify, catalogue.add): every ITEM_CH_ / ITEM_EU_
##   equipment row of a weapon, a shield (TypeID4 1, 2) or an armour piece
##   (families 1, 2, 3, 9, 10, 11; pieces 1..6), of China or Europe, with a
##   degree (`_NN_`) and a known seal suffix, and none of the junk tokens;
## - **the loadout** (loadout): a weapon of a seal drawn by sealWeights (the
##   Sun and Nova spears favoured for China, one time in two), its plus by
##   weaponPlus; a shield beside a one-handed weapon that takes one, at the
##   weapon's plus +-2; six armour pieces of one family and degree (the
##   weapon's degree when the family has it) in the weapon's seal when the
##   table has armour of it, each at +0..9.
## The random numbers are this class's own (RandomNumberGenerator seeded per
## body), not Go's math/rand: the same distributions, not the same bots
## (OURS).

const SEAL_NONE := 0
const SEAL_STAR := 1
const SEAL_MOON := 2
const SEAL_SUN := 3
const SEAL_NOVA := 4
const SEAL_EGYPT := 5
const NUM_SEALS := 6
const SEAL_NAMES := ["normal", "Star", "Moon", "Sun", "Nova", "Egyptian"]
## gear.go's sealWeights (the swarm's own mix).
const SEAL_WEIGHTS := [12, 14, 14, 22, 19, 19]
## gear.go's favoured ids: ITEM_CH_SPEAR_11_C_RARE (Sun), ITEM_CH_SPEAR_11_A_RARE_ACTIVE (Nova).
const SUN_SPEAR := 4118
const NOVA_SPEAR := 62607
const JUNK := ["_HONOR", "_SWITCH", "_EVENT", "_MALL", "_TEST", "_ARENA", "_FRPVP", "_PREMIUM", "_TRADE", "_DEF", "_QUEST", "_GM"]
const ARMOUR_FAMILIES := [1, 2, 3, 9, 10, 11]
## gear.go's shieldHands: the one-handed weapons a shield is worn with.
const SHIELD_HANDS := [2, 3, 7, 10, 15]
## An armour piece's TypeID4 -> its EquipmentNet slot (rules.go SlotFor).
const PIECE_SLOT := {1: EquipmentNet.SLOT_HELM, 2: EquipmentNet.SLOT_SHOULDER_GUARD, 3: EquipmentNet.SLOT_MAIL,
	4: EquipmentNet.SLOT_PANTS, 5: EquipmentNet.SLOT_GAUNTLET, 6: EquipmentNet.SLOT_BOOTS}
const RACE_CHINA := 0
const RACE_EUROPE := 1
const SEX_WOMAN := 0
const SEX_MAN := 1

var seed := 1
var rows := 0
## race -> [seal] -> [item ids], each sorted.
var weapons := {}
var shields := {}
## "race|sex|family|degree|seal" -> {piece: [ids]}
var armour := {}
## "race|sex|seal" -> [[family, degree], ...] sorted
var armour_keys := {}
## id -> [type_ids, seal, degree]
var info := {}

## A code's [seal, degree], or [] when the swarm does not wear it (gear.go classify).
static func classify(code: String) -> Array:
	if not code.begins_with("ITEM_CH_") and not code.begins_with("ITEM_EU_"):
		return []
	for t in JUNK:
		if code.contains(t):
			return []
	var re := RegEx.create_from_string("_(\\d{2})_")
	var m := re.search(code)
	if m == null:
		return []
	var degree := int(m.get_string(1))
	var s := -1
	if code.contains("_SET_A_RARE") or code.contains("_SET_B_RARE"):
		s = SEAL_EGYPT
	elif code.ends_with("_A_RARE_ACTIVE"):
		s = SEAL_NOVA
	elif code.ends_with("_C_RARE"):
		s = SEAL_SUN
	elif code.ends_with("_B_RARE"):
		s = SEAL_MOON
	elif code.ends_with("_A_RARE"):
		s = SEAL_STAR
	elif RegEx.create_from_string("_[ABC]$").search(code) != null:
		s = SEAL_NONE
	else:
		return []
	return [s, degree]

## Builds the catalogue from World3D's item table (id -> ItemTableReader.Item).
func build(item_rows: Dictionary) -> void:
	for id in item_rows:
		var it: ItemTableReader.Item = item_rows[id]
		add(int(id), it.code_name, it.type_ids, it.country, it.req_gender)
	finish()

## Files one row (gear.go catalogue.add); false when the swarm does not wear it.
func add(id: int, code: String, type_ids: PackedInt32Array, country: int, req_gender: int) -> bool:
	if type_ids.size() < 4 or type_ids[0] != 3 or type_ids[1] != 1:
		return false
	if country != RACE_CHINA and country != RACE_EUROPE:
		return false
	var c := classify(code)
	if c.is_empty():
		return false
	var s: int = c[0]
	var deg: int = c[1]
	var fam := type_ids[2]
	var kind := type_ids[3]
	if fam == 6:
		_append(weapons, country, s, id)
	elif fam == 4 and (kind == 1 or kind == 2):
		_append(shields, country, s, id)
	elif fam in ARMOUR_FAMILIES and kind >= 1 and kind <= 6:
		var sexes := [SEX_MAN] if req_gender == 1 else ([SEX_WOMAN] if req_gender == 0 else [SEX_MAN, SEX_WOMAN])
		for sex in sexes:
			var k := "%d|%d|%d|%d|%d" % [country, sex, fam, deg, s]
			if not armour.has(k):
				armour[k] = {}
				var ck := "%d|%d|%d" % [country, sex, s]
				if not armour_keys.has(ck):
					armour_keys[ck] = []
				(armour_keys[ck] as Array).append([fam, deg])
			var pieces: Dictionary = armour[k]
			if not pieces.has(kind):
				pieces[kind] = []
			(pieces[kind] as Array).append(id)
	else:
		return false
	info[id] = [type_ids, s, deg]
	rows += 1
	return true

static func _append(d: Dictionary, race: int, s: int, id: int) -> void:
	if not d.has(race):
		var per: Array = []
		for i in range(NUM_SEALS):
			per.append([])
		d[race] = per
	((d[race] as Array)[s] as Array).append(id)

## Sorts every list, so the picks depend only on the seed and the table.
func finish() -> void:
	for d in [weapons, shields]:
		for race in d:
			for l in d[race]:
				(l as Array).sort()
	for k in armour:
		for piece in armour[k]:
			(armour[k][piece] as Array).sort()
	for ck in armour_keys:
		(armour_keys[ck] as Array).sort_custom(func(a, b) -> bool:
			return a[0] < b[0] if a[0] != b[0] else a[1] < b[1])

func _rng(salt: int, i: int) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = hash([seed, salt, i])
	return r

static func _pick(r: RandomNumberGenerator, l: Array) -> int:
	return 0 if l.is_empty() else int(l[r.randi_range(0, l.size() - 1)])

## Body i's look (look.go lookFor): {race, sex, figure index 0..12, scale byte}.
func look(i: int) -> Dictionary:
	var r := _rng(7919, i)
	var race := r.randi_range(0, 1)
	var sex := r.randi_range(0, 1)
	var figure := r.randi_range(0, 12)
	var scale := (r.randi_range(0, 4) << 4) | r.randi_range(0, 4)
	return {"race": race, "sex": sex, "figure": figure, "scale": scale}

## gear.go weaponPlus: 10% 0..2, 30% 3..7 (the glow), 60% 8..14 (the particles).
static func weapon_plus(r: RandomNumberGenerator) -> int:
	var x := r.randi_range(0, 99)
	if x < 10:
		return r.randi_range(0, 2)
	if x < 40:
		return 3 + r.randi_range(0, 4)
	return 8 + r.randi_range(0, 6)

## Body i's gear for its race and sex (gear.go loadout): [equipped
## {slot: id}, pluses {slot: plus}], both empty when the table has no weapon.
func loadout(i: int, race: int, sex: int) -> Array:
	var r := _rng(104729, i)
	var eq := {}
	var pl := {}
	var ws: Array = weapons.get(race, [])
	if ws.is_empty():
		return [eq, pl]
	var total := 0
	for s in range(NUM_SEALS):
		if not (ws[s] as Array).is_empty():
			total += SEAL_WEIGHTS[s]
	if total == 0:
		return [eq, pl]
	var x := r.randi_range(0, total - 1)
	var cat := 0
	for s in range(NUM_SEALS):
		if (ws[s] as Array).is_empty():
			continue
		if x < SEAL_WEIGHTS[s]:
			cat = s
			break
		x -= SEAL_WEIGHTS[s]
	var w := _pick(r, ws[cat])
	if race == RACE_CHINA and r.randi_range(0, 1) == 0:
		var fav: int = {SEAL_SUN: SUN_SPEAR, SEAL_NOVA: NOVA_SPEAR}.get(cat, 0)
		if fav != 0 and info.has(fav) and int((info[fav][0] as PackedInt32Array)[2]) == 6:
			w = fav
	var wp := weapon_plus(r)
	eq[EquipmentNet.SLOT_WEAPON] = w
	pl[EquipmentNet.SLOT_WEAPON] = wp
	var wkind := int((info[w][0] as PackedInt32Array)[3])
	var wdeg := int(info[w][2])
	if wkind in SHIELD_HANDS:
		var ss: Array = shields.get(race, [])
		var sh := 0
		if not ss.is_empty():
			sh = _pick(r, ss[cat])
			for s in [SEAL_SUN, SEAL_MOON, SEAL_STAR, SEAL_NONE, SEAL_EGYPT, SEAL_NOVA]:
				if sh != 0:
					break
				sh = _pick(r, ss[s])
		if sh != 0:
			eq[EquipmentNet.SLOT_SHIELD] = sh
			pl[EquipmentNet.SLOT_SHIELD] = clampi(wp + r.randi_range(0, 4) - 2, 0, 14)
	# Armour: the weapon's seal when the table has armour of it, else the first that has any.
	var acat := cat
	var keys: Array = armour_keys.get("%d|%d|%d" % [race, sex, acat], [])
	for s in [SEAL_SUN, SEAL_MOON, SEAL_STAR, SEAL_EGYPT, SEAL_NOVA, SEAL_NONE]:
		if not keys.is_empty():
			break
		acat = s
		keys = armour_keys.get("%d|%d|%d" % [race, sex, acat], [])
	if keys.is_empty():
		return [eq, pl]
	var fams := {}
	var fam_ids: Array = []
	for k in keys:
		if not fams.has(k[0]):
			fams[k[0]] = []
			fam_ids.append(k[0])
		(fams[k[0]] as Array).append(k)
	var fam: int = fam_ids[r.randi_range(0, fam_ids.size() - 1)]
	var fl: Array = fams[fam]
	var choice: Array = fl[r.randi_range(0, fl.size() - 1)]
	for k in fl:
		if int(k[1]) == wdeg:
			choice = k
	var pieces: Dictionary = armour["%d|%d|%d|%d|%d" % [race, sex, fam, choice[1], acat]]
	for piece in range(1, 7):
		var it := _pick(r, pieces.get(piece, []))
		if it == 0:
			for k in fl:
				it = _pick(r, (armour["%d|%d|%d|%d|%d" % [race, sex, fam, k[1], acat]] as Dictionary).get(piece, []))
				if it != 0:
					break
		if it == 0:
			continue
		eq[PIECE_SLOT[piece]] = it
		pl[PIECE_SLOT[piece]] = r.randi_range(0, 9)
	return [eq, pl]

func summary() -> String:
	var parts := PackedStringArray(["%d wearable rows" % rows])
	for race in [RACE_CHINA, RACE_EUROPE]:
		var seals := PackedStringArray()
		for s in range(NUM_SEALS):
			seals.append("%s %d" % [SEAL_NAMES[s], ((weapons.get(race, [[], [], [], [], [], []]) as Array)[s] as Array).size()])
		parts.append("%s weapons %s" % ["China" if race == RACE_CHINA else "Europe", " ".join(seals)])
	return "; ".join(parts)
