# The ParamKeeper registry: every param id, with its min, max and default

Recovered whole from `SR_GameServer.exe` on 2026-09-15. This is **real data read
out of the binary**, not an inference: a static table of 20-byte records at VA
`0x00c64110` (file offset `0x864110`), terminated by an id of `0xFFFF`.

## How it was found, and why it is authoritative

`CMainProcess::ParamRegistry_Register` (`0x004b3960`) is a plain loop over that
table, inserting each record into a global map keyed by param id:

```asm
mov  ax, ds:0xc64110        ; first record's id
mov  esi, 0xc64110          ; table base
cmp  ax, 0xffff / je done   ; 0xFFFF terminates
loop:
  mov  WORD  [esp+0xc], ax  ; key   = id
  mov  DWORD [esp+0x10],esi ; value = pointer to this record
  call 0x4b3ff0             ; map[id] = record
  movzx eax, WORD [esi+0x14]
  add  esi, 0x14            ; stride 20 bytes
  cmp  ax, 0xffff / jne loop
```

The record layout is fixed by `ParamKeeper_EnsureParam`, which converts four of
its fields and passes them to `Param_Init`:

```c
struct ParamDesc {          // 20 bytes
    uint16 id;  uint16 pad;
    int32  min;             // +0x04 -> param+0x20
    int32  max;             // +0x08 -> param+0x24
    int32  default;         // +0x0c -> param+0x1c AND +0x28
    int32  flag;            // +0x10 -> param+0x2c   (0 or -1)
};
```

`min`/`max` are pinned by `ParamKeeper_EvaluateParam`'s own clamp assert, which
prints `+0x20` as `min` and `+0x24` as `max`.

**Why this table is the whole story.** There is exactly **one** `CParam`
allocation site in the entire binary, inside `ParamKeeper_EnsureParam`, and it
runs only when the id is present in this map. An id that is absent asserts and
creates nothing; the read wrapper then tail-jumps into `Param_GetValue`, which
dereferences the pointer with no null check. So:

- every param that can exist is in this table, and
- **an unwritten param evaluates to the `default` column here** -- not to zero by
  assumption, and not to some unrecoverable runtime value.

## Two independent checks on the layout

1. **Param 0 is `min=1, max=140`** -- the level cap, which matches `leveldata`'s
   own 140 exactly. Nothing about the parse was tuned to produce that.
2. The magnitudes sort correctly by kind without being told to: HP/MP (3/4) cap
   at 2,100,000,000 (~INT_MAX), percentage stats (10 `bri`, 12 `cri`, 25 `hprg`,
   26 `mprg`, 56 `evbl`, 57 `evcr`) cap at 100, and the rate stats (9 `era`,
   11 `hra`) cap at 65535.

## What it settles

- **Only 7 of 120 params have a non-zero default**, and every one of them is
  `100`: ids **34, 35, 36, 37, 50, 51, 140**. Everything else defaults to **0**.
- `hprg`/`mprg` (25/26) default to **0** in this table. **That default is never
  what a character regenerates at (corrected round 607):** `SetMotionState`
  (`0x4a9d00`) writes their base slot on every motion change -- 8.0 when the
  new state is SIT, 0.8 for any other -- and the character's constructor and
  `GObjPC::Revive` both call it with STAND, so a living PC carries 0.8. The
  "no timer-driven pool writer" this line used to lean on was already wrong on
  2026-09-16 (the 4 s timer, `CGObjPC::vslot_362`).
  `docs/protocol/opcodes/motion.md` has the reading.
- `257` (death-penalty reduction) defaults to **0**, so a character with no
  premium benefit really does take the full penalty. That value is RECOVERED.
- The damage-pipeline params `128-131, 178, 180, 187, 188, 259` all default to
  **0**, so an unbuffed character's damage really is complete without them.

## Unregistered ids

These ids in `0..259` are **not** in the table, so nothing can ever read them --
a "recovered" param id landing in one of these ranges is wrong by construction:

> 61-127, 142, 151-168, 201, 203-255

## The table

