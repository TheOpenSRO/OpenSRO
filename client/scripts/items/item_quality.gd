extends RefCounted
class_name ItemQuality

## An equipment item's white stats and the tooltip's "(+x%)" (round 732,
## docs/protocol/item_tooltip.md "The (+x%) formula"), READ from the
## original client: the stat builder FUN_008bd980 and the stat-line builder
## FUN_0066c5b0, down to their x87 code. The server's mirror is
## server/internal/durability/quality.go; item_quality_test.gd and the Go
## test check the same cases.
##
## This file is data and arithmetic only -- the tooltip window and its
## lines are lane A's (item_tooltip*.gd). The API, all static:
##   ItemQuality.int_stat(L, U, q, inc, plus)        whole-number stat
##   ItemQuality.float_stat(L, U, q, inc, plus)      fractional stat
##   ItemQuality.range_int_pct(vLo, vHi, Llo, Ulo, Lhi, Uhi, inc, plus)
##   ItemQuality.range_float_pct(vLo, vHi, Llo, Ulo, Lhi, Uhi)
##   ItemQuality.single_pct(v, L, U, inc, plus)
##   ItemQuality.durability_pct(q)
##   ItemQuality.group_for(kind, stat) -> the variance group a stat reads
## q is a 5-bit variance group (ItemInstance.variance_group), plus the
## effective plus (ItemInstance.effective_plus()), L/U/inc the item table's
## range and per-plus increment for the stat.

## The divisor of a variance group, .rdata 0xddf2c8 = 31.0.
const GROUP_MAX := 31.0

## Which variance group each stat reads, per item kind -- the `param_3` cases
## of c:0x8bd980 (they match the server's Char_BuildAggregateStats order,
## server/internal/durability/durability.go):
const GROUPS := {
	# TypeID 3/1/6: c:0x8bd9f3's jump table.
	"weapon": {"durability": 0, "phys_reinforce": 1, "mag_reinforce": 2, "attack_rate": 3,
		"phys_attack": 4, "mag_attack": 5, "critical": 6},
	# FUN_0056fa30 (armour): the second switch.
	"armour": {"durability": 0, "phys_reinforce": 1, "mag_reinforce": 2, "phys_defence": 3,
		"mag_defence": 4, "parry": 5},
	# IsShieldItem: the last switch.
	"shield": {"durability": 0, "phys_reinforce": 1, "mag_reinforce": 2, "block": 3,
		"phys_defence": 4, "mag_defence": 5},
	# FUN_0056fb40 (accessory): groups 0 and 1 only, no durability.
	"accessory": {"phys_absorption": 0, "mag_absorption": 1},
}

## The variance group `stat` reads on an item of `kind`, or -1.
static func group_for(kind: String, stat: String) -> int:
	return int((GROUPS.get(kind, {}) as Dictionary).get(stat, -1))

## A float rounded to single precision, as the client stores its stats.
static func f32(x: float) -> float:
	var a := PackedFloat32Array([x])
	return a[0]

## A whole-number stat (attack, hit, parry, block, critical; durability with
## plus 0): trunc((U - L) * (q / 31.0) + L + trunc(inc * plus)), READ at
## c:0x8bdb75-0x8bdbd2.
static func int_stat(l: int, u: int, q: int, inc: float, plus: int) -> int:
	var bonus := 0.0
	if plus != 0:
		bonus = float(int(f32(inc) * float(plus)))
	return int((u - l) * (q / GROUP_MAX) + l + bonus)

## A fractional stat (defence, absorption, reinforce %): plus * inc +
## (q / 31) * (U - L) + L, stored as a float (c:0x8bd980 armour case 3; the
## reinforce stats are built with no plus term -- pass 0).
static func float_stat(l: float, u: float, q: int, inc: float, plus: int) -> float:
	# (U-L)*(q/31.0) unrounded, + L, + inc*plus, rounded to a float once at
	# the store (c:0x8bde5e-0x8bde99; round 732 review F7).
	return f32((f32(u) - f32(l)) * (q / GROUP_MAX) + f32(l) + f32(inc) * float(plus))

## A min~max line of whole-number stats (phys/mag attack, 0x66c66f-0x66c841):
## each end f = (v - TRUNC(inc*plus) - L) / (U - L) as a float, 1 when U == L;
## the percent is trunc((f_lo + f_hi) * 0.5 * 100). The plus bonus is
## TRUNCATED (the fistp at 0x66c6b6 runs with the control word's rounding set
## to chop). A v below zero after the bonus comes off is read as unsigned,
## as the client's +2^32 does.
static func range_int_pct(v_lo: int, v_hi: int, l_lo: int, u_lo: int, l_hi: int, u_hi: int, inc: float, plus: int) -> int:
	var off := 0
	if plus != 0:
		off = int(f32(inc) * float(plus))
	return int((_end_int(v_lo - off, l_lo, u_lo) + _end_int(v_hi - off, l_hi, u_hi)) * 0.5 * 100.0)

static func _end_int(v: int, l: int, u: int) -> float:
	if float(u) - float(l) == 0.0:
		return 1.0
	var fv := f32(float(v))
	if v < 0:
		fv = f32(float(v + 4294967296))
	return f32((fv - float(l)) / (float(u) - float(l)))

## A min~max line of fractional stats (the reinforce ranges, 0x66dc12 and
## 0x66df22): the same average; the client takes no plus off these.
static func range_float_pct(v_lo: float, v_hi: float, l_lo: float, u_lo: float, l_hi: float, u_hi: float) -> int:
	return int((_end_float(v_lo, l_lo, u_lo) + _end_float(v_hi, l_hi, u_hi)) * 0.5 * 100.0)

static func _end_float(v: float, l: float, u: float) -> float:
	if f32(u) - f32(l) == 0.0:
		return 1.0
	return f32((f32(v) - f32(l)) / (f32(u) - f32(l)))

## A one-value line: trunc((v - inc*plus - L) / (U - L) * 100), 100 when
## U == L (0x66cd66). The client takes the plus off only on phys/mag
## defence and absorption (inc at ref +0x1e8, +0x214, +0x200, +0x220); hit,
## parry, critical, block and a single reinforce pass plus 0, even where the
## stat itself carries a plus term.
static func single_pct(v: float, l: float, u: float, inc: float, plus: int) -> int:
	if f32(u) - f32(l) == 0.0:
		return 100
	var fv := f32(v)
	if plus != 0:
		# The unrounded product comes off, rounded once (c:0x66cd25-0x66cd33).
		fv = f32(fv - f32(inc) * float(plus))
	return int((fv - f32(l)) / (f32(u) - f32(l)) * 100.0)

## The durability line's percent: q / 0.31 truncated (0x66d316; the double at
## 0xda1aa0 is the float 0.31 widened, 0.3100000023841858). A perfect q = 31
## shows 99 -- the client's own arithmetic, not a choice.
static func durability_pct(q: int) -> int:
	return int(float(q) / f32(0.31))
