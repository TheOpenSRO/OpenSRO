# The skill-use gate

`FUN_0058d8f0` (3,134 bytes) is the precondition ladder every skill cast passes
through. It sits immediately before `Combat_ResolveDamage` (`0x0058e5f0`) in the
image, and it returns **0 to allow** or one of **seventeen refusal codes**.

It is the single most refusal-dense function in `SR_GameServer.exe`: no other
function materialises more than twelve distinct error codes, and the next
skill-related one manages nine.

**How it was found.** Not by reading functions. `docs/protocol/error_codes.md`
recorded that its server-side scan matched only `mov ax,0xNNNN` / `mov eax,…`
and therefore missed every code that never passes through `ax`. Widening that
pattern to every constant materialisation took the number of server functions
attributable to an error code from **157 to 362**. This function was the richest
thing in the difference. See `client/tools/re/errsites.py`.

## The ladder, in the order the engine checks it

Addresses are the refusal site; the condition is the test immediately above it.

| # | addr | code | name | refused when |
|---|---|---|---|---|
| 1 | `58d93f` | `0x3003` | `SKILL_USE_FAIL_NOTLEARN` | `FUN_0046c1f0(skill->+8)` resolves nothing — the caster does not have the skill |
| 2 | `58de13` | `0x3038` | `QUEST_ERR_CANNOT_MAKE_TRAP_EXIST_MONSTER` | a distance test against `refobj->+0x294` fails |
| 3 | `58dcfd` | `0x3037` | `QUEST_ERR_CANNOT_MAKE_TRAP` | the same test, other bound |
| 4 | `58de3b` | `0x3031` | `EU_BAN_HAWN_TRANS` | `GetBodyMode() == 1` while the skill sets `+0x4a4` |
| 5 | `58de7d` | `0x3006` | `SKILL_USE_FAIL_WRONGTARGET` | the target id at `skill->+0x20` resolves to no ref object |
| 6 | `58de9c` | `0x3008` | `SKILL_USE_FAIL_NOTENOUGHLEVEL` | `casterLevel < refobj->+0x198` |
| 7 | `58df15` | `0x3039` | `SKILL_USE_FAIL_DUPLICATE` | the `+0x4a4` kind is 2 and the effect is already present |
| 8 | `58df6e` | `0x3028` | `SKILLUSE_FAIL_CANT_BATTLE_STATE` | the skill's `+0x428` kind is 1 or 2 and `char[+0xd]` is set |
| 9 | `58dfc9` | `0x3036` | `SKILL_USE_FAIL_GROGGY` | **`MaxHP * 0.3 < CurHP`** — see below |
| 10 | `58dfe9` | `0x3034` | `SKILL_USE_DO_STEALTH` | the skill's flag word has `0x10` and the request lacks it |
| 11 | `58e005` | `0x3032` | `SKILL_USE_FAIL_MUSICAL_RANGE` | flag `0x20` and `FUN_0059ddf0()` returns 0 |
| 12 | `58e095` | `0x3005` | `SKILL_USE_FAIL_TIMEDELAY_COOL_TIME` | the cooldown check `FUN_0064c1a0` fails |
| 13 | `58e186` | `0x3018`/`0x3009` | `SKILL_USE_FAIL_ITS_NOT_A_BATTLE_FIELD` | computed as `0x3018 - (0xf * (skill->+0x49c != 0))` |
| 14 | `58e292` | `0x3013` | `SKILL_USE_FAIL_NOTENOUGHHP` | **`hpCost > 0 && CurHP < hpCost`** |
| 15 | `58e2b1` | `0x3004` | `SKILL_USE_FAIL_NOTENOUGHMP` | **`mpCost > 0 && CurMP < mpCost`** |
| 16 | `58e2fd` | `0x300c` | `SKILL_USE_FAIL_OVERLAP` | the buff is already applied |
| 17 | `58e360` | `0x300e` | `SKILL_USE_FAIL_RUNOUT_AMMO` | no ammunition |
| 18 | `58e52b` | `0x3010` | `SKILL_USE_FAIL_PATH_INTERRUPTED` | the path to the target is blocked |

Row 13 is worth noting as an idiom rather than a rule: the engine does not
branch, it computes the code. `(-(ushort)(x != 0) & 0xfff1) + 0x3018` is
`0x3018` when `x == 0` and `0x3009` when it is not — a conditional spelled as
arithmetic, which is why neither constant appears as an immediate and why the
narrow scan would have missed both even if it had looked at this function.

## The groggy threshold is 30%, and it settles a vtable slot

	0058df8e  mov edx,[eax+0x108] ; call   ; A = slot 0x108()
	0058dfaa  fstp QWORD [esp+0x28]        ; keep A
	0058dfa2  mov edx,[eax+0x110] ; call   ; B = slot 0x110()
	0058dfb8  fmul QWORD ds:0xb45ce0       ; B * 0.3
	0058dfbe  fcomp QWORD [esp+0x28]       ; (B*0.3) vs A
	0058dfc4  test ah,0x5 ; jp skip        ; fall through when ST0 < mem
	0058dfc9  mov ax,0x3036

`.rdata 0x00b45ce0` is a **double**, not the float 2.0 that sits at the same
address when read four bytes wide: the operand is `QWORD PTR`. Its value is
`0.30000001192092896`, which is `(double)0.3f` — the compiler widening a float
literal, so the game's number is **0.3**.

The comparison direction is from the flags, not from the source order: `fcomp`
sets C0 when `ST0 < mem`, `test ah,0x5` masks C0 and C2, and `jp` skips on even
parity, so the refusal is taken exactly when `ST0 < mem`, i.e. `MaxHP*0.3 <
CurHP`. **The skill requires the caster at or below 30% health.**

This is a third independent witness that slot `0x110` is `GetMaxHP` and not the
`GetCurHP` its stub string says — see `docs/protocol/igobj_vtable.md`. If both
slots were current HP the test would read `cur*0.3 < cur`, true for every
positive HP, and the branch would be unreachable.

## What srrevamp already matches

`session.UseSkillHandler` checks the skill is known, then the cooldown, then
**HP cost, then MP cost**, each gated on the cost being greater than zero. That
is the engine's order and the engine's gating, rows 1, 12, 14 and 15 — which was
not known to be the engine's order when it was written. Nothing changed; it is
recorded because "we happen to agree" and "we match a read" are different
claims and only the second is worth anything.

## What is not recovered

- **PARTLY CLOSED 2026-09-17.** Three of the five field names are now recovered
  from the param parser — see `docs/protocol/skill_fields.md`:

	+0x4a4  msch      rows 4 and 7 (EU_BAN_HAWN_TRANS, DUPLICATE)
	+0x39c  reqc      rows 10 and 11 (stealth, musical range)
	+0x49c  qest      row 13's computed ITS_NOT_A_BATTLE_FIELD code

  **`+0x428` and `+0x294` are still unnamed.** Neither appears in the recovered
  map, which for this extractor means only that it could not reach them — the
  tool misses codes whose values go into a list rather than a single field. It is
  not evidence that no code fills them.

  **A four-letter code is a label, not an explanation.** Knowing `+0x4a4` is
  `msch` says which skilldata param fills it, not what the branch means, and the
  rows above are still described by the shape of their test.
- Rows 2, 3, 7, 16, 17 and 18 are listed with the *shape* of their test rather
  than a value. They gate trap placement, buff duplication, ammunition and line
  of sight, and each would need its own read.
- `refobj->+0x198`, the level requirement in row 6, is a byte on the **target's**
  ref object rather than on the skill. That is unusual enough to be worth a
  second look before anything relies on it.
