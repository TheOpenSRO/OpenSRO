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

## Tags that are not character-stat modifiers

These seven have a branch in the dispatcher that returns immediately without
touching any param:

> `er`, `atha`, `rep`, `astr`, `dura`, `luck`, `soli`

**They never reach a ParamKeeper param**, and that part is enumerated rather than
assumed: exactly **28 functions in the binary write a param**, and only one of
them — `Stat_ApplyTaggedModifier` — is dispatched on a tag. The other 27 are
structural (`GObjPC_InitStats`, `Char_PublishCombatStats`, `GObjMob_PublishStats`,
`GObjPC_SetLevel`, `GObjPC_SpendStatPoints`, the premium and mob and siege
paths). So if a tag does not become a param here, it becomes one nowhere.

**CORRECTED 2026-09-15 — an earlier version of this section called these seven
"DEAD" and said a tag the dispatcher ignores "has no effect on a character's
stats".** The first half is right; the word *dead* is wrong, and the reason it
matters is concrete: **`dura` appears on 1,979 skills.** A tag carried by two
thousand skills is not dead.

All seven are recognised elsewhere in the binary — in the description builders
(`CGameServer::FUN_0072e2d0` and neighbours, which work in `LPCSTR`/`PCNZCH` and
produce the `AVT <tag> +%d%%` strings), in the enchant system
(`CEnchant_EnchantAttrStone` and friends), and in `CGItemEquip`. None of those
files contains a single `SetParam` call, which is exactly why they are compatible
with the enumeration above.

So the accurate claim is narrow: **these seven are not character-stat modifiers.**

