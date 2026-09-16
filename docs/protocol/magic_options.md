# Magic options: the engine's stat-tag vocabulary

`MagicOption.txt` (`_RefMagicOption`) is the table of every bonus an item can carry — the
"+3 STR" and "Blocking Rate +5%" lines on a tooltip. Recovered 2026-09-16 while following
`MagicOptGroupID` out of the set-bonus assert (`docs/RE_COMPLETION.md`).

Its value here is not the bonuses. It is that **the table names the engine's stat tags itself.**

## What a tag is

The engine addresses a character stat by a short ASCII string packed big-endian into a 32-bit
word — `'cri'` is `0x637269`. The project already had four of these (`era`, `bri`, `hra`, `cri`,
from the characterdata columns) and no list.

`MagicOption.txt` column 2 is the option's human code name and column 7 is the packed tag it
modifies. So each row pairs a name with a tag, with no inference:

```
MATTR_INT -> 'int'    MATTR_STR -> 'str'    MATTR_BLOCKRATE -> 'bri'    MATTR_CRITICAL -> 'cri'
```

**53 distinct tags, and every one of the 53 packed constants appears in the server binary.**
They are compared in `Stat_ApplyTaggedModifier` (`0x00498690`), a binary-search tree on the
packed value that ends in `GObjPC::ParamKeeper_SetParam`.

## Column 29 is the item kind, and it settles meanings the initials do not

Each row also says which kind of item may carry the option. That column is what proves the
attacker/defender pairing this project recovered separately from the damage pipeline:

| option | carried on | opposes |
|---|---|---|
| `MATTR_CRITICAL` (`cri`) | weapon | `MATTR_EVADE_CRITICAL` (`evcr`), on **shield** |
| `MATTR_BLOCKRATE` (`bri`) | shield | `MATTR_EVADE_BLOCK` (`evbl`), on **weapon** |

It also settles `ER` and `HR`, which initials alone would get wrong: `MATTR_ER` sits on **armor**
and `MATTR_HR` on **weapon** — the parry ratio and the attack ratio the game displays. Reading
`ER` as "evasion" would have been a wrong correction to a correct comment in
`internal/combat/combat.go`.

And it independently re-confirms three things established earlier this session, from an artefact
none of them came from:

- the accessory split — `rsti` is on **necklace**, `rcsi`/`rsli` on **earring**, `rdii`/`rfei`
  on **ring** (see `EQUIP_SLOTS.md`)
- the job suits — `strj`/`intj` are on **hunter, thief, trader** (`FamilyJobSuit`)
- the armour pieces — `hp`/`mp` are on **armor, helm, mail, pants**

## The vocabulary

`xxx` in the item-kind column is the table's own placeholder for an unused slot, kept as it
appears. Packed values are computed, never transcribed — see `internal/combat/paramtags.go`
and the note there about the fourth time hand-typing one went wrong.

