# Skill withdrawal (the skill reset)

A whole system, recovered 2026-09-17, that this project had no trace of.
Implemented as far as it can be in `server/internal/skill/withdraw.go` — the
cost formula is exact; OpenSRO offers no withdrawal feature yet.

## How it was found

Not by reading functions. The widened error-code scan
(`client/tools/re/errsites.py`, see `docs/protocol/error_codes.md`) attributes
**362** server functions to a named refusal, of which **291 are still `FUN_`**.
Grouping those by the *system* their refusals belong to leaves **62** that are
unambiguous — every code they raise comes from one vocabulary. Four of them sit
in one address range and raise nothing but `WITHDRAW_SKILL_*`:

	0059f410   501 bytes    the validator
	0059f610   400 bytes
	0059f8b0  1190 bytes
	0059fd60   542 bytes

A system located by its vocabulary rather than by reading anything.

## The vocabulary, and the success value

| code | name |
|---|---|
| `0x7800` | **success** — not a refusal, see below |
| `0x7801` | `WITHDRAW_SKILL_FAIL_NOT_LEARN` |
| `0x7802` | `WITHDRAW_SKILL_FAIL_INVALID_LEVEL` |
| `0x7803` | `WITHDRAW_SKILL_FAIL_UNKNOWN` |
| `0x7804` | `WITHDRAW_SKILL_FAIL_NOT_ENOUGH_GOLD` |
| `0x7805` | `WITHDRAW_SKILL_FAIL_NOT_ENOUGH_POTION` |
| `0x7806` | `WITHDRAW_SKILL_FAIL_DEPENDANCY_LIMIT` |

`0x7800` is **not** in `docs/protocol/error_codes.md`, and its absence is
correct rather than a gap: that table lists refusals, and the client has no
message for success. It is recovered here from the server's own use —
`FUN_0059f410` returns it as the pass value and tests its helper's result
against it (`if (sVar3 != 0x7800) return sVar3`). Worth stating because a family
that runs `0x7801`–`0x7806` looks complete, and the base of the range is the
one value the client-side harvest structurally cannot supply.

## The validator — `FUN_0059f410`

	iVar5 = FUN_0059d600()                      ; resolve the learned skill
	if (iVar5 == 0)               return 0x7801 ; NOT_LEARN
	if (target != 0 && skill[+0x64] <= target)
	                              return 0x7802 ; INVALID_LEVEL
	if (flags & 1) {                            ; this withdrawal is charged
	    cost = Formulae_0x00410c80(char)
	    if (cost == 0)            return 0x7803 ; UNKNOWN
	    if (gold64 < cost)        return 0x7804 ; NOT_ENOUGH_GOLD
	}
	levels = skill[+0x64] - target
	if (levels < 1)               return 0x7803 ; UNKNOWN
	r = FUN_0059f7b0(skill, levels, 1)          ; dependency / item checks
	if (r != 0x7800)              return r      ; 0x7805, 0x7806
	...                           return 0x7800

`skill[+0x64]` is the skill's current level. The gold test is the same 64-bit
comparison every other cost check in this engine uses — low dword at
`charData+0x78`, high at `+0x7c` — which is the **fifth** independent subsystem
this project has read that layout out of.

That the gold charge is gated on `flags & 1` says there is at least one **free**
withdrawal path. What sets the flag is not read.

## The cost — `0x00410c80`

	base  = goldMin(GetMaxLevel())                  ; see below
	scale = (base / 0.8) * 80.0                     ; = base * 100
	for each link in the skill's chain (next at skill + 0x59c):
	    m     = the link's required mastery level
	    cost += __ftol2((m/10.0 + 1.0) * scale + 0.5)

with `.rdata` `0x00b45bd0` = 0.8, `0x00b45c58` = 80.0, `0x00b45c60` = 10.0,
`0x00b45ac0` = 1.0, `0x00b45c50` = 0.5, all doubles.

**`cost per link = goldMin * 100 * (1 + masteryLevel/10)`.**

`m` is read from the skill's two mastery-requirement slots: ids at `+0xa0` and
`+0xa4`, level bytes at `+0xa8` and `+0xa9`, and the engine takes the level
belonging to the **first slot with a non-zero id**. A skill requiring no mastery
contributes the bare `1.0` term.

The function has two branches that compute the **same** per-link term and differ
only in where they stop: a full reset walks the whole chain, and a withdrawal to
level `target` stops at the first link with `skill[+0x64] <= target`. So the cost
is per refunded level.

### `+ 0.5` is a float-error guard, not a rounding rule

With integer inputs the term is mathematically always an integer —
`goldMin*100 + goldMin*10*m`. Measured over goldMin 1..3000 × mastery 0..200
(600,000 pairs), the `+ 0.5` changes the answer in **27,435** of them, and in
**every one** plain truncation lands exactly one *below* the correct integer.
So it is not a half-up convention that could be swapped for `round()`; dropping
it is a systematic off-by-one on 4.6% of inputs. `withdraw_test.go` asserts the
closed form across a sweep rather than memorising the one case.

### What `base` is, and the caveat it inherits

`0x00410c80` calls vtable slot `0x128` — slot 74, `GetMaxLevel`, the same slot
`StrLevelDamageRatio` uses — and hands the result to `GObjPC::FUN_007243e0`,
which looks that level up in the level-table manager's `+0x268` array and
returns field `+4`.

**That array is the per-level gold table**, settled by its other reader rather
than by its shape: `FUN_00724330` rolls `rand()%101 <= entry[0]` and then a
range between `entry[1]` and `entry[2]` to fund an `ITEM_ETC_GOLD_03` spawn. So
`+0` is a chance percent and `+4`/`+8` are a min/max pair, and `FUN_007243e0`
returns the **minimum**.

**The inherited caveat, stated rather than buried:** this project believes that
array is filled by the client's `levelgold.txt`, and *that linkage is inferred,
not proven* — the server references no refdata filename anywhere, loading from
its database instead. `combat.RollGold` already carries the same caveat for the
same table. The formula is exact; any number it produces is only as good as that
join.

It is worth noticing what the engine chose here: a skill reset is priced in
**hundreds of a level-appropriate gold drop**, so the cost tracks the economy's
own curve rather than a hand-written table. That also means the gold table is
load-bearing for two unrelated systems, which raises the value of proving the
`levelgold.txt` join.

## Not recovered

- **`FUN_0059f7b0`**, which raises `0x7805 NOT_ENOUGH_POTION` and `0x7806
  DEPENDANCY_LIMIT`. The item a withdrawal consumes, and the rule that stops you
  un-learning a skill another skill depends on, are both in there.
- **What sets `flags & 1`**, i.e. when a withdrawal is free.
- The roles of the other three functions in the range (`0059f610`, `0059f8b0`,
  `0059fd60`); only `0059f410` was read.
