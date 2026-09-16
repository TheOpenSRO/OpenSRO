# Skill parameter codes (`_RefSkill.Params`)

A skill's `Params` column is a stream of `(code, value…)` runs. The code is a C
multi-char literal stored big-endian, so reading the stored integer
little-endian gives the letters **reversed** — `0x00617474` unpacks to `tta` and
is `att`. Hand-computing these constants has produced a wrong answer twice in
this project; let the machine do it.

This is the whole vocabulary, extracted mechanically from
`SkillGlobal::RefSkill_ParseParams` (`00587630`) in `SR_GameServer.exe`, which
walks the stream and files each recognised run into a field of the skill struct.

## Two branch shapes, and why the distinction matters

**Fixed-run codes** state their own length:

	if (uVar1 == <code>) {
	    *(uint **)(skill + <field>) = cursor + 1;   // the values
	    cursor = cursor + <run>;                    // past code AND values
	}

The run **includes the code word**, so a run of 6 carries 5 values. That is what
makes `att` a six-word run holding the five values this project already reads,
`(type, percent, min, max, percent)`.

**Variable-length codes** do not:

	cursor = cursor + 1;          // skip only the code word
	skill[field] = cursor;        // the values follow; the count is NOT here

An earlier draft of this table reported these as "run 1, 0 values", which is
self-contradictory — the field is pointed at values the run supposedly does not
contain. They are listed separately below, with no length claimed, because the
parser does not state one. Whatever consumes the field decides how far to read.

## How far to trust this

Validated against the three codes this project had recovered independently,
before it was asked anything new:

| control | expected | extracted |
|---|---|---|
| `att` | field `0x230`, 6 words | field `0x230`, 6 words |
| `defp` | field `0x25c`, 4 words | field `0x25c`, 4 words |
| `defr` | field `0x260`, 3 words | field `0x260`, 3 words |

Three of three. 102 of the parser's 105 code comparisons resolve; the remaining
three take a shape the extractor does not model and are omitted rather than
guessed at.

**What this is and is not.** It is the parser's own structure: every code the
server recognises, where it files the values, and how far the cursor moves. It is
**not** a statement of what any code MEANS. The names are suggestive (`heal`,
`resu`, `stns`, `tele`) but a name is not a use-site. To establish meaning,
follow the field offset into `FUN_00594ac0`, the skill-effect applier, which
reads these fields and publishes ParamKeeper params from them. Worked example:
`hwit` (field `0x588`) is read there and written to ParamKeeper param **195** at
slot 0 — a stat modifier, and given the client's own `PARAM_HWAN_TIME_INCREASE`
most likely the berserk-duration bonus, but that last step is an inference and
is flagged as one rather than entered in the table.

## Where the block starts, and what actually occurs

The Param block begins at **column 69** of a skilldata row (rows are 118-119
columns wide). That is measured, not assumed: across every real skill row the
`att` code appears at column 69 in 30,677 of them and never earlier, the later
positions (71, 81, 84) being rows where another run comes first.

Walking from column 69 with the fixed-run lengths below, **19,839 of 36,389 rows
consume their Param block exactly to the end**. The remainder stop at a
variable-length code, which is expected: those do not state a length. The most
common stopper is `efr` (9,534 rows).

Codes at verified code positions, most common first:

| code | field | run | skills |
|---|---|---|---|
| `att` | 0x230 | 6 | 31,266 |
| `mc` | 0x288 | 3 | 28,142 |
| `getv` | 0x56c | 2 | 2,553 |
| `dura` | 0x280 | 2 | 1,979 |
| `bl` | 0x444 | 6 | 1,526 |
| `st` | 0x450 | 4 | 1,510 |
| `da` | 0x240 | 2 | 1,459 |
| `reqi` | 0x2a4 | 3 | 484 |
| `kb` | 0x254 | 3 | 462 |
| `defp` | 0x25c | 4 | 373 |
| `ps` | 0x31c | 4 | 353 |

This doubles as an end-to-end test of the recovered format: a wrong run length
anywhere in a row derails the rest of the walk, so 19,839 clean traversals are
19,839 independent confirmations of every length they touched.

## Fixed-run codes

