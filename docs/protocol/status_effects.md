# Status effects (abnormal states): the bit vocabulary, and what the server does with each

Recovered 2026-09-19 (round 248) from both binaries. The two sides use **one numbering**:
the client keeps a character's abnormal states as a bit mask and picks an icon per bit
(`FUN_007fdab0` in `sro_client.exe`, a switch on the mask value), and the server keeps a
table of *param appliers* indexed by the same bit (`GObjPC_InstallParamContributionCallbacks`,
`0x004a40c0`, filling `pc+0xe0c + 4*bit`). The icon file names are the engine's own words
for the states; the params are what each applier writes into the character's ParamKeeper
while the state is on it (slot 5 = the abnormal-state context), removed again on expiry.

| bit | mask | client icon (`icon\stateodd\s_*_icon.ddj`) | server applier (`pc+0xe0c+4*bit`) | params written |
|---|---|---|---|---|
| 0 | `0x1` | freeze | `AbnormalState_Freeze_Apply00` (`0x4a4570`) | none -- a state flag |
| 1 | `0x2` | frostbite | `AbnormalState_Frostbite_Apply01` (`0x4a45d0`) | 23, 24 (walk/run speed), 140 |
| 2 | `0x4` | electricshock | `AbnormalState_ElectricShock_Apply03_p9` (`0x4a4850`, **server slot 3**) | 9 (`'era'`, parry rate) as `clamp(100 - value[2], 0, 100)` **percent of normal**, back to 100 on removal |
| 3 | `0x8` | burn | `AbnormalState_Burn_Apply02` (`0x4a46f0`, **server slot 2**) | none -- a timed damage tick, `table[value[2]] / (1 + param8/100)` every 2001 ms |
| 4 | `0x10` | poisoning | `AbnormalState_Poisoning_Apply04` (`0x4a4940`) | none -- a timed HP loss |
| 5 | `0x20` | zombi | *(the shared 3-byte `return 0`, `0x9371f0` -- a filled slot with no behaviour)* | |
| 6 | `0x40` | sleep | `AbnormalState_Sleep_Apply06` (`0x4a49f0`) | |
| 7 | `0x80` | root | `AbnormalState_Root_Apply07` (`0x4a4a50`) | |
| 8 | `0x100` | blunting | `AbnormalState_Blunting_Apply08` (`0x4a4a90`) | 23, 24 (speed), 140 |
| 9 | `0x200` | fear | `AbnormalState_Fear_Apply09` (`0x4a4bd0`) | |
| 10 | `0x400` | myopia | `AbnormalState_Myopia_Apply10` (`0x4a4c60`) | **183 -- the attack-range reduction percent** the action tick multiplies a reach by (`combat.ApproachBand`) |
| 11 | `0x800` | bleeding | `AbnormalState_Bleeding_Apply11` (`0x4a4cc0`) | 5, 6 (flat defence, negative) and a timed damage tick (`(*obj+0x4fc)(source, amount, amount, 2, effect)` every `effect+0x10` ms) |
| 12 | `0x1000` | *(no icon in the switch)* | *(no applier)* | |
| 13 | `0x2000` | dark | `AbnormalState_Dark_Apply13` (`0x4a4e20`) | 11 (`'hra'`, attack rate) |
| 14 | `0x4000` | stun | `AbnormalState_Stun_Apply14` (`0x4a4ec0`) | |
| 15 | `0x8000` | disease | `AbnormalState_Disease_Apply15` (`0x4a4f20`) | 169 |
| 16 | `0x10000` | confusion | `AbnormalState_Confusion_Apply16` (`0x4a4f70`) | |
| 17 | `0x20000` | decay | `AbnormalState_Decay_Apply17` (`0x4a5160`) | 5 (physical flat defence, negative: `-min(effect+0x34, ..)`) |
| 18 | `0x40000` | weakness | `AbnormalState_Weakness_Apply18` (`0x4a5240`) | 6 (magical flat defence, negative) |
| 19 | `0x80000` | powerless | `AbnormalState_Powerless_Apply19` (`0x4a5000`) | 178, 179 |
| 20 | `0x100000` | dissociation | `AbnormalState_Dissociation_Apply20` (`0x4a50b0`) | 180, 181 |
| 21 | `0x200000` | panic | `AbnormalState_Panic_Apply21` (`0x4a5320`) | 3 (MaxHP), 143 |
| 22 | `0x400000` | combustion | `AbnormalState_Combustion_Apply22` (`0x4a54a0`) | 4 (MaxMP), 144 |
| 23 | `0x800000` | *(admittance in the icon list; its mask was not read)* | *(no applier)* | |
| 24 | `0x1000000` | incubation | `AbnormalState_Incubation_Apply24` (`0x4a5620`) | |

