# Round 716 review (0x3056, 0x304E kind 1, the client's 0x3068)

An independent adversarial review of `dev..worktree-agent-a764933fd322d2504` (`d0571d64`,
`e255abd3`, `95dab216`, `f33411c4` on `dca31493`). Every layout and rule below was read in the asm
of `SR_GameServer.exe` (`/var/tmp/srgs.asm`) or `sro_client.exe` (`/var/tmp/sro_client.asm`) on the
render box, with the decompile dumps as a guide. No code was changed.

**Verdict: no BUG and no REGRESSION found.** The wire layouts, the recipients, the zero rule, the
level-up u16 and its value all match the binaries. Six findings, all DEPARTURE or MINOR: one
unlabelled ordering difference, one comment that over-claims the level-110 clamp, a client gold-line
race, extra stats requests, a gap in the spec's 0x304E section, and a missing handler-level test.

## Findings, most severe first

### F1. DEPARTURE: 0x3056 goes out before the level-up announcements; the original sends it last

- **Where:** `server/internal/session/killshare.go:378-388` (`distributeKill`), with the killer's
  `OpLevelUp` sent later by `combat.go`/`status.go` after its OpAttackResult.
- **Evidence:** in `GObjPC_GainExpAndLevel` (`gs:0x4e5250`) the level-up is applied first.
  `GObjPC_SetLevel` (`0x4e4d90`, called at `0x4e555e`) sends `0x3054` (`FUN_00430a00(0x3054)`) and the
  HP/MP delta. Then slot 157 (`+0x274`, `0x4e5783..0x4e5792`, arg `0x80`) runs. `0x3056` is
  written last (`push 0x3056` at `0x4e582d`, sent at `0x4e5907`). OpenSRO sends 0x3056 to every
  receiver first, then `OpLevelUp` to the non-killers. The killer's `OpLevelUp` comes after its
  OpAttackResult, which itself comes after the 0x3056.
- **Effect:** none functional in this client, because the banner and the gauge come from
  `OpLevelUp` and the stats reply. But the order is not the original's, and neither the comment nor
  the spec says so.
- **Fix:** either send each non-killer's `OpLevelUp` before its 0x3056 (swap the two loops), or
  label the order OURS in `distributeKill`'s comment and the spec's "OpenSRO (round 716)" list.
  `OpLevelUp` is OpenSRO's own 0x0067 rather than 0x3054, so labelling it is reasonable.

### F2. MINOR / WRONG-LABEL: the level-110 clamp is keyed on the *starting* level in the original; `expAdded` clamps an award that crosses into 110

- **Where:** `server/internal/session/rewardnotice.go:16-22` (the comment), and line 24
  (`Exp: p.expAdded`).
- **Evidence:** the clamp runs only when the level byte is exactly 110 *before* the award:
  `0x4e52c1..0x4e52d7` does `mov cl,[chardata+0x65]; cmp cl,0x6e`. Above 110 it zeroes the EXP
  (`0x4e52cc`). Below 110 it jumps past the clamp to `0x4e5393`. At 110 the amount becomes
  `min(exp, req - cur - 1)` (`0x4e5365..0x4e5390`). So an award that starts at 109 and overflows
  110's requirement is written unclamped. `expAdded` (`combat.go:457`, after
  `leveldata.Advance`'s cap hold) is clamped in that case. Everywhere else the two are equal: below
  the cap `Advance` loses nothing, and at 110 both give `req - cur - 1`, or 0 when the bar is full.
  The 109→110-overflow case is practically unreachable, because one kill would have to pay level
  109's remainder plus all of level 110's requirement. The comment's "at the level cap … clamps the
  amount to what fits … which is expAdded" is therefore slightly broader than what was READ.
- **Fix:** reword the comment: "the original clamps only when the receiver *starts* at 110
  (`0x4e52c7`); expAdded equals it except for one award crossing into 110's overflow". Or send
  `p.exp` unless the starting level is `MaxCharacterLevel`, in which case send `expAdded`.

### F3. MINOR: the 0x304E gold line is computed against `_last_known_gold`, which unordered stats replies overwrite

- **Where:** `client/scripts/World3D.gd:20825` (`_on_world_stats` sets `_last_known_gold`) and
  `20933-20941` (`_on_gold_total`).