The `flag` column is the fourth field (`0` or `-1`); its meaning is not
recovered, so it is reported rather than interpreted. The `known tag` column is
this project's own id->tag mapping from `Stat_ApplyTaggedModifier`, included
only where already established elsewhere.

**See `param_tags.md`** for the full tag vocabulary — 53 tags, 31 resolved to
param ids, 7 proven dead. Every id it resolves is registered here, which is a
cross-check between two artifacts recovered by completely different means (a
static data table read out of the PE, versus dataflow through a dispatcher's
branches).

| id | hex | min | max | default | flag | known tag |
|---:|----:|----:|----:|--------:|-----:|---|
| 0 | 0x000 | 1 | 140 | **0** | 0 | level |
| 1 | 0x001 | 0 | 9999999 | **0** | 0 |  |
| 2 | 0x002 | 0 | 9999999 | **0** | 0 | int |
| 3 | 0x003 | 0 | 2100000000 | **0** | 0 | hp/hpa |
| 4 | 0x004 | 0 | 2100000000 | **0** | 0 | mp/mpa |
| 5 | 0x005 | 0 | 9999999 | **0** | 0 |  |
| 6 | 0x006 | 0 | 9999999 | **0** | 0 |  |
| 7 | 0x007 | 0 | 10000 | **0** | 0 |  |
| 8 | 0x008 | 0 | 10000 | **0** | 0 |  |
| 9 | 0x009 | 0 | 65535 | **0** | 0 | era (parry rate) |
| 10 | 0x00a | 0 | 100 | **0** | 0 | bri (blocking) |
| 11 | 0x00b | 0 | 65535 | **0** | 0 | hra (attack rate) |
| 12 | 0x00c | 0 | 100 | **0** | 0 | cri (critical) |
| 13 | 0x00d | 0 | 9999999 | **0** | 0 | phys damage low |
| 14 | 0x00e | 0 | 9999999 | **0** | 0 | phys damage high |
| 15 | 0x00f | 0 | 9999999 | **0** | 0 | mag damage low |
| 16 | 0x010 | 0 | 9999999 | **0** | 0 | mag damage high |
| 17 | 0x011 | 0 | 9999999 | **0** | 0 |  |
| 18 | 0x012 | 0 | 9999999 | **0** | 0 |  |
| 19 | 0x013 | 0 | 9999999 | **0** | 0 |  |
| 20 | 0x014 | 0 | 9999999 | **0** | 0 |  |
| 21 | 0x015 | 0 | 9999999 | **0** | 0 |  |
| 22 | 0x016 | 0 | 9999999 | **0** | 0 |  |
| 23 | 0x017 | 0 | 9999999 | **0** | -1 | walk speed -- `GObjPC_InitStats` and `GObjMob_PublishStats` publish the common record's word at `+0xe4` (characterdata column 46, `Speed1`) here; the mover's step multiplies it by seconds (round 231/237) |
| 24 | 0x018 | 0 | 9999999 | **0** | -1 | run speed -- the word at `+0xe6` (column 47, `Speed2`), published beside 23 (round 231/237) |
| 25 | 0x019 | 0 | 100 | **0** | 0 | hprg |
| 26 | 0x01a | 0 | 100 | **0** | 0 | mprg |
| 27 | 0x01b | 0 | 100 | **0** | 0 | rals; **freeze resist %** -- Combat_ApplyStatusEffects' block for that status reads it (round 249) |
| 28 | 0x01c | 0 | 100 | **0** | 0 | **frostbite resist %** -- Combat_ApplyStatusEffects' block for that status reads it (round 249) |
| 29 | 0x01d | 0 | 100 | **0** | 0 | **electric shock resist %** -- Combat_ApplyStatusEffects' block for that status reads it (round 249) |
| 30 | 0x01e | 0 | 100 | **0** | 0 |  |
| 31 | 0x01f | 0 | 100 | **0** | 0 | **poison resist %** -- Combat_ApplyStatusEffects' block for that status reads it (round 249) |
| 32 | 0x020 | 0 | 100 | **0** | 0 | **zombie resist %** -- Combat_ApplyStatusEffects' block for that status reads it (round 249) |
| 33 | 0x021 | 0 | 9999999 | **0** | 0 | **attack range** -- `Char_PublishCombatStats` publishes the equipped weapon's `Range` column (item ref `+0x224`, itemdata 94; 0 while broken) here, and the action tick (`0x4ad8e0`) reads `round(param 33)` as the reach of any skill whose own Range is 0, i.e. every basic attack (round 247) |
| 34 | 0x022 | 0 | 1000 | **100** | 0 |  |
| 35 | 0x023 | 0 | 1000 | **100** | 0 |  |
| 36 | 0x024 | 0 | 1000 | **100** | 0 |  |
| 37 | 0x025 | 0 | 1000 | **100** | 0 |  |
| 38 | 0x026 | 0 | 1000 | **0** | 0 |  |
| 39 | 0x027 | 0 | 1000 | **0** | 0 |  |
| 40 | 0x028 | 0 | 1000 | **0** | 0 |  |
| 41 | 0x029 | 0 | 1000 | **0** | 0 |  |
| 42 | 0x02a | 0 | 1000 | **0** | 0 |  |
| 43 | 0x02b | 0 | 1000 | **0** | 0 |  |
| 44 | 0x02c | 0 | 1000 | **0** | 0 |  |
| 45 | 0x02d | 0 | 1000 | **0** | 0 |  |
| 46 | 0x02e | 0 | 1000 | **0** | 0 |  |
| 47 | 0x02f | 0 | 1000 | **0** | 0 |  |
| 48 | 0x030 | 0 | 1000 | **0** | 0 |  |
| 49 | 0x031 | 0 | 1000 | **0** | 0 |  |
| 50 | 0x032 | 0 | 1000 | **100** | -1 |  |
| 51 | 0x033 | 0 | 1000 | **100** | -1 |  |
| 52 | 0x034 | 0 | 9999999 | **0** | 0 | hpna |
| 53 | 0x035 | 0 | 9999999 | **0** | 0 | mpna |
| 54 | 0x036 | 0 | 9999999 | **0** | 0 |  |
| 55 | 0x037 | 0 | 9999999 | **0** | 0 |  |
| 56 | 0x038 | 0 | 100 | **0** | -1 | evbl |
| 57 | 0x039 | 0 | 100 | **0** | -1 | evcr |
| 58 | 0x03a | 0 | 1000 | **0** | -1 |  |
| 59 | 0x03b | 0 | 1000 | **0** | -1 |  |
| 60 | 0x03c | 0 | 9999999 | **0** | 0 |  |
| 128 | 0x080 | 0 | 1000 | **0** | 0 | drua |
| 129 | 0x081 | 0 | 1000 | **0** | 0 | drua |
| 130 | 0x082 | 0 | 1000 | **0** | 0 | drua |
| 131 | 0x083 | 0 | 1000 | **0** | 0 |  |
| 132 | 0x084 | 0 | 100 | **0** | 0 |  |
| 133 | 0x085 | 0 | 100 | **0** | 0 |  |
| 134 | 0x086 | 0 | 100 | **0** | 0 |  |
| 135 | 0x087 | 0 | 100 | **0** | 0 |  |
| 136 | 0x088 | 0 | 100 | **0** | 0 |  |
| 137 | 0x089 | 0 | 100 | **0** | 0 |  |
| 138 | 0x08a | 0 | 100 | **0** | 0 |  |
| 139 | 0x08b | 0 | 100 | **0** | 0 |  |
| 140 | 0x08c | 0 | 1000 | **100** | 0 |  |
| 141 | 0x08d | 0 | 100 | **0** | 0 |  |
| 143 | 0x08f | 0 | 100 | **0** | 0 | recover HP |
| 144 | 0x090 | 0 | 100 | **0** | 0 | recover MP |
| 145 | 0x091 | 0 | 9999999 | **0** | 0 |  |
| 146 | 0x092 | 0 | 9999999 | **0** | 0 |  |
| 147 | 0x093 | 0 | 9999999 | **0** | 0 |  |
| 148 | 0x094 | 0 | 9999999 | **0** | 0 |  |
| 149 | 0x095 | 0 | 9999999 | **0** | 0 |  |
| 150 | 0x096 | 0 | 9999999 | **0** | 0 |  |
| 169 | 0x0a9 | 0 | 100 | **0** | -1 |  |
| 170 | 0x0aa | 0 | 100 | **0** | 0 |  |
| 171 | 0x0ab | 0 | 100 | **0** | 0 |  |
| 172 | 0x0ac | 0 | 100 | **0** | 0 |  |
| 173 | 0x0ad | 0 | 100 | **0** | 0 | **reinforce success bonus** — see below |
| 174 | 0x0ae | 0 | 100 | **0** | 0 | dara |
| 175 | 0x0af | 0 | 100 | **0** | 0 | dara |
| 176 | 0x0b0 | 0 | 100 | **0** | 0 | dara |
| 177 | 0x0b1 | 0 | 100 | **0** | 0 | dara |
| 178 | 0x0b2 | 0 | 100 | **0** | 0 |  |
| 179 | 0x0b3 | 0 | 100 | **0** | 0 |  |
| 180 | 0x0b4 | 0 | 100 | **0** | 0 |  |
| 181 | 0x0b5 | 0 | 100 | **0** | 0 |  |
| 182 | 0x0b6 | 0 | 100 | **0** | 0 |  |
| 183 | 0x0b7 | 0 | 100 | **0** | 0 | **attack-range reduction percent** of the Myopia (short-sight) state: written by `AbnormalState_Myopia_Apply10` (slot 5) and read by `GObjPC::ActionTick_UseSkill` as `range * (1 - p/100)` (rounds 247-248) |
| 184 | 0x0b8 | 0 | 1000 | **0** | 0 |  |
| 185 | 0x0b9 | 0 | 9999999 | **0** | 0 |  |
| 186 | 0x0ba | 0 | 1000 | **0** | 0 |  |
| 187 | 0x0bb | 0 | 100 | **0** | 0 |  |
| 188 | 0x0bc | 0 | 100 | **0** | 0 | **ignore a monster's defence, as a chance** — granted by skill code `msid` (field `0x4c4`), whose only real carriers are `SKILL_MALL_NASRUN_MOBDEFENCEIGNORE` and `SKILL_ITEM_ETERNITY_SOCKET_IGNORE_*`; rolled in `Combat_ResolveDamage` only when a PC attacks a non-PC (round 388) |
| 189 | 0x0bd | 0 | 100 | **0** | 0 |  |
| 190 | 0x0be | 0 | 999999 | **0** | 0 |  |
| 191 | 0x0bf | 0 | 999999 | **0** | 0 |  |
| 192 | 0x0c0 | 0 | 999999 | **0** | 0 |  |
| 193 | 0x0c1 | 0 | 999999 | **0** | 0 |  |
| 194 | 0x0c2 | 0 | 100 | **0** | 0 |  |
| 195 | 0x0c3 | 0 | 100 | **0** | 0 |  |
| 196 | 0x0c4 | 0 | 100 | **0** | 0 |  |
| 197 | 0x0c5 | 0 | 100 | **0** | 0 |  |
| 198 | 0x0c6 | 0 | 100 | **0** | 0 |  |
| 199 | 0x0c7 | 0 | 100 | **0** | 0 |  |
| 200 | 0x0c8 | 0 | 100 | **0** | 0 |  |
| 202 | 0x0ca | 0 | 1000 | **0** | 0 |  |
| 256 | 0x100 | 0 | 1000 | **0** | -1 | premium |
| 257 | 0x101 | 0 | 1000 | **0** | -1 | death-penalty reduction (premium) |
| 258 | 0x102 | 0 | 1000 | **0** | -1 | premium |
| 259 | 0x103 | 0 | 100 | **0** | 0 |  |