| tag | packed | MagicOption code name | appears on |
|---|---:|---|---|
| `ape` | 6385765 | `MATTR_APE` | accessory, armor, shield, weapon, xxx |
| `astr` | 1634956402 | `MATTR_ASTRAL` | accessory, armor, shield, weapon, xxx |
| `atha` | 1635018849 | `MATTR_ATHANASIA` | accessory, armor, shield, weapon, xxx |
| `bri` | 6451817 | `MATTR_BLOCKRATE` | shield, xxx |
| `brna` | 1651666529 | `MATTR_NASRUN_BLOCKRATE` | avatar_special_armlet, xxx |
| `bu` | 25205 | `MATTR_RESIST_BURN` | accessory, xxx |
| `cri` | 6517353 | `MATTR_CRITICAL` | weapon, xxx |
| `dara` | 1684107873 | `MATTR_AVATAR_DARA` | avatar_helm, xxx |
| `drua` | 1685222753 | `MATTR_AVATAR_DRUA` | avatar_mail, xxx |
| `dura` | 1685418593 | `MATTR_DEC_MAXDUR` | armor, shield, weapon, xxx |
| `duru` | 1685418613 | `MATTR_DUR` | armor, shield, weapon, xxx |
| `er` | 25970 | `MATTR_ER` | armor, xxx |
| `era` | 6648417 | `MATTR_AVATAR_ER` | avatar_helm, xxx |
| `es` | 25971 | `MATTR_RESIST_ESHOCK` | accessory, xxx |
| `evbl` | 1702257260 | `MATTR_EVADE_BLOCK` | weapon, xxx |
| `evcr` | 1702257522 | `MATTR_EVADE_CRITICAL` | shield, xxx |
| `fz` | 26234 | `MATTR_RESIST_FROSTBITE` | accessory, xxx |
| `hp` | 26736 | `MATTR_HP` | armor, helm, mail, pants, xxx |
| `hpa` | 6844513 | `MATTR_AVATAR_HP` | avatar_mail, xxx |
| `hpmp` | 1752198512 | `MATTR_REGENHPMP` | mail, xxx |
| `hpna` | 1752198753 | `MATTR_NASRUN_HPNA` | avatar_special_armlet, xxx |
| `hprg` | 1752199783 | `MATTR_AVATAR_HPRG` | avatar_mail, avatar_mail_addon, xxx |
| `hr` | 26738 | `MATTR_HR` | weapon, xxx |
| `hra` | 6845025 | `MATTR_AVATAR_HR` | avatar_mail, avatar_mail_addon, xxx |
| `int` | 6909556 | `MATTR_INT` | accessory, armor, shield, weapon, xxx |
| `inta` | 1768846433 | `MATTR_AVATAR_INT` | avatar_helm, avatar_mail, xxx |
| `intj` | 1768846442 | `MATTR_INT_3JOB` | hunter, thief, trader, xxx |
| `intv` | 1768846454 | `MATTR_INT_AVATAR` | avatar_extra, xxx |
| `luca` | 1819632481 | `MATTR_AVATAR_LUCK` | avatar_mail, xxx |
| `luck` | 1819632491 | `MATTR_LUCK` | accessory, armor, shield, weapon, xxx |
| `mdia` | 1835297121 | `MATTR_AVATAR_MDIA` | avatar_mail, xxx |
| `mp` | 28016 | `MATTR_MP` | armor, helm, mail, pants, xxx |
| `mpa` | 7172193 | `MATTR_AVATAR_MP` | avatar_helm, xxx |
| `mpna` | 1836084833 | `MATTR_NASRUN_MPNA` | avatar_special_armlet, xxx |
| `mprg` | 1836085863 | `MATTR_AVATAR_MPRG` | avatar_helm, xxx |
| `nrep` | 1852990832 | `MATTR_NOT_REPARABLE` | armor, shield, weapon, xxx |
| `ps` | 28787 | `MATTR_RESIST_POISON` | accessory, xxx |
| `rals` | 1918987379 | `MATTR_RESIST_ALL_SET` | accessory, armor, weapon, xxx |
| `rcsi` | 1919120233 | `MATTR_RESIST_CSMP` | earring, xxx |
| `rdii` | 1919183209 | `MATTR_RESIST_DISEASE` | ring, xxx |
| `rein` | 1919248750 | `MATTR_REINFORCE_ITEM` | accessory, armor, shield, weapon, xxx |
| `reis` | 1919248755 | `MATTR_REINFORCE_ITEM_SET` | accessory, armor, weapon, xxx |
| `rep` | 7497072 | `MATTR_REPAIR` | armor, shield, weapon, xxx |
| `rfei` | 1919313257 | `MATTR_RESIST_FEAR` | ring, xxx |
| `rsli` | 1920167017 | `MATTR_RESIST_SLEEP` | earring, xxx |
| `rsti` | 1920169065 | `MATTR_RESIST_STUN` | necklace, xxx |
| `soli` | 1936682089 | `MATTR_SOLID` | armor, shield, weapon, xxx |
| `str` | 7566450 | `MATTR_STR` | accessory, armor, shield, weapon, xxx |
| `stra` | 1937011297 | `MATTR_AVATAR_STR` | avatar_helm, avatar_mail, xxx |
| `strj` | 1937011306 | `MATTR_STR_3JOB` | hunter, thief, trader, xxx |
| `strv` | 1937011318 | `MATTR_STR_AVATAR` | avatar_extra, xxx |
| `umdu` | 1970103413 | `MATTR_NASRUN_UMDU` | avatar_special_armlet, xxx |
| `zb` | 31330 | `MATTR_RESIST_ZOMBIE` | accessory, xxx |


Regenerate with the script recorded in that tick's entry: decode column 7 of `MagicOption.txt`
as big-endian ASCII and group by it.

## Tag to ParamKeeper param id

