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
| 14 | `58e292` | `0x3013` | `SKILL_USE_FAIL_NOTENOUGHHP` | **`hpCost > 0 && CurHP < hpCost`** — `cmp DWORD [esp+0x10],0x0; jle` at `58e279`/`58e27e`, `GetCurHP` (slot `+0x108`) called at `58e28a`, `cmp eax,[esp+0x10]` at `58e28c`, `jge 58e29d` at `58e290`: **passes on EQUAL**, so a cast costing the caster's whole pool lands her at 0, alive (round 551, below) |
| 15 | `58e2b1` | `0x3004` | `SKILL_USE_FAIL_NOTENOUGHMP` | **`mpCost > 0 && CurMP < mpCost`** — the same shape against slot `+0x10c`: `cmp eax,edi` at `58e2ad`, `jge 58e2bc` at `58e2af` |
| 16 | `58e2fd` | `0x300c` | `SKILL_USE_FAIL_OVERLAP` | the buff is already applied, or one of its state bytes is taken. **Read in full in round 636** (`skill_buffs.md`, "The recast rule"): for a skill with no `lnks` and Target_Required 0, `FUN_0059d870(book, skill, caster)` answering 0 -- its `dttp`, `efr` kind-2 and GroupID branches over the active kind-3, non-`cbuf` records, then the book's state bit set (`book+0x1b0`, `SkillBook::SetGroupBits` 0x59dc00) tested against the row's `ovl2` and Action_Overlap bytes (`FUN_0059db10`); also `0x300c` at once for a `hide` row while the caster's vslot 0x100 answers 4 (OPEN which state). An `lnks` row with an `efr` of kind 3 calls `FUN_0059dc80(0)` instead (OPEN) |
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

