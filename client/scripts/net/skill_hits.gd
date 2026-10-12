extends RefCounted
class_name SkillHits

## A skill's per-target, per-hit results and its caster move (round 785):
## retail's skill-action tail, carried as a trailing suffix on OpAttackResult
## and on OpSkillCast so that a packet without it still decodes as before.
## The server lane's docs/protocol/skill_hit_block.md is the layout's home
## (READ from the retail server's writer FUN_0059e8f0 / FUN_00585730 /
## FUN_005856d0 / FUN_005855f0); this reader agrees with the client's own
## reader of the same bytes, READ:
##
## - 0xB070 result 1 and 0xB071 kind 1 hand the rest of the message to
##   FUN_00a54be0: u32 target, u8 flags (+0xe5); flags & 1 -> the damage block
##   (FUN_00a548e0); flags & 8 (tele) or & 2 (tel2) -> u16 region + 3 x i32,
##   the caster's move (8: IDecoSkill::FUN_00a51320, the slide; 2: put there).
## - FUN_00a548e0: u8 hitCount, u8 targetCount, then per target u32 id and
##   hitCount entries (FUN_00a55e00) -- nested, target by target.
## - FUN_00a55e00, one entry: u8 kind -- bit 0x80 the hit killed the target,
##   the low seven bits the kind:
##     0  a hit:        u32 v (v & 0xff the flags: 1 normal, 2 critical;
##                      v >> 8 the damage), u32 statusBits (the abnormal
##                      states this hit inflicted)
##     4  KNOCKDOWN:    v, statusBits, then u16 region, 3 x i32 the point
##                      (the server's 'ko', motion 8)
##     5  KNOCKBACK:    v, statusBits, then u16 region, 3 x i32 the point
##                      (the server's 'kb', motion 16; the client slides the
##                      body there at 250 u/s under the SYSTEM_KNOCKBACK
##                      decoration 0x8000001d, FUN_00a49290)
##     7  a wall:       u32 v, u16 wall HP, u16 wall max -- no HP change
##     2  blocked, 8 absorbed by a wall, any other: nothing more
## - The hit display (FUN_00a47720): critical (flags & 2) is kind 1, a block
##   kind 2.
##
## OpenSRO's framing (OURS, the server lane's): u8 0xAB, then the retail tail
## above (u32 target, u8 flags, [damage block], [move]), then targetCount x
## u8 target kind (0 character, 1 monster: OpenSRO's ids overlap between the
## two) and a u8 kind for the leading target. On OpAttackResult it follows the
## round-640 wall suffix, which is then always present (payload offset 72
## past the error string); on OpSkillCast it follows the 43 bytes (the act
## carries the whole tail, the start the move only).

const TAG := 0xAB
const FLAG_DAMAGE := 0x01
const FLAG_PUT := 0x02
const FLAG_SLIDE := 0x08
const KIND_HIT := 0
const KIND_BLOCK := 2
const KIND_KNOCKDOWN := 4
const KIND_KNOCKBACK := 5
const KIND_WALL := 7
const KIND_ABSORBED := 8
const HIT_FLAG_CRITICAL := 0x02

class Hit:
	var kind: int = 0
	var died: bool = false
	var flags: int = 0
	var damage: int = 0
	## Kinds 0/4/5: the abnormal states this hit inflicted (StatusNet bits).
	var status_bits: int = 0
	## Kind 7: the wall's HP after the hit, and its maximum.
	var wall_hp: int = 0
	var wall_max: int = 0
	## Kinds 4/5: where the target is put (retail's region and local point).
	var region: int = -1
	var point: Vector3 = Vector3.ZERO

	func critical() -> bool:
		return (flags & SkillHits.HIT_FLAG_CRITICAL) != 0

	func blocked() -> bool:
		return kind == SkillHits.KIND_BLOCK

	## Whether the target's HP falls by this hit (not a wall, a block or an
	## absorbed hit).
	func hurts() -> bool:
		return kind == SkillHits.KIND_HIT or kind == SkillHits.KIND_KNOCKDOWN or kind == SkillHits.KIND_KNOCKBACK

class Target:
	var id: int = 0
	var id_kind: int = 1
	var hits: Array = []

## The tail's leading target and flags.
var target_id := 0
var target_kind := 1
var flags := 0
var hit_count := 0
var targets: Array = []
## The caster's move (flags & 0x0A): region and region-local point.
var move_region := -1
var move_point := Vector3.ZERO
## Bytes the suffix took on the wire, its tag included.
var size := 0

func has_move() -> bool:
	return (flags & (FLAG_PUT | FLAG_SLIDE)) != 0 and move_region >= 0

## The hits of hit index `i` across every target: [[Target, Hit], ...].
func hits_at(i: int) -> Array:
	var out: Array = []
	for t in targets:
		var tt: Target = t
		if i < tt.hits.size():
			out.append([tt, tt.hits[i]])
	return out

## The target with this id and kind, or null.
func target(id: int, id_kind: int) -> Target:
	for t in targets:
		if (t as Target).id == id and (t as Target).id_kind == id_kind:
			return t
	return null

