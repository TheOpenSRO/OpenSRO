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