Recovered 2026-09-16 from `Stat_ApplyTaggedModifier` (`0x00498690`) — **from the disassembly, not
the decompilation.** The dispatcher ends in `GObjPC::ParamKeeper_SetParam`, whose param id arrives
in EDI, a register Ghidra does not map to a parameter; the C output therefore renders every leaf
as the identical `ParamKeeper_SetParam(0, param_3, value)` and cannot tell the tags apart at all.
In the asm each leaf is `mov edi,N` immediately before the call.

**The control:** six of these bindings were already known from unrelated functions, and all six
came back right — which is what licenses the other fourteen.

| tag | param | code name | how the control knew it |
|---|---:|---|---|
| `str` | 1 | `MATTR_STR` | the damage pipeline's `GetParam(1)` |
| `int` | 2 | `MATTR_INT` | the damage pipeline's `GetParam(2)` |
| `bri` | 10 | `MATTR_BLOCKRATE` | `GObjMob_PublishStats` run, characterdata col 76 |
| `cri` | 12 | `MATTR_CRITICAL` | same run, col 78 |
| `evbl` | 56 | `MATTR_EVADE_BLOCK` | `Combat_ResolveDamage` |
| `evcr` | 57 | `MATTR_EVADE_CRITICAL` | `Combat_ResolveDamage` |

The rest, new:

| tag | param | code name |
|---|---:|---|
| `hpa` | 3 | `MATTR_AVATAR_HP` |
| `mp` | 4 | `MATTR_MP` |
| `hra` | 11 | `MATTR_AVATAR_HR` |
| `hpmp` | 25 | `MATTR_REGENHPMP` |
| `hprg` | 25 | `MATTR_AVATAR_HPRG` |
| `mprg` | 26 | `MATTR_AVATAR_MPRG` |
| `rals` | 27 | `MATTR_RESIST_ALL_SET` |
| `bu` | 30 | `MATTR_RESIST_BURN` |
| `mpna` | 53 | `MATTR_NASRUN_MPNA` |
| `drua` | 128 | `MATTR_AVATAR_DRUA` |
| `brna` | 10 | `MATTR_NASRUN_BLOCKRATE` — the same param as `bri` |
| `strj` | 1 | `MATTR_STR_3JOB` |
| `strv` | 1 | `MATTR_STR_AVATAR` |
| `intv` | 2 | `MATTR_INT_AVATAR` |

Shipped as `combat.ParamFor`. Regenerate with `client/tools/ghidra/recover_tag_params.py`.

**Not listed, deliberately:** `fz`, `ps`, `zb` and the other resists share one tail block, each
setting its own EDI before jumping in, so a walk that explores both arms of every branch reaches
all of params 27, 29, 30, 31 and 32 from each. The family occupies that range; which tag takes
which, this walk does not say. (`bu` resolved singly in both a conservative and an exhaustive
walk and is listed, but it is in the same block and carries the same caveat.)

**Regeneration is an item stat.** Params 25/26 exist and `MATTR_REGENHPMP`/`MATTR_AVATAR_HPRG`/
`MATTR_AVATAR_MPRG` write them. That does not reopen the earlier finding that there is no passive
regen, which was about what writes the pools by default — nothing does. These params are there for
items to grant.

## The engine's own names for each tag, and the unit of each bonus

Two server-side debug formatters print an item and its options in the game's own words:
`GObjPC::FUN_004909f0` (`0x004909f0`) and `FUN_00491bd0` (`0x00491bd0`). Both were unnamed
`FUN_` functions carrying tag constants, which is how they were found. Each option line is a
literal like `"block rate +%d"` or `"evcr +%d%%"`, guarded by the tag constant — so the tag, the
human label and the unit come out together. **41 tags get a label this way.**

The pair are near-duplicates that differ in the avatar prefix (`AVT` vs `Ava`) and agree on every
tag below.

**`+%d` versus `+%d%%` is a property of the BONUS, not of the stat.** `block rate +%d` is flat
because the option adds five *points*; the block rate itself is still a percentage. Reading
"flat" as "this stat is not a percentage" would be a misreading, and `paramtags_test.go` has a
test standing against exactly that.