- **Evidence:** the original (`c:0x8a70d0` case 1) prints the rise over its own purse
  (`IFMainPopup+0x378`), which only gold messages move. OpenSRO's client also takes the total from
  every stats reply. That includes the replies the server pushes unprompted: `regen.go:122`
  `pushStats` sends `OpCharacterStatsResult` on a regen or status tick, from another goroutine.
  In `grounditem.go:486-507`, every `AddGold` runs before any `tellGold`. A regen push that reads
  a member's row in that window arrives before the 0x304E and sets `_last_known_gold` to the new
  total. The 0x304E then rises by 0 and **prints no line**. The opposite case is a push read before
  the credit but delivered after the 0x304E. It reverts the base, and a second split before the
  follow-up stats reply prints an overstated rise. The window is milliseconds; the round's notes
  label "refreshed from the server" as OURS but do not mention this race.
- **Fix:** keep the purse base the original's way. Seed `_last_known_gold` from the first stats
  reply only, then move it only on 0x304E and on the client's own pick-up reply. Alternatively,
  ignore stats replies' gold while a 0x304E has arrived since the last request.

### F4. MINOR: the killer now sends two or three stats requests per kill

- **Where:** `client/scripts/World3D.gd:2176` (the attack result's `monster_died` request), `20929`
  (`_on_exp_gained`) and `20748` (`_on_level_up`).
- **Evidence:** before the round a kill caused one request, or two with a level-up. Now the killer's
  0x3056 adds another, and each reply is a full stats read on the server. This is not doubled
  output, since nothing prints from the stats reply, but it is a doubled round trip on every kill.
- **Fix:** coalesce `_request_world_stats` the way `_refresh_stat_panel` does (one deferred request
  per frame). Or drop the `monster_died` request, because every paid kill now brings a 0x3056 and an
  unpaid one changes no gauge.

### F5. MINOR (spec gap): the original sends 0x304E kind 1 on a *solo* gold pick-up too, unshown; and whether its pick-up reply also prints the split picker's line is not read

- **Where:** `docs/protocol/party_protocol.md`, "0x304E kind 1, the gold total", and the OURS comment
  at `server/internal/session/grounditem.go:497-505`.
- **Evidence:** the gold pick-up credit `gs:0x4eaca0` (reached from CGItem slot 310 `0x48fc70`)
  calls the split `0x5bc7f0` for an item-share party. Otherwise it calls
  `OffsetGold(amount, 0, 0x19, 1, 0)` (`0x4ead0a..0x4ead1d`: pushes 0, 1, 0x19, 0, amount). That
  sends 0x304E kind 1 with show 0, so it updates the purse with no line. The spec reads as if only
  the split sends kind 1. Separately, the client's item-move reply prints `UIIT_MSG_STATE_GAIN_GOLD`
  for the gold kind 0xfe from its own u32 (`c:0x87bedc..0x87bf20`). Whether the GameServer writes
  that reply to the picker of a split, and with the pile or the share, was not read. If it does, the
  original's picker sees two lines (that reply's and the shown 0x304E), and OpenSRO's single line
  is a further departure that the OURS note does not cover.
- **Fix:** add the solo `OffsetGold(…, 0x19, 1, 0)` row to the spec. Add an OPEN line for the
  picker's item-move reply, or read its writer (the caller of slot 310) and settle it.

### F6. MINOR (tests): nothing drives the pick-up handler's gold split to check that members get 0x304E

- **Where:** `server/internal/session/rewardnotice_test.go:79-90`.
- **Evidence:** `TestTellGoldSendsTheTotal` calls `tellGold` directly. No test picks a gold pile in
  an item-share party through `GroundItemHandler` and checks three things: each other in-range
  member gets one shown 0x304E with its row's total; the picker gets none; and a share that failed
  to credit (`credited < len(shares)`) is not told. The `shares[1:credited]` slice and the
  picker-first order of `splitGold` (`itemshare.go:98`) are what make the call right, and neither
  is pinned by a test.
- **Fix:** add that session test. The round-712 gold-split tests in `itemshare_test.go` already
  build the party.

## Verified (no finding)

**0x3056 server writer** (`gs:0x4e5250`, asm read in full):
- The arguments are `[ebp+8]` u32 source, `[ebp+0xc]` i64 EXP, `[ebp+0x14]` i64 skill EXP and
  `[ebp+0x1c]` a camp pointer (`ret 0x18`).
