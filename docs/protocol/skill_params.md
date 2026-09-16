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

Three of three. 104 of the parser's 105 code comparisons resolve; the remaining
one takes a shape the extractor does not model and is omitted rather than
guessed at.

**Corrected 2026-09-16.** This said 102 of 105 until a second, independent walker
was run over the same function — one that follows each `je` to its target rather
than reading the fall-through. It agrees on 88 of 90 fixed-run codes and
disagrees on two, `pw` and `skc`, whose fields belonged to the *next* tag in the
search tree. Both were corrected, and the two tags whose fields they had taken
(`rt`, `spi`) were added. See "The damage-type mask, and two corrections to the
table above" at the end of this file.

**An open lead, recorded as a lead and not as a finding.** That second walker
also finds roughly 55 further tag comparisons in this function that are in
neither table here — plausible-looking 2-to-4 character tags, each with its own
distinct field offset. They have not been hand-verified, and this walker has
already over-reported once (it read the in-handler `cmp edx,0x4` value tests as
tags until it was constrained to tags ≥ 0x100). So the count above is still the
extractor's; whether the vocabulary is really ~105 or ~145 is open.

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
| `pdm2` | 0x70646d32 | `0x238` | 2 | 1 |
| `da` | 0x00006461 | `0x240` | 2 | 1 |
| `ck` | 0x0000636b | `0x248` | 2 | 1 |
| `hr` | 0x00006872 | `0x24c` | 3 | 2 |
| `ru` | 0x00007275 | `0x250` | 2 | 1 |
| `kb` | 0x00006b62 | `0x254` | 3 | 2 |
| `defp` | 0x64656670 | `0x25c` | 4 | 3 |
| `defr` | 0x64656672 | `0x260` | 3 | 2 |
| `spda` | 0x73706461 | `0x264` | 3 | 2 |
| `er` | 0x00006572 | `0x27c` | 3 | 2 |
| `dura` | 0x64757261 | `0x280` | 2 | 1 |
| `onff` | 0x6f6e6666 | `0x284` | 3 | 2 |
| `mc` | 0x00006d63 | `0x288` | 3 | 2 |
| `esht` | 0x65736874 | `0x29c` | 3 | 2 |
| `cnsm` | 0x636e736d | `0x2a0` | 4 | 3 |
| `dcmp` | 0x64636d70 | `0x2a8` | 2 | 1 |
| `hpi` | 0x00687069 | `0x2ac` | 3 | 2 |
| `mpi` | 0x006d7069 | `0x2b0` | 3 | 2 |
| `pw` | 0x00007077 | `0x2b4` | 5 | 4 |
| `hste` | 0x68737465 | `0x2b8` | 2 | 1 |
| `hst2` | 0x68737432 | `0x2bc` | 2 | 1 |
| `hst3` | 0x68737433 | `0x2c0` | 2 | 1 |
| `irgc` | 0x69726763 | `0x2d0` | 3 | 2 |
| `apru` | 0x61707275 | `0x2d4` | 3 | 2 |
| `apau` | 0x61706175 | `0x2d8` | 3 | 2 |
| `terd` | 0x74657264 | `0x2dc` | 2 | 1 |
| `thrd` | 0x74687264 | `0x2e0` | 2 | 1 |
| `tpad` | 0x74706164 | `0x2e8` | 2 | 1 |
| `tele` | 0x74656c65 | `0x2ec` | 3 | 2 |
| `tel2` | 0x74656c32 | `0x2f0` | 3 | 2 |
| `tel3` | 0x74656c33 | `0x2f4` | 3 | 2 |
| `reat` | 0x72656174 | `0x2fc` | 3 | 2 |
| `real` | 0x7265616c | `0x300` | 4 | 3 |
| `pola` | 0x706f6c61 | `0x304` | 3 | 2 |
| `summ` | 0x73756d6d | `0x308` | 6 | 5 |
| `fb` | 0x00006662 | `0x310` | 3 | 2 |
| `br` | 0x00006272 | `0x318` | 3 | 2 |
| `ps` | 0x00007073 | `0x31c` | 4 | 3 |
| `zb` | 0x00007a62 | `0x320` | 3 | 2 |
| `heal` | 0x6865616c | `0x324` | 5 | 4 |
| `mwhh` | 0x6d776868 | `0x328` | 2 | 1 |
| `mwmh` | 0x6d776d68 | `0x32c` | 2 | 1 |
| `resu` | 0x72657375 | `0x330` | 3 | 2 |
| `cura` | 0x63757261 | `0x334` | 2 | 1 |
| `pmhp` | 0x706d6870 | `0x338` | 5 | 4 |
| `pmmp` | 0x706d6d70 | `0x33c` | 5 | 4 |
| `pmdg` | 0x706d6467 | `0x340` | 5 | 4 |
| `pmdp` | 0x706d6470 | `0x344` | 5 | 4 |
| `pao` | 0x0070616f | `0x350` | 2 | 1 |
| `cmcr` | 0x636d6372 | `0x36c` | 2 | 1 |
| `lnks` | 0x6c6e6b73 | `0x370` | 5 | 4 |
| `lkcp` | 0x6c6b6370 | `0x378` | 2 | 1 |
| `ovl2` | 0x6f766c32 | `0x37c` | 2 | 1 |
| `scls` | 0x73636c73 | `0x380` | 2 | 1 |
| `puls` | 0x70756c73 | `0x384` | 2 | 1 |
| `reqc` | 0x72657163 | `0x39c` | 2 | 1 |
| `atca` | 0x61746361 | `0x3bc` | 3 | 2 |
| `tant` | 0x74616e74 | `0x3c8` | 3 | 2 |
| `tnt2` | 0x746e7432 | `0x3cc` | 3 | 2 |
| `dtnt` | 0x64746e74 | `0x3d0` | 3 | 2 |
| `pwdt` | 0x70776474 | `0x3d4` | 2 | 1 |
| `mwdt` | 0x6d776474 | `0x3d8` | 2 | 1 |
| `dmgt` | 0x646d6774 | `0x3dc` | 3 | 2 |
| `dru` | 0x00647275 | `0x3e4` | 3 | 2 |
| `expi` | 0x65787069 | `0x3ec` | 3 | 2 |
| `stri` | 0x73747269 | `0x3f0` | 3 | 2 |
| `inti` | 0x696e7469 | `0x3f4` | 3 | 2 |
| `abir` | 0x61626972 | `0x3f8` | 3 | 2 |
| `lfst` | 0x6c667374 | `0x400` | 2 | 1 |
| `mwhs` | 0x6d776873 | `0x404` | 2 | 1 |
| `tran` | 0x7472616e | `0x408` | 3 | 2 |
| `curt` | 0x63757274 | `0x40c` | 3 | 2 |
| `rcur` | 0x72637572 | `0x414` | 2 | 1 |
| `dmgr` | 0x646d6772 | `0x418` | 5 | 4 |
| `abnb` | 0x61626e62 | `0x41c` | 2 | 1 |
| `dtt` | 0x00647474 | `0x420` | 3 | 2 |
| `hide` | 0x68696465 | `0x428` | 4 | 3 |
| `dcri` | 0x64637269 | `0x42c` | 2 | 1 |
| `se` | 0x00007365 | `0x430` | 4 | 3 |
| `rt` | 0x00007274 | `0x434` | 4 | 3 |
| `fe` | 0x00006665 | `0x43c` | 4 | 3 |
| `my` | 0x00006d79 | `0x440` | 5 | 4 |
| `bl` | 0x0000626c | `0x444` | 6 | 5 |
| `stns` | 0x73746e73 | `0x448` | 4 | 3 |
| `dn` | 0x0000646e | `0x44c` | 5 | 4 |
| `st` | 0x00007374 | `0x450` | 4 | 3 |
| `ds` | 0x00006473 | `0x454` | 5 | 4 |
| `ca` | 0x00006361 | `0x458` | 4 | 3 |
| `cssr` | 0x63737372 | `0x45c` | 5 | 4 |
| `csit` | 0x63736974 | `0x460` | 5 | 4 |
| `cspd` | 0x63737064 | `0x464` | 5 | 4 |
| `csmd` | 0x63736d64 | `0x468` | 5 | 4 |
| `cshp` | 0x63736870 | `0x46c` | 7 | 6 |
| `csmp` | 0x63736d70 | `0x470` | 7 | 6 |
| `tb` | 0x00007462 | `0x474` | 5 | 4 |
| `lkag` | 0x6c6b6167 | `0x47c` | 3 | 2 |
| `lkdd` | 0x6c6b6464 | `0x480` | 2 | 1 |
| `tcmd` | 0x74636d64 | `0x488` | 3 | 2 |
| `skc` | 0x00736b63 | `0x490` | 4 | 3 |
| `pchr` | 0x70636872 | `0x498` | 2 | 1 |
| `qest` | 0x71657374 | `0x49c` | 5 | 4 |
| `msch` | 0x6d736368 | `0x4a4` | 3 | 2 |
| `mcap` | 0x6d636170 | `0x4a8` | 3 | 2 |
| `rmut` | 0x726d7574 | `0x4ac` | 2 | 1 |
| `luck` | 0x6c75636b | `0x4b8` | 2 | 1 |
| `mstc` | 0x6d737463 | `0x4bc` | 2 | 1 |
| `mscc` | 0x6d736363 | `0x4c0` | 2 | 1 |
| `msid` | 0x6d736964 | `0x4c4` | 2 | 1 |
| `gdr` | 0x00676472 | `0x4c8` | 2 | 1 |
| `dgmp` | 0x64676d70 | `0x4cc` | 2 | 1 |
| `getv` | 0x67657476 | `0x56c` | 2 | 1 |
| `mom` | 0x006d6f6d | `0x57c` | 5 | 4 |
| `expu` | 0x65787075 | `0x580` | 3 | 2 |
| `spi` | 0x00737069 | `0x584` | 2 | 1 |
| `hwit` | 0x68776974 | `0x588` | 2 | 1 |
| `bldr` | 0x626c6472 | `0x58c` | 4 | 3 |
| `msr` | 0x006d7372 | `0x590` | 3 | 2 |

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


