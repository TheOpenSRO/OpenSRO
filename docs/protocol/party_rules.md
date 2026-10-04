# Party rules: types, sharing, items, jobs, party monsters, party matching

Round 709 (party epic, spec round), lane party709b. This page holds the **rules and formulas**
of the party system; the wire layouts are party709a's (`docs/protocol/party_protocol.md`), the windows party709c's
(`docs/protocol/party_gui.md`). The round-709 review's findings
(`docs/rounds/party709_review_rules.md`) are applied below. Messages are named here by purpose, with an opcode only where
the binary itself put one next to the rule.

The user (2026-10-04) asked for the party system "fully working ... match the client/server opcodes
exactly. Make no mistakes", and asserted a list of rules; every one is answered in "The user's
assertions" below as confirmed, corrected or OPEN.

**Sources.**
- `SR_GameServer.exe` (dump `/var/tmp/decomp_server`, asm `srgs.asm`, objdump on the exe), the
  server package's game server. **READ (GS)** means read there.
- `SR_ShardManager.exe` of the same package (dump `/var/tmp/decomp_shardmgr`, made by lane party709a
  this round; asm by objdump of `/var/tmp/party709a/SR_ShardManager.exe`). **READ (SM)**. The party
  and the party-match registry live in this process (RTTI `CPartyManager`, `CParty`, `PartyRegData`,
  `trs_party_job`); the game server keeps a local copy of each party and relays requests to it.
- `sro_client.exe` (dump `/var/tmp/decomp_client`). **READ (client)**.
- The server package is a private-server distribution. Nothing modded was seen in the party code,
  but a server READ means "READ (this package)", not "retail". The rates (`ExpRatio`,
  `ExpRatioParty`) are config, and this package's config is modded (`internal/rates`).

