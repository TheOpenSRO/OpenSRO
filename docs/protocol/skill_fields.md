# The `CRefSkill` field map

Every `skill+0xNNN` the combat code reads, named. Recovered 2026-09-17 from
`SkillGlobal::RefSkill_ParseParams` (`0x00587630`, 7,509 bytes), which walks a
skill's Param stream as `(code, values...)` runs and stores each value into a
field of the record. Regenerate with `client/tools/re/skillfields.py`.

Before this, `docs/protocol/` named **two** `CRefSkill` offsets. It now names
119.

## The trap, because the first extraction was wrong

MSVC compiles a large switch on sparse values as a **binary search tree** of
comparisons, not an if-else chain. So the nearest preceding `cmp reg,CODE`
before a store is *not* the code that matched — it is whichever tree node was
visited last on the way down.

Pairing stores with the nearest preceding comparison produces a map that is
plausible, monotonic, and wrong. It gave:

	pdm2 -> 0x234     but Combat_ResolveDamage's own comment says 0x234 is pdmg
	resu -> 0x3a0     but skill_params.md says 0x3a0 is reqi's five-slot list

Both anchors disagreed, which is the only reason it was caught. The fix is to
follow control flow instead of proximity: a case body is the target of a `je`
from the comparison that **matched**; `ja`/`jb` are tree navigation and must be
ignored.

This project's own notes already called the binary-search-tree shape a trap when
reading the ParamKeeper tag dispatcher. It cost a first pass here anyway, which
is worth recording: knowing a trap by name is not the same as recognising it in
a new function.

## Verification

Three anchors, none of them used to build the map:

| offset | code | independent source |
|---|---|---|
| `0x234` | `pdmg` | the existing Ghidra comment on `Combat_ResolveDamage` |
| `0x240` | `da` | `skill_params.md`'s "`da` — a conditional damage percentage"; `Combat_ResolveDamage` tests `[ebx+0x240] != 0` right after the magical mitigation |
| `0x2b4` | `pw` | `skill_params.md`'s "Where `pw` is read" |

## What it grounds immediately

Offsets this project was reading blind until today:

| offset | code | read by |
|---|---|---|
| `0x240` | `da` | `Combat_ResolveDamage`, after the magical mitigation |
| `0x39c` | `reqc` | the skill-use gate's stealth and musical-range flags |
| `0x400` | `lfst` | `Combat_ResolveDamage`'s branch to `FUN_0040f750` |
| `0x49c` | `qest` | the gate's `ITS_NOT_A_BATTLE_FIELD` code arithmetic |
| `0x4a4` | `msch` | the gate's `EU_BAN_HAWN_TRANS` and `DUPLICATE` branches |
| `0x534` | `BSHP` | the bonus-map key in `FUN_0040f750` |
| `0x3d0` | `dtnt` | `Combat_ResolveDamage`'s target filter |

Checked rather than assumed: `+0x294` and `+0x428`, the other two the skill-use
gate reads, are **not** in the map. A first draft of this page listed `+0x294` as
`efr`, taken from the contaminated extraction above before it was discarded —
caught by grepping the corrected map for the offset instead of trusting the
earlier output. Absence here means the extractor could not reach them, not that
nothing fills them.

`docs/protocol/skill_use_gate.md` listed `+0x4a4`, `+0x39c` and `+0x49c` under
"What is not recovered". They have names now; what the names *mean* is still
open, and a four-letter code is a label, not an explanation.

## Coverage, stated rather than implied

The parser compares **188** distinct printable codes. **120** case bodies are
reached by a `je`, and **119** contain a direct field store. Those are the ones
below.