## The consumer census was contaminated twice — corrected (2026-09-16)

The reader census that selected `Skill_ApplyEffectsToParams` ranked functions by
how many distinct skill-field offsets they mention. That ranking had **two**
false-positive sources, and both are now measured.

### 1. Vtable calls, not field reads — 58.6% of all occurrences

An offset like `0x27c` is `er`'s field, and it is also a vtable slot. Grepping
`+ 0x27c)` finds both. Dump-wide, over every skill-field offset:

	any occurrence      2,851
	VTABLE calls        1,670   (58.6%)
	typed FIELD reads     664   (23.3%)

`er` (0x27c) is the extreme: **407 vtable calls against 4 real reads.** `scls`
(0x380) is 314 against 4. So more than half of what the census counted as
evidence was a virtual call that has nothing to do with skills.

Filtering to typed reads (`*(int *)(x + 0xNNN)` and friends) drops
`Skill_ApplyEffectsToParams` from 34 distinct codes to **23**, and
`Combat_ResolveDamage` from 28 to 24.

### 2. Guard chains — already known, now applied together

A code tested once in a `== 0 && ... == 0` chain is being checked for presence,
not acted on. Weighting by codes read **more than once** and applying the typed
filter gives the first honest consumer ranking:

| function | acted on | of | dominant codes |
|---|---|---|---|
| `Combat_ResolveDamage` | 12 | 24 | att(11), tant(4), tnt2(4), da(4) |
| `Skill_ApplyEffectsToParams` | 12 | 23 | defp(5), dru(4), apau(4), apru(4) |
| `FUN_0091f330` | 7 | 11 | lfst(8) |
| `FUN_00593f50` | 7 | 9 | heal(7), resu(5), curt(4) |
| `FUN_00586700` | 3 | 3 | tel2(5), tele(3) |