**Labels.** READ (with address and binary), MEASURED, INFERRED (reasoned, not observed), OPEN (not
known), OURS (this project's choice). No game data is on this page: addresses, codes, text keys and
the constants the binaries compute with.

**Float constants were read by operand size** (`fld/fmul QWORD` = double, `fld DWORD` = float) out
of `.rdata`, never from the decompiler's rendering, which mistypes them in this binary.

---

## Corrections to existing records

| Record | Says | What is true |
|---|---|---|
| `docs/protocol/party.md` "The invite ladder", step 5 | "the target is within **`0x26` = 38** of the caller (`GObjPC::IsWithinInteractionRange`)" | `0x26` is the third argument, an **interaction-kind code** (u16, checked against the target's TID by `FUN_004a8d90`), not a distance. The distance is chosen by target class inside `GObjPC::IsWithinInteractionRange` (`0x4a8e10`): **600.0** for a PC target (`fld DWORD 0xb46198`, the `IsPC` branch), default 320.0 (`0xb460dc`); it is a 3D distance (`FUN_00430ba0` keeps y). READ (GS, `0x514620`, `0x4a8eea`-`0x4a8f85`). |
| `docs/protocol/party.md` "Who reads the flag word", `leveldata.go` `PartyExpBonusPerMember` comment, `RE_COMPLETION.md` 2026-09-15 | the 3%-per-member bonus applies in every party, "it does **not** test the party's exp-sharing flag ... OpenSRO applying the bonus unconditionally is therefore correct" | The bonus is the **exp free-for-all** branch only. The monster's kill distributor `CGObjMob` slot 399 (`0x4c44a0`; the gold pet's twin `0x4d68c0` is identical) groups contributors by `(exp-share flag, party or self)`. A group whose flag is set goes to the party share `GObjPC::FUN_005bca60`, which pays 10%/20% per member and splits by level (below); only a group whose flag is clear goes to `0x4c4820`, which builds `1 + (n-1)*0.03`. The flag test is `cmp BYTE [eax+0x10],0` at `0x4c475f` on the group record, set from `party+0x10 & 1` when the group was formed. READ (GS). |
| `leveldata.go` `PartyExpBonusPerMember` "TWO GATES", and the function it cites | names `CGObjCOS_GoldPet::vslot_399` as "the" kill reward | The monster's own path is `CGObjMob::vslot_399` (`0x4c44a0`, RTTI: CGObjMob, CGObjNPC, ... slot 399); the gold-pet function is a twin with the same branch. Cite the monster's. READ (GS). |
| `combat.go` kill path ("How much skill experience a KILL is worth is NOT recovered ... no kill path in this binary feeds the currency at all") and `combat.go` `SPReward` comment | no kill grants skill experience; the census of `GainExpAndLevel`'s 42 call sites found no kill | The census counted **direct** calls. The kill reward `CGObjPC::vslot_420` (`0x4ea6a0`) calls `GObjPC_GainExpAndLevel` **through the vtable** (`call [vt+0x170]`, slot 92) with the EXP as the 64-bit pair and **the kill's skill experience** as the second pair, computed by `Formulae::FUN_004106b0` (formula below). Every kill pays skill experience, and the party multiplier scales it with the EXP. READ (GS). |
| `combat.go` `killExpFor` ("What the engine does when a party of two drops to one is UNREAD") | unread | READ (SM `0x44f580`): a member leaving a party of exactly two **dismisses the party** (`0x44eb30`: notice 1 with `0x2c0b`, the leader's listing deleted). A party is never left with one member. |
| `recovered_names.tsv` `Party_ShareHwanCount` (`0x5bcf30`) | "in the killer's region" | in the killer's **world** (vtable `0x14`, `IGObj::GetWorldID`), alive (`GetLifeState()==1`); no region or distance test. READ (GS). |
| `docs/protocol/party.md` "`0x061` ... A party-side *teleport* action" (and `Party_RemoveMember`'s note) | `0x061` is a party-side teleport; reason 2 is a teleport removal | `0x061` (`FUN_00514530`) requires a party and calls `FUN_005144e0(2)` → `Party_RemoveMember(reason 2)`, which posts the removal to the party server (`trs_wait_response::FUN_005be490`, relay kind 3). Reason 2 is **leaving the party** (the user's own Leave); the `SaveCurPosAsLastTelPosition` name on the helper it calls first is unproven (INFERRED: the name came from another caller). Reasons: 1 = leaving the world on a forced disconnect (`FUN_004def90`, BL==4), 2 = leave, 3 = leaving the world otherwise, 4 = expelled (`0x063`). READ (GS) for the call sites; the reading of 1/3 as kinds of world exit is INFERRED from `FUN_004df050`'s callers (fifty pass 4 from error paths). |
| `party.go` `MaxSize` comment, `party.md` "OpenSRO's parties share experience unconditionally" | eight applies because every OpenSRO party shares EXP | must change: the cap is 8 or 4 by the party's own exp-share bit, chosen at formation (below). |
| `docs/protocol/monster_ai.md` "The kill's party count", `session/nestkill.go` `partyMembersNear` comment | the range is measured from the dead monster (INFERRED) | from the **kill credit** (READ `0x5bcacb`-`0x5bcb29`, ECX = the kill credit), in the same world, horizontally with 1920-unit region steps. Review of round 709. |
| `docs/protocol/party.md` "Whether the exp-sharing flag can change after creation. Nothing read so far writes it." | open | READ: the flags cannot change. The SM's request switch (`FUN_0044ec50`) has kinds 0 form, 2 join, 10 register listing, 11 modify listing, 12 delete listing, 13 list page; the relay switch (`FUN_0044f3f0`) has 3 leave, 6 member update, 7 chat. None writes a party's flags. Modifying a listing with a different flags byte is refused (`FUN_004513c0` returns 5), and registering a listing for an existing party copies **the party's** flags over the client's (`FUN_00451110`). The client has no sender in `0x7064`-`0x7068` (`client_senders.tsv`). |

---

## Who owns what

| Rule | Process | Evidence |
|---|---|---|
| Party object, members, leader, flags, formation, join, leave, dismiss, leader succession | **ShardManager** | SM `0x44ed70` form, `0x44f130` join, `0x44f580` leave, `0x44e1a0` remove + succession, `0x44eb30` dismiss |
| Party matching: listings, numbers, pages, join requests, their timeout | **ShardManager** | SM `0x450680`/`0x450990`/`0x450ba0`/`0x450d20`, `0x44f850` |
| Invite checks, kill EXP/SP sharing, item and gold distribution, party monster arming, berserk share | **GameServer** | the functions cited below |
| Member state updates (HP/MP, level, position, masteries) | GameServer computes, ShardManager relays (kind 6) | GS `CGObjPC::FUN_005bb0c0`, `0x5bc730`; SM `0x44e460` |
| Party chat | GameServer → ShardManager (relay kind 7) → each member's GameServer | GS `0x5bb8c0`; SM `0x44e840`; GS `0x5bef50` |

OpenSRO has one process. This split only says where to read; OURS: implement all of it in the one
server.

---

## Party types: the flags byte

`party+0x10` (GS), `party+0x08` (SM): one byte, three bits. READ.

| bit | meaning | text key (client) | evidence |
|---|---|---|---|
| 0 | **EXP Auto Share** (clear: EXP Free-For-All) | `UIIT_STT_PARTY_EXP_SHARE` / `_EXP_SELF` | the kill distributor's group flag; the 8/4 cap (GS `0x514560`, SM `0x44de70`, client `FUN_00987050`) |
| 1 | **Item Auto Share** (clear: Item Free-For-All) | `UIIT_STT_PARTY_ITEM_SHARE` / `_ITEM_SELF` | pickup round robin and gold split (below); `GObjPC::CheckCanPickUp`'s party test |
| 2 | **anyone may invite** | `UIIT_STT_PARTY_JOIN_ANYONE` "Invitation of party members is active!" | `CParty::CheckCanJoin` (`0x514560`), round 357 |

**The member cap depends on bit 0 alone**: 8 when EXP is shared, 4 when it is not, whatever bit 1
says. Three independent readers agree: GS `CParty::CheckCanJoin` (`cmp [party+0x1c],8` / `,4` on
bit 0, refusals `0x2c13`/`0x2c14`), SM `FUN_0044de70` (`(flags & 1) ? count == 8 : count == 4`),
and the client's own "party is full" test `FUN_00987050` (`expShare==0 && members==4 ||
expShare==1 && members==8`). READ, cross-binary.

So the four combinations:

| EXP | Item | cap | kill EXP/SP | drops and gold |
|---|---|---|---|---|
| Free-For-All | Free-For-All | 4 | each contributor by own damage, × (1 + 0.03 per member past the first) | picker keeps |
| Free-For-All | Auto Share | 4 | same | round robin / gold split |
| Auto Share | Free-For-All | 8 | split by level among members in range, × the 10%/20% bonus | picker keeps |
| Auto Share | Auto Share | 8 | same | round robin / gold split |

**Set once, at formation; never changed.** The type byte travels with the form-party invite (the
u8 after the u32 target in the create request, `party.md` round 269) and the SM creates the party
with it (`FUN_0044e9c0(..., flags, ...)` from `0x44ed70`). Nothing changes it afterwards (see
Corrections). READ (SM).

**A party is formed by an accepted invitation, with two members at once** (SM `0x44ed70` builds
it from inviter and invitee; GS `party.md` round 271). There is no party of one. READ.

---

## Forming, inviting, joining

### Who may invite

- Forming a party: the inviter must be in no party (SM `0x44ed70`: inviter in a party → `0x2c09`;
  invitee in a party → `0x2c18`) and at least **level 5** (GS `CParty::CheckCanCreate`, `0x2c0a`,
  READ earlier).
- Inviting into an existing party: the leader, or any member when bit 2 is set; the party must not
  be full (`0x2c13`/`0x2c14`). READ (GS `0x514560`).
- The target must be within **600.0** units, 3D (Corrections). `IsWithinInteractionRange` returns
  3 for a type mismatch (the `0x26` filter), the bare code **4** when out of range, 0 when the
  target is not found or in another world, and 1 in range; any result but 1 is sent back as the
  refusal code. READ (GS `0x4a8e10`, `0x4a8eb2`, `0x4a902f..0x4a903b`).
- `CParty::CheckTargetAvailable` (`0x514010`) on the target, in order: character lock → `0x2c06`;
  not alive and not dead (life state not 1/2) → 3; already in a party → `0x2c12` (the same party,
  `PARTYERR_EXISTING_MEMBER`) or `0x2c18` (another, `MEMBER_OF_ANOTHER_PARTY`); with a party-match
  registration (`pc[0x734]`) → `0x2c25`; pending-invitation byte 1 or 3 → `0x2c1f`; byte 4 →
  `0x2c25`; any other non-idle state → `0x2c06`; opposite battle-arena teams → `0x2c28`. READ (GS).
  A dead character can be invited (state 2 passes; round 413).
- **No level rule for joining**, other than a listing's level range (below). READ earlier
  (`party.go` `MinLevelToCreate`).

### The invitation's timeout: 30 seconds

The invitation is the generic confirmation request (`GObjPC::FUN_004ea0d0` builds message `0x3080`
with kind 2 = form a party, kind 3 = join this party; `0x5be280`/`0x5be2f0`). Its transaction
object's constructor (`0x46c7e0`) sets `+0x1c = 30.0` (`fld DWORD 0xb45b48` = `0000f041` = 30.0),
and the game server's transaction tick (`CMainProcess::FUN_0046f1e0`) adds the elapsed
GetTickCount milliseconds / 1000.0 (`0xb45c68` = 1000.0, double) to `+0x20` and fires the
transaction's OnTimeout once `+0x20` passes `+0x1c`. `trs_wait_response::OnTimeout` (`0x46ce20`)
for kinds 2 and 3 replies **`0x2c10` `UIIT_MSG_PARTYERR_TIMEOUT`** "The party invite automatically
cancelled due to no response from the other player." READ (GS).

### The job rule on forming and joining

`FUN_005bc1c0` (GS, applied when a join reaches the local copy) and its twin `FUN_0044ed20` (SM,
applied on form `0x44ed70`, join `0x44f130` and match-join `0x44f850`) compare two **job states**
and refuse **`0x2c23` `UIIT_MSG_PARTY_USER_MISSMATCH`** on a mismatch:

| one side | the other may be |
|---|---|
| 1 Trader | 1 Trader or 3 Hunter |
| 3 Hunter | 1 Trader or 3 Hunter |
| 2 Thief | 2 Thief only |
| 4 no job | 4 no job only |

READ (GS `0x5bc1c0`, SM `0x44ed20`, both `cmp cl,..` ladders read in asm). The operands are the
**job state** byte: in GS the new member's record `+0x45` against the head member's (`0x5bc243`),
and `+0x45` is written from vtable slot 71 `GetJobState` (`FUN_005bae80`); in SM the requester's
`+0x48` against the leader's record `+0x49` (`0x44fa9a`). Slot 71 returns `chardata+0xf`
(`CGObjPC::GetJobState`, `0x4ddc80`); the character record's initializer writes **4** there
(`0x4de3eb`, `mov BYTE [edi+0xf],4`), and SetCharacterState kind 10 changes it (`FUN_004e0b20`).
1/2/3 are Trader/Robber/Hunter (`jobs.md`). So 4 is "not in job mode": a player who has a job but
is not wearing the suit is a 4. READ (review of round 709): `0x4e124e` writes 4, then the item in
equipment slot 8 (`push 0x8; call 0x4b8000`) sets 1, 2 or 3 through item slots
`0x418`/`0x41c`/`0x420` (`0x4e128a`/`0x4e12a9`/`0x4e12c8`, each `call 0x4e0b20`). A state of 0
matches nobody, not even another 0 (`0x5bc1c0`'s table; `0x5bf240` asserts on it).

The client's two refusal texts name the same rule: `UIIT_MSG_PARTYMATCH_JOIN_ERROR_JOBTYPE`
"Parties cannot be formed between normal and job users." and `_JOIN_ERROR_HOSTILEJOB` "Parties
cannot be formed between job users in hostility." READ (client strings). The client code that
shows them was not found; the server sends `0x2c23` for both cases.

A member in job mode is carried in the party by his **job alias**: the member record's name is
`GetCharName` (slot `0xec`) when the job state is 4 and `GetNickName` (slot `0xf0`) otherwise
(`FUN_005bae80`), and a party chat line takes the nickname the same way (GS chat case 4). READ (GS).

---

## Kill EXP and SP

### The pipeline

`CGObjMob::vslot_399` (`0x4c44a0`), the monster's death distributor. READ (GS):

1. **Group the contributors.** For each damage entry (`+0x10` attacker id, `+0x14` damage): a COS
   (pet) counts for its owner (`pc[0x736]`). A PC in a party whose `flags & 1` is set is grouped
   **by party** with flag 1; every other PC (no party, or an exp free-for-all party) is its **own**
   group with flag 0. A group accumulates its damage (`+0x18`) and remembers its single biggest
   hitter (`+0x20`).
2. The group with the most damage, and its biggest hitter, is the **kill credit** (the function's
   return value, `mov eax,ebx`).
3. For each group:
   - flag 1 → `GObjPC::FUN_005bca60(party, victim, groupDamage, &count)` — the **party share**;
   - flag 0 → `FUN_004c4820(pc, victim, groupDamage)` — the **individual award**.

Both end in `CGObjPC::vslot_420(victim, damage, multiplier, flags)`, which computes

    EXP = Formula_ExpRewardForContributor(damage)    ; 0x410110, int64, floor 1
    SP  = Formulae::FUN_004106b0(damage)             ; int, floor 1
    EXP = ftol(float32(EXP) × multiplier);  SP = ftol(float32(SP) × multiplier)   ; 0x4ea7e8, 0x4ea82a, 0x4ea863-0x4ea88b
    r = ExpRatioParty if in any party (pc[0x72e]) else ExpRatio
    if r >= 1.01:  EXP += ftol(EXP × (r − 1));  SP += ftol(SP × (r − 1))         ; 0x4ea8a5-0x4ea8e3
    plus premium params
    then GainExpAndLevel(EXP, SP)                    ; vtable slot 92

READ (GS asm `0x4ea7a8`-`0x4ea8e7`). **Both EXP and SP take the same multiplier**, so every
sharing rule below applies to skill experience exactly as to experience.

Two details the round-709 review read (GS):
- **float32 rounding.** EXP and SP are stored to a single-precision float before the multiplier
  (`0x4ea7d9 fild QWORD`, `0x4ea7e8 fstp DWORD`; SP `0x4ea81d`-`0x4ea82e`): an EXP above 2^24 is
  rounded first. It matters for an exact match at high levels.
- **The rate bonus is additive, has a 1.01 floor, and pays SP too.** `fld DWORD 0xb46178` = 1.01
  (float), compared with the rate (`0xc8251c` ExpRatioParty, `0xc82518` ExpRatio); below 1.01 there
  is no bonus at all (`jne 0x4ea8fd`). Otherwise `EXP×(r−1)` and `SP×(r−1)` are added on top of the
  shared amounts. The rates themselves are this package's config (modded).

### The two formulas `vslot_420` calls

`Formula_ExpRewardForContributor` (`0x410110`), ESI = victim, EDI = receiver:

    EXP = slot332(victim) × slot359(victim) × share × Window(rcv, victim) × rcv[0x1cd8] × Diff(rcv, victim)
    share = clamp(damage / victim.MaxHP, 1e-6, 1.0)

`FUN_004106b0`, the kill's **skill experience**:

    SP = slot332(victim) × slot359(victim) × 100.0 / expUnit(rcv.level) × share × Window × rcv[0x1cdc] × Diff
    floor: a result below 1.0 becomes 1

READ (GS asm `0x410110`-`0x41036c`, `0x4106b0`-`0x410872`; `0xb45af0` = 100.0 double; `expUnit` is
the receiver's level row `+0x1c`, leveldata column 5, through `RefLevel_GetEntry` /
`FUN_00411130`). `Window` and `Diff` are `Formula_ExpScaleByLevelWindow`/`_ByLevelDiff`
(`leveldata`), evaluated **for the receiver**, so in a shared kill every member's level gap to the
monster is its own. `rcv[0x1cd8]`/`[0x1cdc]` are the receiver's mastery-lag scales (`leveldata`).

What `slot332` returns for a monster is **OPEN** here: `CGObjMob` slot 332 is `0x4a68b0`, a jump to
the reference object's vtable `+0x34`, not read this round. It is the monster's base EXP. OpenSRO's
`leveldata.KillExp` models a different function (`Formula_MonsterExpReward`, `0x4105d0`); which of
the two the live kill path's base agrees with is for the implementation round to settle by
reading `+0x34`. This does not change any party rule.

`slot359` is `CGObjMob::vslot_359` (`0x4c15c0`), the monster's EXP/SP multiplier (READ, asm):

| | multiplier |
|---|---|
| base | 1.0 |
| party monster (`GetMonsterType() == 1`, slot 192) | **7.5** (`fld DWORD 0xb45b9c` = `0000f040`) |
| then × by rank (`GetMonsterClass`, slot 75): 0, 3, 8 | × 1 |
| 1 champion | × 2 (`fadd st,st`) |
| 4 giant | × 15.0 (`0xb45e88`, double) |
| 5 | × 60.0 (`0xb45e80`) |
| 6 elite | × 4.0 (`0xb45cf0`) |
| 7 | × 30.0 (`0xb45e58`) |
| any other rank (2, 9+) | 1.0, the party factor dropped |

### Exp Free-For-All party, or no party: the individual award

`FUN_004c4820` (GS asm `0x4c4820`-`0x4c48c8`), for one PC:

    multiplier = 1.0
    if pc is in a party:  multiplier = 1.0 + (party.memberCount − 1) × 0.03     ; 0xb45dc8, 0xb45ac0 (doubles)
    if victim.IsMonster() and victim.IsPartySupportMonster() and victim.level < pc.level:
        multiplier ×= 0.5                                                         ; FUN_00410fd0, 0xb45b68 (float)
    vslot_420(victim, pcDamage, multiplier, 0xffffffff)

- `memberCount` is `party+0x1c`, **every** member (`GObjPC::FUN_004ea230`), wherever they are,
  alive or dead. READ.
- Only contributors are paid. A member who did no damage gets nothing from this kill. READ (only
  damage entries are walked).
- Each contributor's `share` is his **own** damage over MaxHP.
- A full 4/4 party pays each contributor ×1.09. READ.

### Exp Auto Share party: the party share

`GObjPC::FUN_005bca60` (GS asm `0x5bca60`-`0x5bcf2c`). READ, every constant a double unless noted:

**Who shares.** Each member is eligible when all hold:
- found on this game server (`FUN_00485dc0` by id);
- alive (`GetLifeState()` == 1, slot 62);
- in the same world (slot 5 `GetWorldID` equal);
- **within 1000.0 units** (`0xb45c68`) of the reference point, measured **horizontally**: the
  delta helper `FUN_00430ad0` zeroes y, adds 1920 per region step (`0xb45ad0`), and answers 1e38
  (`0xb45c44`, float) across the field/dungeon boundary.

The reference point is the kill credit (the biggest hitter of the most-damaging group) when there
is one, else the victim (ECX at the call, `0x4c4775`). It is always non-null when a share call is
made: groups are built only from entries with damage > 0 (`0x4c455b`), so a top group, and with it
a kill credit, exists (READ, review of round 709). Members who did no damage share; dead or
distant members do not.

**The kill credit can sit outside the sharing party** (READ, review of round 709). `vslot_399`
computes it once (`0x4c4708`-`0x4c4711`, `ebx = [topGroup+0x20]`) and passes the same `ecx,ebx` to
`0x5bca60` for **every** exp-share group (`0x4c4775`). When two parties, or a party and a solo
player, damage one monster, the second party's 1000-unit radius is measured from the **other**
group's top hitter; if that point is more than 1000 from all of its members, that party gets no EXP
or SP at all. The count pointer is also the same for every group (`[ebp+0x8]`, `0x4c4768`); each
share call overwrites it (`mov WORD PTR [esi],ax`, `0x5bcd3a`), so the count that reaches the nest
is the **last exp-share group iterated** in the group map's order (that order is OPEN).

**The bonus** (`[esp+0x20]`, `0x5bcd38`-`0x5bcd9c`), with c = eligible members of Country 0
(China) and e = of any other Country (ref object `+0x88`):

    if e > 0:                     bonus = 1 + (e − 1) × 0.2 + c × 0.1        ; 0xb45ee8, 0xb45ec0
    else if c > 0:                bonus = 1 + (c − 1) × 0.1
    else:                         bonus = 1

So a Chinese party gains 10% per extra member in range (8 in range: 1.7), a European one 20% (8 in
range: 2.4), and a mixed party counts its first European as the base. READ.

**The party-monster penalty** (`[esp+0x2c]`, `0x5bcda0`-`0x5bce06`): when the victim `IsMonster`
(slot 10) and `IsPartySupportMonster` (slot 193), `penalty = 0.5` if `victim.level <
avgLevel`, else 1, where `avgLevel = Σlevel / eligibleCount` by integer division. Ordinary monsters:
1. READ.

**The split** (`0x5bce20`-`0x5bcee4`), per eligible member i:

    s_i = level_i / Σlevel                                  ; float
    b_i = bonus
    if s_i > 0.7 and eligibleCount >= 3 and maxLevel >= 21:  ; 0xb46050, 0x15
        b_i = (bonus − 1) × 0.5 + 1                          ; 0xb45c50
    vslot_420(victim, partyDamage, s_i × b_i × penalty, 3)

- `partyDamage` is the whole group's damage, so each member's base share is the group's damage over
  MaxHP, clamped to 1.
- The **split is by level**, not equal.
- **A member who would take more than 70% of the kill keeps only half the bonus**: a high-level
  character in a party of three or more where the top level is at least 21. Only that member's
  bonus is damped; the bonus is recomputed per member.

**Worked examples** (Chinese party, every member in range, ordinary monster, every receiver at the
same gap to the monster, so base EXP B and base SP are equal for all):

| party | bonus | each member's EXP (and SP) |
|---|---|---|
| 2 × level 50 | 1.1 | 0.5 × 1.1 = **0.55 B** |
| 4 × level 50 | 1.3 | 0.25 × 1.3 = **0.325 B** |
| 8 × level 50 | 1.7 | 0.125 × 1.7 = **0.2125 B** |
| levels 80, 10, 10 | 1.2; the 80 has s = 0.8 > 0.7 → b = 1.1 | 80: 0.8 × 1.1 = 0.88 B; each 10: 0.1 × 1.2 = 0.12 B (then each receiver's own level-gap scaling) |
| 4 free-for-all members, each kills alone | 1.09 | each killer 1.09 B; the others 0 |

`count` (the 4th argument) receives the number of eligible members (`mov WORD [esi],ax`,
`0x5bcd3a`). It arms the nest for a party monster (below). READ. With several exp-share groups the
last one written wins (above).

### What applies to everyone in a party, either type

- `ExpRatioParty` replaces `ExpRatio` for anyone in a party (`pc[0x72e]`). READ (GS `0x4ea892`), as
  `internal/rates` already has. The bonus is additive, applies to SP as well, and only at a rate of
  1.01 or more (the pipeline above). OpenSRO's `rates.ExpFor` multiplies EXP alone by any rate
  `≠ 1` (`session/combat.go`), so it diverges on both points (gap 19).
- The level-gap party bonus in `Formula_ExpScaleByLevelDiff` (`+0.15/0.30/0.45`, Europe
  `+0.30/0.60/0.90`) needs **bit 0**, an exp-share party (`leveldata.ExpDiffScale`, round 480). So
  it applies only on the party-share path. READ earlier; consistent with the branch here.

---

## Items and gold

### Pickup rights (already modelled)

A party member may pick another member's reserved drop only when the party shares items (`flags &
2`) and the item is not owner-only (TypeID 3/3/9 except `ITEM_QNO_RM_ARCHEMY*`).
`docs/protocol/ground_items.md`, rounds 493-501. READ.

### Item Auto Share: round robin

**PC pickup** (GS `FUN_00525dc0`, asm `0x525f00`-`0x52608d`), for an item that is not specialty
goods. When the item is not of the owner-only TypeID 3/3/9 shape (or is `ITEM_QNO_RM_ARCHEMY*`) and
the picker's party has `flags & 2`, the recipient is chosen as follows (READ):

1. Up to `memberCount` times, take the next member from the party's **rotation list**
   (`GObjPC::FUN_004d4840`: front of the list at `party+0x20`, moved to the back, its id returned).
2. Accept the first who is found, alive (life state 1), in the picker's world, and within
   **1000.0** of the picker in **3D** (`FUN_00430ba0` keeps y; `fcomp QWORD 0xb45c68`).
3. If none qualifies, the recipient depends on **why the last member tried failed** (READ, review
   of round 709). The loop keeps the last candidate's pointer in `EBX` when he fails the alive test
   (`0x525fae`) or the world test (`0x525fd7`); only a distance failure clears it (`0x526055 xor
   ebx,ebx`). The picker gets the item only when `EBX` is 0 (`0x526069`). So if the last member
   tried failed on distance, the picker gets it; if he was dead or in another world, **he** gets it.
   To match the original exactly, keep the "last candidate" variable this way.

The picker is in the rotation like everyone else. Each skipped member also moves to the back. A new
member is appended to the back of the rotation when he joins (GS `FUN_005bc210`). A leaver is
removed (`FUN_005bc390`).

**Pet pickup** (GS `GObjPC::FUN_004d5510`, from `FUN_004d4f60`, a pet picking for its owner): the
same rotation and tests, measured from the pet, with the same fallback shape (alive `0x4d560e` and
world `0x4d563a` failures keep the candidate; only the distance failure clears it, `0x4d56b6`). It applies only to an item that `CanTrade`
(slot 49) and `CanDrop` (slot 52). When the chosen member's inventory has no free slot, the item
goes to that member's own pet if he has one, else the pickup fails with `0x1807`. READ (GS).

**Inventory full** (GS `FUN_00526090` `0x52633d`-`0x5263a8`): when the chosen recipient is not the
picker and the add fails with `0x1807`, the recipient is told `0x1807` (op result `0xb034`) and the
picker gets **`0x18da` `UIIT_MSG_STRGERR_PARTY_INVENTORY_FULL`** "Inventory slot of the target to
be distributed to is full, thus item distribution has failed." The item stays on the ground
(INFERRED: no add happened). READ.

**The notice**: `FUN_005bdc80` broadcasts **`0x3068`** to the party's local members (receiver id,
item ref id, and plus/stack), only when `flags & 2`. The client text is `UIIT_MSG_PARTYGET_ITEM_
EXPENDABLE` "Item [%s %d pieces]is distributed to [%s]." READ (GS); the layout is party709a's.

### Gold

`GObjPC::FUN_004eaca0` (gold pickup) calls `GObjPC::FUN_005bc7f0` when the picker's party has
`flags & 2`. Otherwise the picker gets it all (reason `0x19`). READ (GS).

`FUN_005bc7f0`'s split:
- **Eligible:** the picker always, plus every member found on this server, in the picker's world,
  and within **1000.0** in **3D** of the pick position (`GObjPC::FUN_005bdb30`, `fcomp QWORD
  0xb45c68`). Being alive is not tested. READ.
- **Split:** `each = amount / n` and `rest = amount % n`. The picker gets `each + rest`, every
  other eligible member `each`, all with reason `0x17`. When `each` is 0 (fewer coins than
  members), the picker takes the whole amount. READ.
- The client text is `UIIT_MSG_PARTYGET_GOLD` "[%d]gold is distributed to [%s]." (the notice
  message is party709a's).
- A pickup of **more than 1000 gold** (1001 or more: `cmp edi,0x3e8; jbe`, `0x4ead1f`) also fires
  the picker's own vtable `0x274(0x80, 0)`.
  What that does is OPEN, likely a client effect.

---

## Party monsters

**When one spawns.** READ (round 660, re-checked this round):

1. The trigger is a kill of a monster from a nest **by an exp-share party** whose party share
   counted **2 or more eligible members**. These are the members alive, in the world, and within
   1000 (horizontal, 1920-unit region steps, inclusive) of the **kill credit**; they do not need to
   have dealt damage. The count comes from `FUN_005bca60` (above); with several exp-share groups
   the last one written wins. CAIState slot 7 (`FUN_00558f20`) arms the nest (`nest+0x30 = 1`) when
   the count is `> 1` (`cmp DWORD [esp+8],2 ; jb`).
   - **An exp free-for-all kill never arms.** READ (review of round 709): the mob death function
     `0x529de0` zeroes the count (`0x529e0a mov DWORD PTR [esp+0xc],0x0`) before the distributor
     runs (slot 311 → `0x4c42f0` → `vslot_399`), then passes `movzx edx,WORD PTR [esp+0x8]` to the
     AI's slot 7 (`0x529e2a`-`0x529e3f`); `0x52d010` does the same. Only the share path writes it.
2. The armed nest's next hatch rolls `rand() % 101 < 50` (50 in 101) for the party flag, for a
   species of rarity **0, 2 or 9 and above** (rarities 5, 3, 8, 6, 7, 4 and 1 copy straight to the
   class, `0x56086e`-`0x5608c6`; review of round 709). The species must not be of the TID shape
   `(w & 0xf800) == 0x2000`. A party hatch disarms the nest. `nest.RollClass`, `Nest_Hatch`
   `0x5607b0`.
3. Level clamp (`nest.ClampClassByLevel`, `0x5eb9a0`, switch on `level/10`, jump table `0x5ebf14`;
   READ exactly by the review). Before the switch, a giant of level 10 or below becomes a champion
   (`0x5eb9f9`-`0x5eba14`). Then the party flag is kept for:

   | level | party flag kept for |
   |---|---|
   | 0-9 | never |
   | 10-19 | rank 0 only |
   | 20-29 | ranks 0 and 1 |
   | 30-39 | ranks 0, 1, 4 (giant) and 6 |
   | 40 and up | always |
4. **The per-world `PARTYMONSTER_SPAWN` gate** (READ GS, review of round 709).
   `CDataDrivenGameWorld::vslot_055` reads the world's `PARTYMONSTER_SPAWN` config value (`0x6086eb
   mov ecx,0xb014bc`) and sets `world+0x58 = 1` only when it compares equal to "ON" (`0xb012f4`,
   `CompareStringA` at `0x60872e`, `0x608739`). A world virtual at `0x609900` (in the vtables at
   `0xb01cf4`/`0xb01de4`/`0xb78fd8`) strips the party nibble from a spawn's class byte when
   `world+0x58` is 0 (`and al,0xf0; cmp al,0x10` → party nibble 0, rank kept). This package's
   `world_config_keys.csv` (EXTERNAL, possibly modded) has 30 `PARTYMONSTER_SPAWN` rows: `ON` only
   for `GROUP_JUPITER_A3`, `_B3` and `_FIELD`; `OFF` for the Pharaoh tombs, Togui, God Flame, Wreck
   and Arabia groups. So in a data-driven (instance) world a party monster survives only when that
   world's key is `ON`. **Whether the main field world has an equivalent gate is OPEN** (next probe:
   the base `CGameWorld` slot at the same vtable index).

So it is not "after 4 or 5 members": two members alive and in range in an exp-share party are
enough, and then it is a coin toss per hatch from that nest (in an instance world, only where the
world allows party monsters).

**What it is.** The class byte's high nibble is 1 (`IsPartySupportMonster` = `(byte & 0xf0) ==
0x10`); the client draws the blue emblem from the same bit (round 660, `CICMonster::vslot_025`,
`combat.MonsterRarityPartyBit`). Its multipliers, all READ (GS):

| | factor | evidence |
|---|---|---|
| HP | ×10 (base 1000% instead of 100%, before the rank multiplier) | `CGObjMob::PublishStats` (`0x4c19f0`), round "x10 HP mode" |
| EXP and SP | ×7.5, before the rank multiplier | `CGObjMob::vslot_359` above |
| its attack value | ×1.2 (elite rank 6 ×1.5 on top), on the attacker's min/max attack stat **before defence** | `FUN_0040da20`: `fld DWORD 0xb45d90` = 1.2; `fmul QWORD 0xb45d78` = 1.5; it scales the value `Combat_ComputeWeaponDamage` (`0x40db50`) and `FUN_0040dc10` build from the attacker's own stat (vtable `0x104`, param `0xd`/`0xf` + (edi≠0)) plus an item bonus, and the result is clamped against `0xb45f20` afterwards (`0x40dbe2`). Final damage is ×1.2 only if the rest of the pipeline is linear in that value, which was not shown (review of round 709) |
| kill reward when the killers out-level it | ×0.5 | party share: victim level < the eligible members' average level; individual award: victim level < the receiver's level (`FUN_00410fd0`) |
| berserk orbs | the kill's orb amount goes to **every** member alive in the killer's world | `Party_ShareHwanCount` (`0x5bcf30`), only when the killer's party shares EXP (round 202's hwan entry) |

Drops: no party-monster factor was found on the drop path this round. That search was not
exhaustive; drops for party monsters are OPEN.

**Why OpenSRO's nest scheduler logs `party=0`.** ~~`ArmParty` has no caller.~~ **Wrong, corrected
by the review of round 709**: this page's first draft grepped only `internal/session`. Arming is
wired through an observer `cmd/server` installs (round 660): `cmd/server/main.go`
`session.SetMonsterKillObserver(respawns.armParty)` (only with `-full-map`), `cmd/server/nest.go`
`armParty` → `s.sched.ArmParty`, called from `session/combat.go` and `status.go` through
`noteMonsterKilled`, which counts with `nestkill.go` `partyMembersNear`. The `party=0` in the log is
the scheduler summary's count of party monsters **hatched so far** (`nest.go`), 0 because no
qualifying party kill has happened. The nest rows need no party column: the roll keys on the nest's
armed state (and, in instance worlds, the `PARTYMONSTER_SPAWN` gate), not on a table value.

What OpenSRO's arming does differently from the original (READ against the code):
- **Party type:** it arms for any party of two or more (`inPartyWithOthers`); the original arms
  only from the exp-share path.
- **Reference point:** it measures from the dead monster, on the ground plane, in the same zone;
  the original measures from the kill credit, in the same world, horizontally with 1920-unit region
  steps, inclusive at 1000.
- **Whose count:** it counts the killer's party; the original takes the count the exp-share groups
  that damaged the monster wrote, the last one iterated winning.
- **World gate:** it has no `PARTYMONSTER_SPAWN` gate.
- Its comments (`nestkill.go`, `monster_ai.md`) recorded "measured from the dead monster" as
  INFERRED; the reference is READ as the kill credit (`0x5bcacb`-`0x5bcb29`, ECX = the kill credit).

---

## Other shared behaviour

### Party chat: party members only, the sender included

The client refuses a party line without a party (`chat.md`). The game server refuses `0x200a`
`UIIT_CHATERR_NOT_A_PARTY_MEMBER` when `pc[0x72e]` is null. Otherwise it posts relay kind 7 with
the sender's id, name and text (`GObjPC::FUN_005bb8c0`). The name is the job alias when the job
state is not 4.

The ShardManager forwards it to every game server holding a member (`FUN_0044e840`). Each server
builds a chat update **`0x3026` type 4** and sends it with `CParty::BroadcastToLocalMember(msg, 0)`
(`CMainProcess::FUN_005bef50`). An exclusion id of 0 excludes no one, so **the sender receives his
own line too**, and nobody outside the party receives it. READ (GS, SM).

### The member updates: what triggers them, and how often

`CGObjPC::vslot_323(changeBits)` is called by the game when a tracked value changes. It calls
`CGObjPC::FUN_005bc730`, which asks `FUN_005bb0c0` which fields changed. If any did, it relays kind
6 with the out-mask and fields, and the ShardManager broadcasts it to the members
(`FUN_0044e460`). READ (GS, SM):

| change bit (caller) | out-mask | field | sent when |
|---|---|---|---|
| `0x8` (`GObjPC_SetLevel`, `0x4e5238`; `FUN_004d6210`) | `0x02` | level | always on the call |
| `0x2` (`GObjPC::FUN_004a8510`) | `0x04` | HP and MP, each quantised to a nibble | **only when a quantised value changes**: HP step = `0` when HP is 0, else `1 − ftol(HP/MaxHP × −10.0)` (`0xb45f78` = −10.0), i.e. 1..11; MP step = `ftol(MP/MaxMP × 10.0)` (`0xb45c60`), 0..10 |
| `0x1` (`GObjPC::FUN_004a9410`, `GObjPC::FUN_004df6b0`) | `0x20` | region, x, y, z (rounded to integers), world id | always on the call |
| `0x10` (`FUN_004ea290`) | `0x40` | the guild name (vtable `0x178`, slot 94 = `0x4ea640` `CGObjPC::GetGuildName`) | always on the call |
| `0x20` (`Skill_HandleMasteryLevelUp`, `GObjPC_HandleSkillMsg_203`) | `0x08` | the two masteries shown (`GObjPC::FUN_005a1890` → `+0x5c`, `+0x60`) | always on the call |
| `0x40` (`GObjPC::UpdateCharRefObjIDAndScale`) | `0x01` | name and ref object id | always on the call |

- **HP/MP updates are throttled by tenths.** A member's HP bar moves in steps of 10% of MaxHP.
  READ.
- **No distance limit on updates.** Every member gets every update. The fade-with-distance the user
  describes is client-side; that is party709c's.
- **Position cadence is OPEN.** How often the position hook fires
  (`FUN_004a9410` writes `pc+0x12c` and calls bit 1) was not established this round.
- The `+0x24` string is the **guild name**: CGObjPC's vtable (`0xaf59fc`) slot 94 holds `0x4ea640`,
  whose recovered name is `CGObjPC::GetGuildName` (read from the exe by the round-709 fix-up pass),
  and the client stores the field where its party window draws the guild (`party_protocol.md`).

### Leaving, expulsion, logout, leader succession, dismissal

READ (SM `0x44f580`, `0x44e1a0`, `0x44eb30`, `0x4296f0`; GS `0x5144e0`, `0x5be1a0`, `0x4def90`):

- **Leaving** sends the leave request with reason 2 to the party server. **Expulsion** is
  leader-only (`0x063`, round 357), reason 4. **Logging out or disconnecting** removes the member
  on the party server's own user cleanup (`0x4296f0`, reason 1). The game server's local removal
  for a world exit uses reasons 1/3 and does not post (GS `0x4def90`).
- In every case the SM's `FUN_0044f580`:
  - **if the party has exactly 2 members → the party is dismissed** (`0x44eb30`: notice 1 with
    `0x2c0b`, the leader's listing deleted, the party freed);
  - otherwise it sends notice 3 (member id, reason) and removes the member.
- **Leader succession.** The new leader is the **first member of the member vector** (`party+4 =
  members[0].id`, `0x44e1a0`). The vector keeps join order, so the longest-standing member takes
  over. The game server's copy does the same with its list head and announces notice 9 with the
  new leader's id (`FUN_005bc390`). The client text is `UIIT_MSG_PARTY_HOST_ROLE_DELEGATED`.
- **A departing leader's listing moves to the new leader** (`0x44e1a0`: listing `+0x2c` and the
  new leader's `+0x24c`, notice 0x12).
- The client texts for the reasons are `UIIT_MSG_PARTY_LOGOUT` "[%s] has been disconnected.",
  `UIIT_MSG_PARTY_SECEDE` "[%s] has left the party.", `UIIT_MSG_PARTY_BOOTED` "[%s] is banned
  from the party." and `UIIT_MSG_PARTY_BROKEN` "The party is dismissed.". The mapping 1→LOGOUT,
  2→SECEDE, 3→server migration (silent, debug line only), 4→BOOTED is READ in the client's notice-3
  jump table (`c:0x8872e8`, indexed by reason − 1; `party_protocol.md`).
- **Teleport and zone change** do not touch the party: the party removal is called only from
  leave, expel and world exit (the three callers of `0x5144e0`/`0x5be1a0`, census of `srgs.asm`).
  READ. A member on another game server is simply not found locally, so he does not share kills or
  items there (above).

### The aggro link

A party member's hit pulls neighbouring monsters in only in an exp-share party. READ earlier
(`monster_ai.md`, round 269).

---

## Party matching

### The listing record

The client's form-party / edit dialog (`UI_PARTYMATCH::FUN_0073f370`, serializer
`UI_PARTYMATCH::FUN_00823c20`, senders `SendOnRegisterPartyReq` `0x7069` / `SendPartyMatch_HandleModify`
`0x706a`) writes, READ (client):

| field | source in the dialog |
|---|---|
| u32 listing number | `param_1[0x1f0]` (0 when forming) |
| u32 party id | 0 (the server fills it) |
| u8 flags | the three party-setting checkboxes: bit 0 EXP share, bit 1 item share, bit 2 anyone may invite |
| u8 **purpose** | the purpose combo (control `0x28`) |
| u8 min level, u8 max level | controls `0x2a`, `0x2b` |
| string title | control `0x31` |

The client refuses locally `min < 1` or `max < min` (`UIIT_MSG_PARTYMATCH_RECORD_ERROR_LEVEL` "Level
submission incorrect.") and an empty title (`_RECORD_ERROR_TITLE`). READ (client `0x73f370`).
The Form-party button itself (`FUN_007397b0`) refuses a party-less character below level 5 with
`UIIT_MSG_PARTYMATCH_JOIN_ERROR_LEVEL` before opening the dialog -- the client's copy of the
creator-level rule. READ (client).

**The purpose enum**, READ (client `FUN_00740910` labels, `UI_PARTYMATCH::FUN_0073f610` default
titles):

| value | label key | default title key (English) |
|---|---|---|
| 0 | `UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTCOMBAT` (shown as "Hunting") | `UIIT_MSG_PARTYMATCH_RECORD_DEFAULT1` "For open hunting on SRO!" |
| 1 | `UIIT_STT_QUEST` | `..._DEFAULT3` "When will the quests end on the Silkroad?" |
| 2 | `UIIT_CTL_PARTYMATCH_PSEARCH_FIND_OBJECTTRADER` (trade) | `..._DEFAULT2` "Until the day SRO is all covered with money!" |
| 3 | `UIIT_CTL_PARTYMATCH_PSEARCH_FIND_OBJECTTHIEF` (thief) | `..._DEFAULT4` "No need for blood or tears for thieves! Robbery is the only way to go!" |

The search box adds `UIIT_CTL_PARTYMATCH_PSEARCH_OBJECTALL` ("All") as combo index 4; it is a
search-only value and is never sent (`c:0x73b12e push 4`). READ (client).

**The purpose is tied to the job** (GS `Party_UserMatches` `0x5bf240` and SM `FUN_0044f7f0`,
identical). The registrant's job state must fit the purpose, else **`0x2c23`**:

| job state | allowed purposes |
|---|---|
| 1 Trader, 3 Hunter | 2 (trade) only |
| 2 Thief | 3 (thief) only |
| 4 no job | 0 or 1, never 2 or 3 |

READ (GS: AL = `GetJobState`, CL = the record's `+9`, `0x5bf34e`-`0x5bf35b`; SM `0x44fab7`). Applied
on register and modify (GS kinds 0xa/0xb) and on the match join request (SM, requester against the
listing's purpose).

**There is no hunter purpose and no hunter icon in matching.** A hunter lists, and is listed, under
purpose 2 together with traders. The listing's "Type" column is the party type, the "Race" column
the leader's race byte (`user+0x250`), and the "Purpose" column the purpose (`FUN_0044f640` writes
them). READ (SM). The user's screenshot (from another client, "Esro Online") shows the 1/4 rows
(3929, 3959) with a different Type icon from the x/8 rows; this exe draws `pt_eachone.ddj` /
`pt_association.ddj` for Type and **text** for Race and Purpose (`party_gui.md` §3). The red flag
and race shields in the screenshots are that other client's, not this exe's. **USER DECISION
(2026-10-03): Race and Purpose are drawn as text, as this exe does.**

### Registering, modifying, deleting

All READ (SM).

- **Register** (kind 10, `FUN_00450680`):
  - user not found → `0x2c0f`; already has a listing (`user+0x24c`) → **`0x2c1b`**
    `RECORD_ERROR_AGAIN`;
  - when in a party, the record's flags byte must equal the party's → `0x2c20` (no client text
    found);
  - in a party: only the leader → `0x2c1d`; the party must not be full → **`0x2c08`**
    `PARTYERR_ALREADY_FULL`; the listing **takes the party's flags** (`FUN_00451110`);
  - not in a party: the listing carries the record's flags and becomes the party's type when
    someone joins (`FUN_00451290`; accepted join `0x44fbe0` → `FUN_0044e9c0(..., listing flags,
    ...)`);
  - the game server also requires creator level 5 when not in a party, refuses `0x2c26`
    (`JOBITEM_WEAR_ERR_PARTYMATCH`) when `chardata+0x13` is non-zero (`0x514196`; what that byte
    holds is OPEN, and it is **not** the worn job suit, which sets `+0xf`: if it were, no trade or
    thief listing could be registered), and refuses a non-leader re-listing (`0x2c1d`).
- **Listing number** (the "No." column): a manager counter, `++counter`, skipping 0
  (`FUN_0044def0` / `FUN_00451290`: `+0x8c`). Numbers only grow for the life of the server and are
  not reused. The listings live in a map keyed by number, so lists come out **in ascending
  number**. READ (SM). The screenshots agree: 4, 778, 906, 1362 … ascending.
- **Modify** (kind 11, `FUN_00450990` → `FUN_004513c0`): needs a listing (`0x2c1c`), leader only
  (`0x2c1d`). The flags must be unchanged (returns 5). Purpose, levels and title are replaced, and
  the timestamp is renewed. Client text `UIIT_MSG_PARTYMATCH_MODIFY_COMPLETE`.
- **Delete** (kind 12, `FUN_00450ba0` → `FUN_00451490`): needs the listing (`0x2c1c`), leader only
  (`0x2c1d`), and the party must match (`0x2c0d`).
- **A listing disappears**:
  - when its party is dismissed (`0x44eb30`);
  - when its party-less owner logs out (`0x4296f0` → `FUN_00451590`);
  - when its owner deletes it;
  - when the page builder finds the owner gone, or a trade/thief listing whose leader has left job
    mode (`FUN_0044f640` returns 0; INFERRED for the job-mode reading of `user+0x268` / member
    `+0x20`);
  - **when the party fills up, the leader's own client deletes it.** `UI_PARTY::FUN_007387c0`
    sends the delete (`0x706b`) when the local player is the leader, a listing exists and
    `FUN_00987050` says full. The reply then shows `UIIT_MSG_PARTYMATCH_DELETE_COMPLETE2` "The
    party will be removed from the party matching because it cannot accommodate any more party
    members." READ (client). The server does not do this itself.

### The list and its pages

All READ (SM).

- **The page builder** (`FUN_00451630`) walks the listings in number order. It writes each valid
  entry and closes a page at **23 entries** (`cmp al,0x17`, `0x4517ed`). The pages are kept
  prebuilt, at most 0xfe of them, and rebuilt after every change (register, modify, delete, join,
  leave).
- **A list request** (kind 13, `FUN_00450d20`) carries a u8 page number. A page past the end
  becomes page 0. The reply carries the page count, the page index and the entry count.
- **The requester's own listing is added to every page** (count + 1, `FUN_0044f640` on the
  requester's own listing). The user's screenshot shows it: row 3480 "Tobi" in blue at the top of
  page 1, out of number order.
- **A row** carries the listing number, the leader's (or job alias's) name, the member count (1
  without a party), the leader's race, the flags, the purpose, the level range and the title.
- **Name, purpose and level search** are not in the server's list request: the server sends whole
  pages, and only a page number. The search is a client-side filter over the records held, READ
  (`party_gui.md` §3, `c:0x73bb80` → `0x73b780`): an exact whole-name match, the purpose unless
  All, and the level ranges overlapping; nothing left gives `UIIT_MSG_PARTYMATCH_PSEARCH_NORESULT`.

### The join request

**Requester side** (SM `FUN_0044f850`, opcode `0x706d`), READ in this order:

| # | check | refusal |
|---|---|---|
| 1 | requester already in a party | `0x2c18` |
| 2 | requester has a listing of his own | `0x2c25` |
| 3 | the listing no longer exists | `0x2c1c` |
| 4 | the listing's party is full | `0x2c13` / `0x2c14` by its bit 0 |
| 5 | the requester's job state does not fit the party leader's (job table) | `0x2c23` |
| 6 | the requester's job state does not fit the listing's purpose (purpose table) | `0x2c23` |
| 7 | **requester level outside [min, max]**, inclusive | **`0x2c1e` `UIIT_MSG_PARTYMATCH_JOIN_ERROR_LEVEL`** "Not the required level for the party." |
| 8 | another join request to this listing is pending (`listing+0x34`) | `0x2c1f` "In the process of joining a party." |
| 9 | the leader is not found | `0x2c0e` |

Check 5 is made only when the listing has a party (after a leader lookup that refuses `0x2c1c`). The level is the requester's (`+0x8c`), the
range the listing's (`+0xa`, `+0xb`).

On passing all nine, the listing is marked pending and the request goes to the leader with a
**timeout of 15.0 seconds**:
- `fld DWORD 0x79b018` = `00007041` = 15.0 is passed to the transaction initializer `0x4206f0`,
  which stores it at `+0x2c`;
- the SM's transaction tick `FUN_00421de0` adds GetTickCount ms / 1000.0 (`0x79ada8` = 1000.0) to
  `+0x30` and fires OnTimeout past `+0x2c`. READ (SM).
- **But the client decides first** (review of round 709; READ client, `party_gui.md` §4-5). The
  leader's popup sends answer code **2** after **10 s** (timer `0x2710` ms set at `c:0x7406de`;
  handler `c:0x73fb70`), and the requester's progress bar fills and closes at 10 s (`c:0x7322e0`,
  the double 10000.0 at `c:0xdb3720`; display only). So the visible behaviour is **10 s, ended by
  the leader's client sending reply 2**; the ShardManager's 15 s is the fallback when the leader's
  client sends nothing.

**The automatic refusals** the user describes at the bottom right are these codes, coming back as
the request's failure. A server refusal reaches the client as `0xb06d [2][code]` and is drawn in the
bottom-right system message window (`c:0x778190` takes child `0x44`, `GDR_SYSTEM_MESSAGE_VIEW`;
READ, review of round 709); the client's local checks use `0x7781b0(4, text)`, the same window.

**The answer** (SM `FUN_0044fbe0`, a u8):
- **accept**:
  - a party-less listing forms a party from the leader and the requester with the listing's flags
    (the listing then points at the new party);
  - a party listing adds the requester through the join path, with its own `0x2c12`/`0x2c13`/
    `0x2c14` refusals.
- **deny** or **timeout**: the requester gets the result, and the pending mark is cleared.

The client maps the reply's u16 (`FUN_008847d0`, READ client):

| value | text |
|---|---|
| 1 | `UIIT_MSG_PARTYMATCH_JOIN_COMPLETE_MASTER` |
| 0 | `UIIT_MSG_PARTYERR_CREATE_PARTY_REFUSED` "The request for the party denied." |
| 2 | `UIIT_MSG_PARTYMATCH_JOIN_NOREPLY` "No reply given in appropriate time. Party admission is cancelled." |

So **2 is the timeout**. The exact SM-to-client path is party709a's.

### Auto match

**Auto match is client-driven** (READ client `FUN_008847d0`). After a refusal (0) or a timeout (2),
while auto matching is on (`DAT_0110f80c+0x64c`), the client tries the next candidate
(`FUN_00786e70`). It says `UIIT_MSG_PARTYMATCH_AUTO_PROGRESS` while candidates remain and
`_AUTO_FAILURE` when none is left. Candidates are chosen client-side from the held records, READ
(`party_gui.md` §3, `c:0x73ebc0`): the purpose, the race unless Open, the type flags, the player's
level inside the range; up to 10 queued.

---

## The user's assertions

| The user said | Verdict |
|---|---|
| Invite works on the selected player model | the server half: a PC target within **600** units (Corrections), not in a party, alive or dead, not mid-transaction. READ. The selection is party709c's. |
| "You set the party type you want by clicking Set" | the type is chosen before forming and sent with the form-party invite (or with a listing); it **cannot change** once the party exists. READ. |
| Party match: select purpose, level and name, or cycle pages | pages of 23 in listing-number order; the server sends whole pages, and the purpose/level/name search is a client-side filter over the page held (READ, `party_gui.md` §3). |
| A gold border on the selected listing | confirmed: `com_bar01select_` (a (255,178,82) line), READ/MEASURED in `party_gui.md` §3. |
| Refused automatically for level or job, the reason at the bottom right | **confirmed**: `0x2c1e` (outside the listing's level range, inclusive) and `0x2c23` (job against leader or purpose), plus the other ladder codes. READ. |
| A progress bar for "the duration it tries" | **10 seconds**: the bar fills over 10 s (display only), and the leader's client answers "no reply" (code 2) at 10 s if the leader does nothing. The server's 15 s is a backstop. READ (client and SM). |
| The leader gets a box with the requester's info and accepts or denies | confirmed (SM `0x44fbe0` answers accept/deny; timeout = deny with reply 2). The box's fields are party709c's. |
| Two or three job types: thieves, and traders (with hunters) | **confirmed, and stricter.** Traders and hunters may party together; thieves only with thieves; and a **non-job player cannot party with any job player** in job mode (`0x2c23`, "Parties cannot be formed between normal and job users."). READ. |
| "I don't think there's a blue icon for hunter in the party matching" | **confirmed**: there is no hunter purpose. Hunters use the trade purpose (2). READ. |
| Thieves have a purple icon and only thieves can join | thieves list under purpose 3 and only job state 2 may join it. READ. The colour is party709c's. |
| Party types share EXP or items, or both | confirmed: two independent bits, plus "anyone may invite". READ. |
| "If you have all sharing turned off it turns into a 1/4 player party" | **corrected**: the 4-cap follows the **EXP** setting alone. EXP Free-For-All (with or without item sharing) holds 4; EXP Auto Share holds 8. READ, three binaries. |
| 1-4: a small bonus per additional player, 4/4 the max (EXP and skill EXP) | **confirmed**: each contributor's own kill × (1 + 0.03 per member past the first); a full 4 gives ×1.09; both EXP and SP. READ. Members who did not hit get nothing. |
| 1-8: you split the experience (and skill) but get a big bonus per additional player | **confirmed and specified**: split **by level** among members alive and within 1000 units, × (1 + 0.1 per extra Chinese member, 0.2 per extra European); a member taking more than 70% keeps half the bonus. READ. |
| "After 4 or 5 you start getting party mobs" | **corrected**: two eligible members of an exp-share party arm the monster's nest; the next normal hatch there is a party monster 50 times in 101; none below level 10 (and the level clamp above); in an instance world only where `PARTYMONSTER_SPAWN` is ON. READ. |
| Party mobs have a blue emblem, are harder to kill and give more experience | **confirmed**: HP ×10, attack value ×1.2 before defence, EXP and SP ×7.5 (×0.5 if the party out-levels it on average). READ. |
| Sharing is within a certain radius | **1000 units**: EXP/SP horizontal from the kill credit; items and gold 3D from the picker. Berserk orbs go to the whole party in the same world. READ. |
| The leader's red flag; far members show blue and their buffs are hidden; select glow; mastery icons; HP/MP | client (party709c). The server side: members get updates whatever the distance; HP/MP in tenths; the two masteries are in the member record. READ. |
| Party chat only to the party | confirmed; the original also echoes the line to the sender. READ. |

---

## Gap list: OpenSRO today against the rules

| # | OpenSRO now | The rule | Where |
|---|---|---|---|
| 1 | Own opcodes `0x0080`-`0x0089`; a create path that makes a party of one | parties are formed by an accepted invite with two members; retail opcodes | `session/party.go`, `party/party.go` (party709a for the opcodes) |
| 2 | No party flags; `MaxSize = 8` for every party | flags byte chosen at formation; cap 8/4 by bit 0; anyone-invite bit 2 | `party/party.go` |
| 3 | `applyPartyExpBonus` gives every party 3% per member, killer only | 3% only in exp free-for-all parties, per contributor by own damage; exp-share parties split by level × the 10%/20% bonus to all eligible members within 1000; the 70% damping; the party-monster halving | `session/combat.go`, `leveldata` |
| 4 | `killExpFor`'s gap bonus for any party of two or more | only for exp-share parties (bit 0) | `session/combat.go` |
| 5 | Kill SP = the kill's EXP (a disclosed stand-in) | the kill's skill experience is `FUN_004106b0`'s formula, scaled by the same party multiplier | `session/combat.go` (needs `slot332` read, see OPEN) |
| 6 | No damage-share: the killer gets the whole unit | `share = groupDamage / MaxHP` clamped to [1e-6, 1]; every contributor (or group) is paid | `session/combat.go` |
| 7 | Leader leaving → next member (index 0 after removal) | correct by luck (the SM also takes index 0); but a party of two must be **dismissed** when one leaves, and a lone member must not remain | `party/party.go` `leaveLocked` |
| 8 | Party chat skips the sender | the original echoes it to the sender | `session/chat.go` (party709a to confirm the client does not echo locally) |
| 9 | No invite flow, no 30 s timeout, no range or state checks | invite ladder; 600 units; 30 s → `0x2c10` | new |
| 10 | No job rule | the job tables on form/join/match (`0x2c23`); purpose ↔ job | `party`, `jobs` |
| 11 | Item pickup: party members may pick each other's drops only with item share (modelled); no distribution | round robin by the rotation list within 1000 (3D); full inventory `0x18da`; gold split among members within 1000; the `0x3068` notice | `grounditem`, `session/grounditem.go` |
| 12 | Arming is wired (round 660, `nestkill.go` → `cmd/server/nest.go`, `-full-map` only) but arms for any party of two or more, counts the killer's party from the dead monster in its zone, and has no world gate. (This row's first draft said "no caller"; wrong, review of round 709) | arm only from the exp-share path, with the count the share wrote (members within 1000 of the kill credit, same world, horizontal; last exp-share group wins); `PARTYMONSTER_SPAWN` gate in instance worlds | `session/nestkill.go`, `session/combat.go` |
| 13 | No party-monster damage factor | ×1.2 on its damage | `combat` |
| 14 | No monster EXP multiplier at all (`ScaleHPForMonster` has the HP ×10 and the rank HP percentages; MEASURED: nothing in `combat`/`leveldata` scales EXP by rank) | `CGObjMob::vslot_359`: party ×7.5, then rank ×2/15/60/4/30 (ranks 1/4/5/6/7), on EXP and SP | `combat`, `leveldata` |
| 15 | Berserk party share not wired | orbs to every member alive in the killer's world, exp-share parties, party-monster kills | `berserk`, `session/combat.go` |
| 16 | No member updates | event-driven updates: level, HP/MP in tenths, position, masteries, name/model | new |
| 17 | No party matching | listings, counter numbers, 23-entry pages, own listing on every page, join request ladder, 15 s timeout, accept/deny, the purpose/job rule, the leader's client deletes a full listing | new |
| 18 | Logout removes the member (`LeaveBySession`) | correct, with the party-of-two dismissal, and the leaver's listing moving to the new leader / being deleted | `party/party.go` |
| 19 | `rates.ExpFor` multiplies EXP alone by any rate `≠ 1` | an additive `EXP×(r−1)` **and** `SP×(r−1)`, only when `r ≥ 1.01`; EXP and SP through float32 before the multiplier | `session/combat.go`, `rates` |
| 20 | Item round robin not built | when no member qualifies, the last candidate keeps the item unless he failed on distance (the loop's `EBX` rule) | `session/grounditem.go` |

---

## OPEN, and what blocks implementation

Closed by the round-709 review and fix-up: the free-for-all out-count (READ 0, never arms), the
reason → text mapping (READ, client), the member record's `+0x24` string (the guild name), the
client-side join durations (10 s), and the client search and auto match (READ in `party_gui.md`).

| Item | Blocks | Next probe |
|---|---|---|
| What `CGObjMob` slot 332 (`0x4a68b0` → ref object vtable `+0x34`) returns | the absolute size of kill EXP/SP on the live path (gap 5); not the sharing rules | read the ref-char vtable slot 13 in the GS dump |
| Position update cadence (`FUN_004a9410` callers) | how often to send member positions | caller census of `0x4a9410` and `0x4df6b0` |
| Whether the main field world has a `PARTYMONSTER_SPAWN` equivalent | whether field nests are ever gated | the base `CGameWorld` slot at the vtable index of `0x609900` |
| The order of the kill distributor's group map | which exp-share group's count arms the nest when two groups shared a kill | the map type behind `vslot_399`'s groups |
| What `chardata+0x13` holds (the `0x2c26` gate) | refusing a party-match registration exactly | writers of `+0x13` |
| Drops from party monsters | whether drop counts or rates change | caller census of slot 192/193 in `RefItemDrop` |
| `pc[0x274](0x80,0)` on a gold pickup over 1000 | a client effect, probably | name GS vtable slot 157 |
| `0x2c20` | the flags-mismatch refusal has no client text in `error_codes.md` | error-code table lookup |
| `FUN_005bbae0` (needs both bits; walks a member's list on join) | probably quest sharing in an exp+item party | read its vtable `0x69c` call |