| tag | unit | the engine's label |
|---|---|---|
| `str` `int` `mp` | flat | as spelled |
| `bri` | flat | **block rate** |
| `cri` | flat | **critical** |
| `astr` | flat | as spelled |
| `hr` `er` `duru` `evbl` `evcr` | percent | as spelled |
| `rein` | percent | **reinforce** |
| `dura` | percent, **negative** | **flaw** (`"flaw -%d%%"`) |
| `hpmp` | percent | **regen hpmp** |
| `ps` `fz` `bu` `es` `zb` | percent | **anti-toxin, anti-frostbite, anti-burn, anti-eshock, anti-zombie** |
| `rsti` `rsli` `rfei` `rdii` `rcsi` | percent | **resist stun / sleep / fear / disease / csmp** |
| `hra` `era` `hpa` `mpa` `inta` `stra` `luca` `mdia` `drua` `dara` `hprg` `mprg` | mixed | `AVT <base>` — the avatar family |

`dura` is the one worth noticing: it prints as **flaw**, with a minus sign. That is what
`MATTR_DEC_MAXDUR` means — a durability penalty, and the only negative option in the table.

The five elemental resists get their meanings here even though the previous tick could not
separate their param ids. A name and an id are different questions, and this answers the first.

**`hp` is deliberately absent.** `0x004909f0` prints `"hp +%d%%"` and `0x00491bd0` prints
`"hp +%d"`. Both literals are really in the binary, so the engine disagrees with itself; which
governs is not established, so neither ships.

**Two rows were dropped as attribution noise**, and it is worth saying how they were caught: the
extractor tracks the most recently seen tag constant, so a literal can be attributed to a
neighbouring tag. `int` came back labelled "Ava hr" and `soli` labelled "resist stun" — both
labels that plainly belong to another tag. A first, looser pattern also swept up
`"ape(%d%%): %d"`-style lines, where the `%%` is a *probability* and not the value's unit; that
alone produced six false conflicts. Tightening the pattern to literals that are exactly
`label ±%d[%%]` cut the conflicts to the two real ones.

## The bless family, and the per-item option record

Four options print differently from every other one in the item dumper
(`FUN_00491bd0`, `0x00491bd0`) — **two numbers instead of one**:

```
"ape(%d%%): %d"    "luck(%d%%): %d"    "solid(%d%%): %d"    "atha(%d%%): %d"
```

The first number comes from the option record's `+0x14`, a field no other branch reads. These are
the probabilistic blessings — `MATTR_APE`, `MATTR_LUCK`, `MATTR_SOLID`, `MATTR_ATHANASIA` — and
they fire by chance rather than applying flatly.

**The set is closed, and the binary says so.** Any tag reaching that group and matching none of
the four falls through to

```c
FUN_00425f70("unknown bless[%d]", tag);
```

A fallback that names the concept is stronger evidence of a closed set than an enumeration would
be: it shows the author expected nothing else to arrive there.

`rep` (`MATTR_REPAIR`) sits in the same branch group and is **not** one of them — it prints
`"rep: %d,"` with no chance, and at `value - 1`. The stored number is one more than the displayed
one, which is recorded because an off-by-one in a display path is exactly what gets re-derived
wrongly later.

### The record

Two independent readers agree on the layout. The dumper walks the options printing `+0x04` as the
tag and `+0x10` as the value; the accessor `FUN_004927e0` (`0x004927e0`) returns `+0x10` and
writes `+0x04` back through EDI. The bless branch adds `+0x14`.

| offset | field |
|---:|---|
| `+0x04` | tag (packed) |
| `+0x10` | value |
| `+0x14` | chance — bless family only |

The options live in a container at `GObjPC + 0x5c0` and are **looked up, not indexed**, so there
is no stride to record. An item carries at most 12 of them, from the client's own assert
`"m_btMagicParamNum <= MAX_MAGPARAM_PER_ITEM"`.

Shipped as `combat.BlessTags` and the `MagicOption*Offset` constants. Nothing consumes them yet —
srrevamp implements no magic options — but a later implementation that modelled these four as
unconditional would be wrong, which is why they are recorded now.

**What the data could not confirm.** No column of `MagicOption.txt` is populated on every bless
row and no plain row, so the chance is not a distinct reference column; consistent with `+0x14`
being a per-item-instance field rather than a table one, though that was not separately proven.

## What is NOT here

The bonus *magnitudes*. Columns 4/5 hold a level and a factor and columns 8–16 further numbers,
none of which are decoded. srrevamp grants no magic options and has no system to grant them
into, so nothing here is wired into gameplay — it is a naming resource.