**`FUN_00589d20` (24 codes) and `FUN_00589f10` (16) drop off the list entirely** —
every one of their codes is read exactly once, so they are pure guard functions.
The naive ranking put them at the top and would have sent a reader to spend a
tick on functions that do nothing with those codes.

### What this does and does not invalidate

The **code → param join stands.** It was validated by six independent controls
that reproduced exactly, and its mechanism — pairing a field read with the
`SetParam` annotation that follows — cannot be produced by a vtable call. What
was contaminated is the *selection* of which function to read, not the join
computed from it. `Skill_ApplyEffectsToParams` turns out to be tied rather than
dominant: a right answer reached partly by luck.

**Not claimed**: the three functions above are dominated by one code each
(`lfst`, `heal`/`resu`, `tel2`/`tele`), which is suggestive of life-steal, healing
and teleport handlers. Neither `FUN_00586700` nor `FUN_0091f330` carries a string
confirming it, and `FUN_0091f330` is a vtable slot in the quest band. Naming them
from the code's abbreviation is the reasoning this project has rejected
repeatedly, so they stay unnamed.


## `tant` and `tnt2`: the mechanic, recovered; the name, not (2026-09-16)

Two codes that the corrected consumer ranking showed `Combat_ResolveDamage`
genuinely acts on (4 typed reads each, not guard mentions). `tant` is on **293**
skill rows and `tnt2` on **550**.