| code | constant | skill field | run | values |
|---|---|---|---|---|
| `att` | 0x00617474 | `0x230` | 6 | 5 |
| `pdmg` | 0x70646d67 | `0x234` | 2 | 1 |
| `da` | 0x00006461 | `0x240` | 2 | 1 |
| `ck` | 0x0000636b | `0x248` | 2 | 1 |
| `hr` | 0x00006872 | `0x24c` | 3 | 2 |
| `ru` | 0x00007275 | `0x250` | 2 | 1 |
| `kb` | 0x00006b62 | `0x254` | 3 | 2 |
| `defp` | 0x64656670 | `0x25c` | 4 | 3 |
| `defr` | 0x64656672 | `0x260` | 3 | 2 |
| `er` | 0x00006572 | `0x27c` | 3 | 2 |
| `dura` | 0x64757261 | `0x280` | 2 | 1 |
| `onff` | 0x6f6e6666 | `0x284` | 3 | 2 |
| `mc` | 0x00006d63 | `0x288` | 3 | 2 |
| `esht` | 0x65736874 | `0x29c` | 3 | 2 |
| `dcmp` | 0x64636d70 | `0x2a8` | 2 | 1 |
| `mpi` | 0x006d7069 | `0x2b0` | 3 | 2 |
| `hste` | 0x68737465 | `0x2b8` | 2 | 1 |
| `hst3` | 0x68737433 | `0x2c0` | 2 | 1 |
| `irgc` | 0x69726763 | `0x2d0` | 3 | 2 |
| `apru` | 0x61707275 | `0x2d4` | 3 | 2 |
| `apau` | 0x61706175 | `0x2d8` | 3 | 2 |
| `terd` | 0x74657264 | `0x2dc` | 2 | 1 |
| `thrd` | 0x74687264 | `0x2e0` | 2 | 1 |
| `tpad` | 0x74706164 | `0x2e8` | 2 | 1 |
| `tele` | 0x74656c65 | `0x2ec` | 3 | 2 |
| `tel2` | 0x74656c32 | `0x2f0` | 3 | 2 |
| `reat` | 0x72656174 | `0x2fc` | 3 | 2 |
| `fb` | 0x00006662 | `0x310` | 3 | 2 |
| `br` | 0x00006272 | `0x318` | 3 | 2 |
| `ps` | 0x00007073 | `0x31c` | 4 | 3 |
| `heal` | 0x6865616c | `0x324` | 5 | 4 |
| `mwmh` | 0x6d776d68 | `0x32c` | 2 | 1 |
| `resu` | 0x72657375 | `0x330` | 3 | 2 |
| `cura` | 0x63757261 | `0x334` | 2 | 1 |
| `pmmp` | 0x706d6d70 | `0x33c` | 5 | 4 |
| `pmdp` | 0x706d6470 | `0x344` | 5 | 4 |
| `pao` | 0x0070616f | `0x350` | 2 | 1 |
| `cmcr` | 0x636d6372 | `0x36c` | 2 | 1 |
| `lkcp` | 0x6c6b6370 | `0x378` | 2 | 1 |
| `ovl2` | 0x6f766c32 | `0x37c` | 2 | 1 |
| `scls` | 0x73636c73 | `0x380` | 2 | 1 |
| `reqc` | 0x72657163 | `0x39c` | 2 | 1 |
| `tant` | 0x74616e74 | `0x3c8` | 3 | 2 |
| `tnt2` | 0x746e7432 | `0x3cc` | 3 | 2 |
| `dtnt` | 0x64746e74 | `0x3d0` | 3 | 2 |
| `pwdt` | 0x70776474 | `0x3d4` | 2 | 1 |
| `mwdt` | 0x6d776474 | `0x3d8` | 2 | 1 |
| `dru` | 0x00647275 | `0x3e4` | 3 | 2 |
| `stri` | 0x73747269 | `0x3f0` | 3 | 2 |
| `abir` | 0x61626972 | `0x3f8` | 3 | 2 |
| `lfst` | 0x6c667374 | `0x400` | 2 | 1 |
| `mwhs` | 0x6d776873 | `0x404` | 2 | 1 |
| `tran` | 0x7472616e | `0x408` | 3 | 2 |
| `curt` | 0x63757274 | `0x40c` | 3 | 2 |
| `rcur` | 0x72637572 | `0x414` | 2 | 1 |
| `dmgr` | 0x646d6772 | `0x418` | 5 | 4 |
| `abnb` | 0x61626e62 | `0x41c` | 2 | 1 |
| `dtt` | 0x00647474 | `0x420` | 3 | 2 |
| `se` | 0x00007365 | `0x430` | 4 | 3 |
| `pw` | 0x00007077 | `0x434` | 5 | 4 |
| `fe` | 0x00006665 | `0x43c` | 4 | 3 |
| `bl` | 0x0000626c | `0x444` | 6 | 5 |
| `stns` | 0x73746e73 | `0x448` | 4 | 3 |
| `st` | 0x00007374 | `0x450` | 4 | 3 |
| `ds` | 0x00006473 | `0x454` | 5 | 4 |
| `ca` | 0x00006361 | `0x458` | 4 | 3 |
| `cssr` | 0x63737372 | `0x45c` | 5 | 4 |
| `csit` | 0x63736974 | `0x460` | 5 | 4 |
| `cshp` | 0x63736870 | `0x46c` | 7 | 6 |
| `csmp` | 0x63736d70 | `0x470` | 7 | 6 |
| `tb` | 0x00007462 | `0x474` | 5 | 4 |
| `lkdd` | 0x6c6b6464 | `0x480` | 2 | 1 |
| `tcmd` | 0x74636d64 | `0x488` | 3 | 2 |
| `pchr` | 0x70636872 | `0x498` | 2 | 1 |
| `qest` | 0x71657374 | `0x49c` | 5 | 4 |
| `msch` | 0x6d736368 | `0x4a4` | 3 | 2 |
| `rmut` | 0x726d7574 | `0x4ac` | 2 | 1 |
| `luck` | 0x6c75636b | `0x4b8` | 2 | 1 |
| `mstc` | 0x6d737463 | `0x4bc` | 2 | 1 |
| `mscc` | 0x6d736363 | `0x4c0` | 2 | 1 |
| `gdr` | 0x00676472 | `0x4c8` | 2 | 1 |
| `getv` | 0x67657476 | `0x56c` | 2 | 1 |
| `mom` | 0x006d6f6d | `0x57c` | 5 | 4 |
| `expu` | 0x65787075 | `0x580` | 3 | 2 |
| `skc` | 0x00736b63 | `0x584` | 4 | 3 |
| `hwit` | 0x68776974 | `0x588` | 2 | 1 |
| `bldr` | 0x626c6472 | `0x58c` | 4 | 3 |