**Row 14 at exactly the cost (round 551).** The compare is `jge`, so `CurHP ==
hpCost` passes and `EngageSkill` then spends the whole pool: the caster stands
at 0. What the engine does with a pool its own cost emptied was not recovered
(no `OnDeath` call was traced from slot `0x308`'s spend). srrevamp's rule,
disclosed at `combat.CanPaySkillHealth` and `session/skill.go`'s payment: the
caster is left ALIVE at 0 -- life state 1, no death penalty, no respawn -- and
the next monster or duel blow whose damage lands on her is her death, decided
under her kill lock (`session/monsterstrike.go` `killLock`; `monster_ai.md`,
"The player's dead state"). Round 550's arbiter, the store's transition flag,
read every blow on her as `(0, false)` and dropped it, so a caster who had
spent her last point could not be killed and her duel could not end; round
551 closed it (`TestCounterOnACasterAliveAtZeroKills`). These addresses are
`SR_GameServer.exe`'s (`/var/tmp/srv.asm` on the RE box); looked up in the
client's image they fall mid-instruction, which is not a bad citation.

## The gate is a check, and the reach comes between it and the costs (round 534)

The gate spends nothing. Rows 14 and 15 compare the costs with the caster's HP
and MP; the costs are TAKEN later, by `EngageSkill` (`0x593540`), whose first
step is vtable slot `0x308` with the context's HP and MP costs
(`skill_params.md`, "EngageSkill, step by step"). No instruction in the gate's
range (`58d8f0`–`58e52f` in `srv.asm`) references offset `+0x308`, and none of
its direct calls is `EngageSkill` or the reuse-timer arm `FUN_0064c700`.

Which rows run depends on the caller's mask (the third argument, `[ebp+0x10]`):

| bit | guards | where |
|---|---|---|
| `0x1` | row 12, the cooldown | `58e077 test al,0x1`, refusal at `58e095` |
| `0x10` | rows 14 and 15, HP then MP | `58e1ac test byte [ebp+0x10],0x10`, refusals at `58e292`, `58e2b1` |

`CGCharAutoCommandActor::Tick_UseSkill` (`0x4ae590`, `auto_command.md`) calls
the gate with mask `0x17` in phase 0 (`push 0x17` at `4ae6af`) and `0x91` in
phase 1 (`push 0x91` at `4aea11`, the call at `4aea18`). Both carry `0x1` and
`0x10`. Only then does phase 1 test `Action_IsTargetWithinReach` (`4aea39`):
in reach it enters phase 2 (`4aea4b mov eax,2 ; call 0x4ac9e0`), out of reach
it walks (`MoveTowardObject`, `4aeaca`) and stays in phase 1. Phase 2 posts the
0x7070 command (`push 0x7070` at `4aebc6`). Neither the tick nor the 0x7074
handler (`0x4acc40`) calls `EngageSkill` or the reuse-timer arm `FUN_0064c700`
(their direct calls, listed from `srv.asm`). The per-kind cast handlers call
them; `Skill_BuildUseContext_B` (`0x586700`), for one, copies Consume_HP and
Consume_MP (`+0xca`/`+0xcc`) into the context, arms the timer at `586c22` and
calls `EngageSkill` at `586c44`. Which function consumes 0x7070 and reaches
those handlers was not traced.

So, for a targeted cast: **cooldown and affordability, then the reach, then the
costs and the cooldown arm.** A cast whose target is out of reach costs nothing:
the engine walks instead.

**srrevamp since round 534.** `session/skill.go` refuses a cast out of reach
("too far away") instead of walking, and until round 534 it did so after
spending the HP and MP and recording the use. It now tests, in order: the
cooldowns, affordability (`skillCostRefusal`, the same comparisons without
spending), the reach (`skillInReach`, skipped for a non-damaging row as
before), and only then spends the HP, the MP and records the use. The
refusal as too far away still ends a running keep-up (the 0x7074 handler's
mask `0x37` does not test reach, so the engine queues such a cast and the
keep-up ends at depth 2). `TestSkillRefusedAsTooFarCostsNothing` holds it.


## Which row tests which param (2026-09-17)

The previous pass named the 15 fields the gate reads but **declined to say which
refusal each one guards**, on the grounds that matching `hide`, `trap`,
`tele`/`tel2`/`tel3` and `cnsm` to the stealth, trap, teleport and ammunition
rows by theme was the inference this project has been wrong with before.

That was the right call. **The actual join contradicts the theme match.**

| row | refusal | field the guard tests | how known |
|---|---|---|---|
| 4 | `EU_BAN_HAWN_TRANS` | **`msch`** `0x4a4` | decompiled `param_4 + 0x4a4` |
| 7 | `SKILL_USE_FAIL_DUPLICATE` | **`msch`** `0x4a4` | same field, `== 2` |
| 8 | `SKILLUSE_FAIL_CANT_BATTLE_STATE` | **`hide`** `0x428`, with **`trap`** `0x4a0` inside | decompiled `param_4 + 0x428`, `+0x4a0` |
| 9 | `SKILL_USE_FAIL_GROGGY` | **`reqc`** `0x39c`, bit `0x4` | decompiled `**(uint**)(param_4+0x39c)` |
| 10 | `SKILL_USE_DO_STEALTH` | **`reqc`** `0x39c`, bit `0x10` | same word |
| 11 | `SKILL_USE_FAIL_MUSICAL_RANGE` | **`reqc`** `0x39c`, bit `0x20` | same word |
| 13 | `ITS_NOT_A_BATTLE_FIELD` | **`qest`** `0x49c` | decompiled `param_4 + 0x49c` |
| 17 | `SKILL_USE_FAIL_RUNOUT_AMMO` | `cnsm` `0x2a0` — **positional only** | read at `0058e348`, immediately before |

### What the theme match would have got wrong

- **`hide` does not guard the stealth row.** It gates the *battle-state* block.
  Stealth is `reqc` bit `0x10`.
- **`trap` does not guard the trap rows.** It is an inner condition of that same
  battle-state block, and the trap refusals are hundreds of bytes earlier.
- **`reqc` is one flag word driving three different rows** via bits `0x4`,
  `0x10` and `0x20` — groggy, stealth and musical range, which share no theme at
  all. No name-to-row mapping could have produced that.

`cnsm` before the ammunition row is the one case where position and theme agree,
and it is marked positional because that is all the evidence is: the field read
sits immediately before the refusal, and no decompiled condition was read for it.

**The general lesson, now measured rather than asserted**: a four-character param
name says which skilldata column fills a field. It does not say what the field
means, and for 3 of the 4 suggestive names here it actively misleads.

### The fields, for reference

| param | offset | | param | offset |
|---|---|---|---|---|
| `ao` | `0x274` | | `qest` | `0x49c` |
| `cnsm` | `0x2a0` | | `reqc` | `0x39c` |
| `hide` | `0x428` | | `rpkt` | `0x2cc` |
| `lnks` | `0x370` | | `tel2` | `0x2f0` |
| `msch` | `0x4a4` | | `tel3` | `0x2f4` |
| `nmf` | `0x594` | | `tele` | `0x2ec` |
| `pw` | `0x2b4` | | `trap` | `0x4a0` |

`0x294` is the one field still unnamed. `+0x428` — listed below as unnamed by an
earlier pass — is `hide`, read through `esi` like the rest.

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