**The slot is not always the bit** -- the engine says so itself, and round 248 got two rows
wrong by assuming it was. `AbnormalState_DeactivateSlotAndRebuildMask` (`0x4a5660`) rebuilds
the character's mask at `pc+4` by OR-ing, for every active slot, the word the table at
**`0xc63ec8`** holds for it. That table is `1 << i` for all 32 slots **except 2 and 3, which
are swapped**: slot 2 carries `0x8` and slot 3 carries `0x4`. So the mask the client turns
into an icon makes **slot 2 burn** and **slot 3 electric shock**, and the two rows above now
follow the table rather than the slot number.

Three data-flow pairs agree with it independently, each applier reading the field that its
own state's block in `Combat_ApplyStatusEffects` writes and no other block does:

| state | its block writes | the applier that reads it |
|---|---|---|
| burn (`bu`) | `+0x24`, from the `0xc63c94` table | slot **2** (`0x4a46f0`) |
| electric shock (`es`) | `+0x28`, the raw `value[2]` | slot **3** (`0x4a4850`), as `100 - it` |
| poison (`ps`) | `+0x38`, the raw `value[2]` | slot **4** (`0x4a4940`), as the damage |

The rest of the alignment stands on the agreements round 248 found: slot 8 lowers speed and
bit 8 is "blunting"; slot 10 cuts the attack range and bit 10 is "myopia" (short sight);
slot 17 cuts physical defence and bit 17 is "decay"; slot 18 cuts magical defence and bit 18
is "weakness"; slot 13 cuts attack rate and bit 13 is "dark" -- and for those the mask table
is the identity, so slot and bit coincide.

## What srrevamp does

Nothing yet: there is no status-effect system, so every one of these params is at its
registry default and `combat.ApproachBand` takes the myopia percent as 0. The table is the
spec for one. The params a state writes were harvested from the appliers' own
`ParamKeeper_SetParam`/remove pairs (`FUN_004b3510`/`FUN_004b3570` with slot 5); the states
whose row says only a name have appliers that act through object virtuals rather than
params, and are unread past that.

## How a skill applies one -- `Combat_ApplyStatusEffects` (`0x590680`), round 249

The applier is one block per status the skill row can carry, in this order of skill
fields (`skill_fields.md` offsets), each guarded by the field being present. Every block
asks the target's active-effect map (`target+0xa30`, `FUN_005a1a20(map, kind << 24, level)`)
whether the state can be applied at this level, and the six elemental blocks then roll the
same way (read in full for burn at `0x590af9..0x590c5d`):

	level  = value[1] + bonus                       ; the skill's status level
	if GetParam(resist%) >= 100: skip
	chance = round((100 - resist%) / 100 * value[0]) - round(GetParam(flat resist))
	if chance <= 0: skip
	record: +0x14 level, +0x1a chance, +0x20 1.0, +0x24 word[0xc63c94 + 4*value[2]],
	        +0x10 tick interval = skill 'puls' value[0], else 2000 ms (0x7d0)

The **kind** in the map key is the client's icon bit + 1, and the server's applier slot
(`pc+0xe0c + 4*slot`) is the bit itself -- three numberings, one order:

| skill code | field | kind (`<<24`) | client bit / icon | resist % / flat params |
|---|---|---|---|---|
| `fz` | `+0x30c` | 1 | 0 freeze | **27 / 145** |
| `fb` | `+0x310` | 2 | 1 frostbite | **28 / 146** |
| `es` | `+0x314` | 3 | 2 electricshock | **29 / 147** |
| `bu` | `+0x318` | 4 | 3 burn | **30 / 148** (`bu` = `MATTR_RESIST_BURN` on 30, already known) |
| `ps` | `+0x31c` | 5 | 4 poisoning | **31 / 149** |
| `zb` | `+0x320` | 6 | 5 zombi | **32 / 150** |
| `se` | `+0x430` | 7 | 6 sleep | -- |
| `rt` | `+0x434` | 8 | 7 root | -- |
| `sl` | `+0x438` | 9 | 8 blunting | -- |
| `fe` | `+0x43c` | 10 | 9 fear | -- |
| `my` | `+0x440` | 11 | 10 myopia | -- (its value becomes param 183 through the slot-10 applier) |
| `bl` | `+0x444` | 12 | 11 bleeding | -- |
| `dn` | `+0x44c` | 14 | 13 dark | -- |
| `st` | `+0x450` | 15 | 14 stun | -- |
| `ds` | `+0x454` | 17 | 16 confusion | -- |
| `ca` | `+0x458` | 18 | 17 decay | -- |
| `cssr` | `+0x45c` | 19 | 18 weakness | -- |