## Variable-length codes

The parser consumes only the code word and points the field at what follows.

| code | constant | skill field |
|---|---|---|
| `ao` | 0x0000616f | `0x274` |
| `eshp` | 0x65736870 | `0x298` |
| `hitm` | 0x6869746d | `0x2c8` |
| `rpkt` | 0x72706b74 | `0x2cc` |
| `php1` | 0x70687031 | `0x348` |
| `pmp1` | 0x706d7031 | `0x34c` |
| `ssou` | 0x73736f75 | `0x354` |
| `cbuf` | 0x63627566 | `0x358` |
| `nbuf` | 0x6e627566 | `0x35c` |
| `bbuf` | 0x62627566 | `0x360` |
| `lks2` | 0x6c6b7332 | `0x374` |
| `reqi` | 0x72657169 | `0x3b4` |
| `hntp` | 0x686e7470 | `0x48c` |
| `slcc` | 0x736c6363 | `0x494` |
| `nmf` | 0x006e6d66 | `0x594` |

## What a code DOES: the skill-effect join

The table above is the parser's structure — where each code's values are filed.
It says nothing about meaning. `FUN_00594ac0`, the skill-effect applier, reads
those same skill fields and publishes ParamKeeper params from them, so joining
the two gives **code → the stat it modifies**.

Extracted the same way and validated the same way, against three pairs this
project had recovered independently before the join was run:

| control | expected | extracted |
|---|---|---|
| `defp` | params 5/6 at slot 0 (the flat absorb) | `5@0, 6@0` |
| `defr` | params 5/6 at slot 1 (a percentage on it) | `5@1, 6@1` |
| `hwit` | param 195 | `195@0` |

Three of three. Notation below is `param@slot`, where the slot is
GParamKeeper's: 0 base, 1 additive percent, 2 multiplier, 3 percent scale (see
the `reference_sro_server_internals` note and `combat.MitigateDamage`).

Only 22 of the 102 codes publish a param directly. The rest act elsewhere —
teleports, summons, cures, state flags — and reading one of those means
following its field into whatever consumes it, not into this table.