## The damage pipeline's params, and which side supplies each (2026-09-16)

The registry above gives every param's bounds and default but leaves the role
column empty. For the eight params the mitigation formulas touch, the role is
now readable — and so is the thing that matters more, **which of the two
characters each is read from.**

`Formula_MitigatePhysicalDamage` (`0x0040e450`) takes the defender in **EDX**
and the attacker as its **first stack argument**; the magical twin
(`0x0040e830`) is identical with every type-specific id shifted by one. Reading
the `GetParam` sites in address order, with the object register resolved:

| # | addr (phys / mag) | side | param | bounds | role |
|---|---|---|---|---|---|
| 1 | `40e504` / `40e8a6` | **defender** | 5 / 6 | 0..9,999,999 | flat absorption, subtracted |
| 2 | `40e51a` / `40e8bc` | **defender** | 7 / 8 | 0..10,000 | percentage reduction, the divisor |
| 3 | `40e5a4` / `40e94a` | attacker | **128 or 129** | 0..100 | one of two, chosen by `test [ecx],0x2` |
| 4 | `40e5d8` / `40e97e` | attacker | 259 | 0..100 | **only when the defender is a monster of class 3** |
| 5 | `40e663` / `40ea09` | attacker | 189 | 0..100 | gated on flag bit `0x4` |
| 6 | `40e75b` / `40eb0d` | attacker | 178 / 179 | 0..100 | |
| 7 | `40e78d` / `40eb3f` | **defender** | 180 / 181 | 0..100 | |