Both have run length 3 — the code plus two words — and both are used the same
way:

```c
acc = state[0x1c] + src[0x20];                      // running accumulator
pct = code[1];
acc = round(acc * (pct / 100.0 + 1.0));             // 0xb45af0 = 100.0, 0xb45ac0 = 1.0
state[0x1c] = code[0] + acc;                        // then the flat word
```

So each code carries a **(flat, percent) pair**: scale the accumulator by
`1 + percent/100`, then add the flat amount. The run length agrees exactly — two
words, both used, none spare.

**They are alternatives, not cumulative.** The branch is
`if (tant == 0) { if (tnt2 != 0) {…} } else {…}`: `tant` takes precedence and
`tnt2` applies only in its absence. Both arms compute the identical formula, so
the two codes differ in *when* they apply, not in *what* they do.

**What the value is remains unrecovered.** `state` is an object constructed a few
lines earlier in the damage path — fields at 0x24-0x48 are filled in, including
the float 2.0 at +0x48 — and `+0x1c` is the field this pair scales. That is the
shape of a timed status-effect record rather than the blow's damage, which is
carried in the separate fields `da` scales (`+0x24` and `+0x28`). Which quantity
+0x1c holds is not settled here, so the codes are recorded with their mechanic
and without a name.

The client's `PARAM_*` set offers `PARAM_TIME_BOMB` and similar as tempting
matches for `tant`/`tnt2`. That is an abbreviation argument with no use-site, and
it is not taken.

## The damage-type mask, and two corrections to the table above (2026-09-16)

**Two rows in the table above were wrong, and the table has been corrected.**
They were not omissions — they were mis-pairings, and both have the same cause.