| code | skill field | publishes |
|---|---|---|
| `ru` | `0x250` | 33@0 |
| `defp` | `0x25c` | 5@0, 6@0 |
| `defr` | `0x260` | 5@1, 6@1 |
| `er` | `0x27c` | 9@0 |
| `dcmp` | `0x2a8` | 141@0 |
| `mpi` | `0x2b0` | 145@0, 146@0, 147@0, 148@0, 149@0, 150@0, 27@0, 28@0, 29@0, 30@0, 31@0, 32@0, 11@1 |
| `hste` | `0x2b8` | 23@2, 24@2 |
| `hst3` | `0x2c0` | 23@2, 24@2 |
| `irgc` | `0x2d0` | 25@1, 26@1 |
| `apru` | `0x2d4` | 13@1, 14@1, 15@1, 16@1 |
| `apau` | `0x2d8` | 13@0, 14@0, 15@0, 16@0 |
| `terd` | `0x2dc` | 9@0 |
| `thrd` | `0x2e0` | 11@0 |
| `tpad` | `0x2e8` | 13@1, 14@1 |
| `dru` | `0x3e4` | 128@0, 129@0, 130@0, 131@0 |
| `stri` | `0x3f0` | 1@0 |
| `luck` | `0x4b8` | 173@0 |
| `gdr` | `0x4c8` | 182@0 |
| `expu` | `0x580` | 186@0, 202@0, 187@0 |
| `skc` | `0x584` | 194@0 |
| `hwit` | `0x588` | 195@0 |
| `bldr` | `0x58c` | 198@0, 199@0, 200@0 |

Worth singling out, because they touch params this project already models:

- **`apau`** adds a flat amount to params 13–16 — the physical and magical
  damage min/max. **`apru`** adds a percentage to the same four. Those are the
  params a weapon's range and the Strength-derived term already land in, so a
  buff of either kind stacks into the same slot-0 sum or slot-1 percentage the
  damage pipeline already reads.
- **`stri`** publishes param 1, Strength itself, so a skill can raise the stat
  the damage term derives from.
- **`irgc`** publishes 25 and 26 at slot 1 — `'hprg'` and `'mprg'`, the health
  and mana regeneration params.
- **`er`** and **`terd`** both publish param 9 (`'era'`, parry rate), and
  **`thrd`** publishes 11 (`'hra'`, attack rate).

None of these is wired: srrevamp has no buff system, and a value with no
consumer is the pattern this project keeps correcting. They are recorded so that
a buff system, when it exists, starts from the game's own vocabulary rather than
from invented effects.

## What the codes DO: the code → ParamKeeper join (2026-09-16)

The table above says where each code's values land in the skill struct. This
section says what the engine then does with them, for 28 of the codes.

### Method

A code's meaning is settled by whoever READS its field. Censusing every function
in the server dump for reads of the 87 known field offsets ranks the skill
consumers by how many distinct codes they touch:

| function | distinct code fields read |
|---|---|
| `SkillGlobal::RefSkill_ParseParams` | 87 (the parser itself, by construction) |
| **`Skill_ApplyEffectsToParams`** (`0x00594ac0`) | **34** |
| `Combat_ResolveDamage` | 28 |
| `FUN_00589d20` | 24 |
| `FUN_00589f10` | 16 |
| `FUN_00593f50` | 12 |

`Skill_ApplyEffectsToParams` is the lever: it reads a skill's parsed fields and
pushes them into the target's ParamKeeper, and the dump already annotates each
`SetParam` with its param id. Pairing each skill-field read with the param ids
written within the next 14 lines yields the join below.

### The controls came first

Six of the resulting rows were already established by completely independent
means, and all six reproduce exactly:

| code | joined to | previously established as |
|---|---|---|
| `irgc` | 25, 26 | the skill code that grants `hprg`/`mprg` |
| `er` | 9 | `'era'` → 9, parry rate |
| `hr` | 11 | `'hra'` → 11, attack rate |
| `stri` | 1 | param 1 = Strength |
| `mpi` | 4 | `'mp'` → 4 |
| `dru` | 128, 129, 130, **131** | `'drua'` → 128-131 |

That last row is worth its own note: `dru` joining to **four** params
independently confirms the correction made when the tag vocabulary was
extracted, where a by-hand read of the decompiled C had recorded only three and
missed the fourth behind a `goto`.

`luck` is the other row worth singling out. The tag `luck` is one of the seven
that `Stat_ApplyTaggedModifier` recognises and then ignores — and the skill code
`luck` writes **param 173** here. That is a direct confirmation that "the stat
dispatcher ignores it" never meant "it does nothing", which is exactly the
narrowing that section of `param_tags.md` had to make.