## The damage a target takes from hit `from` on (its HP before them, given
## its HP after all of them: hp + this).
func damage_from(id: int, id_kind: int, from: int) -> int:
	var t := target(id, id_kind)
	if t == null:
		return 0
	var n := 0
	for i in range(maxi(from, 0), t.hits.size()):
		var h: Hit = t.hits[i]
		if h.hurts():
			n += h.damage
	return n

## Decodes the suffix at `offset` (its tag byte). Null when there is no tag
## there or it is cut short (the packet then decodes as without it).
static func decode(data: PackedByteArray, offset: int) -> SkillHits:
	if offset < 0 or offset + 6 > data.size() or data[offset] != TAG:
		return null
	var out := SkillHits.new()
	out.target_id = data.decode_u32(offset + 1)
	out.flags = data[offset + 5]
	var at := offset + 6
	if out.flags & FLAG_DAMAGE:
		if at + 2 > data.size():
			return null
		out.hit_count = data[at]
		var n_targets: int = data[at + 1]
		at += 2
		for _t in n_targets:
			if at + 4 > data.size():
				return null
			var t := Target.new()
			t.id = data.decode_u32(at)
			at += 4
			for _h in out.hit_count:
				if at + 1 > data.size():
					return null
				var h := Hit.new()
				var k: int = data[at]
				at += 1
				h.died = (k & 0x80) != 0
				h.kind = k & 0x7f
				match h.kind:
					KIND_HIT, KIND_KNOCKDOWN, KIND_KNOCKBACK:
						if at + 8 > data.size():
							return null
						var v := data.decode_u32(at)
						h.flags = v & 0xff
						h.damage = v >> 8
						h.status_bits = data.decode_u32(at + 4)
						at += 8
						if h.kind != KIND_HIT:
							if at + 14 > data.size():
								return null
							h.region = data.decode_u16(at)
							h.point = Vector3(float(data.decode_s32(at + 2)), float(data.decode_s32(at + 6)),
								float(data.decode_s32(at + 10)))
							at += 14
					KIND_WALL:
						if at + 8 > data.size():
							return null
						var v := data.decode_u32(at)
						h.flags = v & 0xff
						h.damage = v >> 8
						h.wall_hp = data.decode_u16(at + 4)
						h.wall_max = data.decode_u16(at + 6)
						at += 8
					_:
						pass
				t.hits.append(h)
			out.targets.append(t)
	if out.flags & (FLAG_PUT | FLAG_SLIDE):
		if at + 14 > data.size():
			return null
		out.move_region = data.decode_u16(at)
		out.move_point = Vector3(float(data.decode_s32(at + 2)), float(data.decode_s32(at + 6)),
			float(data.decode_s32(at + 10)))
		at += 14
	# OURS: the targets' kinds, then the leading target's. A suffix cut before
	# them keeps the retail part, every target a monster.
	for t in out.targets:
		if at < data.size():
			(t as Target).id_kind = data[at]
			at += 1
	if at < data.size():
		out.target_kind = data[at]
		at += 1
	out.size = at - offset
	return out

## Encodes a suffix (tests, and QA's server double).
static func encode(hits: SkillHits) -> PackedByteArray:
	var out := PackedByteArray([TAG, 0, 0, 0, 0, hits.flags & 0xff])
	out.encode_u32(1, hits.target_id & 0xffffffff)
	if hits.flags & FLAG_DAMAGE:
		out.append(hits.hit_count & 0xff)
		out.append(hits.targets.size() & 0xff)
		for t in hits.targets:
			var tt: Target = t
			var id := PackedByteArray()
			id.resize(4)
			id.encode_u32(0, tt.id & 0xffffffff)
			out.append_array(id)
			for h in tt.hits:
				var hh: Hit = h
				out.append((hh.kind & 0x7f) | (0x80 if hh.died else 0))
				match hh.kind:
					KIND_HIT, KIND_KNOCKDOWN, KIND_KNOCKBACK:
						var b := PackedByteArray()
						b.resize(8)
						b.encode_u32(0, ((hh.damage & 0xffffff) << 8) | (hh.flags & 0xff))
						b.encode_u32(4, hh.status_bits)
						out.append_array(b)
						if hh.kind != KIND_HIT:
							out.append_array(_point(hh.region, hh.point))
					KIND_WALL:
						var b := PackedByteArray()
						b.resize(8)
						b.encode_u32(0, ((hh.damage & 0xffffff) << 8) | (hh.flags & 0xff))
						b.encode_u16(4, hh.wall_hp & 0xffff)
						b.encode_u16(6, hh.wall_max & 0xffff)
						out.append_array(b)
	if hits.flags & (FLAG_PUT | FLAG_SLIDE):
		out.append_array(_point(hits.move_region, hits.move_point))
	for t in hits.targets:
		out.append((t as Target).id_kind & 0xff)
	out.append(hits.target_kind & 0xff)
	return out

static func _point(region: int, p: Vector3) -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(14)
	b.encode_u16(0, region & 0xffff)
	b.encode_s32(2, int(p.x))
	b.encode_s32(6, int(p.y))
	b.encode_s32(10, int(p.z))
	return b
