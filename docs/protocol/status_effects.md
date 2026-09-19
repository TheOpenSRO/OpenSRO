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
| 2 | `0x4` | electricshock | `AbnormalState_ElectricShock_Apply02` (`0x4a46f0`) | (through object slots; unread) |
| 3 | `0x8` | burn | `AbnormalState_Burn_Apply03` (`0x4a4850`) | 9 (`'era'`, parry rate) |
| 4 | `0x10` | poisoning | `AbnormalState_Poisoning_Apply04` (`0x4a4940`) | none -- a timed HP loss |
| 5 | `0x20` | zombi | *(no applier installed)* | |
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

The alignment is the evidence: the server's slot 3 lowers parry and the client calls bit
3 "burn"; slot 8 lowers speed and bit 8 is "blunting"; slot 10 cuts the attack range and
bit 10 is "myopia" (short sight); slot 17 cuts physical defence and bit 17 is "decay"; slot
18 cuts magical defence and bit 18 is "weakness"; slot 13 cuts attack rate and bit 13 is
"dark". Six independent agreements between a param's meaning and an icon's name, from two
binaries that never share a string.

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
onward) do not read a resist pair; their chance path is not read yet, nor is the
`0xc63c94` word table the `value[2]` index selects (by shape a duration table).