- The appends are 4, 8, 8 and 1 bytes (`0x4e583c..0x4e5878`). Then come a u32 from `[camp]+4` when
  `flags&0x0f == 1` and two u32s from `[camp]`, `[camp]+8` when `flags&0xf0 == 0x10`
  (`0x4e587d..0x4e58c1`). Then a u16 from `chardata+0x84`, only when the new level is above the
  old one (`0x4e58df..0x4e58fa`, `cmp [esp+0x18],[esp+0x1c]; jle`).
- With a null camp pointer the flags are 0 (`0x4e57da..0x4e5823`). The kill path passes a non-null
  one (`lea eax,[esp+0x74]` at `0x4eabda`), so the flags depend on camp membership, which OpenSRO
  lacks. Flags 0 is right.
- **The zero rule:** nothing is sent when the post-multiplier, post-clamp EXP and the skill EXP are
  both 0 (`0x4e5393..0x4e53a1` → `0x4e590c`). `sendExpGain` matches.
- **The stat points:** `GObjPC_SetLevel` adds the points to `chardata+0x84` before the append, so
  the u16 is the **total unspent** after the level-up. `expGainFor` sends `levelUp.StatPoints`, the
  row's new total. That matches. The per-level count (5 in this GameServer's SetLevel against
  OpenSRO's grounded 3) is pre-existing and not this round's.

**The kill path:**
- `CGObjPC::vslot_420` calls slot 92 (`call [esi+0x170]` at `0x4eabf9`) once per receiver, with
  `[[ebp+8]+8]`, the victim's unique id, as the source (`0x4eabd2..0x4eabd5`). The skill EXP is
  sign-extended from an int (`cdq` at `0x4eabe3`).
- **The killer** is one of the receivers, so it gets its own 0x3056 in the original. OpenSRO sends
  it to every entry of `paid`, killer included. The status-tick and absent-killer paths
  (`status.go:744`, `grantKill`) go through `distributeKill` too, so a DoT kill now tells its
  killer for the first time.
- `planKill` gives each character at most one award (one group key per attacker), so the merge in
  `payKill` never combines two awards into one 0x3056.

**0x3056 client reader** (`c:0x8a97c0`, asm read in full):
- It reads 4, 8, 8, 1, then the camp u32s on the same flag tests (`0x8a9802..0x8a988a`).
- **The u16 is decided from the client's own state, not from the bytes left.** For a positive EXP
  it computes `own +0x870 + exp` against its current level's requirement, and only when that
  reaches the requirement does it read the u16 into `+0x884` (`0x8a9928..0x8a997d`). It does this
  before its level loop.
- So the lane's "remaining bytes" reader is a labelled OURS departure. With this server it is safe
  in both directions: OpenSRO writes the u16 exactly when its own `Advance` raised the level, every
  message is a separately framed packet, and at 110 the clamp (`req - cur - 1`) keeps a
  synchronised retail client off the u16 branch too. The spec's description of the client's rule
  is accurate.
- **The lines** are all type 1: GAIN_EXP for EXP > 0 (`0x8a9a45..0x8a9a76`), LOSE_EXP with the
  negated value for EXP < 0 (`0x8a9b76..0x8a9baa`), and GET_SKILL_EXP for skill EXP > 0
  (`0x8a9cd1..0x8a9cfa`). The skill counter `+0x878` is taken mod 400 (`0x8a9c8d..0x8a9cbd`).
  `RewardNoticeNet.exp_lines` matches.

**0x304E kind 1:**
- **The writer** `gs:0x4e3fb0` (asm): u8 kind, then for case 1 eight bytes from `chardata+0x78` and
  the show byte (`0x4e3ffa..0x4e401d`).
- **`OffsetGold`** (`0x4e4b60`) sends it when its fifth argument is 1, with the sixth as show
  (`0x4e4bd7..0x4e4be1`).
- **The split** `0x5bc7f0` calls `OffsetGold(share, hi, 0x17, 1, 1)` for every member, the picker
  with the remainder. When the quotient is 0 the picker alone gets it, which `splitGold`
  (`itemshare.go:110-112`) matches.
- **The client** `c:0x8a70d0` case 1 reads u64 then u8. When show is set it prints GAIN_GOLD with
  `new - own`, clamped to `0x7fffffff`, and only when the total rose. It then sets its gold.
  `charmsg.EncodeGold` and `RewardNoticeNet.decode_gold`/`gold_line` match.

**0x3068 client reader** (`c:0x873990`):
- It reads u32 JID, u32 RefItemID, then the class from the item's TypeID word: bit 1 or "other"
  gives u8, expendable gives u16, gold gives u64.
