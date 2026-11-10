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
| 17 | `0x20000` | decay | `AbnormalState_Decay_Apply17` (`0x4a5160`) | 5 (physical flat defence, negative: `-min(effect+0x34, ftol(current - current x 0.3))` -- never more than 70 % of the defence there is, the 0.3 at `0xb461a0`; round 880) |
| 18 | `0x40000` | weakness | `AbnormalState_Weakness_Apply18` (`0x4a5240`) | 6 (magical flat defence, negative, the same cap) |
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

## What OpenSRO does (round 659)

Monsters give and receive states: `internal/statuseffect` lands a skill's status runs
(`Resolve`), keeps one record per slot (`Holder`) and ticks them; `session/status.go` wires it to
monsters and characters and sends every change of an object's mask as retail's 0x3057 abnormal
block (see "The wire" below). Of the params the table lists, OpenSRO applies the move speed
(frostbite 50 %, slow 75 %), bleeding's flat defence cut on a monster, and the three damage ticks;
the others are not published (myopia's range cut, dark's attack rate, the curses' params, electric
shock's parry -- OPEN). The params a state writes were harvested from the appliers' own
`ParamKeeper_SetParam`/remove pairs (`FUN_004b3510`/`FUN_004b3570` with slot 5).

### CORRECTION: an elemental run's value[1] is the chance, value[0] the strength (READ, round 659)

The round-249 block below says `level = value[1] + bonus` and computes a "chance" from value[0];
round 276 then read `record+0x1a` as that chance and concluded "the number that decides whether a
state lands also decides how long it lasts". Both are wrong. The freeze block, in full
(`0x590756..0x590889`):

	mov eax,[p+4] ; add eax,edi            ; value[1] + GetParam(169) (the disease gate, `0x5906e6`)
	mov ecx,0x1000000 ; lea edx,[esi+0xa30] ; kind << 24, the TARGET's accumulator map
	call 0x5a1a20                          ; GObjPC::RollChance -> FUN_00599cc0, the chance-memory dice
	je skip
	GetParam(0x1b) resist% ; >= 100 skip
	edi = ftol((100 - resist%) / 100.0 * value[0]) - ftol(GetParam(0x91))  ; jle skip
	record+0x1a = di ; record+0x14 = value[1] ; record+0xc = 0x410b40(slot 0, di)

So **value[1] is the percent chance**, rolled through the same bad-luck-protected dice as a
critical (`combat.RollChanceTracked`), one accumulator per state kind **on the CASTER** (round 659's review:
ESI is the source -- `[esi+8]` goes to record+0x4c -- and the caller loads it from `[esp+0x124]` at
`0x58f412`, the object whose `+0xa30` the critical roll uses at `0x58ed76`; the key has no id bits);
**value[0] is
the strength** that the resist cuts and the duration multiplies. The retail rows agree (MEASURED,
33,698 skilldata rows through `export-refdata`'s new column 90): `MSKILL_CH_WATERGHOST_ATTACK02`
carries `ps:34,100,16` (always lands, 34 s, 16 a tick), `SKILL_CH_COLD_GIGONGTA_A_01`
`fz:30,5;fb:30,25` (a 5 % freeze for 2.9 s, a 25 % frostbite for 7.5 s),
`MSKILL_CH_TIGERWOMAN_ATTACK03` `zb:72,100`.

The non-elemental blocks roll the same dice (`mov ecx,0x7000000; lea edx,[esi+0xa30]; call
0x5a1a20` at `0x59106f` for sleep, `0xf000000` at `0x592051` for stun) with round 277's chance,
after three terms OpenSRO holds at zero: 0x59de50's lookup in the target's effect map (what its
own buffs take off), that lookup's percent cut, and the disease bonus. `record+0x18 =
(byte)value[2]`, the level. Bleeding (`0x591a11..0x591c52`) also writes `+0x38 = value[3]` (the
damage a tick), `+0x40 = value[4]` (the flat defence cut) and `+0x10` = 'puls' or 2000.

### Whom a damage tick names (READ, round 659's review)

Burn (`0x4a46f0`), poison (`0x4a4940`) and bleeding (`0x4a4cc0`) share one shape. They resolve
`record+0x4c` (`0x485d90`) and, while the record's latch `+0x6c` is clear: no object -> the damage
goes with no source; an object whose life state (vslot `0xf8`, `CGObj::GetLifeState` `0x485ee0`) is
neither 2 DEAD nor 3 GONE -> the damage goes **with** it, every tick, poison's included; dead or
gone -> the latch is set for good. Latched, burn and bleeding keep the source only for a fatal
tick, and poison drops it always. So a living caster is booked every tick (the damage list, the
struck event), and a kill by a tick is credited to its caster even after the caster has died.
`statuseffect.SourceRule`. (Round 659 first read "the source is dropped unless fatal" alone.)

### The blocked flag, not a life state (READ, round 659's review)

`0x5906c0 cmp [edi+5],2` in the prologue tests the HIT RECORD's blocked flag (`[ebp+5] = 2` is
written after the block roll at `0x58f0ef`, where the damage is zeroed): a blocked blow applies no
state, in both directions. That OpenSRO never afflicts a dead character is OURS.

### What a state stops (READ)

- **Movement**: the movement handler (`GObjPC::FUN_004b0ea0`, slot 377 of every mobile class,
  monsters included) refuses a move for mask bits `0xc1` -- freeze, sleep, root -- and `0x4000`,
  stun (`0x4b0fa6`, `0x4b0fae`). `Holder.CanMove`.
- **Acting**: freeze, stun and sleep call **vslot 0x570** on apply, `GObjPC::FUN_004aa340`
  (slot 348, shared by CGObjPC and CGObjMob -- the two vtables `0xaf59fc` / `0xaeddac` read): stop
  the move (`vslot 0x4c0` moving? then `0x4b0`), cancel the running action through the action queue
  at `+0xa30`, and **vslot 0x55c**, `GObjPC::FUN_004a9d00` (slot 343): SetMotionState to 10 FROZEN,
  9 STUN or 0x13 (sleep; past the MOTIONSTATE table's 18), back to 0 STAND on removal -- freeze's
  removal passes a 1.5 s AJStateChanger delay (`_DAT_00b45c10` = 1.5): OpenSRO holds a thawing
monster from acting for those 1.5 s (`Holder.CanActAt`). INFERRED:
  that no new attack starts while the motion state is one of those -- the refusing test on the
  monster's attack path is not read. `Holder.CanAct`.
- **Speed**: frostbite writes params 23/24 (walk, run) at 50.0 in the abnormal context's scale slot
  (`push 5; push 3`, `0xb4603c`), slow at 75.0 (`0xb45de0`) only while no frostbite bit is set,
  its tick taking over once frostbite lets go; 100.0 (`0xb45e10`) on removal. Each then republishes
the speed at once (vslots `0x4e8`/`0x4ec`); OpenSRO restarts a moving monster's leg at the new
speed on the next AI tick. Both also write
  param 140 (200.0 / 125.0, unnamed; not modelled). `Holder.SpeedPercent`.
- **Root** (`0x4a4a50`) stops a moving object (`0x4c0`/`0x4b0`) and nothing else.
- **Fear** (`0x4a4bd0`) sends the object's AI message 0x14 with the source -- what the AI does with
  it is OPEN; OpenSRO shows fear and does nothing else with it.

### The wire (round 659)

Retail's 0x3057 is the HP/MP/abnormal update (`sro_client.exe` `0x8a9e30`): u32 id, u16, u8 flags;
flag 1 u32 HP, flag 2 u32 MP, flag 8 u16, **flag 4 u32 mask** (`0x9cd5e0` stores it at `+0x2c4`
and diffs it), **then one u8 level per set bit with `(1<<b) & 0x17fefc0`, low bit first**
(`MsgStreamBuffer::FUN_009d2220`). OpenSRO's `OpObjectStatus 0x3057` carries that block after
its own head (u8 owner kind, i64 id -- OURS), flag 4 only. The client (`StatusNet`) keeps each
object's mask and the target window's buff viewer adds one icon per bit after the skill buffs,
in the second list (`0x699480` -> `0x7fd2e0`), icon and label from `0x7fdab0`, tooltip from
`0x7fc260` kind 2: the text of `PARAM_<label>`, ` <level><UIIT_STT_GRADE>`, then the category's
text and `UIIT_STT_MACROPOTION_ABNORMAL`. OPEN on the client: the body effect `0x9cd5e0` attaches
per bit (a skill object from the `PARAM_<label>` lookup, `0xa950a0` -> `0xa54020`), the colour
tints (freeze sets `+0xbd` and animation state 9; frostbite/slow set the animation speed `+0xc0`;
electric shock, burn, poison, zombie, dark and stun lerp the body colour over 1000 ms through
`vtable +0x48`), the buff bar's own abnormal icons (`UI_STATE::0x7836d0`), and the tooltip's
description line.

### How a state's look ends (round 847)

The user: "sometimes the status effects cast on the players ... linger even after it's been removed
naturally or through pills. It eventually goes away but it takes awhile."

**Every end is one message (READ / MEASURED).** The server ends a state in four places --
the status pass at its time (`Holder.Step`, `AbnormalState_UpdateOwnerClear` `0x4a4390`), a cure
pill or cure skill (`statusFX.cureCharacter`, `FUN_004a56c0` then the mask rebuild and send
`0x4a5c60`), a death (`finishKill` -> `endCharacter`) and a logout or a pass that finds the
character gone -- and each sends the owner's new mask as 0x3057 to the owner and to every player
holding its body (`broadcastStatus` -> `sendAboutOwner`). A state landed again before its end
replaces its slot's record (`Holder.Put`, READ: one record a slot), so it ends once, at the
renewal's time. `server/internal/session/status847_test.go` holds each of them, owner and observer.
MEASURED on a prod-like lane server (no `-trust-client-positions`, the navmesh): the send is in the
same 100 ms pass as the end, and both clients took it at once.

**What the client does with a bit that went off (READ, `sro_client.exe`).** The mask setter
`FUN_009cd5e0` calls `GlobalDataManager::FUN_009cd2b0(effect id)` for it, which walks the object's
decoration list (`+0x288`) and ends each `CIDecoSkill` whose id (`+0x5c`) is the state's
`PARAM_<label>` with `FUN_00a53120` -- the same end a buff's 0xB072 runs. Its tail,
`IDecoSkill::FUN_00a4ffe0(1)`, runs `FUN_00a4db00` and `FUN_00a488f0` for every effect entry:
`FUN_00a4db00` first calls `FUN_00a48690`, which hands the row's **Fade first value** (row `+0xa`)
to `FUN_00a48190` on the entry and on each of its copies -- with a non-zero value it starts an
alpha fade 255 -> 0 over `value / 1000.0` s (the double at `0xd83268` is 1000.0) -- and always
returns 0 (`0xa486f5 xor eax,eax`), so the effect's keep flag is then cleared (slot 4 with 0);
`FUN_00a488f0` frees the entry's extra copies at once (slot 2). The decoration's update
`CIDecoSkill::vslot_014` (`0x00a503f0`) then steps the fade each frame (`FUN_00a47d20`, linear),
hands the alpha to the effect (slot `0x24`), and frees the effect (slot 2) when the fade is done at
alpha 0 -- or sooner, when the effect's own update says it has finished. The pulse ends in the same
call (`vtable +0x4c`), and the clip speed and the freeze flag go back at once.

Every `PARAM_` row has **Fade 300,300** (MEASURED, skilleffect.txt): a state's aura is gone 300 ms
after its end, fading all the way. Of the 146 ACT_L AT_LOOP rows, 59 have a Fade (10, 100, 300,
500 or 800 ms) and 87 none (MEASURED).

**The cause (MEASURED).** OpenSRO ended the aura with `EfpEffect.release` alone (round 785's reading
of `FUN_00a4db00` without `FUN_00a48690`): the keep flag cleared, the particles left to play out.
`client/tools/state_aura_release_probe.gd` stepped each `status_bad_*.efp` kept for 6 s, released
it, and counted: stun 0.5 s, electric shock 0.6, poison and zombie 1.5, root and slow 2.0, dark 2.0,
sleep, fear and hide 2.4, myopia 2.7, panic 3.5, burn, frostbite, bleeding and disease **4.0 s**,
and confusion's `status_bad_temptation.efp` **never** (still 69 particles after 60 s; its root
re-arms every wrap) -- so it drew until `EfpEffect.ONESHOT_MAX_LIFE`, 30 s after the end. Live,
on the base (`f2a20b92` + the timing lines), an observer (real time) drew poison 1.04 s, burn
2.47 s, darkness 1.54 s, bleeding at a death 1.50 s and **confusion 29.97 s** past the message;
the owner's frames (60 a second of scene time) 40, 181, 90 and 289 frames, and confusion more
than 1,042 (the run ended first). That is "it eventually goes away but it takes awhile". The
server, the message and its receipt were on time on every path; the icons and the pulse ended with
the message.

**Now (`SkillEffects._end_kept`).** A kept effect remembers its row's Fade
(`EfpEffect.end_fade_ms`, `SkillEffects.end_fade_ms_of`); its end releases it and, with a Fade,
fades it 255 -> 0 over that many ms and frees it (the arrival fade's own stepper, `_step_lingers`).
That is every state aura (`_apply_state_look`, `_drop_state_look`, the zone change's undo) and every
buff aura (0xB072, the grace end); a row without a Fade is let go as before. MEASURED after, the
same live schedule: every aura on every path was gone 18 frames (300 ms) after the message on the
owner's and the observer's rendered frames, and 297-332 ms on the headless clients' wall clock --
confusion's included. (One headless 1.5 s, the dying owner's own bleeding in the observer run:
INFERRED, its respawn's reload stalled that client's frames over the fade -- the fade counts scene
time, and the same death drawn by the rendered owner was 18 frames.) A cast's kept loops
(`SkillEffects.stop_all`) take the same path in the original (`FUN_00a534d0` / `FUN_00a50a00` ->
`FUN_00a4ffe0`) and are still only let go here: OPEN, not part of this report.

**Timers that are the original's (READ).** The target window's buff viewer and the party window's
buff row rebuild from the object every 1000 ms (`0x69a215` / `0xb93320(1, 0x3e8)`), so a state's
icon there can stay up to a second after its end, in the original as here. OURS: while a group of
players is being spawned, another player's 0x3057 waits behind the group
(`NetClient._passes_group`); this player's own never does.

### A state's colour: one slot on the body, never in a material (round 855)

**READ (`sro_client.exe`).** The colour pulse is a state of the character's compound object
(`[obj+0x9c]+4`, CCompChar), not of any material:

- `+0x48`, `CObjRendererVS::FUN_00c25800(c1, c2, ms)`: `+0x1ec = 1`, the colours at `+0x238` /
  `+0x244`, the ms at `+0x250`, the elapsed `+0x254 = 0` rising (`+0x258 = 1`), the current colour
  `+0x1f4` = colour 1. A second call overwrites the same fields: **one slot, the last start wins.**
- Each frame the compound's update `CCompChar::FUN_00c33430` steps it while `+0x1ec` is set
  (`FUN_00c26ff0`: the elapsed up to the ms and back down, the colour lerped between the two).
- Every part drawn reads its compound's flag (`CObjRendererVS::vslot_038`, `c:0xbf5830`:
  `param_1[0x38] = [compound+0x1ec]`) and while it is set draws with the pulse colour in place of the
  material's and the object's (`FUN_00c27180`: c10, c11, c14).
- `+0x4c`, `FUN_00c258b0`: `+0x1ec = 0` and nothing else; the next draw of every part is its own.
- Callers of `+0x4c`: the mask setter `FUN_009cd5e0` for a tinted bit going off (`0x9cdb5d` for BU,
  ES, PS, ZB, DN, STUN; the FB case beside it) -- guarded only by the body mode `+0x2c2` and the
  decoration kind `+0x448` (round 856, below), not by any other bit still on -- and any skill
  decoration's end `CIDecoSkill::FUN_00a53dd0` when one of its rows carried SCT_MAT (flag 0x800):
  berserk's, and every other kept decoration's. All name the same compound.

So: a burn and a poison on one body draw the colour of the bit set last in the walk (low to high);
either ending ends the colour while the other runs. A part added or rebuilt mid-pulse draws it; at
the end there is nothing to put back.

### The colour's guards: body mode 1 (berserk) and decoration kind 2 (round 856)

**READ (`FUN_009cd5e0`, its disassembly `c:0x9cd640..0x9cdb68`; esi is the object whose mask it is).**

- Only the colour calls are guarded. On: the `+0x48` of FB, ES, BU, PS, ZB, DN, STUN behind the tests
  at `0x9cd74a`, `0x9cd7df`, `0x9cd84d`, `0x9cd8b7`, `0x9cd969`, `0x9cd9d1`, `0x9cda37`. Off: the `+0x4c`
  at `0x9cdb35..0x9cdb56` and in the FB case. Not guarded: the `PARAM_` decoration's start
  (`FUN_00a54020`, `0x9cd723`) and end (`FUN_009cd2b0`, `0x9cdac0`), FB's and SLOW's clip speed `+0xc0`
  (`0x9cd7bf`, `0x9cd95e`; off `0x9cdb01`, `0x9cdb2d`), FZ's motion state 9 and `+0xbd` (`0x9cd7ce`,
  `0x9cd7d3`; off `0x9cdb0b`).
- The test sits in each bit's case and reads the object's own bytes: `+0x2c2 == 1` or `+0x448 == 2`
  skips the call. **DN's end reads `+0x2c2` alone** (`0x9cdb35 cmp byte [esi+0x2c2],1` jumps straight
  to the `je` at `0x9cdb56`, past the `+0x448` compare at `0x9cdb4f`).
- **`+0x2c2` is the body mode, not riding.** Its one writer is the body-mode setter `FUN_009cf880`
  (`[this+0x2c3] = extra; [this+0x2c2] = mode`), reached from 0x30BF kind 4 (`FUN_008a80a0` case 4, any
  object in view), the spawn (`FUN_009d17e0`, `GlobalDataManager::FUN_0052dc70`: the state block's
  `+0x470`) and a debug command (`FUN_005470f0`); the constructor `CICharactor::FUN_009d2ad0` zeroes it.
  Mode 1 runs `FUN_009dd620(1, ...)` (the hwan decoration, 0x80000000 / `SYSTEM_CH_HWAN2MODE`), mode 4
  draws the body at alpha 0x50. **Mode 1 is berserk.** Mounting a horse writes neither byte, so a
  rider's state colour is drawn and ends as anyone's. (Round 785's StateLook header and round 855's
  entry called it "the riding byte"; wrong.)
- **`+0x448` is a skill decoration's mark on its object** (`deco+0x58`): `FUN_00a53850` (a
  decoration's start) and `FUN_00a54be0` (a cast's action read) write 2 when the decoration's skill ref
  (`deco+0x154`) has a non-zero `+0x110` -- the client's skilldata parser `FUN_009bbca0` files the
  Param code `0x6d6f6d` (`mom`) there -- and `FUN_00a54be0` writes 1 when `+0x114` (`pmhp`) reads 100 at
  its `+8`; `FUN_00a53120` (a decoration's end) writes 0 for a `mom` skill. MEASURED: of the client's
  61,330 decrypted skilldata rows (Media.pk2's ENC files, decrypted with the executable's own tables on
  the box) one skill has `mom`: `MSKILL_RM_ROC_ATTACK10` (id 31102), skilleffect.txt's "괴조 로크 광폭화"
  -- the Roc's frenzy -- whose ACT_L row is `SCT_MAT,170,30,0,235,155,0,1000`. The server's
  `SkillAction_Buff` (`s:0x5830b0`, ref `+0x57c`) re-arms its stat stacks every value[0] ms.
- So a state's colour neither starts nor ends while the body's own decoration colour holds the slot
  (berserk's red, the frenzy's orange); the decoration's end (`+0x4c`) ends whichever colour is on. A
  state begun before and ended inside leaves the slot as it is; one begun inside never draws.

**A kept decoration's colour (READ).** `IDecoSkill::FUN_00a513a0`, playing a decoration's rows, hands
a row with flag 0x800 to the compound's `+0x48` (colour 1 the row bytes `+0x82/+0x81/+0x80`, colour 2
`+0x86/+0x85/+0x84`, each / 255; the ms `+0x88`) and keeps it at `+0x180`; the destructor
`CIDecoSkill::FUN_00a53dd0` calls `+0x4c` when one was kept, unless the decoration is flagged hwan
(`+0xfc & 1`) and `FUN_009c7b20` says the body mode is still 1. No body-mode or kind test. 22 rows of
skilleffect.txt carry SCT_MAT (MEASURED): berserk's three (`SYSTEM_CH_HWANMODE`, `HWAN2MODE`,
`HWAN2LINKMODE`), `PARAM_STONE`, the Roc's frenzy, five petrify attacks (`status_bad_stone_on.efp`),
the two `SKILL_EU_CLERIC_REBIRTHA_SPECIAL_*_BUFF`, seven flame-master / dark-mob marks
(`EFFECT_AM_*`), the two event thieves' marks, and one cast row (`MSKILL_TQ_WHITESNAKE_ATTACK03` READY).

**Here (round 856).** `StateLook.walk(..., guard)` leaves out a guarded bit's colour call
(`colour_guarded`); World3D's `_state_guard` reads body mode 1 from NetClient's `body_modes` (the
0x30BF kind 4 book) and kind 2 from the owner's running buffs (a skill whose Param block has `mom`,
`SkillBuffCatalog` "mom"). `SkillEffects` draws a kept decoration's SCT_MAT colour for buff auras and
state auras (`DECO_WHO`) and ends it when the aura ends, after its rows' Fade (INFERRED: the
decoration is freed at its fade's end). Not built: a cast's SCT_MAT row (the white snake's READY), and
the kind-2 mark a 'mom' CAST sets on its caster before the buff (`FUN_00a54be0`) -- OpenSRO's server
casts no 'mom' skill (it starts no monster self-buffs), so kind 2 is not reached live.

**The bug (MEASURED, round 855).** OpenSRO drew the pulse by giving each mesh a copy of its material
and painting `material_override` every frame (StateLook, round 785). `CharacterLight` rescans a body
every 8th visit and swaps each object material for ObjectLight's shared per-level copy -- it left a
berserk copy alone but not a state's. So on any terrain tile (a level other than 0.6) the pulse's
copy was replaced within a few frames by the shared level copy, StateLook painted *that*, and at the
state's end it put back... the same shared material, with the last pulse colour in it: the body kept
the colour, and so did every body at that level wearing the same material, until the body stepped to
another level or the material was freed. A body on an object (the Jangan plaza deck, 0.6) was never
swapped, which is why round 847's live runs at the spawn saw the colour end on time.
`r855_probe` (headless, base `6b1b1223`): after a poison on a level-153 body, CharacterLight's rescan
and the end, the shared level copy's `object_tint` stayed `(0.166, 0.260, 0.108, 1)` and a second
body at that level drew it. Live numbers: WORLD_ISSUES round 855.

**Now (`BodyPulse`, OURS method for the READ rule).** One slot per body, started and ended by the
state walk's events (`StateLook.walk()["pulse"]`: the last tinted event of the change) and by
berserk (`BerserkLook`), last start wins, any end ends it. It paints only copies it made: each frame
a mesh drawing its copy is painted; one whose material something else replaced (an equipment glow,
a fade's end) has that material taken as its own and a new copy made; one drawing a fade twin keeps
the twin (a cohort's shared twin is never painted; a twin made from the copy is the mesh's alone and
pulses). `CharacterLight` leaves a pulsed mesh alone (the pulse stands in for the object colour) and
the end puts each mesh back on its material at the body's level then. A body with a colour on is not
drawn by the far crowd (`_crowd_eligible`: "pulse"), whose instances would keep the copy.

## How a skill applies one -- `Combat_ApplyStatusEffects` (`0x590680`), round 249

The applier is one block per status the skill row can carry, in this order of skill
fields (`skill_fields.md` offsets), each guarded by the field being present. Every block
asks the target's active-effect map (`target+0xa30`, `FUN_005a1a20(map, kind << 24, level)`)
whether the state can be applied at this level, and the six elemental blocks then roll the
same way (read in full for burn at `0x590af9..0x590c5d`):

	level  = value[1] + bonus                       ; CORRECTED (round 659): the CHANCE, rolled here
	if GetParam(resist%) >= 100: skip
	chance = round((100 - resist%) / 100 * value[0]) - round(GetParam(flat resist))   ; the STRENGTH
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