The parser's tag tests come in two shapes. Most are `cmp edx,TAG` / `jne <next
test>`, where the handler follows immediately. But some are `cmp edx,TAG` / `je
<handler elsewhere>`, and there the *next* instructions are the following tag's
handler, not this one's. The mechanical extractor recorded the fall-through in
both cases, so for two codes it filed the **next tag's** field:

| code | was | is | what `was` actually belongs to |
|---|---|---|---|
| `pw` | `0x434` | **`0x2b4`** | `rt`, which was missing entirely |
| `skc` | `0x584` | **`0x490`** | `spi`, which was missing entirely |

Both recovered tags have been added. Verified by hand at `005879c1` (`pw`/`rt`)
and `00587d6c` (`skc`/`spi`), and then mechanically: a walker that follows each
`je` to its target and reads the field it stores agrees with the corrected table
on **88 of 90** fixed-run codes and disagrees on exactly these two.

The two errors are not random. `pw` and `skc` are the only two codes whose
handler **rewrites the value it points at** instead of just filing a pointer, and
it is that unusual shape — a store followed immediately by `cmp DWORD PTR
[edx],0x4` rather than by the loop tail — that the extractor's handler-detection
tripped over. Which is the useful part: the failure had a signature, and the
signature is exhausted.

A note on tag width, because the decompiler misleads here. Ghidra renders these
compares as `uVar1 == 0x7077`, which looks like a truncated 16-bit test against a
4-byte tag. It is not. `005879c1` is `cmp edx,0x7077` — a full 32-bit compare
against a value whose top two bytes are zero. Short tags are ordinary in this
table (`rt` 0x7274, `ru` 0x7275, `st` 0x7374, `se` 0x7365, `dru` 0x647275).

### The parser normalises value[0]

`pw` at `005879e9` (and `skc` at `00587d94`, identically):

```
skill[0x2b4] = cursor + 1;             // the field points at value[0]
v = *(cursor + 1);
if (v == 4 || v == 8 || v == 0xc)      v |= 1, v |= 2;
else if (v == 1 || v == 2 || v == 3)   v |= 4, v |= 8;
cursor += 5;                            // code + 4 values, on every path
```

So value[0] is a **4-bit mask over two independent axes** — bits 1/2 and bits
4/8 — and the parser's job is to fill in whichever axis the author left out with
"both". Whatever the author wrote survives; only the missing axis is defaulted.

### What bits 4 and 8 mean

The same two bits appear in `att` value[0], and there they are load-bearing.
`Formula_MitigatePhysicalDamage` (`0040e450`) and
`Formula_MitigateMagicalDamage` (`0040e830`) both open with the same guard:

```c
if (skill[0x230] == 0 || ... || ((**(byte **)(skill + 0x230) & BIT) == 0))
    return 0;                   // BIT is 4 for physical, 8 for magical
