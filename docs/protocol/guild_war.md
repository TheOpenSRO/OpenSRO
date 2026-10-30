# Guild war (round 844, lane V)

The whole war, both sides, as the original does it. Labels: READ (s: SR_GameServer.exe, m:
SR_ShardManager.exe, c: sro_client.exe), MEASURED (Media.pk2), INFERRED, OURS, OPEN. The rules the
round-272 era recovered (the ladder's codes, the cap of 50, the `_GUILDWAR` columns) are in
[guild.md](guild.md) "Guild war — RECOVERED 2026-09-17"; this page completes them.

Code: `server/internal/guild/war.go`, `war_rules.go`, `war_store.go`, `sqlstore_war.go`;
`server/internal/session/guildwar.go` (and the hooks in `jobpvp.go`, `monsterstrike.go`, `party.go`,
`guildblock.go`, `guildops.go`); `server/internal/jobs/pvp.go` (`AttackCode`, its hostile argument). Client:
`net/guild_war_net.gd`, `net/hostile_data.gd`, `ui/hud/guild_war_panes.gd`,
`ui/hud/guild_war_request_box.gd`, `world/guild_war_ui.gd`.

## Where and who

- **The guild window** (READ c:0x5b57c0): tab 73 "Guild rel." shows pane 164 (`guild_r.2dt`), whose
  sub-tab 88 "Hostility" shows **CNIFHostileGuild 2000**; tab 74 "Combat" shows **CNIFGuildWar 548**
  (`guild_w.2dt`). Every war message refreshes both (0x799510 -> 0x5b3c50 / 0x5b3c70).
- **The Hostility pane** (MEASURED `guild_r.2dt`, READ fill 0x5bd740, select 0x5bdd40 -> 0x5bcb80): ten
  CNIFHostileSlot rows (225, 231, 235, 239, 243, 247, 255, 259, 263, 267): 127 the hostile guild's
  name, 128 the literal "-" (0xd81ea0: the data has no level), 131 its crest; an empty row is hidden.
  Selecting a row shows 156 / 153 / 159 / 161 and the values 155 (the name), 148 and 160
  (UIIT_CTL_GUILD_DONOTKNOW "Unconfirmed": the leader and the member count are never known), and
  hides 135 "No guild is selected."; none selected, the reverse.
- **Buttons** (0x5bca80): **52 "Request to start the war"** for the master only (the own name equals
  the guild master's, CDD+0x148 +0x48); **53 "Request to end the war"** for the master with a war and
  no end countdown running (+0xa8 != 0, +0x7c8 == 0).
- **The Combat pane** (MEASURED `guild_w.2dt`, READ 0x5af160): seven CNIFGuildWarSlot rows (518 the
  name); the shown war (the row selected, else the first): 541 the name, 542 the own points, 543
  theirs, 544 the victory points or "Unlimited", 545 the wager "%s %s" (grouped, UIIT_STT_GOLD), 546
  the time left "%0.2d : %0.2d : %0.2d" or "Unlimited"; with none, those hidden and 62 "<No hostile
  Guild>". The contribution rows (250, 506, 510, 514: 503 the member, 504 the rank, 505 the points)
  read the members' contribution, kept live by the kill news. **OPEN:** their order and the rank's
  text (OURS: highest first, "%d").
- The ResInfo CIFGuildWar / CIFHostileGuild (`ifguildwar.txt`, `ifhostileguild.txt`) are in the exe
  but no live path to them was found (OPEN, presumed unused).

## Declaring

- **The request box** CIFRequestGuildWar ("RequestGuildWar", 0x79bbb0; frame
  `interface\messagebox\msgbox2_window_`; OK 5, Cancel 6):
  - **State 1, input** (0x71b070; 350x257, UIIT_STT_INPUT_BOX, `ifguildwarrequest.txt` sections
    Create, Condition, Message, InputGuild): combo 23 the victory points ("Unlimited", then 5000,
    10000, 50000, 100000, 150000, 250000, 300000; default index 2); money button 28 opens the gold
    box (INFERRED: capped at min(the gold carried, 500,000,000)) and 40 shows the amount grouped;
    combos 24 / 25 / 26 the period ("00Day".."30Day", "00Hour".."23Hour", "00Minute".."50Minute" by
    ten, each ending with "Unlimited"; default 1 day); edit 55 the name (12 characters, focused).
  - **OK** (0x71c480 state 1), each refusal a system line and the GDR_WARNING_WND banner: no name
    UIIT_MSG_GUILDWAR_HGN_INPUT; the own guild GUILDWARERR_SELFWAR; a length outside 2..12
    GUILDERR_INVALID_GUILDNAME_LEN; the name filter GUILDWARERR_ERRINPUT; over 500,000,000
    GUILDWARERR_LIMIT_COMPENSATION "(500,000,000)". Then the period word (0x71a810): any part Unlimited
    0x7fffffff, else `day << 10 | hour << 15 | minutes << 20`; state 2 opens.
  - **State 2, confirm** (0x71aad0; 350x222, UIIT_STT_CONFIRM_BOX, `ifguildwarconfirm.txt`):
    SANCTIONWAR_01 with the name, _02, and the points, period and wager read-only. OK sends 0x7110.
- **0x7110** (c:0x824a30, s:0x51c980): str the target guild, u8 0 (WarType, INFERRED; always 0), u32
  the period, u8 the victory index, u32 the stake (one side's).
- **The ladder** (s:0x5c6b60, in order): the target guild 0x4c25; its master online and **within
  300.0** of the declarer (s:0xb45c40, 3D) else 0x4c60 TOO_FAR -- the masters meet; the declarer in a
  guild 0x4c0d; the victory index <= 7 and the period's days <= 30, hours <= 23, minutes <= 50 else 2;
  s:0x425210 else 3 (OPEN what it tests); the master 0x4c1e; the declarer's gold >= the stake 0x4c43;
  the stake <= 500,000,000 0x4c5e; the hostile counts < 50 (own 0x4c3e, the target's 0x4c3f); not at
  war already 0x4c3a; not the same union 0x4c41; the ghost-hunt zone 0x4c79 and the battle arena
  0x4c7a (no such zones here). A refusal is 0xB110 {2, u16}; success sends no reply. OURS: a target
  master already asked is refused 0x4c06; the own guild (the client stops it first) 2.
- **The question** (s:0x5c6f4c -> s:0x46c9e9): 0x3080 {u8 10, u32 the declarer's uid, str its guild,
  u8 the type, u32 the period, u8 the index, u32 the stake} to the target master, who has 30 s
  (s:0xb45b48). The client (c:0x88b1d4 index 9 -> 0x885920) opens **state 3** (0x71a9b0; 350x222,
  UIIT_STT_AGREEMENT_BOX, `ifguildwaragree.txt`: CONSENTWAR_01 with the declarer's guild, _02, the
  terms); **OK is disabled while the master's own gold is below the stake**. The answer is 0x3080
  {u8 1, u8 1 accept / 0 refuse} (c:0x820450); a Cancel also says WARREFUSAL with the own guild.
- **The answer** (s:0x46cb30 -> s:0x5c8510), each refusal 0xB110 {2, code} to the declarer: the
  declarer gone 0x4c0e, the target gone 3, the declarer no longer master 0x4c1e, the target no longer
  master 0x4c24, a refusal 0x4c16, the target's gold below the stake 0x4c0c, the declarer's 0x4c43;
  a timeout 0x4c10 (s:0x46ce51). Then **both masters pay the stake** (reason 10), the war begins
  (m:0x43be90 `_GuildWar_Begin`: LodgedGold = 2 x the stake, WarEndTime = now + the period or NULL)
  and 0x38F5 0x19 goes to both guilds.

## The wire during a war

- **E**, the war (s:0x5cfd30; c:0x87ff10 SGuildWarDef): u32 the war, u32 the seconds left
  (0x7fffffff unlimited), u8 the victory index, u32 LodgedGold, u32 guild A (the declarer), u32 guild
  B, u32 A's points, u32 B's points.
- **0x3109** the hostile list (CGuild slot 8 s:0x5c38a0; c:0x87fd90 -> 0x99ab20): u8 n, n x (E, str
  the enemy's name), or u32 0 for an enemy guild that no longer exists. At world entry and to a joining
  member, only while the guild has a war. The client only adds (0x999260, keyed by the war id; own side
  by A or B).
- **0x38F5** (c:0x887330): **0x19** E + str the other guild (GOTOWAR "The war between [own]guild and
  [their]guild has now started." on the banner); **0x1d** {u8 1 the killer's guild / 2 the victim's,
  u32 the war, u32 the points, u32 the own member, str the opponent, or str "" then str the owner of a
  fallen COS (shown "*" + owner)} (KILLNEWS on the banner; points, kills, deaths and contribution
  kept); **0x1f** {u32 the war, u32 seconds} every 60 s for a timed war (m:0x40c69c); **0x1a** (to
  the guild surrendered to) / **0x1b** (to the surrendering guild) {u32 the war}: ENDCOUNT "is to
  close in a minute" in a box, then "Until the end of war (%d seconds left)" on the banner every
  second from 60 (0x781250, timer 0xd); **0x1c** {u32 the war, u32 the winner}: WINERGUILD / LOSEGUILD
  in a box titled UIIT_STT_EVENTGUIDE, the entry removed; **0x23** {u32 guild, str name} a hostile
  guild renamed; **0x32** (c: a refusal, a timeout, the gold box) is read by the client but this
  server's reading sends B110 instead.
- The client recolours the guild lines (0x9a4450) and every name (0x9dbd10 -> 0x9cfd50) after 0x3109,
  0x19, 0x1c and 0x23.

## Fighting

- **Who may hit whom** (CGObjPC slot 394, s:0x5293a0): after the own COS (0x3006), a town on either
  side (0x3018: **no war in towns**), the same party (0x3022), the cape and caravan rules, **two
  guilds at war fight** (IsHostileGuild, CGuild slot 7 s:0x5d1220) -- before the PK-off code, the
  area flag, the level-20 rule and the murder limits: war needs no PK mode and has no level limit.
- **The client** (c:0x9de780, CICUser slot 42): a player whose guild is in the hostile list is an enemy
  **without Alt** (unless both wear job suits, or under the team / fortress rules); the cursor is the
  hostile sword 0xa0; a click attacks when he is already selected; the level-20 rule is waived while
  the hostile map is not empty (0x988a70); his **name** is drawn 0xffff6262 outside the party
  (0x9cfd50), his **guild line** 0xffff0000 (0x9a4f40).
- **A kill** (cause 5, ResolveDeathCause s:0x4e6590 via s:0x4eb390): points (s:0x5c721x) with d =
  the victim's level less the killer's (a fallen COS's own level): **1 at d <= -6, 15 d + 100 up to
  d = 10, 251 above** (100 at equal levels); the killer's Contribution and GuildWarKill and the
  victim's GuildWarKilled (s:0x5cb430); a side reaching the victory target wins at once (m:0x43c320).
- **The death** (GObjPC_OnDeath s:0x4e6980, cause 5): no murder points; a victim above level 10
  loses 20 x the level's exp unit (DeathPenaltyKilledByPlayer) and no SP. OPEN: the item-drop roll
  (OpenSRO drops nothing on any death) and the killer's exp reward.
- **OPEN:** GUILDWARERR_NOT_WEAR_JOBITEM (0x18c3, a server refusal: job items cannot be equipped
  during guild wars) is not built; instance entry is refused 0x1c39 during a war (s:0x415eb0) --
  the instance is not identified.

## Ending

- **By time** (m:0x438430, every second): past WarEndTime with the totals apart, the higher wins; a
  tie runs on. A war with no end and no victory target ends only by surrender.
- **By victory points** (m:0x43c320, at a kill).
- **The end proposal is a surrender** (0x7112 {u32 the war}, s:0x5c7390): refusals 0xB112 {2, code}
  (no guild 0x4c0d, an unknown war 2, not the master 0x4c1e, the enemy gone 0x4c25); then 0x1a to the
  other guild, 0x1b to the own, and after 60 s (m:0x79b020) **the other guild wins** (UNJOIN,
  m:0x43ccf0; the server log "GuildWar Guild[%d,%d] Surrendered Guild[%d]"). No message asks the other
  side to agree. The client's box (0x5bcfe0): MsgBoxSimple UIIT_STT_AGREEMENT_BOX, SANCTION_ENDWAR_01
  + "\n" + _02; OK sends 0x7112. RECONCILABLE_HGN_INPUT and NOTENEMYGUILD are unused.
- **The reward**: the winner's guild keeps LodgedGold as **Booty** (_GUILD +0x8c, s:0x5c4f20). At the
  guild manager the master's line **0x1b UIIT_CTL_GUILD_COMPENSATION "War reward gold received"**
  (c:0x7010f6) sends **0x7114 {u32 the NPC}** (any member may ask, s:0x5c72a0): 0xB114 {1, u32 the
  booty} -> COMPENSATION_01 "War refundable rewards is [%d]." + _02 (UI_GUILDWAR 0x6f9510), whose OK
  sends **0x7113 {u32 the NPC}** (the master only, 0x4c1e; s:0x5c7330): the whole booty to the
  master's gold (reason 0xb), 0xB113 {1}. No booty: {2, 0x4c45} -> NOTCOMPENSATION "No refundable
  rewards." Both need the NPC talk (0x1c78 check, else 3); OURS: the NPC in reach.
- **Disband** is refused 0x4c46 GUILD_ERROR_BREAK_WAR while the guild has any war (s:0x5c6870);
  leaving and expelling are not.

## Unions

- Declaring on a guild of the own union is refused 0x4c41 (above).
- An alliance proposed to a hostile guild is refused 0x4c42 "Cannot propose an alliance to a hostile
  guild." (Guild_ValidateAllianceRequest s:0x5c6550) -- lane U's request flow; `guild.AtWar` is the
  test it needs.

## Persistence

- The ShardManager keeps `_GUILDWAR` (WarEndTime a wall-clock time, PointGain written on every kill)
  and `_GUILD.Booty`, so wars, their points and an unclaimed reward survive a restart and the 1 s check
  picks up. OpenSRO: `guild_wars` (id, war_type, victory_index, lodged_gold, war_end_time NULL for
  none, guild_a, guild_b, points_a, points_b, started_at) and `guild_war_booty`, created by the store
  itself; the members' counters are guild_members' war_kill / war_killed / contribution. The server
  loads the wars at start.
- `guild + 0x44` is the size of the std::map of wars at +0x3c keyed by the enemy guild's id: only its
  insert (s:0x5d1ef0) and erase (s:0x5d1fd0) change it.

## OURS and OPEN, together

- OURS: `/guildwar` (the list) and `/guildwar end <guild> [seconds]` (a QA aid: the war's end moved);
  partybot `-war-answer`, `-war-declare`, `-war-surrender-after`; the NPC-in-reach stand-in for the
  talk check; the 0x4c06 refusal for a master already asked; the contribution rows' order.
- OPEN: WarType, Data1, Data2; s:0x425210's test; the UIIT names of 0x4c43, 0x4c5e, 0x4c79 and 0x4c10
  (the client shows nothing for them -- no row in its category-0x10 table); why 0x1a and 0x1b both
  exist (the client treats them alike); NOT_WEAR_JOBITEM; the 0x1c39 instance; the death item roll;
  the killer's exp; the spawn record's war byte (the guild block's first u8 after the three u32 is 1
  when the guild has no war, s:0x4e5e21; OpenSRO writes 0); the client's 0x7074 {2} cancel at 0x1c
  (OpenSRO's keep-up stops at the next refused swing).