So the resist family is settled per tag, which `magic_options.md` had left open: freeze
27/145, frostbite 28/146, electric shock 29/147, burn 30/148, poison 31/149, zombie 32/150.
The function opens by reading **param 169** (the Disease applier's param) -- the gate on the
whole roll, which is what "disease" does. The blocks after the six elemental ones (sleep
onward) do not read a resist pair; their chance path is not read yet.

## Where a state lives, and how it ticks (round 275, 2026-09-20)

A character carries a **fixed array of 32 state records**, stride `0x70`, the first at
`pc+0xc` (the constructor loop in `GObjPC_InstallParamContributionCallbacks` walks exactly
that: `in_EAX + 3`, `+0x1c` dwords a step, 32 times). The applier for record *i* is the
function pointer at `pc+0xe0c + 4*i`, and it is called as `applier(mode, record)` with
**mode 0 apply, 1 tick, 2 remove**. The record's own fields, as the appliers read them:

| offset | what |
|---|---|
| `+0x10` | the tick interval bleeding uses (the others hard-code 2001 ms) |
| `+0x14` | the status level |
| `+0x1a` | the rolled chance |
| `+0x20` | a float factor, written 1.0 by the applier block |
| `+0x24` | burn's damage numerator, from the `0xc63c94` table |
| `+0x28` | electric shock's `value[2]` |
| `+0x38` | poison's and bleeding's per-tick damage |
| `+0x40` | bleeding's flat-defence amount |
| `+0x4c` | the source object id |
| `+0x60` | the active byte the mask rebuild reads |
| `+0x68` | the last-tick `GetTickCount` |

### The three damage ticks, read

Each of the three damaging states fires when `GetTickCount() - record+0x68 >= 2001` and then
restamps. They are `statuseffect.BurnTickDamage`, `PoisonTickDamage` and (for the parry cut)
`ElectricShockParryPercent`.

**Burn** (slot 2): `damage = table[value[2]] / (1 + GetParam(8)/100) * record+0x20`, read off
the FPU sequence at `0x4a4720..0x4a4756` (`movzx` the word, `fdiv 100.0`, `fadd 1.0`,
`fdivr`, `fmul` the float). **Param 8 is left unnamed** -- the registry has it as 0..10000
with no tag, and nothing here earns it a meaning; what is grounded is that the tick divides
by `1 + param8/100`. Burn **can kill**, and the applier drops the source only when the blow
would *not* be fatal, which is how a killing tick gets credited.

**Poison** (slot 4): `loss = max(curHP - value[2], 1)`, `damage = curHP - loss`, i.e.
`min(value[2], curHP - 1)`. **Poison cannot kill** -- it stops at 1 HP -- and it clears the
source unconditionally, so no poison tick is ever credited to anyone.

**Electric shock** (slot 3) does not tick damage at all: on apply it contributes
`clamp(100 - value[2], 0, 100)` to param 9 (parry rate) in the abnormal-state slot, and on
removal writes **100**. That the neutral is 100 is the useful part: a param-9 contribution
from this slot is a *percent of normal*, not a flat delta.

## The whole vocabulary, joined from both binaries (round 278, 2026-09-20)

Three numberings and two names meet, and they are joined by reading rather than by
resemblance:

- the **skill code** and its `CRefSkill` field (`skill_fields.md`, from the param parser);
- the **kind**, the literal each block loads as `kind << 24` before asking the target's
  effect map whether the state may be applied (`mov ecx,0xN000000` then `call 0x5a1a20`) --
  read at all **23** sites in `Combat_ApplyStatusEffects`;
- the client's mask **bit**, its icon, and the **label** the client carries beside the icon
  (`0x7fdab0` in `sro_client.exe`), which this page had never recorded.

| code | field | kind | bit | icon | the client's label |
|---|---:|---:|---:|---|---|
| `fz` | `0x30c` | 1 | 0 | freeze | **FZ** |
| `fb` | `0x310` | 2 | 1 | frostbite | **FB** |
| `es` | `0x314` | 3 | 2 | electricshock | **ES** |
| `bu` | `0x318` | 4 | 3 | burn | **BU** |
| `ps` | `0x31c` | 5 | 4 | poisoning | **PS** |
| `zb` | `0x320` | 6 | 5 | zombi | **ZB** |
| `se` | `0x430` | 7 | 6 | sleep | SLEEP |
| `rt` | `0x434` | 8 | 7 | root | ROOT |
| `sl` | `0x438` | 9 | 8 | blunting | SLOW |
| `fe` | `0x43c` | 10 | 9 | fear | FEAR |
| `my` | `0x440` | 11 | 10 | myopia | MYOPIA |
| `bl` | `0x444` | 12 | 11 | bleeding | BLOOD |
| `dn` | `0x44c` | 14 | 13 | dark | **DN** |
| `st` | `0x450` | 15 | 14 | stun | STUN |
| `ds` | `0x454` | 17 | 16 | confusion | CHAOS |
| `ca` | `0x458` | 18 | 17 | decay | CURSE_PD |
| `cssr` | `0x45c` | 19 | 18 | weakness | CURSE_MD |
| `csit` | `0x460` | 20 | 19 | powerless | CURSE_STR |
| `cspd` | `0x464` | 21 | 20 | dissociation | CURSE_INT |
| `csmd` | `0x468` | 22 | 21 | panic | **CURSE_HP** |
| `cshp` | `0x46c` | 23 | 22 | combustion | **CURSIE_MP** (the engine's own typo) |
| `csmp` | `0x470` | 24 | 23 | *(no case in the switch)* | *(none)* |
| `tb` | `0x474` | 25 | 24 | incubation | TIME_BOMB |

**Kind is always bit + 1**, and the labels prove it rather than assuming it: the client calls
the six elemental states FZ, FB, ES, BU, PS and ZB, and dark DN -- the skilldata codes in
upper case. Fifteen of the twenty-three agree letter for letter, at both ends of the run and
throughout it, which leaves the table no room to be off by a row.

**The trap.** The `cs*` codes do **not** mean what their letters suggest: `cshp` applies the
**MP** curse and `csmd` the **HP** curse. Two independent checks say so -- the kind literals,
and round 248's appliers (bit 21 writes MaxHP and its label is `CURSE_HP`; bit 22 writes
MaxMP and its label is `CURSIE_MP`; bit 17 writes physical flat defence and is `CURSE_PD`;
bit 18 writes magical flat defence and is `CURSE_MD`). Read a state off its kind, never off
its code's letters. `statuseffect.States`.

Three bits have no applying block: 12 and 23 have none at all, and 15 -- **DISEASE** -- is a
real state that no skill block applies, because it is the gate the applier reads first
(param 169). And bit 23's `csmp` is a state the skill table can carry that the client's
switch has **no case for**, so it is never drawn; whatever "admittance" is in the icon
directory, this function does not reach it.

### The non-elemental states carry their own duration and chance -- READ (round 277)

The blocks after the six elemental ones work the other way round, and this page's "their
chance path is not read yet" is now closed for sixteen of the seventeen.

They store **no chance**: every one of the 17 writes `record+0x1a = 0`. So the
`chance x unit` duration below cannot apply to them, and the block computes both numbers
itself from two authored values, each scaled by how far the target's level is above the
status's reach. Read as assembly (the sleep block, `0x590f06..0x590ff9`), because the
decompiler collapses the whole FPU chain into argument-less `FUN_009fbb40()` calls -- that
is the `ftol` helper:

	d   = max(GetLevel() - 10*(value[2] + bonus), 0)                  ; the OVERSHOOT
	dur = max(ftol(value[0] * (1 - 0.025*d)), ftol(0.5 * value[0]))   -> record+0xc
	chn = max(ftol(value[1] * (1 - 0.05*d)),  ftol(0.1 * value[1]))   -> rolled, not stored
	record+0x18 = (byte)value[2]                                      ; the status level

The FPU stack balances to empty across that run, which is the reading's own check: every
one of `2.5` (`0xb45e50`), `100.0` (`0xb45af0`), `0.5` (`0xb45c50`) and `0.1` (`0xb45ec0`)
is consumed exactly once, and the two `max` pairs are the two `cmp`/`jge` at `0x590fe9` and
`0x590ff3`.

So **value[0] is the duration in milliseconds and value[1] the chance**, each with its own
falloff and its own floor: the duration loses 2.5 % a level and stops at half, the chance
loses 5 % a level and stops at a tenth. The chance therefore bottoms out first (18 levels
over, against the duration's 20): a badly over-levelled target is hard to afflict, but once
afflicted keeps the state for half its authored time. `statuseffect.NonElementalDurationMs`,
`NonElementalChance`, `LevelOvershoot`.

**How far the shape reaches.** Fingerprinting every block in the function by its constants:
sixteen of the seventeen non-elemental blocks -- skill fields `+0x430` through `+0x470` --
have exactly one level term, one `2.5`, one `0.5`, one `0.1` and five `ftol`s. Two of them
(`+0x438`, `+0x450`) prefix an extra iterative term with an `imul`, unread. The last,
`+0x474`, has no level term and neither `2.5` nor `0.5`: a different computation, unread.

**And there are six status fields this page never listed**: `+0x460`, `+0x464`, `+0x468`,
`+0x46c`, `+0x470` and `+0x474` all guard a status block of this family. Which skill codes
and which states they are is **not** read -- the elemental blocks could be identified by
their resist `GetParam` calls and these have none, so nothing here names them.

### How long a state lasts -- READ (round 276, 2026-09-20)

The duration lives at **`record+0xc`**, the start stamp at **`+0x64`** (`+0x68` is the
LAST-tick stamp, a different field), and the removal test is
`AbnormalState_UpdateOwnerClear` (`0x4a4390`), which walks all 32 slots each pass:

	for slot in 0..31, if the record is active:
	    if (ownerMask & record+0x8) == 0                       -> remove
	    else if GetTickCount() - record+0x64 > record+0xc      -> remove
	    else  ownerMask' |= maskTable[slot] ; applier(1, record)

Removal clears the flag bytes and calls `applier(2, record)`. **The owner's mask at `pc+4`
is the authority**: clear a bit there and the state goes on the next pass, which is what the
function's name means by "owner clear".

The duration itself is a `CFormulae` switch (`0x410b40`), and all six elemental blocks call
it identically -- the assembly is the whole argument, because the decompiler drops both
arguments (one in `AL`, one in `CX`):

	mov cx, WORD PTR [ebx+0x1a]      ; the resist-reduced CHANCE this block just computed
	mov al, <kind>                   ; a literal, per block
	call 0x410b40
	mov [ebx+0xc], eax               ; the duration, in milliseconds

| block | state | `al` | multiplier | duration at chance 30 |
|---|---|---:|---:|---:|
| `+0x30c` `fz` (`0x590830`) | freeze | 0 | `0x61` = **97 ms** | 2.9 s |
| `+0x310` `fb` (`0x590965`) | frostbite | 1 | `0xfa` = **250 ms** | 7.5 s |
| `+0x318` `bu` (`0x590c07`) | burn | **2** | `0x2ee` = **750 ms** | 22.5 s |
| `+0x314` `es` (`0x590a97`) | electric shock | **3** | **500 ms** | 15 s |
| `+0x31c` `ps` (`0x590d64`) | poison | 4 | **1000 ms** | 30 s |
| `zb` (`0x590eb4`) | zombie | 5 | `0x2ee` = **750 ms** | 22.5 s |

Two things fall out of that table. **The number that decides whether a state lands also
decides how long it lasts** -- one value, `record+0x1a`, is both. And the `al` literal is the
SERVER SLOT, not the client bit: burn passes 2 and electric shock passes 3, which is a
fourth independent agreement with the `0xc63ec8` mask table above, from a different
mechanism again.

Only these six take their duration from the formula; every other `al` hits the switch's
assert. Where the non-elemental states' `+0xc` comes from is unread.

### The `0xc63c94` table is burn's damage curve, not a duration table

This page called it "by shape a duration table". It is not. It is written in exactly one
place in the binary -- the `bu` block of `Combat_ApplyStatusEffects` -- and read in exactly
one place, burn's applier, as the numerator of the damage above. The shape was the only
evidence there had ever been for "duration", and the use site says otherwise.

It is a rising word table in the server's own `.rdata`, at least 140 entries long:
index 0 is 0, then 8, 9, 11, 12, 14, 15, 17, 19, 20, ... reaching 100 at index 33, 1000 at
index 88 and 5365 at index 139. The full table is read from the operator's own binary at
`0xc63c94`, four bytes a stride, low word used.