**The bounds corroborate the roles rather than being assumed from them.** Param
5's ceiling of 9,999,999 is a flat quantity; param 7's 10,000 is a percentage
with headroom; and every other param here is capped at exactly 100, which is
what a percentage looks like. None of that was used to derive the split — it is
a second source agreeing with it.

### Which side is which, settled twice

The project had already settled this by **monotonicity**: a larger param 7
yields less damage, so it cannot belong to the attacker (see
`combat.MitigateDamage`). The register walk settles it again, independently:

	40e5b4  mov eax,[edi]          ; the EDX object
	40e5ba  mov edx,[eax+0x28]     ; vtable slot 10 = IGObj::IsMonster
	40e5bf  call edx / test eax,eax / je skip
	40e5c5  mov eax,[edi]
	40e5c7  mov edx,[eax+0x12c]    ; vtable slot 75 = IGObj::GetMonsterClass
	40e5cf  call edx / cmp al,0x3 / jne skip
	40e5d5  mov eax,[ebp+0x0]      ; the STACK object
	40e5d8  mov edx,[eax+0x104]    ; GetParam
	40e5de  push 0x103

The formula asks the EDX object *what kind of monster it is* and, on the answer,
reads a param off the stack object. A bonus conditioned on what the target is
belongs to the attacker, so EDX is the target. Two routes, one answer.

