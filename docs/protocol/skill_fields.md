# The `CRefSkill` field map

Every `skill+0xNNN` the combat code reads, named. Recovered 2026-09-17 from
`SkillGlobal::RefSkill_ParseParams` (`0x00587630`, 7,509 bytes), which walks a
skill's Param stream as `(code, values...)` runs and stores each value into a
field of the record. Regenerate with `client/tools/re/skillfields.py`.

Before this, `docs/protocol/` named **two** `CRefSkill` offsets. It now names
**203** — 203 codes to 203 distinct offsets, a one-to-one map covering 91% of
the record's param area.

## The record's shape, which bounds the whole map

The prologue is the structural check that the map is right:

	00587638  lea ebp,[esi+0x230]
	00587641  call 0x9e3520          ; memset(ebp, 0, 0x37c)

So **`esi` is the CRefSkill record and the param-field block is exactly
`0x230`–`0x5ac`** — 223 dword slots, of which 203 are now named. Every recovered
offset falls inside it, no code claims two offsets, and no offset is claimed by
two codes. That
is an independent check on the table as a whole rather than on any single row:
an extraction that had drifted would put fields outside the block the parser
clears.

**Each field holds a POINTER INTO THE PARAM STREAM, not a value.** A case body
does `add eax,4` to step past the code word and stores EAX:

	005877ff  add eax,0x4
	00587802  mov DWORD PTR [esi+0x240],eax    ; a pointer to da's values
	00587808  add ecx,0x2                      ; 2 words consumed: code + 1 value
	0058780b  add eax,0x4

so `CRefSkill+0x240` is *where `da`'s values start*, not `da`. Reading the table
as "offset holds the value" would be wrong everywhere.

`ecx` counts **words including the code word**, which settles a question this
page's sibling raised. `att`'s block does `add ecx,0x1` then `add ecx,0x5` — six
words — and the parser's own header comment calls `att` "six words". That is
**one code word plus five values**, so `skill_params.md`'s
`(type, percent, min, max, percent)` is complete; there is no unaccounted sixth
value. The worry that there might be was this page's, and it is resolved rather
than dropped.

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
| `0x230` | **`att`** | the attack descriptor the ENTIRE damage pipeline reads |

`att -> 0x230` is the one that matters most, and the first version of this tool
lost it. Its store is `mov [ebp+0x0],eax` — offset **0** relative to the block,
via the `ebp` alias — and the filter was `offset >= 0x20`, a guess dressed as a
rule. Replacing it with the real bound (the memset block, `0x230`–`0x5ac`)
recovers it. `docs/protocol/damage_pipeline.md` already identified the `+0x230`
descriptor as skilldata's `att`; what is new is that the parser says so
directly, rather than the identification resting on the three fields matching.
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

**`reqi` is still absent**, and its absence is a limit of the tool rather than
evidence it has no field: it fills a five-slot array at `0x3a0`
(`docs/protocol/skill_params.md`) written by a loop whose body sits past a
conditional branch. It is the one code this project already knew about that the
tool cannot reach, so the gap is *known* to be real rather than suspected —
which is what lets it be stated as a bound on the tool.

`att` used to be listed here too. It was never a list-valued case; it was a
filter bug. The two failure modes look identical from the output, which is why
the claim needed a known-missing example to rest on rather than a count.

## Four forms of one trap

Every expansion of this map came from a *different* way MSVC spells "this code
matched", and each one silently produced plausible wrong rows until it was
handled:

| # | shape | what it hid |
|---|---|---|
| 1 | proximity, not control flow | the whole first map: `pdm2 -> 0x234`, `resu -> 0x3a0` |
| 2 | `cmp reg,CODE ; jne DEFAULT`, body falls through | `pdm2` at `0x238`, beside `pdmg` |
| 3 | `sub reg,K1 ; je` / `sub reg,K2 ; jne` — a chain compiled as a **running subtraction**, so the second test is `K1+K2` | `cr`/`ck` at `0x244`/`0x248`, beside `da` |
| 4 | a `je` target that is itself another comparison **sub-tree** | `getv` claiming `BLAT`'s field at `0x530` |

