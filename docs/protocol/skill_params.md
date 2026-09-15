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