```

and the raw-damage builders beneath them draw on a different pair of stats each
— `0040db50` reads ParamKeeper param `(max ? 1 : 0) + 13`, `0040dc10` reads
`(max ? 1 : 0) + 15`. The recovered registry names those independently:
**13/14 phys damage low/high, 15/16 mag damage low/high**
(docs/protocol/param_registry.md). `0040db50` also gates its flat `att` min/max
add on the same `test BYTE PTR [eax],0x4`.

**Bit 4 is physical, bit 8 is magical.** Two sources agree without being asked
to: the formula guards and the stat pairs.

### The blow's total is the sum of its halves — and only one is ever live

`Combat_ResolveDamage` writes the two halves into a per-blow record and sums
them:

```c
rec[0x28] = Formula_MitigatePhysicalDamage(...);   // physical
rec[0x24] = Formula_MitigateMagicalDamage(...);    // magical
...
rec[0x20] = rec[0x28] + rec[0x24];
```

This project treated that sum as dangerous for three ticks — summing two halves
could double a blow. **Measured against the real table, it cannot.** Across
36,389 real skilldata rows, 31,605 carry `att`, and the distribution of
value[0] is:

| value[0] | bits | rows | half |
|---|---|---|---|
| 5 | {1,4} | 17,075 | physical |
| 10 | {2,8} | 6,971 | magical |
| 6 | {2,4} | 4,055 | physical |
| 9 | {1,8} | 2,528 | magical |
| 8 | {8} | 966 | magical |
| 0 / 1 / 2 | — | 10 | neither |

**Zero rows of 31,605 set both bit 4 and bit 8.** The two formulas are mutually
exclusive by authoring, and the sum has exactly one non-zero term. So the sum is
not a doubling risk; it is how the engine writes "whichever half this skill
deals".

Bits 1 and 2 are a second, orthogonal axis. In the magical formula they select
which flat-absorption param is read — bit 1 → param `0x82` (130), bit 2 → param
`0x83` (131), via the getter at vtable `+0x104`. Every real row sets exactly one
of them, which is why the 4/8 and 1/2 pairs both look like enums in the table
above.

### Where `pw` is read

`Combat_ResolveDamage` reads `pw` value[0] off a *different* skill than the one
being cast — one reached through an object hanging off `+0xC0C` of a character
in the blow — and uses its bits to **suppress** the corresponding half:

```c
if (holder != 0) {
    if (**(byte **)(*(int *)(*(int *)(holder + 0x18) + 8) + 0x2b4) & 4)  rec[0x28] = 0;
    if (**(byte **)(*(int *)(*(int *)(holder + 0x18) + 8) + 0x2b4) & 8)  rec[0x24] = 0;
}
```

applied twice: once to the base blow, and once to a second damage record the
same holder contributes before it is added in. Note the polarity is the
**opposite** of `att`'s: in `att` a set bit *enables* a half, in `pw` a set bit
*removes* it.

### Which skills carry it, and what that says

61 `pw` runs exist in the whole real table, and every one belongs to a Cold or
Fire "Wall" skill:

| value[0] | bits | effect | skills |
|---|---|---|---|
| 7 | {1,2,4} | removes the physical half | `SKILL_CH_COLD_BINGBYEOK_A..D` (빙벽, ice wall) |
| 11 | {1,2,8} | removes the magical half | `SKILL_CH_FIRE_HWABYEOK_A..E` (화벽, fire wall) |

Both authored values are from the 4/8 axis, which is why the parser filled in
bits 1|2 on every one of them — the `1/2/3` arm of that branch exists in the
code and is used by nothing that shipped.

**What is not settled:** whether `+0xC0C` hangs off the attacker or off the
target. The decompiler reuses one variable for both the `mc` param pointer and,
later, an object returned from a lookup, so the receiver cannot be read off the
C without following the lookup. A barrier that removes one damage type reads
naturally as a buff on the *target*, and the skill names agree with that, but a
name is not a use-site and this one is left open rather than asserted.

### `skc` is the same vocabulary used as a filter

`skc` (field `0x490`, run 4) carries values from the same 4-bit space and is
consumed as a **mask intersection** rather than a switch:

```c
(**(uint **)(skill + 0x230) & **(uint **)(other + 0x490)) != 0
```

— `att` value[0] AND-ed with `skc` value[0]. That is one line, and it is what
ties the three codes together: they are not three private encodings that happen
to use small integers, they are one damage-type vocabulary, written by `att`,
tested by `skc`, and inverted by `pw`.

Measured over the real table, 181 `skc` runs carry value[0] ∈ {15, 12, 0} —
every one a clean mask, none a magnitude — on EU guard, invisibility and dance
buffs (`SKILL_EU_BARD_BATTLAA_GUARD_A`, `SKILL_EU_WIZARD_COLDA_INVISIBLE_A`, …).
15 is all four bits and so intersects any blow; 12 is {4,8} and intersects any
blow that deals damage at all, irrespective of the 1/2 axis.

The two codes recovered alongside them do **not** belong to this vocabulary, and
saying so is the point of measuring rather than assuming:

| code | field | run | real values | carriers |
|---|---|---|---|---|
| `rt` | `0x434` | 4 | 10000 (×225), 3000 (×4) | `*_ROOT_*`, `*_ABNORMAL_*` |
| `spi` | `0x584` | 2 | 11, 12, 15 (×1 each) | `SKILL_ITEM_ETC_SOCKET_STONE_SP_E` |

`rt`'s values are magnitudes, not masks — 10000 on 225 of 230 runs, which has the
shape of a per-myriad rate but is not claimed as one here. `spi` occurs three
times in the entire table and its three values are mask-shaped, which is
suggestive and nothing more.

## `ReqCast_Weapon`: the weapon gate, recovered (2026-09-16)

Not a param code — two fixed columns — but it belongs here because it decides
whether a skill runs at all, and because it settles a question the damage work
kept bumping into.

### The engine names the field itself

`SkillGlobal::FUN_005893e0`, the skilldata row loader, validates every row:

```c
if ((*(char *)(skill + 199) == '\0') || (*(char *)(skill + 200) == '\0')) {
    FUN_00936640(0x2000000, "ReqWeapon Error [RefSkill ID: %d]", skill[4]);
    Assert_BreakIfDebugger();
}
```

So `CRefSkill+199` and `+200` (0xc7/0xc8) are the two required-weapon bytes,
named by the game's own error string rather than by a schema listing. **Zero is
invalid** — the loader refuses it — which is worth knowing, because it means 0
is not "no requirement".

### The check

`FUN_0058d480(actor, skill)`:

```c
if (skill[0x3a0] == 0) {                                  // no override list
    if (skill[199] == -1 && skill[200] == -1) return 0;   // no requirement
    code = *(ushort *)equippedWeapon >> 11;               // the TID's top 5 bits
    if (code == 0) code = 1;                              // BARE HANDS == 1
    for (p = skill + 199; p - skill < 201; p++)
        if (*p != 0xff && code == *p) goto ok;            // exactly two slots
    return 0x300d;                                         // wrong weapon
}
```

So the code is `TID >> 11`, `0xff` marks an unused slot, both `0xff` means no
requirement, an empty hand reads as **1**, and a mismatch is error **0x300d**.
Code **16** is special-cased into `GObjPC::FUN_004f1130`.

### The vocabulary, confirmed by the skills' own names

Columns **50 and 51** carry these bytes. That mapping is not taken from a schema
listing — it is confirmed by the data confirming itself. Grouping all 36,389
real rows by the family in their `Basic_Code` and taking each family's code:

| code | weapon | named by | code | weapon | named by |
|---|---|---|---|---|---|
| 1 | bare hand | the `code == 0` branch | 9 | axe | `SKILL_EU_AXE` |
| 2 | CH sword | `SKILL_CH_SWORD` (2,3) | 10 | wand | `SKILL_EU_WAND`, `_WARLOCK` |
| 3 | CH blade | " | 11 | staff | `SKILL_EU_STAFF`, `_WIZARD` |
| 4 | CH spear | `SKILL_CH_SPEAR` (4,5) | 12 | crossbow | `SKILL_EU_CROSSBOW` |
| 5 | CH glaive | " | 13 | dagger | `SKILL_EU_DAGGER`, `_ROG` |
| 6 | bow | `SKILL_CH_BOW` | 14 | harp | `SKILL_EU_HARP`, `_BARD` |
| 7 | EU sword | `SKILL_EU_SWORD` | 15 | cleric rod | `SKILL_EU_CLERIC` |
| 8 | EU two-hander | `SKILL_EU_TSWORD` | 16 | fortress weapon | `SKILL_*_FORTRESSWEAPON` |

Twenty-four families, each landing on the code its own name says it should.
`SKILL_CH_SWORD` and `SKILL_CH_SPEAR` are the only ones using both slots, and
they use them for the two weapons of the same class — which is what a two-slot
field is for.

### What this settles about magical damage

**4,144 of the 10,465 magical attack skills require no weapon at all** (both
bytes `0xff`) — every CH elemental nuke among them. So the engine does *not*
prevent casting a magical skill with a physical-only weapon, and an earlier
entry that deferred work on the claim that it does was wrong.

Nor does that produce a 1-damage blow. The skill's own flat `att` damage is
added to the bound inside the builder regardless of the weapon (`0040dc10` reads
the attack descriptor's `+0xc`), and across those 4,144 rows the median flat is
**2,068** against a median percent of **263**. The weapon's contribution is the
small term.

| kind | weapon requirement | rows |
|---|---|---|
| magical | none | 4,144 |
| magical | required | 6,321 |
| physical | none | 11,499 |
| physical | required | 9,631 |
| neither | none | 10 |

**Not yet wired into srrevamp.** The gate needs the equipped item's TID, and
`refdata.Item` does not carry one — exporting it is the next step.

## The vocabulary is 148 codes, and the walk now closes (2026-09-16)

An earlier section recorded an open lead: a second walker found "roughly 55
further tag comparisons in this function that are in neither table", unverified,
with the note that *"whether the vocabulary is really ~105 or ~145 is open"*.
**It is 148, and the question is now closed by a structural test rather than by
reading more disassembly.**

### The test

Walk every real skilldata row's Param block from column 69 using a table's run
lengths, and count how each walk ends: **clean** (reaches the `0` terminator or
the row's end), **varlen-stop** (hits a code with no stated length), or
**unknown** (hits a code the table does not have). A wrong run length lands the
cursor on a *value* and derails everything after it, so this fails loudly in the
direction that matters.

| table | fixed | varlen | clean | varlen-stop | unknown |
|---|---|---|---|---|---|
| the doc's table, as it stood | 89 | 15 | 19,155 | 1,609 | 15,625 |
| + 30 recovered fixed-run codes | 119 | 15 | 19,990 | 1,845 | 14,554 |
| + 14 recovered stoppers | 119 | 29 | 19,990 | 16,399 | **0** |

**Zero of 36,389 rows now hit an unrecognised code.** Every code the real table
uses is in this file.

(The control's 19,155 differs from the 19,839 quoted earlier in this document.
Two harnesses, slightly different end conditions — what is comparable is the
delta *within* one harness, and the load-bearing number is the unknown column
going to zero.)

### Each addition was confirmed on its own

Adding all 30 at once raises clean walks by 835, which a batch of wrong runs
could not do. Adding them **one at a time** against the unmodified table: 24
raise the clean count on their own, 4 are neutral (the rows reaching them stop
later on a different code, so they cannot complete a walk alone), and **none
lower it**. `cnsm` alone accounts for 226 rows, `atca` 115, `mwhh` 65.

### Why the raw walker output was worthless and these 30 are not

Taking the walker's whole 145-tag table and walking with it scores **910** clean
— far worse than the doc's 89 codes. That is not a paradox, it is the walker's
run lengths being unreliable: it accumulates `add ecx,N` over a fixed window and
under-counts any handler that adds more inside a branch. So the walker is a good
*finder* of tags and a bad *source* of runs, and only the entries that real data
actually exercises — where the walk confirms the run — are published here.

This is the same lesson the `pw`/`skc` correction taught, arriving from the other
side: that correction came from a walker disagreeing with the table, and this one
comes from real data disagreeing with the walker.

### The stoppers, and one that is understood

Fourteen codes stop a walk. Five have a recovered field:

| code | constant | skill field |
|---|---|---|
| `odar` | 0x6f646172 | `0x270` |
| `trap` | 0x74726170 | `0x4a0` |
| `efta` | 0x65667461 | `0x4b0` |
| `lkdr` | 0x6c6b6472 | `0x478` |
| `nmh` | 0x006e6d68 | `0x598` |

Nine do not: **`bu`, `cr`, `curl`, `efr`, `es`, `fz`, `ko`, `setv`, `sl`**. They
are listed because real rows demonstrably stop on them — `efr` on 9,538 rows, the
single most common stopper in the table — not because their handlers have been
read.

`efr` explains the class. It *is* dispatched by an ordinary `cmp edx,0x656672`,
but its handler does not store a field and move on:

```
587bf6:  mov  edx,DWORD PTR [eax+0x4]   <- value[0]
587bfc:  add  ecx,0x1
587bff:  sub  edx,0x1 / je ...          <- branch on the value
587c04:  sub  edx,0x1 / je ...
```

It **branches on its own first value** before storing anything, so the field and
the run depend on that value. That is exactly the shape that mis-filed `pw` and
`skc`, and it is why a scanner looking for the next `mov [esi+N],eax` finds the
wrong one or none at all.

So "variable-length" is the right *operational* class for these — a walk cannot
pass them — but the mechanism is value dispatch rather than an unstated count,
and that distinction is recorded rather than smoothed over.