### The join

| code | writes ParamKeeper params |
|---|---|
| `apau` | 13, 14, 15, 16 |
| `apru` | 13, 14, 15, 16, 57 |
| `bldr` | 198, 199, 200 |
| `dcmp` | 141 |
| `defr` | 5, 6, 7 |
| `dru` | 128, 129, 130, 131 |
| `dtt` | 188 |
| `er` | 9 |
| `expu` | 186, 202 |
| `gdr` | 172, 182 |
| `hr` | 11 |
| `hst3` | 23, 24 |
| `hste` | 23, 24 |
| `hwit` | 195 |
| `irgc` | 25, 26 |
| `luck` | 173 |
| `mpi` | 4 |
| `onff` | 26 |
| `pmdp` | 5, 6, 170 |
| `reat` | 145, 146, 147, 148, 149, 150 |
| `ru` | 33 |
| `skc` | 194 |
| `stri` | 1 |
| `tant` | 187 |
| `terd` | 9 |
| `thrd` | 11 |
| `tpad` | 13, 14 |

Readable immediately from the param registry: `apau`/`apru`/`tpad` move the
damage bounds (13-16), `defr`/`pmdp` the defences (5, 6, 7), `hst3`/`hste` the
**movement pair** (23, 24), `er`/`terd` parry and `hr`/`thrd` attack rate.

### Limits, stated

- **This is a proximity join, not a proof per row.** Six rows are controlled;
  the rest rest on the same mechanism and the same 14-line window. A row here is
  good evidence about which params a code touches, and is NOT a claim about the
  code's full semantics — duration, stacking and target selection are not in it.
- It covers only the codes `Skill_ApplyEffectsToParams` handles. Codes consumed
  by `Combat_ResolveDamage`, `FUN_00589d20` and the cure/resurrect handler at
  `FUN_00593f50` (`cura`, `curt`, `heal`, `rcur`, `resu`, `rmut`, `tran`) are
  not joined here.
- None of it is wired into srrevamp, which models skill damage but no stat
  buffs. It is vocabulary for when that changes.

## The combat-side codes, and a correction to the census above (2026-09-16)

`Combat_ResolveDamage` came second in the reader census at 28 distinct code
fields. **That number is misleading, and the way it misleads is worth recording
because the census is a tool this project will reuse.**

Twenty of those 28 appear exactly once each, all inside a single `== 0 && ... ==
0` chain spanning about twenty lines — one composite guard asking *"does this
skill carry any effect field at all?"* before taking the plain-attack path. A
code named in that guard is being tested for presence, not acted on. So
**ranking functions by distinct offsets read over-counts anything with a large
null-guard**, and the fix is to weight by the number of reads per code rather
than by distinct codes.

By read count, the codes `Combat_ResolveDamage` actually acts on are `att` (15),
`da` (12), `tant` and `tnt2` (5 each), `ck` and `dtnt` (4), `kb`, `lfst` and
`pdmg` (3).

### `da` — a conditional damage percentage

```c
if (skill[0x240] != 0 && target->vf[0xfc]() == 8) {
    dmg[0x28] = round(da[0] * dmg[0x28] / 100.0);
    dmg[0x24] = round(da[0] * dmg[0x24] / 100.0);
}
```

`da[0]` is a percentage (the divisor is the familiar 100.0 at `0xb45af0`) and it
scales **both** damage fields, not one. The gate is the target's kind from
`vf[0xfc]`, a small enum compared across the binary against only 0, 8 and 11 —
**what kind 8 denotes is not recovered**, so this is "a damage bonus against one
specific target kind" and no more.

### `kb` — knockback

Gated on four conditions at once: the skill carries `kb`, the attacker's ref
object has bit 1 set at `+0x258`, the result byte is not already 4, and
`GObjPC::FUN_005a1a20()` passes. It then sets the hit-result byte to **5** and
does position arithmetic reading `kb[1]`, copying attacker and target coordinate
triples (`[0x22]`, `[0x23]`, `[0x24]` on each).

**A near-miss worth recording**: a line five instructions earlier computes
`x / 1000.0 + 0.5` (both constants `QWORD`, so doubles) and looked exactly like a
knockback duration in seconds. It is in the preceding block, not the `kb` branch,
and is NOT attributed here. The same care that separates a guard from an action
separates a neighbouring block from the one being read.

None of this is wired into srrevamp: it has no target-kind concept for `da` and
no knockback result for `kb`.