**Codes whose values go into a list are absent**, and their absence is a limit
of the tool rather than evidence they have no field: `reqi` fills a five-slot
array and `att` is six words (the function's own header comment says so), and
both are written by loops whose bodies sit past a conditional branch. `reqi` and
`att` are the two this project already knew about, so the gap is known to be
real rather than suspected.

## The map

| code | offset | | code | offset | | code | offset |
|---|---|---|---|---|---|---|---|
| `da` | `0x240` | | `cmcr` | `0x36c` | | `qest` | `0x49c` |
| `hr` | `0x24c` | | `lks2` | `0x374` | | `trap` | `0x4a0` |
| `ru` | `0x250` | | `lkcp` | `0x378` | | `msch` | `0x4a4` |
| `defp` | `0x25c` | | `ovl2` | `0x37c` | | `rmut` | `0x4ac` |
| `defr` | `0x260` | | `scls` | `0x380` | | `luck` | `0x4b8` |
| `spda` | `0x264` | | `puls` | `0x384` | | `mstc` | `0x4bc` |
| `dura` | `0x280` | | `reqc` | `0x39c` | | `mscc` | `0x4c0` |
| `onff` | `0x284` | | `tant` | `0x3c8` | | `gdr` | `0x4c8` |
| `mc` | `0x288` | | `tnt2` | `0x3cc` | | `E1SA` | `0x4d4` |
| `eshp` | `0x298` | | `dtnt` | `0x3d0` | | `E2SA` | `0x4d8` |
| `esht` | `0x29c` | | `pwdt` | `0x3d4` | | `E2AH` | `0x4e0` |
| `dcmp` | `0x2a8` | | `mwdt` | `0x3d8` | | `WIMD` | `0x4e4` |
| `mpi` | `0x2b0` | | `dru` | `0x3e4` | | `WIRU` | `0x4e8` |
| `pw` | `0x2b4` | | `dru2` | `0x3e8` | | `COAT` | `0x4f0` |
| `hste` | `0x2b8` | | `stri` | `0x3f0` | | `FIAT` | `0x4f4` |
| `hst3` | `0x2c0` | | `abir` | `0x3f8` | | `LIAT` | `0x4f8` |
| `hitm` | `0x2c8` | | `lfst` | `0x400` | | `RPTU` | `0x504` |
| `rpkt` | `0x2cc` | | `mwhs` | `0x404` | | `RPBU` | `0x508` |
| `irgc` | `0x2d0` | | `tran` | `0x408` | | `CBAT` | `0x510` |
| `apru` | `0x2d4` | | `curt` | `0x40c` | | `STSP` | `0x514` |
| `apau` | `0x2d8` | | `rcur` | `0x414` | | `STDU` | `0x518` |
| `terd` | `0x2dc` | | `dmgr` | `0x418` | | `DGHR` | `0x520` |
| `thrd` | `0x2e0` | | `abnb` | `0x41c` | | `DTAT` | `0x528` |
| `tpad` | `0x2e8` | | `dtt` | `0x420` | | `getv` | `0x530` |
| `tele` | `0x2ec` | | `bl` | `0x444` | | `BSHP` | `0x534` |
| `tel2` | `0x2f0` | | `stns` | `0x448` | | `MUAT` | `0x540` |
| `reat` | `0x2fc` | | `st` | `0x450` | | `MUER` | `0x544` |
| `fb` | `0x310` | | `ds` | `0x454` | | `DSER` | `0x54c` |
| `ps` | `0x31c` | | `ca` | `0x458` | | `BDMD` | `0x554` |
| `heal` | `0x324` | | `cssr` | `0x45c` | | `HLFS` | `0x564` |
| `mwmh` | `0x32c` | | `csit` | `0x460` | | `HLMI` | `0x568` |
| `resu` | `0x330` | | `cshp` | `0x46c` | | `HLBP` | `0x56c` |
| `pmmp` | `0x33c` | | `csmp` | `0x470` | | `HLSM` | `0x570` |
| `pmdp` | `0x344` | | `tb` | `0x474` | | `mom` | `0x57c` |
| `php1` | `0x348` | | `lkdr` | `0x478` | | `expu` | `0x580` |
| `pmp1` | `0x34c` | | `tcmd` | `0x488` | | `hwit` | `0x588` |
| `pao` | `0x350` | | `hntp` | `0x48c` | | `bldr` | `0x58c` |
| `cbuf` | `0x358` | | `skc` | `0x490` | | `nmf` | `0x594` |
| `nbuf` | `0x35c` | | `slcc` | `0x494` | |  |  |
| `bbuf` | `0x360` | | `pchr` | `0x498` | |  |  |