(4) is the subtlest and the reason the map is now checkable: `getv` really is a
code (`cmp edx,0x67657476 ; je 0x5882b5`), but its target compares four more
codes, and a linear walk from it runs into an unrelated leaf's store. The
discriminator is that **a real case body is straight-line up to its store** —
`att` branches, but only *after* storing. Abandoning a block whose first
conditional jump precedes any store drops `getv` and keeps `att`.

**The collision check is what caught it.** 205 codes claiming 204 offsets is one
duplicate, and one duplicate in 205 rows is easy to wave away as an alias. It was
not an alias; it was a whole class of mis-attribution showing through a single
row. The map is now a bijection, which is a property that *cannot* hold by
accident across 203 rows and is therefore worth more than any individual anchor.

## Still missing, and why

`reqi` (a five-slot array at `0x3a0`, known from `skill_params.md`) and `getv`
are both real codes the tool does not place. `reqi` writes through a loop past a
conditional branch; `getv` is a tree node whose own field — if it has one — is
not reachable by this method. Twenty of the block's 223 slots are unnamed, and
these two account for some of them.

Their absence is a limit of the tool. It is **not** evidence that those codes have
no field, and the tool has now been wrong about exactly that once: `att` was
listed here as list-valued when it was a filter bug.

## The map

| code | offset | | code | offset | | code | offset | | code | offset |
|---|---|---|---|---|---|---|---|---|---|---|---|
| `att` | `0x230` | | `summ` | `0x308` | | `tkss` | `0x3fc` | | `gdr` | `0x4c8` |
| `pdmg` | `0x234` | | `fz` | `0x30c` | | `lfst` | `0x400` | | `dgmp` | `0x4cc` |
| `pdm2` | `0x238` | | `fb` | `0x310` | | `mwhs` | `0x404` | | `hwir` | `0x4d0` |
| `ko` | `0x23c` | | `es` | `0x314` | | `tran` | `0x408` | | `E1SA` | `0x4d4` |
| `da` | `0x240` | | `bu` | `0x318` | | `curt` | `0x40c` | | `E2SA` | `0x4d8` |
| `cr` | `0x244` | | `ps` | `0x31c` | | `curl` | `0x410` | | `E2AA` | `0x4dc` |
| `ck` | `0x248` | | `zb` | `0x320` | | `rcur` | `0x414` | | `E2AH` | `0x4e0` |
| `hr` | `0x24c` | | `heal` | `0x324` | | `dmgr` | `0x418` | | `WIMD` | `0x4e4` |
| `ru` | `0x250` | | `mwhh` | `0x328` | | `abnb` | `0x41c` | | `WIRU` | `0x4e8` |
| `kb` | `0x254` | | `mwmh` | `0x32c` | | `dtt` | `0x420` | | `EAAT` | `0x4ec` |
| `saps` | `0x258` | | `resu` | `0x330` | | `dttp` | `0x424` | | `COAT` | `0x4f0` |
| `defp` | `0x25c` | | `cura` | `0x334` | | `hide` | `0x428` | | `FIAT` | `0x4f4` |
| `defr` | `0x260` | | `pmhp` | `0x338` | | `dcri` | `0x42c` | | `LIAT` | `0x4f8` |
| `spda` | `0x264` | | `pmmp` | `0x33c` | | `se` | `0x430` | | `RPDU` | `0x500` |
| `ar` | `0x268` | | `pmdg` | `0x340` | | `rt` | `0x434` | | `RPTU` | `0x504` |
| `dar` | `0x26c` | | `pmdp` | `0x344` | | `sl` | `0x438` | | `RPBU` | `0x508` |
| `odar` | `0x270` | | `php1` | `0x348` | | `fe` | `0x43c` | | `CBRA` | `0x50c` |
| `ao` | `0x274` | | `pmp1` | `0x34c` | | `my` | `0x440` | | `CBAT` | `0x510` |
| `br` | `0x278` | | `pao` | `0x350` | | `bl` | `0x444` | | `STSP` | `0x514` |
| `er` | `0x27c` | | `ssou` | `0x354` | | `stns` | `0x448` | | `STDU` | `0x518` |
| `dura` | `0x280` | | `cbuf` | `0x358` | | `dn` | `0x44c` | | `DGHR` | `0x520` |
| `onff` | `0x284` | | `nbuf` | `0x35c` | | `st` | `0x450` | | `DTAT` | `0x528` |
| `mc` | `0x288` | | `bbuf` | `0x360` | | `ds` | `0x454` | | `DTDR` | `0x52c` |
| `eshp` | `0x298` | | `pcdu` | `0x364` | | `ca` | `0x458` | | `BLAT` | `0x530` |
| `esht` | `0x29c` | | `chcr` | `0x368` | | `cssr` | `0x45c` | | `BSHP` | `0x534` |
| `cnsm` | `0x2a0` | | `cmcr` | `0x36c` | | `csit` | `0x460` | | `SAAA` | `0x538` |
| `rhru` | `0x2a4` | | `lnks` | `0x370` | | `cspd` | `0x464` | | `TRAA` | `0x53c` |
| `dcmp` | `0x2a8` | | `lks2` | `0x374` | | `csmd` | `0x468` | | `MUAT` | `0x540` |
| `hpi` | `0x2ac` | | `lkcp` | `0x378` | | `cshp` | `0x46c` | | `MUER` | `0x544` |
| `mpi` | `0x2b0` | | `ovl2` | `0x37c` | | `csmp` | `0x470` | | `MUCR` | `0x548` |
| `pw` | `0x2b4` | | `scls` | `0x380` | | `tb` | `0x474` | | `DSER` | `0x54c` |
| `hste` | `0x2b8` | | `puls` | `0x384` | | `lkdr` | `0x478` | | `DSCR` | `0x550` |
| `hst2` | `0x2bc` | | `reqc` | `0x39c` | | `lkag` | `0x47c` | | `BDMD` | `0x554` |
| `hst3` | `0x2c0` | | `reqn` | `0x3b4` | | `lkdd` | `0x480` | | `HLRU` | `0x558` |
| `tctc` | `0x2c4` | | `reqa` | `0x3b8` | | `thld` | `0x484` | | `HLMD` | `0x55c` |
| `hitm` | `0x2c8` | | `atca` | `0x3bc` | | `tcmd` | `0x488` | | `HLAT` | `0x560` |
| `rpkt` | `0x2cc` | | `pwtt` | `0x3c0` | | `hntp` | `0x48c` | | `HLFS` | `0x564` |
| `irgc` | `0x2d0` | | `mwtt` | `0x3c4` | | `skc` | `0x490` | | `HLMI` | `0x568` |
| `apru` | `0x2d4` | | `tant` | `0x3c8` | | `slcc` | `0x494` | | `HLBP` | `0x56c` |
| `apau` | `0x2d8` | | `tnt2` | `0x3cc` | | `pchr` | `0x498` | | `HLSM` | `0x570` |
| `terd` | `0x2dc` | | `dtnt` | `0x3d0` | | `qest` | `0x49c` | | `MAAT` | `0x574` |
| `thrd` | `0x2e0` | | `pwdt` | `0x3d4` | | `trap` | `0x4a0` | | `fitp` | `0x578` |
| `tpdd` | `0x2e4` | | `mwdt` | `0x3d8` | | `msch` | `0x4a4` | | `mom` | `0x57c` |
| `tpad` | `0x2e8` | | `dmgt` | `0x3dc` | | `mcap` | `0x4a8` | | `expu` | `0x580` |
| `tele` | `0x2ec` | | `lkdh` | `0x3e0` | | `rmut` | `0x4ac` | | `spi` | `0x584` |
| `tel2` | `0x2f0` | | `dru` | `0x3e4` | | `efta` | `0x4b0` | | `hwit` | `0x588` |
| `tel3` | `0x2f4` | | `dru2` | `0x3e8` | | `alcu` | `0x4b4` | | `bldr` | `0x58c` |
| `bgra` | `0x2f8` | | `expi` | `0x3ec` | | `luck` | `0x4b8` | | `msr` | `0x590` |
| `reat` | `0x2fc` | | `stri` | `0x3f0` | | `mstc` | `0x4bc` | | `nmf` | `0x594` |
| `real` | `0x300` | | `inti` | `0x3f4` | | `mscc` | `0x4c0` | | `nmh` | `0x598` |
| `pola` | `0x304` | | `abir` | `0x3f8` | | `msid` | `0x4c4` | |  |  |