### A mechanic OpenSRO does not model

Step 4 is an **anti-monster-class damage bonus**: attacker param 259, applied as
a percentage, only when the defender is a monster whose `GetMonsterClass()`
returns 3. `CGObjMob::GetMonsterClass` is `MOV AL,[ECX+0x1cd8] ; AND AL,0xF`, so
the class is the low nibble of a byte on the mob.

OpenSRO has no item or skill that grants param 259, so the bonus is
unreachable rather than omitted — recorded here so it is not mistaken for a gap
in the formula. The same goes for steps 3, 5 and 6, which are attacker
percentages no OpenSRO source publishes.

## Params are read through TWO paths, and one grep sees only half (2026-09-16)

`docs/RE_COMPLETION.md`'s combat entry calls the `GetParam` virtual **"the
single most useful handle found for the stat system"** and says **"every param
read in the binary is greppable, with its id visible"**, recommending it as the
first thing to reach for. The handle is genuinely good and the recommendation is
worth keeping, but the coverage claim is wrong, and measurably:

| path | how the id travels | sites | distinct literal ids |
|---|---|---|---|
| `IGObj::GetParam`, vtable slot 65 / offset `0x104` | pushed as an argument | 186 | 53 |
| `EvaluateParam`, `0x004b3740` | in **EAX** | 65 | 40 |

