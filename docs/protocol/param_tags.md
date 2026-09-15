# The stat-tag vocabulary: which tag writes which ParamKeeper param

Recovered from `Stat_ApplyTaggedModifier` (`0x00498690`) on 2026-09-15. The
binary has **no id->name table as data** — the enum was compile-time only — but
this dispatcher is one as *code*: it takes a stat tag as a C multi-char literal
in `EAX` and pushes a value into a specific param id and slot.

Companion to `param_registry.md`, which gives every param's min/max/default.
Every id below was checked against that registry, and **all of them are
registered** — two independently recovered artifacts agreeing.

## Method, and how it was checked

Two passes, because one is not enough:

1. **Decompiled C**, attributing each `/* ParamKeeper param id: EDI .. */`
   annotation to the nearest preceding `in_EAX == 0x...` equality. This finds
   19 tags.
2. **Disassembly dataflow**, because 34 of the 53 tags reach their param through
   a shared tail (`LAB_00498adf`) with the id left in `EDI` — invisible to the
   annotation pass, which only ever resolves ids at a direct `SetParam` call.
   Walking each branch forward while tracking `mov edi, imm` resolves 12 more.

**The control came first.** Run against the 19 already-established tags the
disassembly pass reproduced 17 exactly. The two discrepancies were both
informative rather than fatal:

- **`drua`** came back as `128, 129, 130, 131` against a recorded `128, 129,
  130`. The disassembly settles it at the use-site: the branch does three
  `SetParam`s, then `mov edi,0x83` (131) and `jmp 0x498adf` into the tail, which
  performs a fourth. **The previously recorded entry was incomplete** — the
  fourth write was hidden behind exactly the `goto` this pass exists to see
  through.
- **`hp`** came back empty: it returns immediately after its single `SetParam`
  and the walker lost it. Already known (`-> 3`) and confirmed in the decompiled
  C, so it is carried below from pass 1.

**Trap, still live:** the compiler emits this dispatch as a binary-search tree,
so the function is full of `0x627269 < in_EAX` range tests beside the real
equality tests. Match `in_EAX == 0x...` only. And the tags are stored
**big-endian**, so a little-endian read gives reversed letters (`0x00617474` is
`att`, not `tta`).

## Resolved tags

`slot` is the ParamKeeper slot written: 0 base, 1 additive %, 2 multiplier,
3 percent scale. `tail(0)` means the write happens at the shared tail, which
pushes slot 0.

| tag | param ids | slot | registry max | registry default |
|---|---|---|---|---|
| `bri` | 10 | 0 | 100 | 0 |
| `brna` | 10 | 0 | 100 | 0 |
| `bu` | 30 | 0 | 100 | 0 |
| `cri` | 12 | 0 | 100 | 0 |
| `dara` | 174, 175, 176, 177 | 2 | 100 | 0 |
| `drua` | 128, 129, 130, 131 | 0 | 1000 | 0 |
| `era` | 9 | 1 | 65535 | 0 |
| `es` | 29 | 0 | 100 | 0 |
| `evbl` | 56 | 0 | 100 | 0 |
| `evcr` | 57 | 0 | 100 | 0 |
| `fz` | 27 | 0 | 100 | 0 |
| `hp` | 3 | 0 | 2100000000 | 0 |
| `hpa` | 3 | 0 | 2100000000 | 0 |
| `hpmp` | 25, 26 | 1 | 100 | 0 |
| `hpna` | 52 | 1 | 9999999 | 0 |
| `hprg` | 25 | 1 | 100 | 0 |
| `hra` | 11 | 1 | 65535 | 0 |
| `int` | 2 | 0 | 9999999 | 0 |
| `intv` | 2 | 0 | 9999999 | 0 |
| `mp` | 4 | 0 | 2100000000 | 0 |
| `mpa` | 4 | 0 | 2100000000 | 0 |
| `mpna` | 53 | 1 | 9999999 | 0 |
| `mprg` | 26 | 1 | 100 | 0 |
| `ps` | 31 | 0 | 100 | 0 |
| `rals` | 27, 28, 29, 30, 31, 32 | 0 | 100 | 0 |
| `str` | 1 | tail(0) | 9999999 | 0 |
| `stra` | 1 | tail(0) | 9999999 | 0 |
| `strj` | 1 | tail(0) | 9999999 | 0 |
| `strv` | 1 | tail(0) | 9999999 | 0 |
| `umdu` | 259 | tail(0) | 100 | 0 |
| `zb` | 32 | 0 | 100 | 0 |

### What this newly settles

- **Param 1 is Strength.** Four tags (`str`, `stra`, `strj`, `strv`) write it,
  and the dispatcher's own fall-through tail defaults to `mov edi,0x1`. This
  independently corroborates the stat graph, where health runs
  `Str(1) -> 52 -> 54 -> MaxHP(3)`.
- **Params 27-32 are the six status-effect resistances.** `rals` writes all six
  at once; the individual tags are `fz` 27, *(28 unnamed)*, `es` 29, `bu` 30,
  `ps` 31, `zb` 32. Id 28 is written only as part of a pair — one branch does
  `mov edi,0x1b` (27) alongside `mov [esp+0x24],0x1c` (28) — so its own tag was
  not isolated here. The client's `textuisystem.txt` names three of these:
  `PARAM_FZ` "Freezing", `PARAM_PS` "Poisoning", `PARAM_ZB` "Zombie".
- **`drua` writes four params, not three** (see above).
- **`umdu` writes 259**, which is one of the damage-pipeline params this project
  had established as unwritten for an ordinary character. Consistent: `umdu` is
  a buff/item tag, so only a buffed character has it.

## Dead tags: recognised, but they do nothing

These seven have a branch in the dispatcher that returns immediately without
touching any param. They are **not** unimplemented-and-waiting; the dispatcher
is the modifier path, so a tag it ignores has no effect on a character's stats:

> `er`, `atha`, `rep`, `astr`, `dura`, `luck`, `soli`

Worth singling out: **`luck` is dead**, even though the client ships a
`PARAM_LUCK` = "Lucky" localisation string and displays the stat. Note this is a
statement about the `luck` tag specifically — the separate tag `luca` is live
(it reads the current value and adds to it), so do not read this as "luck does
nothing in the game".

Note also `er` is dead while `era` is live, and `dura` is dead while `drua` is
live. The pattern is suggestive of legacy short forms, but `hp` and `mp` are both
short and both live, so it is reported as an observation, not a rule.

## Unresolved

15 of the 53 tags are recognised and do reach a param, but through paths this
pass does not follow (read-modify-write via `ParamKeeper_GetParam`, or ids the
dataflow could not pin):

> `ape`, `duru`, `hr`, `inta`, `intj`, `luca`, `mdia`, `nrep`, `rcsi`, `rdii`,
> `rein`, `reis`, `rfei`, `rsli`, `rsti`

Do not guess these from the abbreviation. The client's `PARAM_*` localisation
keys are the game's own wording and have already corrected this project twice
(`era` is *parry*, not evasion; `hra` is *attack rate*, not hit rate).
