## Round 709 (lane party709b): the party rules read out of both servers -- the 4/8 cap follows the EXP setting alone, an EXP-share party splits by level with 10%/20% per member inside 1000 units, the 3% bonus is only for EXP free-for-all, items go round robin, a party monster needs just two members in range, and party matching pages hold 23 in listing-number order with a 15-second join request

*Spec round, docs only. Lane party709b of round 709 (siblings: party709a wire protocol, party709c
client GUI). Written for the coordinator to file as part of round 709 in `docs/WORLD_ISSUES.md`.*

### The question

The user asked for the party system "fully working", matching the original down to the opcodes,
and asserted a set of rules about party types, sharing, job parties, party matching and party
monsters. This lane read the rules and formulas out of `SR_GameServer.exe` and
`SR_ShardManager.exe` (the latter decompiled this round by party709a into
`/var/tmp/decomp_shardmgr`), with the client for cross-checks. The full record is
`docs/protocol/party_rules.md`. Every constant there was read by operand size out of `.rdata`.

### What was found

- **The party lives in the ShardManager**, which owns formation, join, leave, dismissal, leader
  succession and the whole party-matching registry. The game server keeps a local copy and does the
  sharing.
- **The cap is 8 or 4 by bit 0 (EXP share) alone.** The GS join check, the SM's own full test and
  the client's full test agree. The user's "all sharing off = 1/4" is corrected: EXP Free-For-All
  is 4 whatever the item setting.
- **The flags are fixed at formation.** No SM request kind writes them; a listing modify with a
  different flags byte is refused; a listing registered for an existing party takes the party's
  flags.
- **Kill EXP and SP take the same multiplier** (`CGObjPC::vslot_420` scales both), from two
  branches of the monster's death distributor `CGObjMob::vslot_399` (`0x4c44a0`):
  - **EXP free-for-all, or no party:** each contributor is paid for his own damage share,
    × (1 + 0.03 per member past the first, counting every member).
  - **EXP Auto Share** (`FUN_005bca60`):
    - eligible are the members alive, in the world and within **1000** units horizontally of the
      kill credit;
    - bonus `1 + 0.1 × (extra Chinese)`, or `1 + 0.2 × (Europeans − 1) + 0.1 × Chinese`;
    - the split is **by level** (`level / Σlevel`);
    - a member taking more than 70% keeps half the bonus (3+ members, top level ≥ 21);
    - a party monster out-levelled on average pays half.
- **Kills do pay skill experience.** Slot 420 calls `GainExpAndLevel` through the vtable with
  `FUN_004106b0`'s skill EXP. A previous census counted only direct calls and recorded the opposite
  in `combat.go`.
- **Items:**
  - item share hands a pickup to the next member of a **rotation list** who is alive, in the world
    and within 1000 (3D) of the picker, falling back to the picker;
  - when the recipient's inventory is full the picker gets `0x18da`;
  - gold splits equally among members within 1000 of the pick, the remainder to the picker.
- **Job rules** (`0x2c23`):
  - trader and hunter together, thief only with thief, a non-job player only with non-job players;
  - a listing's purpose must fit the leader's job: trader and hunter use trade (2), thief uses
    thief (3), everyone else combat (0) or quest (1);
  - there is no hunter purpose or icon.
- **Party monsters:**
  - two eligible members of an EXP-share party arm the nest; the next normal hatch rolls 50/101;
    none below level 10 (round 660's reading, confirmed);
  - HP ×10, **damage ×1.2** and **EXP/SP ×7.5**, the last two found this round;
  - OpenSRO's nest log says `party=0` because `ArmParty` has no caller.
- **Party matching:**
  - listing numbers come from a monotonic counter;
  - pages of **23** in number order, with the requester's own listing added to every page;
  - the join request ladder: level outside [min, max] → `0x2c1e`, job → `0x2c23`, pending →
    `0x2c1f`, full → `0x2c13`/`0x2c14`;
  - the join request times out after **15.0 s** (SM transaction tick, READ); the plain invite
    after **30.0 s** (`0x2c10`);
  - the leader's own client deletes a listing when the party fills.
- **Leaving and chat:**
  - a party of two is **dismissed** when one leaves;
  - the new leader is the longest-standing member, and a leader's listing moves with the role;
  - party chat goes only to members, **including the sender**;
  - member updates are event-driven, with HP/MP in tenths.

### Corrections filed (for the coordinator to apply)

| Record | Correction |
|---|---|
| `party.md` invite ladder step 5 | `0x26` is an interaction-kind code, not a distance; the invite range is **600** units (3D) |
| `party.md`, `leveldata.go`, `RE_COMPLETION.md` | the 3% bonus is the EXP free-for-all branch only; EXP-share parties use the level split |
| `combat.go` kill path, `SPReward` | kills grant skill EXP (`FUN_004106b0`) |
| `combat.go` `killExpFor` | a party of two dropping to one is dismissed (READ) |
| `recovered_names.tsv` `Party_ShareHwanCount` | same **world**, not region |
| `party.md` `0x061` | leave (reason 2), not a teleport |
| `party.go` `MaxSize`, `party.md` | 8/4 by the party's own bit 0 |

### Perf gate

Not run: a docs-only round.

### Open

- what the monster's EXP base (slot 332) returns on the live path;
- the position update cadence;
- the record's `+0x24` string;
- party-monster drops;
- the reason → message mapping;
- `0x2c20`'s text;
- the client's own progress-bar durations.

All are listed in `party_rules.md` with the next probe.