**29 param ids are read only through the second path** and are invisible to a
grep on the first:

	13 14 15 16 25 26 33 136 137 138 139 143 144 170 171 174 175 176 177
	183 186 194 195 196 197 202 256 257 258

That set is not marginal. It holds **195** (`hwit`, the berserk duration bonus)
and **256/257/258** — the death-penalty reduction this project recovered by
reading the disassembly by hand precisely because the decompiled C showed a bare
call.

### And one id is computed, so no literal grep finds it

The berserk activation reads its base duration as

	515c4a  mov esi,0xfffffffb     ; -5, reused from the charge spend
	515c5c  lea eax,[esi+0x41]     ; eax = 0x3c = param 60
	515c5f  call 0x4b3740

so **param 60 never appears as a literal anywhere near its own read**. Searching
for `GetParam(195)` across both dumps returns zero hits, and that empty result
is what sent this pass to the second path — an ordinary application of this
project's own rule that a negative result is a fact about the probe.

**When looking for who reads a param, run three probes:** `push <id>` before a
`[reg+0x104]` call; `mov eax,<id>` before `call 0x4b3740`; and, if both come
back empty, a register trace, because the id may be arithmetic.

## The damage pipeline is wider than the inline reads show (2026-09-16)

The table above ("The damage pipeline's params, and which side supplies each")
was built by walking the `GetParam` sites **inline** in the two mitigation
twins. That is incomplete: the twins also read params through a **helper**, and
those never appeared.

`Formula_MitigatePhysicalDamage` calls `0x00410bb0` at `40e60b`, and the magical
twin calls the same helper at `40e9b1`:

	40e5f9  mov edx,[esi+0x230]   ; the attack descriptor's flags
	40e5ff  mov ecx,[eax+0x230]   ; a second descriptor's flags
	40e605  mov eax,[edx]
	40e607  mov ecx,[ecx]
	40e609  mov edx,edi           ; edi = the DEFENDER
	40e60b  call 0x410bb0

so params **174..177 are defender params in the damage pipeline** and belong in
that table.

### Two 2x2 param selectors

Both helpers pick one param from a pair of flag axes and read it off
`obj + 0x1ec` (the ParamKeeper):

| helper | `0x4`+`0x1` | `0x4`+`0x2` | `0x8`+`0x1` | `0x8`+`0x2` |
|---|---|---|---|---|
| `0x00410bb0` (both mitigation twins; defender) | 174 | 175 | 176 | 177 |
| `0x00410c20` (`Combat_ResolveDamage`, once) | 136 | 137 | 138 | 139 |

**Bit `0x4` is physical and bit `0x8` is magical, settled by a use-site rather
than by analogy.** Two further callers pass the flags as literals, and they are
a phys/mag twin pair identified by the params they themselves read:

| caller | reads | passes | selects |
|---|---|---|---|
| `0x0040f1b0` | 5, 7, 180 — the **physical** defender set | `5` = `0x4\|0x1` | 174 |
| `0x0040f3d0` | 6, 8, 181 — the **magical** defender set | `9` = `0x8\|0x1` | 176 |

The second axis (`0x1` against `0x2`) is **not settled**. Both literal callers
use `0x1`, and no use-site seen so far distinguishes them, so it is left open
rather than guessed.

### `dara` is four params, not one

The registry tags 174..177 `dara`, and `docs/protocol/magic_options.md` names it
`MATTR_AVATAR_DARA` on `avatar_helm` — the avatar family. So one magic-option
tag resolves to **four** params, chosen by damage type and the second axis, each
bounded 0..100 and read off the defender inside mitigation. That is an avatar
damage-reduction percentage.

OpenSRO has no source for `dara`, so this is unreachable rather than omitted,
the same as the anti-monster-class bonus recorded above.

## The damage pipeline holds 47 params, and a depth-0 walk sees 16 (2026-09-16)

The two tables above were each built by reading one function's own `GetParam`
sites. That is the wrong unit, and this is the measurement that says by how
much. Walking the call graph from `Formula_MitigatePhysicalDamage`,
`Formula_MitigateMagicalDamage` and `Combat_ResolveDamage` to depth 3, and
collecting param reads on **both** paths at every function reached:

| | count |
|---|---|
| functions reachable within depth 3 | 156 |
| distinct params read anywhere in the pipeline | **47** |
| read at depth 0 — what an inline walk sees | **16** |
| read only deeper | **31** |

The 16: 5, 6, 7, 8, 10, 12, 56, 57, 178, 179, 180, 181, 187, 188, 189, 259.

**The walk validates against ground it did not produce**: 190/191 land in
`Formula_RollWeaponDamage` and 192/193 in its magical twin, which this project
documented long ago; 174..177 land in the `dara` selector and 136..139 in its
sibling, both recovered the previous tick; 143/144 land in
`GObjPC::ApplyHPMPDelta`.

This is the same failure that produced three corrections in a row — the v0.1.259
pipeline table (depth 0), the "no passive regeneration" enumeration (it
enumerated writers without checking what drives them), and the `GetParam`
coverage claim (one of two read paths). **An enumeration is only as complete as
the depth and the paths it searches, and saying which depth it searched is part
of reporting it.**

## Params 145..150 are the flat terms of the six resists

`FUN_00590680` — 11,956 bytes, reachable at depth 1 from `Combat_ResolveDamage`
— reads thirteen params, and the order is the finding:

	5906e0  param 169      <- gates the block
	59078e  param 27       590c97  param 31
	5907e0  param 145      590d08  param 149
	5908c3  param 28       590e22  param 32
	590915  param 146      590e74  param 150
	5909f5  param 29
	590a47  param 147
	590b33  param 30
	590b85  param 148

**Strict alternation, six times.** Each percentage param is followed ~80 bytes
later by one of the 145..150 run, so the two runs are six `(percent, flat)`
pairs — the same shape mitigation uses with param 7 (percent) and param 5
(flat):

| percent | 27 | 28 | 29 | 30 | 31 | 32 |
|---|---|---|---|---|---|---|
| **flat** | **145** | **146** | **147** | **148** | **149** | **150** |

Params 27..32 were already known to be the resist family (`rals` =
`MATTR_RESIST_ALL_SET` on 27, `bu` = `MATTR_RESIST_BURN` on 30). **145..150 were
in no document at all**, and their bounds agree with the reading without having
been used to reach it: 27..32 are capped at 100 like percentages, 145..150 at
9,999,999 like flat quantities.

So `bu`'s flat counterpart is param 148. Which tag takes which of the other
five is still open, and still for the reason `magic_options.md` records — the
tags share a tail block, each setting its own EDI before jumping in.

**Not claimed:** what param 169 is. It gates the block and is capped at 100, and
that is all this pass read.


## Param 173 is the reinforce success bonus (2026-09-17)

Named from its only use-site, which is unambiguous. `CEnchant_Reinforce`'s
vtable slot 7 (`0x00506df0`) is 41 bytes and does exactly two things:

	00506df3  mov    eax,DWORD PTR [esi]
	00506df5  mov    edx,DWORD PTR [eax+0x18]   ; slot 6 -- the base rate
	00506df9  call   edx
	00506dfe  mov    edi,eax
	00506e00  mov    eax,DWORD PTR [ecx]
	00506e02  mov    edx,DWORD PTR [eax+0x104]  ; slot 65 -- IGObj::GetParam
	00506e08  push   0xad
	00506e0d  call   edx
	00506e0f  call   0x9fbb40                   ; __ftol2
	00506e14  add    eax,edi                    ; rate = base + (int)param(173)

so the returned rate is `baseRate + (int)GetParam(173)`, and that rate is what
`CEnchant_Reinforce::vslot_001` clamps to [10, 100] and rolls `rand() % 100`
against. The param is added in **percentage points**, and its registry row
already says `min 0, max 100, default 0`, which is the right shape for one and
was recorded before this use-site was read.

This is the first param named from the alchemy system rather than the damage
pipeline. `0x9fbb40` is the CRT's `__ftol2` (`fstp qword [esp]; cvttsd2si`), so
the param is a float truncated toward zero — not rounded.

See `docs/protocol/alchemy.md`.