- **Self:** the self test compares the JID with `[0x986f50()+0x18]`. `0x986f50` is
  `lea eax,[ecx+0x20]` on `0xeeebd8`, and `party_gui.md` reads `+0x18` of that block as the player's
  own id. For the player's own JID, on a non-gold class, the line is
  `UIIT_MSG_STATE_GET_ITEM_EXPENDABLE` type 1 with (name, count).
- **Another member:** `UIIT_MSG_PARTYGET_ITEM_EXPENDABLE` type 4 with (name, count, member).
- **Gold:** `UIIT_MSG_PARTYGET_GOLD` type 4, whoever the recipient is. `item_notice_line` matches
  all three branches, including gold ahead of self.
- **Recipients** are unchanged from round 712: everyone but the recipient (`sendItemNotice`).

**Double reporting:**
- `UIIT_MSG_STATE_GAIN_EXP` is now written only by `_on_exp_gained`. The attack-result path no
  longer prints (`World3D.gd:2150-2156`), and `exp_gain_lines` survives only as a static used by
  tests.
- The killer's OpAttackResult keeps its EXP tail, which the client no longer reads for a line, so
  the killer sees each gain once.
- The gauge comes from a stats reply requested after the 0x3056. The server has already written
  the row (`SetLeveling`, `AddSkillExp`) before sending, so the reply is not stale.

**Regressions:**
- A solo kill gets one 0x3056 and one line.
- The level-up flow is unchanged (`OpLevelUp` to non-killers in `distributeKill`, to the killer
  after its result).
- The death penalty and the quest kill credit (`announceKill`) are untouched.
- A solo gold pick-up is unchanged: `shares[1:1]` is empty, so no 0x304E is sent.
- `partybot -kill` drains the stale GM reply before `/spawn`, and its 0x3056 capture does not feed
  `b.other`.
- World3D's changes are signal handlers only, with no per-frame code. That supports skipping the
  perf gate.
- `gofmt -l` is clean on the touched packages, and `go vet` is clean on `charmsg`, `session` and
  `partybot`.

## Tests run

- **Go:** `go test -count=1 -p 1 ./...` against the local `opensro_test` (Postgres reachable, DB
  present). **66 packages ok, 0 failing**, exit 0. `session` took 134.8 s; `charmsg`, `party` and
  `systems` passed.
- **Box:**
  - `RENDER_DIR=/opt/opensro-client-r716rev GODOT_LOCK=/var/tmp/r716rev/lock client/tools/remote_godot.sh check`:
    **checked 602 scripts and 9 scenes, ALL LOAD**.
  - `… tests`: **ran 230 suite(s), 0 failing**.
- **Live, re-run independently:** the worktree's own `server` and `partybot`, built here and run on
  the box. The server ran in memory on port 15937 with retail `leveldata.csv`, a monsters CSV
  carrying ExpToGive, and the box's chargen CSV. The run was `partybot -mode share -level 18`:

```
--- 1: the baseline, a solo kill (multiplier 1)
[rsSolo] <- 0x3056 source 25 EXP 54 skill EXP 242 level-up false
[rsSolo] killed chakji #25 (HP 1031): EXP +54, SP +242
--- 2: an Exp Auto Share party of two; one member kills
[rsMate] <- 0x3056 source 26 EXP 29 skill EXP 133 level-up false
[rsKill] <- 0x3056 source 26 EXP 29 skill EXP 133 level-up false
[rsKill] killed chakji #26 (HP 1031): EXP +29, SP +133
    killer +29 EXP, mate +29 EXP; want both trunc(54 x 0.55) = 29
    0x3056: killer 29 EXP / 133 skill EXP, mate 29 EXP / 133 skill EXP (source 26)
--- 3: an Exp Free-For-All party of two; one member kills
[rsFfa] <- 0x3056 source 27 EXP 55 skill EXP 249 level-up false
[rsFfa] killed chakji #27 (HP 1031): EXP +55, SP +249
    killer +55 EXP, idle member +0 EXP; want trunc(54 x 1.03) = 55 and 0
--- all share steps passed
```

  The run reproduces the lane's numbers. The server log has no errors. The idle free-for-all member
  got no 0x3056, and the killer's 0x3056 arrives before its OpAttackResult (see F1). The box scratch
  (`/var/tmp/r716rev`, `/opt/opensro-client-r716rev`) was deleted afterwards. No game data was
  copied off the box.