**SUPERSEDED 2026-09-16 — what they ARE is now recovered.** This paragraph used
to say their meaning was unknown and warned off guessing (`dura` "for a
duration, say"). `magicoption.txt` names all seven outright, and the guess
floated here was wrong: `dura` is **MATTR_DEC_MAXDUR**, durability, not
duration. See the MATTR table below.

`luck` deserves its own note: it does not modify a stat, even though the client
ships a `PARAM_LUCK` = "Lucky" localisation string and displays it. The separate
tag `luca` **is** live (MATTR_AVATAR_LUCK), so do not read this as "luck does
nothing in the game".

## Previously unresolved — now NAMED by the game's own data (2026-09-16)

15 of the 53 tags reach a param through paths the dispatcher pass could not
follow. All 15 are now named, and **not by guessing the abbreviation**: the
client's `magicoption.txt` stores each item magic-option's stat tag as a
big-endian multi-char literal beside its `MATTR_*` code name, so the table
states the mapping outright.

| tag | the game's own name |
|---|---|
| `ape` | MATTR_APE |
| `duru` | MATTR_DUR |
| `hr` | MATTR_HR |
| `inta` | MATTR_AVATAR_INT |
| `intj` | MATTR_INT_3JOB |
| `luca` | MATTR_AVATAR_LUCK |
| `mdia` | MATTR_AVATAR_MDIA |
| `nrep` | MATTR_NOT_REPARABLE |
| `rcsi` | MATTR_RESIST_CSMP |
| `rdii` | MATTR_RESIST_DISEASE |
| `rein` | MATTR_REINFORCE_ITEM |
| `reis` | MATTR_REINFORCE_ITEM_SET |
| `rfei` | MATTR_RESIST_FEAR |
| `rsli` | MATTR_RESIST_SLEEP |
| `rsti` | MATTR_RESIST_STUN |

Seven of them are **resistances** (`rsli`, `rsti`, `rfei`, `rdii`, `rcsi`, plus
the already-known `bu`/`es`/`fz`/`ps`/`zb`), which is why they never appeared in
the stat dispatcher's damage paths.

### This CONFIRMS the "not a stat modifier" explanation with data

The seven tags the dispatcher recognises and ignores were explained as item
condition fields rather than character stats — an argument built on
`PARAM_REPAIRING_CHARGES` sitting beside `PARAM_DURA` in the client's key set.
`magicoption.txt` settles it outright:

	dura -> MATTR_DEC_MAXDUR        (decrease maximum durability)
	rep  -> MATTR_REPAIR
	nrep -> MATTR_NOT_REPARABLE
	soli -> MATTR_SOLID
	astr -> MATTR_ASTRAL
	atha -> MATTR_ATHANASIA
	luck -> MATTR_LUCK

Durability, repair and not-repairable are unambiguously **item** properties. A
stat dispatcher skipping them is correct behaviour, now on the game's own naming
rather than on an abbreviation argument. The earlier tier-2 caveat on `rep` can
be dropped.

## The full tag → MATTR map

56 tags appear in `magicoption.txt`. Where a tag has several `MATTR_*` variants
(base, `_SET`, avatar, event) the shortest is shown.

| tag | MATTR name |
|---|---|
| `2d` | MATTR_HP |
| `ape` | MATTR_APE |
| `astr` | MATTR_ASTRAL |
| `atha` | MATTR_ATHANASIA |
| `bri` | MATTR_BLOCKRATE |
| `brna` | MATTR_NASRUN_BLOCKRATE |
| `bu` | MATTR_RESIST_BURN |
| `cri` | MATTR_CRITICAL |
| `dara` | MATTR_AVATAR_DARA |
| `dn` | MATTR_REGENHPMP |
| `drua` | MATTR_AVATAR_DRUA |
| `dura` | MATTR_DEC_MAXDUR |
| `duru` | MATTR_DUR |
| `er` | MATTR_ER |
| `era` | MATTR_AVATAR_ER |
| `es` | MATTR_RESIST_ESHOCK |
| `evbl` | MATTR_EVADE_BLOCK |
| `evcr` | MATTR_EVADE_CRITICAL |
| `fz` | MATTR_RESIST_FROSTBITE |
| `hp` | MATTR_HP |
| `hpa` | MATTR_AVATAR_HP |
| `hpmp` | MATTR_REGENHPMP |
| `hpna` | MATTR_NASRUN_HPNA |
| `hprg` | MATTR_AVATAR_HPRG |
| `hr` | MATTR_HR |
| `hra` | MATTR_AVATAR_HR |
| `int` | MATTR_INT |
| `inta` | MATTR_AVATAR_INT |
| `intj` | MATTR_INT_3JOB |
| `intv` | MATTR_INT_AVATAR |
| `luca` | MATTR_AVATAR_LUCK |
| `luck` | MATTR_LUCK |
| `mdia` | MATTR_AVATAR_MDIA |
| `mp` | MATTR_MP |
| `mpa` | MATTR_AVATAR_MP |
| `mpna` | MATTR_NASRUN_MPNA |
| `mprg` | MATTR_AVATAR_MPRG |
| `nrep` | MATTR_NOT_REPARABLE |
| `nx` | MATTR_REGENHPMP |
| `ps` | MATTR_RESIST_POISON |
| `rals` | MATTR_RESIST_ALL_SET |
| `rcsi` | MATTR_RESIST_CSMP |
| `rdii` | MATTR_RESIST_DISEASE |
| `rein` | MATTR_REINFORCE_ITEM |
| `reis` | MATTR_REINFORCE_ITEM_SET |
| `rep` | MATTR_REPAIR |
| `rfei` | MATTR_RESIST_FEAR |
| `rsli` | MATTR_RESIST_SLEEP |
| `rsti` | MATTR_RESIST_STUN |
| `soli` | MATTR_SOLID |
| `str` | MATTR_STR |
| `stra` | MATTR_AVATAR_STR |
| `strj` | MATTR_STR_3JOB |
| `strv` | MATTR_STR_AVATAR |
| `umdu` | MATTR_NASRUN_UMDU |
| `zb` | MATTR_RESIST_ZOMBIE |

Note `magicoption.txt` names a tag's MEANING, not its param id. The id still
comes from `Stat_ApplyTaggedModifier` or the skill-code join; this table is what
each tag IS.
