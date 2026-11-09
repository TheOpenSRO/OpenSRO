# The academy (training camp)

**"Training camp" is the engine's name.** Every class, table and error code says
`TRAININGCAMP`, `TC_` or `MENTOR`; the player sees "Academy". The rules live in
`server/internal/academy`.

This page is the round 865 specification: what the original does, byte for byte, so
that a server half and a client half built apart agree. The build checklist is at the
end (section 18). Earlier passes read the server binary without a running game; their
evidence is kept in condensed form (section 16) and their wrong statements are
corrected in section 15.

Labels: **READ** (from a binary, with the address: `s:` game server, `m:` shard
manager, `c:` client), **MEASURED** (observed in the running game), **INFERRED**,
**OURS** (an OpenSRO choice), **OPEN** (not known; do not guess).

## 1. Wire conventions

- Little-endian. A string `str` is a u16 length then that many ANSI bytes, no NUL
  (READ s:0x426040, c:0x4f7a70, c:0x53d8c0). The client converts its wide text to ANSI
  before it writes (c:0x4fc950).
- A date `ts` is 16 bytes, ODBC `TIMESTAMP_STRUCT`: i16 year, u16 month, u16 day, u16
  hour, u16 minute, u16 second, u32 fraction (READ s:0x5e7400). MEASURED: every academy
  date is minute-rounded (the stored type is a small date-time): a camp founded at
  hh:08:02 carries hh:08:00 with seconds 0, fraction 0; a member who joined at hh:24:41
  carries hh:25:00.
- Every academy reply is `u8 result`: **1** success (body may follow), **2** failure
  followed by `u16 code` (READ s:0x4e7250 `mov byte [esp+0xb],2`; c:0x899630..0x899940).
  The client ignores any other result byte (READ).
- Request opcodes are 0x74xx; the server answers on 0xB4xx (0xB000 | index), with two
  crossed channels noted in place (READ s:0x5191d0, s:0x5195xx; MEASURED for leave).
- Strings sent by the client for names are the character name as the server knows it;
  the server compares names case-insensitively (READ `CompareStringA(0x400,
  NORM_IGNORECASE|NORM_IGNOREKANATYPE)`), and a name shorter than 2 characters is
  "not found".

## 2. Roles and constants

| class byte | role (engine) | title (class) | per camp | joins at | self graduation | forced graduation |
|---:|---|---|---:|---|---|---|
| 0 | guardian (founder) | `UIIT_STT_TC_GUARDIAN` "Guardian" | 1 | founds the camp at level >= 60 | never (answer 5) | never |
| 1 | assistant guardian | `UIIT_STT_TC_ASSISTANT_GUARDIAN` "Asst. guardian" | **2** | invited at current level 40..59 | max level >= 60 | stored max level >= 61 |
| 2 | apprentice | `UIIT_STT_TC_STUDENT` "Novice apprentice" | **5** | invited at current level <= 39 | max level >= 40 | stored max level >= 41 |

- READ: caps s:0x5e44d0 (`cmp eax,5`), s:0x5e4450 (`cmp eax,2`); role by level
  s:0x5192ce (`cmp al,0x27`), s:0x519303 (`cmp al,0x3b`); class titles c:0x6e8ed0.
  MEASURED: a level-1 invitee joined as class 2, a level-40 invitee as class 1, the
  founder's record carries class 0; inviting a level-60 character is refused with
  code 3.
- The camp holds at most 8 members (1 + 2 + 5); the client asserts "TraningCampMember
  is Over than 8" (READ c:0x999550).
- The stored class is also re-derived from the member's **max** level when the row is
  written: < 40 apprentice, < 60 assistant, else guardian, with the caps re-checked
  (MEASURED as the store's rule). The game server picks the role by **current**
  level (READ s:0x5192c4). The two only differ for a character whose current level is
  below its max level (section 17, choice 2).

| constant | value | evidence |
|---|---|---|
| founder level | 60 | READ s:0x4e4680 `GetLevel() < 0x3c -> 0x6809`; client menu line c:0x700b96 |
| founding fee | 100,000 gold, taken after the camp is stored | READ s:0x4e4650 `OffsetGold(-100000)`; MEASURED: 0x304E {1, u64 gold-100,000} arrives just before 0xB470 |
| invite range | 600.0 units | READ s:0x4a8e10 (float 0x44160000) |
| invitation wait | 30 s | READ s:0xb45b48 (30.0f); MEASURED 30.4 s and 30.5 s |
| ban / leave window | 86,400 s from JoinDate | READ s:0x5dd3f0 (`mov ecx,0x15180`, stamp at member+0x40 = JoinDate); MEASURED refusals 0x6820 / 0x6821 minutes after joining |
| disband window | 604,800 s from CreationDate | READ s:0x5dd350 (`mov ecx,0x93a80`, stamp at camp+0x1c = CreationDate); MEASURED 0x681d with 603,589 s left 20 min 11 s after a founding |
| reopen penalty (after disband) | 604,800 s | READ CTJ_PenaltyKeeper::Create case 7 (s:0x00651c5b) |
| invite penalty (guardian, after banning an apprentice) | 86,400 s | case 8 (s:0x00651c81); applied s:0x5dfb3b |
| entry penalty (apprentice who left) | 86,400 s | case 9; applied s:0x5ddce9 |
| entry penalty (assistant who left) | 259,200 s | case 10 (s:0x00651ca3); applied s:0x5ddd15 |
| graduation exp (self-graduating apprentice only) | 2,000,000 | READ s:0x5dfc69 `push 0x1e8480` |
| evaluation -> EvaluationPoint | byte 0..4 -> -3, -1, +1, +3, +5 | READ s:0xade9a4 |
| honor at an apprentice's graduation | guardian +(40 - joinLevel), each assistant +trunc((40 - joinLevel) / 10), only if joinLevel <= 30 | READ s:0x5e3730 (double 0.1 at s:0xb45ec0); MEASURED as the stored rule |
| assistant leaving (not banned) | loses 10 honor points (floor 0) | MEASURED as the stored rule |
| honor rank update | daily at 00:00:00 server time, and at shard start when the last update was not today | MEASURED (the schedule row: daily, start 00:00:00, 60 s); READ m:0x66466e names SCHEDULE_DEF_MENTOR_HONOR_UPDATE |
| honor ranking | top 50 camps with EvaluationPoint >= 10, ordered by EvaluationPoint desc, then LatestEvaluationDate asc; rank 1 = places 1-5, 2 = 6-15, 3 = 16-30, 4 = 31-50, 5 = unranked | MEASURED as the stored rule |
| matching join wait | 15 s | READ m:0x79b018 (15.0f) |
| notice title / content | 1..128 / 1..2048 bytes, else 0x6817; the client's box allows 1023 characters of content | READ s:0x5df070; MEASURED box caption "(0/Max.1023)" |

## 3. Persistence

Four tables, column order as stored (the earlier `db_bind_columns.tsv` names them);
MEASURED types:

| table | columns |
|---|---|
| `_TRAININGCAMP` | ID int (identity), CreationDate smalldatetime, Rank tinyint (5 = unranked), GraduateCount int, EvaluationPoint int, LatestEvaluationDate datetime, CommentTitle varchar(129), Comment varchar(2048) |
| `_TRAININGCAMPMEMBER` | CampID, CharID, RefObjID int, CharName varchar(64), JoinDate smalldatetime, MemberClass tinyint, CharJoinedLevel, CharCurLevel, CharMaxLevel tinyint, HonorPoint int |
| `_TRAININGCAMPBUFFSTATUS` | CampID, RecipientCharID, BuffSlotIdx tinyint, DonorCharID, StartingTime smalldatetime, RemainBuffPoint int, BuffType tinyint |
| `_TRAININGCAMPHONORRANK` | Ranking int (1..50), CampID, Rank |

plus a per-character honor bank `(CharID, HonorPoint)` for points that outlive a
membership (an assistant's points when it leaves, is banned, graduates or the camp is
disbanded; spent back into the next membership's HonorPoint when it joins or founds a
camp), and one "last rank update" date (MEASURED).

What the store does (MEASURED as the stored rules; the calls are READ in the shard
manager's query strings):

- **Found:** a camp row (Rank 5, GraduateCount 0, EvaluationPoint 0,
  LatestEvaluationDate = CreationDate = now, empty notice), then the founder added as
  a member.
- **Add member:** refuse if the character is in any camp; class from max level (above);
  refuse a second guardian, a third assistant, a sixth apprentice; JoinDate = now;
  CharJoinedLevel = the character's max level, CharCurLevel its current level,
  CharMaxLevel its max level; HonorPoint = the banked points (bank row removed). Buff rows:
  a guardian or an apprentice gets one `BuffType 0, slot 0` row; a guardian also gets
  `BuffType 3` slots 1..5 and an apprentice `BuffType 3` slot 1, each with
  StartingTime 2000-01-01 and 0 points. MEASURED rows exactly that after a founding
  and an apprentice's join.
- **Remove member (leave / ban / character deleted):** never the guardian. An
  assistant's points are banked (less 10 unless banned); an apprentice's buff rows are
  deleted.
- **Graduate:** an assistant's points are banked; an apprentice's graduation adds the
  honor shares and, if it joined at <= 30, `GraduateCount += 1`, `EvaluationPoint +=
  evaluation`, `LatestEvaluationDate = now`; otherwise only `GraduateCount += 1`. The
  member row and (apprentice) buff rows are removed.
- **Disband:** every assistant's points (> 0) banked; all member rows, the camp row and
  its buff rows deleted.
- **Level refresh:** the member row's CharCurLevel / CharMaxLevel follow the character
  only when its level changes in game (SetLevel, s:0x4e4e13 / s:0x4e4e42). MEASURED: a
  character whose level changed while offline still shows its old levels in the
  member record after logging in.
- **Survives logout and restart:** everything above. Online state, positions and the
  matching board do not (the board entry is dropped when the guardian logs out, READ
  m:0x459b04).

## 4. Opcodes

| op | dir | name | payload | READ (client / server) | MEASURED |
|---|---|---|---|---|---|
| 0x7470 | C>S | open | u32 npc unique id | c:0x821e40 / s:0x518fd0 | yes |
| 0xB470 | S>C | open result | 01 + CampInfo / 02 code [u32 seconds if 0x681c] | c:0x899630 / s:0x5dfd76 | yes |
| 0x7471 | C>S | disband | — | c:0x8220e0 / s:0x519120 | yes |
| 0xB471 | S>C | disband result | 01 / 02 code [u32 seconds if 0x681d] | c:0x899730 | yes (0x681d) |
| 0x7472 | C>S | invite | u32 target unique id | c:0x821f00 / s:0x519230 | yes |
| 0xB472 | S>C | invite result (refusals only) | 02 code | c:0x8997a0 | yes |
| 0x3080 | S>C | invitation box, kind 9 | 09, u32 inviter unique id, str inviter name | c:0x88aa60 / s:0x46c94f | yes |
| 0x3080 | C>S | invitation answer | 01 01 accept / 02 u16 0 otherwise | c:0x788840 case 8 / s:0x46cb30 | yes (accept) |
| 0x7473 | C>S | ban | str member name | c:0x824f80 / s:0x5193a0 | yes |
| 0xB473 | S>C | ban result (and leave's 24 h refusal) | 01 / 02 code | c:0x899800 | yes |
| 0x7474 | C>S | leave | — | c:0x822240 / s:0x519510 | yes |
| 0xB474 | S>C | leave result | 01 / 02 code | c:0x899850 | — |
| 0x7475 | C>S | graduate (self) | u8 evaluation | c:0x822180 / s:0x519600 | — |
| 0xB475 | S>C | graduate result | 01 / 02 code | c:0x8998a0 | — |
| 0x7476 | C>S | graduate a member (guardian) | str member name | c:0x825100 / s:0x519770 | — |
| 0xB476 | S>C | its result | 01 / 02 code | c:0x8998f0 | — |
| 0x7477 | C>S | notice | str title, str content | c:0x824560 / s:0x519900 | yes |
| 0xB477 | S>C | notice result | 01 / 02 code | c:0x899940 | yes |
| 0x7478 | C>S | honor rank list | u32 npc unique id | c:0x8222e0 / s:0x519ad0 | yes |
| 0xB478 | S>C | honor rank list | 01, u8 n, n x HonorRow / 02 code | c:0x89c620 / s:0x5dd29a | yes (empty) |
| 0x747A | C>S | matching register | u32 0, u32 camp id, u8 type, str title (7.10) | c:0x823eb0 / s:0x519b80 | yes |
| 0xB47A | S>C | its result | 01, u32 entry id, u32 camp id, u8 type, str title, u32 graduates / 02 code | c:0x8907f0 | yes |
| 0x747B | C>S | matching modify | u32 entry id, u32 (any), u8 flags, str title | c:0x823f70 / s:0x519bd0 | — |
| 0xB47B | S>C | its result | 01, u32, u32, u8, str / 02 code | c:0x890960 | — |
| 0x747C | C>S | matching delete | u32 entry id | c:0x81d2f0 / s:0x519c20 | yes |
| 0xB47C | S>C | its result | 01, u32 entry id / 02 code | c:0x88df80 | yes |
| 0x747D | C>S | matching list page | u8 page | c:0x81d3b0 / s:0x519c70 | yes |
| 0xB47D | S>C | its result | 01, u8 page count, u8 page, u8 n, n x MatchRow / 02 code | c:0x890ab0 | yes (empty: 01 00 00 00) |
| 0x747E | C>S | matching join request | u32 entry id | c:0x81d470 / s:0x519cc0 | yes (round 866) |
| 0x747E | S>C | the request reaching the guardian | u32 job, u32 requester, u32 entry, u32 requester, u8 level, u8 max level, u32 RefObjID, str name (7.10) | c:0x890fa0 / s:0x5df260, m:0x422230 | yes (round 866) |
| 0x347F | C>S | guardian's answer to it | u32 job, u32 requester, u8 answer (1 Yes, 0 No or the box's 15 s) | c:0x81d530 / s:0x519d10 | yes (round 866) |
| 0xB47E | S>C | join result | 01 u8 s / 02 code | c:0x892c50 / s:0x5e0940 | yes (round 866: 01 00 and 01 01) |
| 0x7483 | C>S | transfer cumulated exp buff | — | c:0x788840 case 9 / s:0x519d40 | — |
| 0xB483 | S>C | accumulated buff list / transfer result | see 5.11 | c:0x89b7b0 / s:0x4e4580 | — |
| 0x3C80 | S>C | academy push (sub-type) | section 6 | c:0x8a2110 | yes (01-0d except 04, 0c) |
| 0x3C81 | S>C | whole camp | CampInfo (no leading byte) | c:0x8986c0 / s:0x4dfc5d | yes |
| 0x3C82 | S>C | own cumulated buff | section 5.11 | c:0x89bcc0 / s:0x4e4410 | — |
| 0x3C86 | S>C | own cumulated buff minutes | u32 minutes | c:0x89bf00 | — |
| 0x3C87 | S>C | accumulated buff minutes | u32 minutes, u32 member key | c:0x89bae0 | — |
| 0x7025 / 0x3026 | both | academy chat, type 0x10 | section 5.12 | | yes |

0x7479, 0x7480..0x7482 and 0x3C83..0x3C85 have no handler on either side (READ: not
in the server's message map, not in the client's three registration lists).

## 5. Records

### CampInfo (READ s:0x5e4230 mask 0xff, c:0x99ace0; MEASURED)

| field | width | value |
|---|---|---|
| camp id | u32 | the camp row's ID (MEASURED: a fresh identity) |
| CreationDate | ts | minute-rounded |
| Rank | u8 | honor rank 1..5, 5 = unranked (client: `com_honor_level_<n>.ddj`) |
| notice title | str | empty when none |
| notice content | str | empty when none |
| count | u8 | members, <= 8 |
| members | count x MemberEntry | guardian first, then in join order (MEASURED) |

### MemberEntry (READ s:0x5e3620 + s:0x5dd0bf..0x5dd13d, c:0x997900; MEASURED)

| # | field | width | client store | notes |
|---:|---|---|---|---|
| 1 | camp id | u32 | +0x00 | |
| 2 | CharID | u32 | +0x04 | the member key every update uses |
| 3 | RefObjID | u32 | +0x08 | the body; drives the 3D head portrait |
| 4 | CharName | str | +0x0c | |
| 5 | MemberClass | u8 | +0x44 | 0 / 1 / 2 |
| 6 | CharJoinedLevel | u8 | +0x46 | not shown |
| 7 | JoinDate | ts | +0x48 | not shown |
| 8 | CharCurLevel | u8 | +0x58 | shown first in "Lv %d(%d)" |
| 9 | CharMaxLevel | u8 | +0x59 | in the parentheses; drives grade and graduation buttons |
| 10 | HonorPoint | i32 | +0x5c | the character window's "Honor Point" |
| 11 | play state | u8 | +0x74 | **0 online, 1 offline** (MEASURED: logout pushes 1, login 0; 1 shows `pt_no_face.ddj`) |
| 12 | world id | u32 | +0x78 | MEASURED 0x00010001 in the open world; 0 while never placed |
| 13 | region | u16 | +0x7c | |
| 14-16 | x, y, z | i16 x 3 | +0x7e..+0x82 | region-local, truncated |
| 17 | display name | str | +0x28 | empty while offline; online: the character name, or its job alias when it wears a job suit (READ s:0x5dd0d8: job state 4 -> name, else nickname). MEASURED a job alias here. The minimap finds the live object by this string. |

Field 11 and the location group are what the member was last known as. MEASURED: a
member entry built for the **other** members when someone joins carries play state **1**
and a zero location (world 0, region 0, 0, 0, 0, empty name) -- both joins measured
(`02 .. 01 01 00000000 01 00000000 0000 0000 0000 0000 0000` for a level-1 joiner, the same
for a level-40 one; stage 2 corrected an earlier "play state 0" here); the joiner's own
copy of itself carries play state 1 and its position; a 0x3C80 05 (field 1 = 0) follows
at once in both cases. Build exactly that. A member's own copy in a 0x3C81 at world entry
also carries play state 1 (MEASURED), its display name possibly empty.

Lane AS (stage 2), from the same measurements, byte by byte: the own entry in a 0x3C81
carries play state **1 at a login** (two logins) but **0 at a teleport** (three teleports:
a member already online stays online; the guardian's own entry in the teleport frame
3c81_world is `.. 00 | 01000100 ..`), and in all five it carries the member's name. The
display name follows the character, not the play-state byte: it is present whenever the
member's character is in the world on the server (the joiner's own copy and a logging-in
member's own entry carry play state 1 with the name); an offline member's entry carries
play state 1, its last-known world, region and x, y, z, and an empty name. The server
builds exactly that; a client reads the byte either way.

### HonorRow (0xB478; READ s:0x5dd29a..0x5dd2f4, c:0x993230)

u32 ranking (1..50), u8 rank, str guardian name, u8 guardian current level, u8
guardian max level, u32 GraduateCount, str guardian's guild name (empty when none).
Only camps loaded on that game server are listed (READ s:0x5e17f0 patches the count).

### MatchRow (0xB47D; READ c:0x890ab0, consumer c:0x773320)

u32 entry id, u32 camp id (MEASURED round 866; not stored), u8 type, str title, u32 the
entry's registration time in Unix seconds (MEASURED round 866: a row read back seconds after
its 0x747A carried that moment; not shown), u8 level, u8
max level, u32 guardian RefObjID (race from it), str guardian name, u32 GraduateCount,
u8 honor rank, u32 assistants, u32 apprentices. The list header before the rows is u8,
u8, u8 n: page count, then page (READ c:0x7738c0 stores them crossed). The server's page layout is
built in the shard manager (OPEN beyond the empty reply and a one-row page). OpenSRO
(stage 2) sends 12 rows a page (the window's rows 70..81, INFERRED); round 866 puts the
camp id and the registration time in the two unread u32s, as MEASURED. MEASURED one-row
page: `01 01 00 01 | <entry> <camp> 01 <title> <time> 46 46 <body> <name> 00000000 05
01000000 01000000` (a level-70 guardian, rank 5, one assistant, one apprentice).

## 6. The 0x3C80 push (READ s:0x5dd4f0.., c:0x8a2110; MEASURED where marked)

First byte is the sub-type. "Members" means the camp's online members on the game
server (BroadcastToLocalMember, s:0x5de1e0).

| sub | after the sub byte | to | when | client effect | MEASURED |
|---:|---|---|---|---|---|
| 01 | — | all members | camp disbanded | `UIIT_STT_TC_DISSOLUTION_SUCCESS`, store cleared, academy windows closed, type-8 buff icons removed | |
| 02 | MemberEntry | members except the joiner | a member joined | adds it; system line `UIIT_MSG_TC_MACHING_JOINING_MEMBER` "[%s] has been added to the Academy." | yes |
| 03 | u32 CharID, u8 reason (1 left, 2 banned, 3 silent) | all members incl. the removed one | removal | self: store cleared + `UIIT_STT_TC_OUT_TRAININGCAMP_ANNOUNCE` (1) or `UIIT_MSG_TC_EXPULSION_RESULT_ANNOUNCE` (2); others: `..._OUT_TRAININGCAMP_OTHER_USER` / `..._EXPULSION_RESULT` "[%s] ..." and the slot removed | |
| 04 | u32 CharID, u8 kind | all members incl. the graduate | graduation | self: `UIIT_STT_TC_GRADUATION_CONGRATULATIONS`, store cleared; others: `UIIT_STT_TC_GRADUATION_ANNOUNCE` "[%s] has graduated." (kind 0 and 1 both; OPEN which is which -- INFERRED 1 for 0x7475 and 0 for 0x7476: the game server's job 4 carries one byte, the self flag, 1 from 0x7475 and 0 from 0x7476, READ s:0x5def20's two callers; OpenSRO sends that) | |
| 05 | u32 CharID, u8 field, value | all members incl. the subject | a member's field changed | field 1 u8 play state (0 online / 1 offline); 2 u8 max level (grade recomputed); 3 u32 honor; 5 str name; 6 u8 current level; 7 u32 RefObjID. The client reads 1, 2, 3, 6 and 7 only: its jump table c:0x6e9674 sends 4 and 5 to the exit, so a field-5 name reaches no display | field 1 both ways |
| 07 | str title, str content | all members | notice changed | stored; banner `UIIT_MSG_TC_COMMON_KNOW_REMIND_UPDATE` "The Academy notice has been updated." | yes |
| 0a | 01 + CampInfo, or 02 u16 code | the invitee only | invitation accepted (or matching join done) / failed | 01: store filled, the academy window opens (c:0x79af70), centre banner `UIIT_STT_TC_JOIN_ANNOUNCE` "Joined Academy."; 02: the code's text only (c:0x8a2fd5 -- the invitation box is left to its own timer) | yes (01; 02 with code 0x000e) |
| 0c | u8 rank | all members | the camp's honor rank changed | rank mark redrawn | |
| 0d | u32 CharID, str display name, u32 world, u16 region, i16 x, i16 y, i16 z | members except the subject | the member's position | location group | yes |

Where each line goes (READ c:0x8a2110, c:0x6e8ed0, c:0x899630..0x899940): the GDR_WARNING_WND
banner (0x77b580) carries `DISSOLUTION_SUCCESS`, `OUT_TRAININGCAMP_ANNOUNCE`,
`EXPULSION_RESULT_ANNOUNCE`, `GRADUATION_CONGRATULATIONS`, `COMMON_KNOW_REMIND_UPDATE` (07 and
0xB477) and `JOIN_ANNOUNCE`; the system message window, type 0 (0x778210 / 0x7781b0(0, ..)),
carries `MACHING_JOINING_MEMBER`, `OUT_TRAININGCAMP_OTHER_USER`, `EXPULSION_RESULT`,
`GRADUATION_ANNOUNCE`, `CONNECT2` / `DISCONNECT2`, `COMMON_KNOW` and `OPEN_SUCCESS`; the
refusals go through 0x778190(0x1d, code).

Sub 05 field 1 on the client: for another member, 0 prints `UIIT_MSG_TC_CONNECT2`
"%s [%s] has logged on to the game." and 1 `UIIT_MSG_TC_DISCONNECT2` "... logged out of
the game.", the first %s being the class title (Guardian / Asst. guardian / Novice
apprentice). MEASURED: "Novice apprentice [name] has logged on to the game.", "Asst.
guardian [name] has logged on to the game.", "Novice apprentice [name] has logged out of
the game.". For the member itself, field 1 = 0 prints `UIIT_STT_TC_COMMON_KNOW` "Academy
Notice “%s”" with the notice title (MEASURED at world entry) -- only when the camp has a
title (READ c:0x6e9223 `cmp [eax+0x4c],esi ; je`: no title, no line). The guardian's log-on is
announced once (c:0x6e8ed0 window flag) and a member's only when its slot was offline
(READ).

### Measured sequences (exact order)

- **Founding:** 0x304E {01, u64 gold} -> 0xB470 {01, CampInfo} (the founder's own
  entry with play state 1) -> 0x3C80 {05, founder, 01, 00}.
- **Invitation accepted:** the inviter's 0x7472 -> the invitee's 0x3080 {09, u32
  inviter unique id, str inviter name} -> the invitee's 0x3080 {01 01} -> 0x3C80 {02,
  MemberEntry} to every existing member -> 0x3C80 {0a 01, CampInfo} to the joiner ->
  0x3C80 {0d, joiner ...} to the existing members -> 0x3C80 {05, joiner, 01, 00} to
  everyone including the joiner. The inviter gets **no** 0xB472 on success (READ
  s:0x5dfe10).
- **Invitation timed out (30 s):** 0xB472 {02, 0e 00} to the inviter and 0x3C80 {0a,
  02, 0e 00} to the invitee, in the same instant; neither client shows any text
  (code 0x000E has no entry).
- **World entry (login, teleport, zone change):** 0x3C81 {CampInfo} to the member,
  right after its own spawn; then 0x3C80 {0d, member ...} to the others and 0x3C80
  {05, member, 01, 00} to everyone including the member. MEASURED on a login and on
  every GM teleport.
- **Logout:** 0x3C80 {05, member, 01, 01} to the others.
- **Notice:** 0x7477 -> 0x3C80 {07, title, content} to every member (the writer
  included) -> 0xB477 {01} to the writer.
- **Moving:** 0x3C80 {0d ...} to the others when a member moves (READ: the same change
  trigger as party positions, CGObjPC::vslot_323 bit 1; MEASURED after walks and
  teleports).

## 7. Requests, rule by rule

Each list is the server's order. "3" etc. are bare codes (the client shows
`UIIT_STT_ERR_COMMON_INVALID_TARGET` for 3, nothing for the others).

### 7.1 Open — 0x7470 {u32 npc}

Client: the NPC menu line "Academy Establishment" (item 0x2D) shows only when the NPC
offers the storage service (its option set holds code 4 on the client, function 3 on
the server), the player is in no academy and its level byte is >= 60 (READ
c:0x700b10..0x700b9d). Clicking it opens `UIIT_MSG_TC_TRAININGCAMP_OPEN` "Fee of 100,000
gold is needed to establish an Academy. Would you like to establish an Academy?" (Yes /
No). Yes: when the player's gold is below 100,000 the client prints
`UIIT_MSG_TC_ERROR_OPEN_GOLD` and sends nothing (READ c:0x6f7b21; MEASURED: no packet);
otherwise it sends 0x7470 with the talk NPC's unique id.

Server (READ s:0x4e4680 then the NPC check): character lock 0x6808; dead 0x6807; level <
60 0x6809; gold < 100,000 (64-bit) 0x680a; already in a camp 0x6812; reopen penalty
(2, 7) 0x681c + u32 seconds left; then the NPC: **any failure answers 3** (CORRECTED
round 865 stage 2, READ s:0x51908e: a result of s:0x4e72a0 other than 1 falls to `push
3`, so its 0x1c0d and the range codes never reach the wire; s:0x519b02 does the same for
0x7478). s:0x4e72a0 needs the NPC in reach (IsWithinInteractionRange, filter 0x146) and
the player **in an interaction with that NPC** (s:0x4dd5d0 on the NPC's +0x1a0 set), then
the NPC's function set must hold 3 (s:0x5190c4). So the client sends 0x7470 / 0x7478
while the NPC talk is open, before its 0x704B. Then the store's founding; on success the fee
is taken and the sequence of section 6 goes out (MEASURED). The client prints
`UIIT_MSG_TC_OPEN_SUCCESS` "An Academy has been established." (READ c:0x899630).

### 7.2 Invite — 0x7472 {u32 target}

Client: the Invite button (guardian only) needs a selected target; it sends the
target's unique id (a COS resolves to its owner, c:0x9ce910), then prints
`UIIT_STT_TC_PROPOSAL_PENDING` "Request for Academy registration to [%s] is in
process." (MEASURED). MEASURED: after Invite with no target the button stays armed
(drawn red) and the next click on a player sends the request.

Server, inviter (READ s:0x4e4800): lock 0x6808; dead 0x6807; no camp 3; not guardian
0x6816; target is self 3; invite penalty (2, 8) 0x681f. Target (s:0x4a8e10): not found
0; farther than 600 4; not a player 3. By the target's current level: <= 39 and 5
apprentices -> 0x6828; 40..59 and 2 assistants -> 0x6810; >= 60 -> 3 (MEASURED: a
level-60 target gets 02 03 00 and the client prints "Invalid object"). Target state
(s:0x4e4890): locked or in an exclusive interaction (trade, stall) 0x6806; dead 3;
entry penalty (2, 9) or (2, 10) 0x681e; already in this camp 0x680f, in another
0x6812. Then the 0x3080 kind 9 box (30 s).

The invitee's box: `UIIT_STT_TC_JOIN_REQUEST` "[%s] has requested for Academy
registration. Approve?" with Yes / No, caption "Join request sent" (MEASURED). Answer:
Yes -> 0x3080 {01 01}; No or closing -> 0x3080 {02, 00 00}. The box is GInterface
0x788270's MsgBoxSimple (360 x 151 at creation), its text set by 0x643250, which sizes the
box to the text (0x6413a0: the text's width + 0x3c by its height + 0x7a, never smaller),
and the box's own timer armed (0x644650, READ c:0x88aba8..0x88ad62). Its timer ending
answers nothing (MEASURED: no 0x3080 from the invitee in either timed-out case; the
server's 0x000E ends it). MEASURED boxes of this kind: the invitation 402 x 167, the
disband question 498 x 168, the leave question 618 x 151, the ban question 754 x 151 (one
text line 151 high, two 167 / 168). Server on the answer (READ
s:0x5df910): inviter gone 0x680c; target gone 3; refused (answer byte != 1) -> 0xB472
{02, 0x6811} to the inviter and 0x3C80 {0a, 02, 0x6811} to the invitee (READ; not what
was MEASURED, below); accepted -> the store adds the member; success per section 6.

MEASURED (round 866, twice): a No answers `3080 {02 00 00}`, and both sides got code **0**,
not 0x6811 -- the inviter `B472 {02 00 00}`, the invitee `3C80 {0a 02 00 00}` in the same
instant -- so neither printed anything (code 0 has no row); the inviter's last line stays
"Request for Academy registration to [name] is in process.". The READ above (s:0x5df910's
`mov eax,0x6811` for an answer byte other than 1) is not what was sent. **OpenSRO follows
the measurement** (round 866, the user's decision): a refusal answers code 0 both ways
(`academy.InviteRefusedCode`) and neither client prints anything; the client's 0x1d table
keeps 0x6811's row ("Invitation has been refused.") as READ.

### 7.3 Leave — 0x7474 {}

Client: a member's own slot button reads "Leave" (`UIIT_CTL_LEAVE_PARTY`) until it may
graduate; clicking asks `UIIT_STT_TC_OUT_TRAININGCAMP` "When you leave the Academy, you
will receive secession penalty. Still leave the Academy?" (MEASURED), Yes sends.

Server (READ s:0x519510): no camp 0x680b (on 0xB474); guardian 0x6816; own record
missing 0x6815; joined less than 24 h ago **0x6821 on 0xB473** (MEASURED: 0xB473 {02 21
68}, text "Leaving the Academy is not allowed for 24 hours after registration.").
Success: 0xB474 {01}; 0x3C80 {03, CharID, 01} to all; penalty (2, 9) 24 h on an
apprentice, (2, 10) 72 h on an assistant (both shown with `NOT_ENTRY_24T`'s text, which
says so); store per section 3.

### 7.4 Ban — 0x7473 {str name}

Client: on the guardian's view a member's button reads "Banish" (`UIIT_CTL_BAN_PARTY`)
until the member may be force-graduated; clicking asks `UIIT_STT_TC_BAN_TRAININGCAMP`
"When you ban an apprentice, you will receive ban penalty(excluding guardian
assistant). Still ban [%s]?" (MEASURED), Yes sends the name.

Server (READ s:0x5193a0): no camp 0x680b; not guardian 0x6816; name not found 0x6815;
self 0x6816; joined less than 24 h ago 0x6820 (MEASURED: 0xB473 {02 20 68}, "Ban is not
allowed for 24 hours after recruitment."); the shard refuses 0x6829 when the target is
busy (m:0x456777; its text `UIIT_STT_TC_BAN_MACHING_ERROR` "To ban, you must first
delete your matching registration."). Success: 0xB473 {01}; 0x3C80 {03, CharID, 02} to
all; when the banned member was an apprentice the **guardian** gets the invite penalty
(2, 8) 24 h; the banned member gets none.

### 7.5 Disband — 0x7471 {}

Client: the guardian's "Dismiss" button (`UIIT_STT_PARTY_DISSOLVE`) on the header row
asks `UIIT_STT_TC_DISSOLUTION` "Disbanding Academy will reset all your honor points and
honor grade. Are you sure you want to disband Academy?" (MEASURED), Yes sends.

Server (READ s:0x4e4780): lock 0x6808; dead 0x6807; no camp 3; not guardian 0x6816;
less than 604,800 s since CreationDate 0x681d **+ u32 seconds left** on 0xB471
(MEASURED). Its other refusals go out on **0xB470** (s:0x5191d0). Success: 0xB471 {01};
0x3C80 {01} to all; the guardian's honor buffs cancelled; reopen penalty (2, 7) 7 days
on the guardian; store per section 3.

### 7.6 Graduation by the member — 0x7475 {u8 evaluation}

Client: the own slot button reads "Graduate" (`UIIT_CTL_TC_GRADUATION`) when an
apprentice's max level is >= 40 or an assistant's >= 60. An apprentice gets the judge
window (10.3) and sends the chosen evaluation (4 very satisfied .. 0 very
disappointed, default 3); an assistant gets `UIIT_STT_TC_GRADUATION` "Graduate from
Academy?" and sends 0.

Server (READ s:0x519600): no camp 0x680b; guardian 5; record missing 0x6815; max level
(GetMaxLevel, the live character) < 40 apprentice / < 60 assistant 0x681a; apprentice
evaluation > 4 -> 5. Success: 0xB475 {01}; 0x3C80 {04, CharID, kind} to all; a
graduating **apprentice** gains 2,000,000 exp; honor shares to the guardian and
assistants each as 0x3C80 {05, CharID, 03, u32 new total}; GraduateCount and
evaluation per section 3. No penalty.

### 7.7 Graduation by the guardian — 0x7476 {str name}

Client: on the guardian's view the member's button reads "Graduate" when its stored
max level is > 40 (apprentice) or > 60 (assistant); clicking asks
`UIIT_MSG_TC_GRADUATION_COMPULSION` "Apprentices(excluding Guardian Assistants) will
not be rewarded when you force graduation. Do you still want to force graduate [%s]?",
Yes sends the name.

Server (READ s:0x519770): no camp 0x680b; not guardian 0x6816; not found 0x6815; self 5;
the member's **stored** max level <= 40 apprentice / <= 60 assistant 0x6822
`POSIBLE_41L`. Success: 0xB476 {01} to the guardian; then as 7.6, with an
EvaluationPoint delta of +1 (the server passes the points value 1 itself, s:0x5198a7)
and **no** exp.

### 7.8 Notice — 0x7477 {str title, str content}

Client: the pencil button (guardian only) opens the shared notice writer in academy
mode ("Notice": "Please enter the title of the note.", "Please enter the contents of
the note.(0/Max.1023)", Completed / Cancel; MEASURED); the window's mode byte 2 titles it
`UIIT_CTL_TC_COMMON` (static 53, READ c:0x70b720); Completed with an empty title or an empty
content prints 0x6817's text through category 0x1d and sends nothing (READ c:0x70b8a3),
otherwise it sends 0x7477.

Server (READ s:0x519900, s:0x5df070): chat-banned -> dropped silently (0x3405 to the
sender); not guardian 0x6816; a `'` or `"` or a filtered word in either -> dropped
silently, no reply; dead 0x6807; no camp 0x680b; not guardian 0x6816; lengths 0x6817.
The first test (TrainingCamp_IsMemberClass0, before the strings are read) answers 0
for no camp too, so a **non-member is refused 0x6816**, not 0x680b (READ s:0x519900).
Success per section 6. Members who log in later see the title in their system line at
world entry (MEASURED).

### 7.9 Honor rank list — 0x7478 {u32 npc}

Client: the NPC line "Honor Rank" (item 0x2E) is offered by every storage keeper, member
or not (READ c:0x700b73; MEASURED). Server: the NPC must be in range and have function
3, else 02 03 00. Reply 0xB478 {01, u8 n, rows}; MEASURED with no ranked camp: `01 00`
and the window opens empty.

### 7.10 Matching board — 0x747A..0x747F

- The academy window's "Matching" button opens "Guardian Matching" for anyone (MEASURED;
  a non-member uses it to apply). The client asks 0x747D page 0 when it opens (MEASURED
  `747D 00` -> `B47D 01 00 00 00`).
- Register (guardian only): "Registration" opens a box with two checkboxes
  "Apprentice Recruitment" / "Asst. Guardian Recruitment" and a title (MEASURED). The
  client refuses an empty title (`UIIT_STT_TC_MACHING_TITLE_ERROR`) and a full role
  (`..._STUDENT_COUNT_OVER` / `..._SECOND_GUARDIAN_COUNT_OVER`) itself. Flags: bit 0
  apprentices, bit 1 assistants (READ m:0x45a0dc). MEASURED: `747A 00000000 <camp id>
  01 "Join us"` -> `B47A 01 <entry id 1> <camp id> 01 "Join us" 00000000`, banner
  `UIIT_STT_TC_MACHING_ENTRY` "Academy has been registered to the matching system.", and
  the list shows the camp's own row: No. 1, level 70, race CHN, the guardian's name,
  the title, graduates 0, members "3/8", grade (5).
- Server checks (READ s:0x4e4950): lock 0x6808; job suit 0x6823; no camp 0x6824; not
  guardian 0x6816; invite penalty 0x681f; already registered 0x6825 (m:0x45808e).
- Modify 0x747B / delete 0x747C: guardian only; delete MEASURED `747C <entry id>` ->
  `B47C 01 <entry id>`. The board drops an entry when the camp fills
  (`UIIT_STT_TC_MACHING_PULL_DELETE`) and when the guardian logs out.
- Join 0x747E {u32 entry}: refusals 0x6808, 3, 0x681e, 0x6812 (game server), then the
  shard: role by max level, caps, flags (0x682a), one pending request per entry
  (0x6827), guardian online (0x680c), then a 15 s wait for the guardian's 0x347F. The
  result 0xB47E {01, u8 s}: 1 `UIIT_STT_TC_MACHING_COMPLETE`, 0 `UIIT_MSG_TC_JOIN_CANCEL`,
  2 `UIIT_MSG_TC_JOIN_NOREPLY`. The joiner then gets 0x3C80 {0a 01, CampInfo} as in an
  invitation.
- **The guardian's question (round 866, READ and MEASURED both sides).**
  - Requester: Join sends 0x747E {entry} and opens the joining window in the academy's
    mode (c:0x77011d pushes kind 2 to c:0x732000): caption "Joining"
    (`UIIT_PAG_PARTYMATCH_JOINPROGRESS`), text `UIIT_MSG_TC_JOIN_ERROR_DUPLE` "Registration
    is in process." (c:0x73201c), the gauge 0x3a98 ms = 15 s (c:0x7323fa), not the party's
    `UIIT_STT_PARTYMATCH_JOIN_PROGRESS` (kind 1, 10 s). MEASURED: "Registration is in
    process." with the gauge.
  - The game server writes {u32 entry, u32 requester, u8 level, u8 max level, u32 RefObjID,
    str name} (s:0x5df260 -> s:0x5e2c80) and the shard puts its job id and the requester in
    front (m:0x422230, as for a party's 0x706d). MEASURED: `<job> <key> <entry> <key> 1e 1e
    <body> <name>` for a level-30 requester, the two keys equal (the requester's account
    id) and the job ids counting up by one per request. OpenSRO's key is
    `party.JIDOf(CharID)`, as its party matching's.
  - Guardian: c:0x890fa0 reads it (the two u32s into the record's +0x2c / +0x30, then
    c:0x88f4d0) and opens CMessageBoxManager box kind 0xe (c:0x77f0a0; UI_SILKMALL::
    FUN_00644c90 case c:0x6458c6): section MsgBoxINIF at screen w / 2 - 0x9a, h / 2 - 0x4a,
    titled `UIIT_PAG_PARTYMATCH_JOINREQUEST` "Join request sent", 0x168 x 0xd7; OK (0x65,
    0xae), Cancel (0xbd, 0xae), +0x808 hidden; a one-line text control 0x140 x 0x10 at (0xe,
    0x3b) with `UIIT_STT_TC_JOIN_REQUEST` and the name; "Level" (`UIIT_CTL_WARENETWORK_
    RESULT_LEVEL`) at (0xf, 0x79) and "Race" (`UIIT_CTL_PARTYMATCH_PSEARCH_LIST_RACE`) at
    (0xb5, 0x79); two `msgbox_blackbox.ddj` fields 0x3a x 0x14 at (0x62, 0x79) "%d(%d)" and
    (0x108, 0x79) the race; timer 0xa, 15 s. MEASURED: "[name] has requested for Academy"
    (the line's rest and "Approve?" cut by the one-line control), "Level 30(30)", "Race
    CHN", Yes / No. One box of a kind at a time (c:0x6ec400).
  - The answer 0x347F {job, requester, u8}: Yes 1; No and the box's own timer 0
    (c:0x63bf40 -> 0x777dd0 -> 0x797d90 case 0xe, c:0x798081..0x7980c2). MEASURED: No ->
    0x347F {.., 00}; no click -> 0x347F {.., 00} 15.0 s after the question.
  - Results (MEASURED): 0 -> the requester 0xB47E {01 00}, "Request has been cancelled."
    (type 4), the joining window closed; the guardian nothing. The no-reply case therefore
    shows "Request has been cancelled." too, because the guardian's box answers before the
    shard's 15 s (m:0x79b018) end; the shard's own `{01 02}` reaches a requester only when
    the guardian's client does not answer. 1 -> the guardian gets 0x3C80 02 (the new
    member), 0d, 05 (field 1 = 0) and then 0xB47E {01 01}; the requester 0x3C80 {0a 01,
    CampInfo}, 05 and then 0xB47E {01 01}; both show "Registration has been completed."
    on the banner, the guardian also "[name] has been added to the Academy." and "Novice
    apprentice [name] has logged on to the game.", the requester "Academy Notice “title”"
    and its academy window opens. The matching window's rows are not refreshed (the
    guardian's own row kept "3/8").
  - OpenSRO (round 866): the server sends the question and acts on 0x347F
    (`session/academyboard.go`); only the camp's guardian may answer its job, with the
    job's requester echoed (OURS, as the party matching); a failed accept answers 0xB47E
    {02, code} to both (INFERRED from m:0x459b30's two sends). Its own backstop is 17 s
    (OURS: the shard's 15 s plus 2 s, so the guardian's box answers first, as MEASURED).
- The client's side, READ in stage 2 (CIFMentorMatch, Create c:0x770910; the register box
  c:0x7693d0 / c:0x640660, its OK c:0x76fcc0):
  - the register box's two checkboxes are exclusive (0x63c150 / 0x63c170), the apprentice
    one on at open; the byte sent is a **type**, 1 apprentices, 2 assistants, 0 neither
    (c:0x63c1c0) -- never 3; the shard reads it as the bit set above, so 1 and 2 agree;
  - 0x747A's second u32 is the camp id (camp+0, c:0x76fdcb), its first 0; 0x747B's first
    is the own entry's id (c:0x76ff47); a modify starts with an empty title;
  - 0xB47A's last u32 is stored as the own entry's Graduate count (own+0x14, c:0x7738e0),
    the rest of the own row built from the camp record (c:0x775bc0);
  - 0xB47D's header is u8 page count, then u8 page; a row 0 carrying the player's name
    becomes the own entry, pinned in row 0 (c:0x7747c0, c:0x770bc0);
  - Delete sends 0x747C {own id} with no question (c:0x769510); 0xB47C with the own id
    clears the own entry, and with no page held the page is asked for again (c:0x88df80);
    the client deletes its own entry itself when a join fills the role it recruits
    (c:0x76f7b0, called at c:0x8a242b) -- the case that shows `..._PULL_DELETE`;
  - enabling (c:0x76f430): Join with no own entry, below level 60 and rows shown;
    Whisper with rows; Registration in an academy, level 60 or more, the guardian, no own
    entry and a role not full; Change and Delete with an own entry; Search always;
    Refresh asks the spin's page and locks itself 2000 ms (c:0x769f70).

### 7.11 Exp buffs (partly OPEN)

- Buff icons: type 7 = the member's own **cumulated** buff (`UIIT_CTL_TC_SAVE_BUFF`,
  "Cumulated Size: %d P"), type 8 = an **accumulated** buff received from a member
  (`UIIT_CTL_TC_RESERVE_BUFF`, donor name + "Accumulated Size"). Art
  READ c:0x7ff360..0x7ff382: kind 7 draws `icon\skill\etc\tc_reserve_buff.ddj`, kind 8
  `icon\skill\etc\tc_amends_buff.ddj`.
- Guardian and apprentices bank part of their kill exp while their buff runs: pct =
  min(30, trunc(A / B x 100 x 0.1)) (READ s:0x4eaaaf; A, B OPEN). A buff lasts 1,440
  minutes from its StartingTime; the remaining minutes go out as 0x3C86 {u32} every 10
  minutes and every minute below 11 (READ s:0x4eb860). An apprentice reaching level 40
  ends it (READ s:0x4e4e2c).
- Transfer: a member clicks its own type-7 icon with at least 60 minutes on it,
  confirms `UIIT_CTL_TC_PASS_BUFF` "Transfer cumulated experience points to Guardian?",
  and the client sends 0x7483 {}; guardian offline -> 0xB483 {02}
  (`UIIT_MSG_TC_PASS_ERROR`); else the guardian receives a type-4 donated slot and
  0xB483 {00, u8 n, n x {u32 minutes, u32 donor CharID, u32 points}} printing
  `UIIT_MSG_TC_RECIEVE_BUFF` "Received accumulated buff from [%s]." At world entry a
  member with donated slots gets 0xB483 {01, u8 n, same rows} (READ s:0x4dfd15).
- 0x3C82 {u8 sub; 0/1/7: u32 minutes, u32 points; 5/8/9: nothing} sets the own type-7
  icon (7 also prints `UIIT_CTL_TC_SAVE_BUFF_TIME_OVER`; READ c:0x89bcc0). Which sub the
  server sends when, and the banking formula, are OPEN (section 16).

### 7.12 Academy chat — 0x7025 type 0x10

MEASURED: the client strips the leading `&` and sends `7025 {10, u8 index, str text}`;
the server answers `B025 {01 10 <index>}` and sends `3026 {10, str sender name, str
text}` to **every online member including the sender**, the result first (MEASURED
order). On OpenSRO's wire these are its own chat messages OpChatSend / OpChatResult /
OpChatUpdate (0x00A5..0x00A7) with type 0x10, as for every other channel: the update's
bytes are 3026's, the result is OpenSRO's {ok, type, index, u16 code, str}. The receiver shows
"name(Academy):text" in 0xff64c7ff (MEASURED colour light blue; OpenSRO's chat already
formats this). The retail client refuses to send outside an academy with
`UIIT_MSG_TC_ERROR_NOT_POSITION` (READ 0x7ad400); the server's own refusal is 0x200f
(READ s:0x4b1dbf). Route: the game server relays through the shard to every game
server holding members (READ s:0x5de760).

## 8. Penalties (timed jobs, category 2)

| id | length | given to | when | blocks | refusal |
|---:|---:|---|---|---|---|
| 7 | 604,800 s | the guardian | disband succeeded | founding | 0x681c + u32 seconds |
| 8 | 86,400 s | the guardian | banned an apprentice | inviting, matching register | 0x681f |
| 9 | 86,400 s | the apprentice | left | being invited, matching join | 0x681e |
| 10 | 259,200 s | the assistant | left | being invited, matching join | 0x681e |

READ: CTJ_PenaltyKeeper::Create's jump table s:0x00651d00; the check helpers s:0x411440
/ s:0x4114d0 on the character's list at +0x1dfc; the timed-job manager polls every 10 s
(docs/protocol/timed_jobs.md). They persist with the character's timed jobs. OpenSRO
has `server/internal/timedjob` for them.

## 9. Honor

- **Points:** per member (HonorPoint), earned only by the guardian and assistants
  through apprentice graduations (section 2), shown in the character window as "Honor
  Point" (`GDR_PI_HONOR_DATA`; `UIIT_STT_TC_CAMP_NOT_JOIN` "N/A" outside an academy;
  READ c:0x6b8aab).
- **Spending:** the honor store. MEASURED: the storage keeper's store line "Purchase/
  Sell Honor Items" (a normal store line from its shop tabs) opens a
  store with an "Honor ..." and an "Alchemy Stone" tab; an item's tooltip shows "Price:
  46000000Gold" and "Honor Point : 2500P", and honor items carry "Available Number of
  Repair (5time/times)". MEASURED: 32 store packages carry an honor-point price (payment
  device 32), from 10 to 8,000 points; 16 of them are sold, in `STORE_<race>_HONOR_TAB1/2`
  (round 865 stage 3: the other 16, the `_09_` honor weapons and one repair stone, are on no
  store tab), so the mall CSV holds 16 `npchonor` rows. **Who sees the line** (round 865
  stage 3): READ c:0x700a6f..0x700a93 -- at an NPC offering 1 and 3 without 0x0f (a storage
  keeper) the store lines are added only when c:0x989d20(the player's own name) is true,
  and c:0x989d20 compares that name with the camp record's guardian name (camp block
  +0x18): **only the academy's guardian** gets the keeper's store lines. MEASURED: a
  level-60 non-member at the honor keeper saw "1. Deposit into storage. 2. Academy
  Establishment 3. Honor Rank 4. End conversation.", the guardian "1. Purchase/ Sell Honor
  Items 2. Deposit into storage. 3. Honor Rank 4. End conversation." OpenSRO keeps a
  keeper's store lines for everyone (OURS since round 513, `npc_service_reader.gd`); the
  user decides. READ: an honor
  price above the member's HonorPoint refuses with 0x18d4 (s:0x617629); the store
  deducts it (payment device bit 32). Honor items cannot be disjointed or take the
  repair-count option except on honor items (`TC_ERROR_NOT_RONDO_HONOR_ITEM`,
  `TC_ERROR_ENCHANT_HONOR_ITEM` 0x5425, docs/protocol/alchemy.md).
- **On OpenSRO's wire** (round 865 stage 2, OURS like the guild goods' refusals): the
  NPC store's buy answers on OpenSRO's OpShopBuyResult with a reason string, so the
  honor refusal is the client's own text for `UIIT_MSG_TC_LACK_HONOR_POINT`, "Selected
  item cannot be purchased due to insufficient amount of honor points.", which the
  client maps back to the key; the gold refusal comes first. The honor prices travel in
  the mall CSV's `npchonor` rows (item id, points), as the guild goods' `npcgp`.
- **Rank:** per camp, daily (section 2). The guardian alone gets cumulative skills by
  rank: 4 `SKILL_TC_COPPER_BUFF_01`; 3 adds `SILVER`; 2 adds `GOLD`; 1 adds `CROWN`
  (READ s:0x5dd9b0, table s:0xc6748c); re-applied at the guardian's world entry, on a
  rank change (0x3C80 0c) and on revival; cancelled at disband. Their effects are the
  skill rows' own params (OpenSRO's skill data). Shown as the honor grade mark
  `com_honor_level_<rank>.ddj` in the academy window, the ranking and the matching list.

## 10. Client windows

All rects are the layout files' (`Media.pk2` `resinfo\...`).

### 10.1 The academy window — `ifapprenticeship.txt`, CIFApprenticeShip (Create c:0x6e9770)

Opened by the key **L** (`UIIT_CTL_TC_SHORTKEY_L` "Academy ( L )"), by the main popup's
academy pane, and automatically when the player joins (MEASURED). The pane is the main
popup's (GDR_MAINPOPUP, registry rect 595,262,388,408), so it sits where the popup does: x by
the tab (0x50 from the left for the academy tab), y the registry's 262 -- unless the
client's `Setting\wndpos.dat` holds a saved place (round 865 stage 3, READ: CGInterface::Create
c:0x78c910 calls c:0x79eb20, which reads version 3, count 10 and the screen size the file was
written at, and only when that equals the current screen moves ten windows -- registry IDs
0x19 the main popup, 0xf, 0x13, 0x1a, 0x1c, 0x78, 0x20, 0x2c, 0x87, 0x85 -- to their saved
x, y; c:0x79e620 writes the file at c:0x788180). MEASURED: the popup drawn at y 416 of 1024
where that file held y 416 for it; the earlier "(82, 442)" was a measurement 22 px off (the
whole frame was offset). OpenSRO has no saved window places: its popup starts at 262.

| id | control | rect | art / text | behaviour (READ) |
|---:|---|---|---|---|
| 1 | FRAMEL CIFSubFrame | 0,0,364,303 | `frame\sframe_wnd_`, `UIIT_CTL_TC_MEMBER` "Academy Member" | |
| 2 / 3 | BGTILE_0 / _1 | 16,36,332,33 / 27,300,308,4 | `com_bg_tile_b` / `_a` | |
| 10 | DECO_ICON_FRAME | 6,30 | `party\pt_icon_frame` | |
| 14 | LEADER | 33,27 | `ifcommon\com_pt_leader` | the star before the guardian's name (MEASURED) |
| 15 | LEADER_RANK_MARK | 53,46,16,16 | `ifcommon\com_honor_level_<camp rank>.ddj` | shown when a guardian exists |
| 41 | PICTURE | 9,33,28,28 | the guardian's 3D head (64x64 render, "Bip01 Head") | |
| 46 | LEADER_STATUS | 9,33,28,28 | `party\pt_no_face.ddj` when the guardian is offline | |
| 42 / 43 / 44 / 45 | name / "Lv" / "%d(%d)" / title | 71,46,83,17 / 156,46,14,17 / 172,46,19,17 / 201,46,104,17 | | title `Guardian` when its grade is 7 |
| 48 | DISSOLVE_APPRENTICESHIP_BTN | 316,38 | `party\pt_button`, "Dismiss" | guardian only enabled (MEASURED greyed for others); 7.5 |
| 30..36 | SLOT_0..SLOT_6 CIFApprenticeShipSlot | 2, 69 + 33 i, 360, 36 | SLOT_0/1 `pt_slot_co.ddj` (blue), SLOT_2..6 `pt_slot_re.ddj` | assistants fill SLOT_0.., apprentices SLOT_2.. in join order (MEASURED) |
| 40 | SLOT_MSGBOARD | 0,304 | `party\pt_msg` | |
| 63 | NOTIFY_SUBJECT_STATIC | 12,315,38,13 | `UIIT_CTL_TC_COMMON` "Notice" | |
| 61 | NOTIFY_SUBJECT CIFSelectableArea | 4,306,358,28 | `guild\gil_windo02_off.ddj` over the whole rect, `gil_windo02_on.ddj` under the pointer (round 867, READ c:0x6e99f8..0x6e9aa1; selected art `_on` too, never used); text inset 0x50,7 (c:0x6e9ac0): the title, or `UIIT_MSG_GUILD_COMMON_NOTEXIST` "You have no notes.", "" after the reset | click toggles 140 when a title exists (c:0x6e9690: the NotifyContents section made, or destroyed); MEASURED: orange (140,82,0) at 84..337 x 310..326 only while the pointer is on it, not while 140 is open |
| 62 | NOTIFY_EDIT_BTN | 338,308 | `stall\stl_edit_button` | guardian only; 7.8 |
| 140 | NOTIFY_CONTENTS CIFGuildNotifyContents | 0,102,364,201 | `inventory\int_window_` | hidden at create; its children moved by Create for the academy (c:0x70b210, round 867): black square (1) 12,13,342,149 (under BG_01, not seen); BG_01 (2) 10,8,344,180; BG_02 (3, black) 10,11,332,139; scroll (5) 326,28,16,92, length 0x5c; Confirm (4) 142,168; text (6) 23,27,293,109, pitch 18, 6 lines shown; content (c:0x70b050) sets the scroll's range to lines - 6 and the first line shown to 0; one line per arrow or wheel step (MEASURED) |
| 20 | BTN_INVITE | 56,339 | `com_button`, "Invite" | guardian only enabled; 7.2 |
| 22 | BTN_MATCH | 230,339 | `com_button`, "Matching" | opens 10.5 |

Message map c:0xeb9af0. Refresh c:0x6e9b00 clears the slots, then fills; no academy ->
reset (c:0x6e8c30).

### 10.2 The member slot — `ifapprenticeshipslot.txt` (fill c:0x6eab30, click c:0x6eb0f0)

| id | control | rect | content |
|---:|---|---|---|
| 9 | PICTURE | 2,4,28,28 | the member's 3D head |
| 20 | STATUS | 2,4,28,28 | `pt_no_face.ddj` when offline (MEASURED: blue face) |
| 10 | RANK_MARK | 44,14,16,16 | `ifcommon\com_icon_level_<grade>.ddj` |
| 11 / 12 / 13 | name / "Lv" / "%d(%d)" | 63,14,80,17 / 145,14,14,17 / 161,14,19,17 | current(max) |
| 14 | RANK_NAME | 199,14,104,17 | the grade title |
| 18 | BTN_EXITFROMAPPRENTICESHIP | 314,7 | see below |

**Grade** (computed by the client from class and the max level +0x59, never sent; READ
c:0x98e120): apprentice 1..10 -> 1 `FIRST_STUDENT` "New apprentice", 11..20 -> 2
`STUDENT` "Novice apprentice", 21..30 -> 3 `SECOND_STUDENT` "Junior apprentice", >= 31
-> 4 `THIRD_STUDENT` "Senior apprentice"; assistant 40..49 -> 5 `FIRST_GUARDIAN` "Novice
guardian", >= 50 -> 6 `SECOND_GUARDIAN` "Junior guardian"; guardian >= 60 -> 7
`GUARDIAN`. MEASURED: level 1 apprentice "New apprentice", level 40 assistant "Novice
guardian".

**The button** (READ c:0x6ead69): the guardian sees "Graduate" for an apprentice whose
max level > 40 or an assistant > 60, else "Banish"; a member sees on its own row
"Graduate" at >= 40 / >= 60, else "Leave"; every other row's button is **hidden**
(ShowWindow(0) at c:0x6eaee7; MEASURED on an apprentice's view: no button on the
assistant's row). Clicks per
7.3, 7.4, 7.6, 7.7 (message-box types 100..103, c:0x6ea7e4). MEASURED: guardian sees
"Banish" on a level-1 apprentice and a level-40 assistant; the apprentice sees "Leave".

### 10.3 Guardian evaluation — `ifapprenticeshipjudge.txt`, "ApprenticeShipJudge" (c:0x808740)

A CIFMainFrame (RTTI) framed by the registry entry GDR_APPRENTICESHIP_JUDGE (ginterface ID
155, 420 x 174, `msgbox2_window_`), whose Text `UIIT_STT_TC_APPRAISAL_GUARDIAN` "Guardian
Evaluation" is the caption (READ). The radio's geometry (READ c:0x8087a1..0x8087d8): origin
(0, 0), pitch 0x46, the label 0x14 right of the dot, left-aligned, 0x50 wide, five in a row.
Controls: 1 BLACKSQUARE 15,44,391,72; 4 BG_01 10,40,394,126 `com_bg_tile_b`; 5 BG_02
15,44,391,72 `com_bg_tile_e`; 20 RADIOBUTTON 34,59,406,40 with five items "Very
satisfied", "Satisfied", "Average", "Disappointed", "Very disappointed" (index 1
selected at open; index -> byte 4, 3, 2, 1, 0; c:0x80867c); 30 BTN_CONFIRM 128,132
"Evaluate" -> 0x7475 {byte} and close; 31 BTN_CANCEL 216,132 closes.

### 10.4 Honor ranking — `ifapprenticeshiphonorranking.txt`, "ApprenticeShipHonorRankWnd"

Registry entry GDR_APPRENTICESHIP_HONOR_RANK (ginterface ID 154, 512 x 386, `msgbox2_window_`,
Text `UIIT_STT_TC_HONOR_RANKING`; a CIFMainFrame). The LEVEL cell is "%d(%d)%s" with the
`UIIT_STT_LEVEL_LV` text after the numbers (READ c:0x8082b1). MEASURED: the window's left edge
centred: READ c:0x79ac50 (called by the openers c:0x79d180 and, for the matching window,
c:0x79c420) moves the window to (screen width / 2 - width / 2, screen height / 2 - height / 2)
from its own size. The earlier "22 below centred" was the same 22 px measuring offset as the
academy window's (round 865 stage 3).
Opened by 0xB478 success. MEASURED: title "Honor Rank", columns Rank, Grade, Guardian,
Level, Graduate, Guild, a page spin "1", Confirm. READ: header buttons 20..25, rows
30..39 (`ifapprenticeshiphonorslot.txt`, 475 x 24 at y 74 + 23 i), 10 rows a page
(pages = ceil(n / 10)), spin id 4, Confirm id 3. Row: rank "%d"; grade icon
`com_honor_level_<rank>.ddj`; guardian name; "%d(%d)" + "Lv" (current, max);
graduates "%d"; guild or `UIIT_STT_NO_GUILD`.

### 10.5 Guardian matching — `ifmentormatch.txt` / `ifmentormatchslot.txt`, "MentorMatch"

MEASURED: title "Guardian Matching"; a search row "Name [ ] Honor Grade [All v]
Condition [All v] Search Refresh"; columns No., Level, Race, Name, Title, Graduate,
Member, Honor Grade; buttons Join, Whisper, page "< 1 >", Registration, Change entry,
Delete entry. READ ids: 15 JOIN, 16 WHISPER, 18 REGISTER, 19 MODIFY, 20 DELETE, 25 page
spin, 26 scroll, 47 name edit, 45 honor grade combo, 46 condition combo, 55 SEARCH, 56
REFRESH, headers 60..67, rows 70..81 (715 x 24 at y 144 + 23 i), 200 join progress, 105
the register box (CIFPartyMatchRegister). Row columns: No. = entry id; Level "%d" or
"%d(%d)"; Race from the RefObjID; Name; Title; Graduate; Member "%d/8" = assistants +
apprentices + 1; Honor Grade icon + "(%d)".

### 10.6 Elsewhere

- **NPC menu** (storage keepers): "Academy Establishment" (7.1), "Honor Rank" (7.9);
  MEASURED orders: a level-60 non-member at one keeper "1. Deposit into storage. 2.
  Academy Establishment 3. Honor Rank 4. End conversation."; a member at the keeper with
  the honor store "1. Purchase/ Sell Honor Items 2. Deposit into storage. 3. Honor Rank
  4. End conversation.". `UIIT_STT_TC_SPECIAL_BUY` and `UIIT_STT_TC_TRADE_PRACTICE` have
  no menu case in the client (READ c:0x6fd394; not shown).
- **Character window:** "Honor Point" / its value (9).
- **Chat:** the "&Academy" tab and `&` prefix (7.12; `hud_chat.gd` has them).
- **Minimap / world map:** every other member who is online and in the same world (+0x78
  equals the player's world) gets `interface\minimap\mm_sign_apprenticeship.ddj` inside
  the radius and `mm_sign_apprenticeshiparrow.ddj` at the edge outside it; position from
  the live object found by the display name, else the record's region and x, y, z
  (READ c:0x663bc2..0x663f2a); the academy loop runs before the party's, with the party's
  47.0 rim and 1920-unit tiles; the dot's corners are +-4.0 (8 x 8), the arrow's +-16.0
  (0xda0ef8 / 0xe1b8e0: 32 x 32, where the party arrow's are +-8.0); the world map draws
  `wmap_sign_apprenticeship.ddj` the same
  way (c:0x61eec0).
- **Buff bar:** the type-7 / type-8 icons and tooltips (7.11).
- **HUD hint:** an element with sound "snd_quest" shown while the player is in no academy
  and below level 40, re-evaluated on level-up (READ c:0x765330; which control OPEN,
  `ub_new_icon_apprenticeship` INFERRED).
- **Character select:** the list record's academy byte is **2 for the guardian, 1 for
  an assistant or an apprentice, 0 for none** (MEASURED on all three; the delete box
  picks `..._STUDENT` / `..._GUARDIAN` from it, READ c:0x858b66).

## 11. Error codes and their text (READ c:0x7bbe14, category 0x1d)

| code | text id | English |
|---|---|---|
| 3 | `UIIT_STT_ERR_COMMON_INVALID_TARGET` | "Invalid object" (MEASURED) |
| 0x6807 | `UIIT_MSG_TC_ERROR_DIE_PASSING` | Registration approval process cannot be proceeded when dead. |
| 0x6809 | `..._OPEN_LEVEL` | Academy cannot be established because you do not meet the level requirements. |
| 0x680a | `..._OPEN_GOLD` | Academy cannot be established due to insufficient amound of gold. |
| 0x680b | `..._TRAININGCAMP_NOTHING` | Academy does not exist. |
| 0x680f | `..._TRAININGCAMP_ALREADY_ENTRY` | You are already registered to an Academy. |
| 0x6810 | `..._SECOND_GUARDIAN_COUNT_OVER` | You have exceeded maximum number of Assistants Guardian. |
| 0x6811 | `..._INVITE_REJECTION` | Invitation has been refused. |
| 0x6812 | `..._OTHER_TRAININGCAMP_ENTRY` | The user belongs to another Academy. |
| 0x6813..0x6816 | `..._ORDER_WORK` | Requested operation has failed. |
| 0x6817 | `UIIT_MSG_GUILD_COMMON_NOTEXIST` | You have no notes. |
| 0x681a | `..._GRADUATION_LEVER` | Your level does not meet the required level for graduation. |
| 0x681c | `..._NOT_OPEN_7D` | Academy establishment will not be allowed for next 7 days after Academy disbandment. |
| 0x681d | `..._NOT_DISORGANIZATION_7D` | Academy disbandment will not be allowed for next 7 days after Academy establishment. |
| 0x681e | `..._NOT_ENTRY_24T` | After leaving the Academy, Guardian Assistants will not be allowed to rejoin an Academy for 72 hours, and 24 hours for Apprentices. |
| 0x681f | `..._NOT_INVITE_24T` | Recruitment is not allowed for 24 hours after ban. |
| 0x6820 | `..._NOT_BAN_24T` | Ban is not allowed for 24 hours after recruitment. (MEASURED) |
| 0x6821 | `..._NOT_OUT_24T` | Leaving the Academy is not allowed for 24 hours after registration. (MEASURED) |
| 0x6822 | `..._POSIBLE_41L` | Forced graduation is possible from level 41. |
| 0x6823 | `..._JOB_DRESS` | Registration is not possible during equipment and unequipment of job items. |
| 0x6824 | `..._NOT_POSITION` | You do not belong to an Academy. |
| 0x6825 | `..._ALREADY_OPEN` | Academy has already been established. |
| 0x6826 | `..._NOT_INFORMATION` | No Academy information has been registered. |
| 0x6828 | `..._STUDENT_COUNT_OVER` | You have exceeded maximum number of Apprentice. |
| 0x6829 | `UIIT_STT_TC_BAN_MACHING_ERROR` | To ban, you must first delete your matching registration. |
| 0x682a | `..._INVITE_TYPE_DIFFERENT` | Cannot join due to different recruitment type. |
| 0x6808, 0x680c..0x680e, 0x6818, 0x6819, 0x681b, 0x6827, 0, 2, 4, 5, 0x000e, > 0x682a | (none) | nothing is printed |

Where each is sent from: section 7, in each request's order. The shard's
own: 0x680c inviter / guardian offline, 0x680d requester not found, 0x6813 / 0x6814 store
failures, 0x6819 camp busy, 0x6825..0x6827 board, 0x682a role not recruited (m:).

## 12. What other players see

Nothing academy-related above a character: no mark on the name plate, nothing in the
spawn record (READ: no academy field in 0x3015 / 0x3013 on either side; the only
readers of the server's camp pointer are academy, exp and chat code; MEASURED: plates
show the name, job icon and guild only). Members see each other on the minimap and
world map (10.6) and in the academy window.

## 13. Multiplayer, in one table

| event | the actor | other online members | everyone else |
|---|---|---|---|
| found | 0x304E, 0xB470, 0x3C80 05 | — | — |
| invite | system line; 0xB472 on refusal | the invitee: 0x3080 kind 9 | — |
| join | (invitee) 0x3C80 0a 01 + 05 | 0x3C80 02, 0d, 05 | — |
| world entry | 0x3C81, 0x3C80 05 | 0x3C80 0d, 05 (0 = online) | — |
| logout | — | 0x3C80 05 (1 = offline) | — |
| move | — | 0x3C80 0d | — |
| level / model / name / honor change | 0x3C80 05 | 0x3C80 05 | — |
| notice | 0x3C80 07, 0xB477 | 0x3C80 07 | — |
| chat | 0xB025, 0x3026 | 0x3026 | — |
| leave / ban | 0xB474 / 0xB473, 0x3C80 03 | 0x3C80 03 | — |
| graduate | 0xB475 / 0xB476, 0x3C80 04 (+05 honor) | 0x3C80 04, 05 | — |
| disband | 0xB471, 0x3C80 01 | 0x3C80 01 | — |
| rank change | 0x3C80 0c | 0x3C80 0c | — |

## 14. OpenSRO today (before stage 2)

- `server/internal/academy`: the rule constants and validators (open, disband, ban,
  leave, invite role / caps, penalties, graduation constants from round 865). No store,
  no handlers.
- `server/internal/proto/opcodes.go`: every academy opcode named (round 865).
- `server/internal/session/chat.go`: type 0x10 refused with the OURS code 0xf002
  (`ChatErrNoAcademy`) because the client holds no academy state.
- `server/internal/session/lobby.go` / `client/scripts/net/lobby.gd`: the char-select
  academy byte, always 0.
- `server/internal/persistence/schema.go`: the four tables named, no columns created.
- Client: the academy pane in the main popup (`hud_main_popup.gd`, `hud_panels.gd`,
  key L in `keymap.gd`) shows the empty layout; `hud_chat.gd` has the &Academy tab and
  the `&` prefix; `npc_service_reader.gd` offers "Academy Establishment" from level 60
  with the membership byte taken as 0 and "Honor Rank"; `party_map_marks.gd` leaves the
  academy marks unbuilt.

**Stage 2, the server (round 865, lane AS).** `internal/academy`: `store.go` /
`memstore.go` / `sqlstore.go` (tables `persistence.AcademySchema`, new tables only),
`wire.go` (every record and push of sections 4-6), `board.go` (the matching board).
`internal/session`: `academy.go` (0x7470..0x7478, 0x7483, the 0x3080 kind 9 answer),
`academylive.go` (world entry, logout, moves, level / name / body refresh, honor rank,
honor buffs, chat audience, lobby byte), `academyboard.go` (0x747A..0x747F),
`academyshop.go` (the honor store). OURS: OpenSRO keeps no max level apart from the level
(a level never falls here), so choice 2's two rules agree; the members' places are
sampled each second for 0x3C80 0d (the party sampler's cadence); a GM's `/academytime
<duration>` moves the academy's clock forward for QA (a bots' aid, not in the console);
a request through the matching board that passes every refusal waited 15 s and ended as
"no reply" (the guardian's question was OPEN; round 866 sends it, 7.10); every camp counts as loaded for the honor
list (one game server); the board's type byte is read as the shard's bits (1 and 2 agree).

## 15. Corrections to the earlier version of this page

- "What role class 0 is, is not read" — class 0 is the **guardian** (sections 2, 5).
- `CheckMembershipLevel` (s:0x519770) is not a membership check: it is the handler of
  **0x7476**, the guardian forcing a member's graduation; 41 / 61 are forced-graduation
  floors. The table "membership floor" column was wrong; section 2 has the real one.
- Ban and leave requests are **0x7473 {str name}** and **0x7474 {}** (READ both sides,
  MEASURED); the earlier note called them unread.
- The disband window runs from **CreationDate**, the ban / leave window from
  **JoinDate** (both were "not read").
- `0xB476` is the forced graduation's reply (it was "not named"); 0xB477 the notice's,
  0xB478 the honor list's, 0xB47A..0xB47E the matching board's.
- The invitee never gets a success reply on 0xB472, and a timed-out invitation answers
  **0x000E**, not 0x680e (the engine keeps the low byte; MEASURED).
- The "leave's 24 h refusal on 0xB473" and "disband's plain refusals on 0xB470" crossed
  channels stand; the first is now MEASURED.

## 16. Earlier evidence kept

- Validators: `CInstanceTrainingCamp::CheckCanCreate` s:0x4e4680,
  `TrainingCamp_CheckCanDisband` s:0x4e4780 (its 0x681d is computed, `(-(remaining != 0)
  & 0x681c) + 1`, so no literal exists), `TrainingCamp_CheckCanInvite` s:0x4e4800,
  `TrainingCamp_CheckCanEnter` s:0x4e4890 (`sbb eax,eax ; and eax,3 ; add eax,0x680f`
  gives 0x680f / 0x6812), and their `GObjPC::` twins s:0x4e4950 / s:0x4e4aa0 for the
  board.
- Handlers: open s:0x518fd0, disband s:0x519120, invite s:0x519230, ban s:0x5193a0, leave
  s:0x519510, graduation s:0x519600, forced graduation s:0x519770, notice s:0x519900,
  rank list s:0x519ad0, board s:0x519b80..0x519d10, buff transfer s:0x519d40.
- Job types to the shard (`SendOlappedTrainingCampJobReqToSM` s:0x5df5c0, type in `CL`):
  0 open, 1 disband, 2 join, 3 remove (ban reason 2, leave reason 1), 4 graduate, 7
  notice, 0x10..0x13 board; results through `TrainingCamp_DispatchJobResult` s:0x5e0fa0;
  a job timeout is 0x680e (s:0x46dd03).
- The penalty list: `0x411440` walks the per-character list at +0x1dfc matching category
  (slot 0x68) and id (slot 0x6c); `CTJ_PenaltyKeeper::Create` switches on the same id.
  The ids are **not** day counts (the old "7 days because the argument is 7" reading
  was a coincidence; the duration table is the evidence).
- Client: the request senders c:0x821e40 (0x7470), c:0x8220e0 (0x7471), c:0x821f00
  (0x7472), c:0x822180 (0x7475); the handler registration lists c:0x8a4010 (via
  c:0x8a1b80) and c:0x8980e0 (via c:0x894ac0); 0x3080's generic handler c:0x88aa60.

## 17. OPEN, and choices that need the user

**OPEN** (not measured, not read; do not guess):
1. 0x3C80 04's kind byte: which value is a self and which a forced graduation (both
   print the same text).
2. The exp banking formula's inputs, the buff's point cap, the server side of 0x3C82
   (which sub when) and 0xB483's non-login send (s:0x4e4580 field order).
3. (Round 866: 0x747E's push to the guardian, 0x347F's fields and MatchRow's two
   unstored u32s are READ and MEASURED, 7.10 and 5.) Still OPEN: the board's page size
   beyond a one-row page, and what the shard does to the entry when an accept fills the
   recruited role (m:0x45ab50; OpenSRO keeps the client's own pull delete).
4. (Resolved in stage 2: the judge window's title is its registry caption; kind 7 draws
   tc_reserve_buff, kind 8 tc_amends_buff -- 10.3, 7.11.)
5. What `SKILL_TC_*_BUFF_01` do (skill data; OpenSRO reads it).
6. Not measured live (READ only): success of leave, ban and disband (each needs a day
   or a week to pass), graduation of either kind, the honor shares, a matching join, the
   buff transfer, the honor rank update. Stage 3 can measure graduation after a level-up
   inside the game; the windows need real time.

**Choices, decided (round 865, before stage 2): each follows the original.**
1. Copy the 0x000E timeout code byte-exact. 2. Check the role by current level and store the
class by max level, as the original does. 3. Keep the OURS 0xf002 server answer and add the
retail client-side refusal (`UIIT_MSG_TC_ERROR_NOT_POSITION`). 4. Copy the stale member levels
(refreshed only on an in-game level change).

**The choices as they were put:**
1. **The invitation timeout code.** The original sends 0x000E (a truncated 0x680e), and
   the client prints nothing. Recommend: copy it (byte-exact). The alternative is 0x680e,
   which also prints nothing.
2. **Role by current or max level.** The game server picks the role (and caps) by the
   invitee's current level, the store by its max level. Recommend: check by current
   level as the game server does, and store the class the store derives from the max
   level (both as the original), noting that they only differ after a level loss.
3. **The no-academy chat refusal.** OpenSRO's server answers 0xf002 (OURS) because its
   client held no academy state. Once the client holds it, the client should refuse
   itself with `UIIT_MSG_TC_ERROR_NOT_POSITION` (retail). Recommend: keep the OURS server
   answer for safety and add the client-side refusal.
4. **Stale member levels.** The original refreshes a member's stored levels only on an
   in-game level change. Recommend: copy it (a GM level edit while offline then shows
   old levels until the next level-up).

## 18. Build checklist (stage 2)

The wire is the original's (docs/protocol/PROTOCOL_DECISION.md: a superset of the
retail protocol); every layout above is the contract. Golden bytes: section 6's
measured sequences, with names replaced by test names.

### SERVER

1. **Store** — `server/internal/academy/store.go`, `memstore.go`, `sqlstore.go` (as
   `internal/guild` does), tables in `server/internal/persistence/schema.go` with the
   columns of section 3 and the honor bank. Found, add (class from max level, caps,
   buff rows), remove (bank / -10 rule), graduate (shares, GraduateCount, evaluation),
   disband, notice, level refresh, rank update. Dates minute-rounded. Test:
   `academy/store_test.go` against both stores, one case per rule of section 3.
2. **Wire** — `server/internal/academy/wire.go`: CampInfo, MemberEntry, every 0x3C80
   sub, 0x3C81, the replies, HonorRow, MatchRow, the request decoders. Test:
   `wire_test.go` golden bytes from section 6 (e.g. `3C80 05 <id> 01 00`, `B471 02 1d 68
   <u32>`, `B47A 01 01000000 <camp> 01 "Join us" 00000000`).
3. **Handlers** — `server/internal/session/academy.go`, registered beside the guild's:
   0x7470..0x7478, 0x7483, in the refusal orders of section 7 (crossed channels
   included). Test: `session/academy865_test.go`, one test per refusal in order and per
   success sequence.
4. **Invitation** — 0x3080 kind 9 with the 30 s timer; `academyInviteAnswer` chained in
   `party.go` `handlePartyAnswer` beside `guildInviteAnswer`; refusal 0x6811 both ways;
   timeout 0x000E both ways. Test: accept, refuse, timeout (fake clock).
5. **World entry / logout / moves** — after the own spawn at every world entry
   (`playerview.go` where `sendOwnGuildBlock` is called): 0x3C81, then 0x3C80 0d to the
   others and 05 field 1 = 0 to all; on logout 05 field 1 = 1; on movement 0d (the party
   position trigger). Test: two sessions, assert bytes and order.
6. **Member refresh** — level-up (fields 6 and 2), body change (7), rename (5), honor
   (3). Test: level a member, assert the push and the stored levels.
7. **Penalties** — `internal/timedjob` category 2 ids 7..10 with section 8's lengths,
   given at disband / ban of an apprentice / leave; checked at open / invite / being
   invited / board. Test: each refusal with its seconds where carried.
8. **NPC gate and gold** — 0x7470 / 0x7478 need a storage keeper in range (server
   function 3); the fee taken after the store succeeds, 0x304E before 0xB470. Test.
9. **Graduation** — 7.6 / 7.7; 2,000,000 exp to a self-graduating apprentice
   (`leveldata` gain path), honor pushes. Test: both kinds, both classes, the level
   gates 0x681a / 0x6822.
10. **Honor rank** — the daily 00:00 update and the start-up catch-up; 0x3C80 0c to
    changed camps; the guardian's `SKILL_TC_*` buffs by rank (engage / cancel). Test:
    ranking order and bands with 60 fake camps.
11. **Honor store** — payment device 32 in `internal/shop` (HonorPoint check 0x18d4,
    deduction, 0x3C80 05 field 3 to the camp). Test: buy with and without points.
12. **Chat** — `chat.go` type 0x10: 0x3026 {10, name, text} to every online member
    incl. the sender, 0xB025 {01 10 idx}; non-member keeps 0xf002 (choice 3). Test.
13. **Matching board** — 0x747A..0x747E per 7.10 (in memory, dropped at the guardian's
    logout), 15 s join wait. Test: register, list, delete, join refusals.
14. **Exp buffs** — the parts READ in 7.11 only; leave the OPEN formula out (labelled).
15. **Char select** — `lobby.go` AcademyClass 2 guardian / 1 member / 0. Test in
    `lobby_golden_test.go`.

### CLIENT

1. **Net** — `client/scripts/net/academy_net.gd`: encoders for every request, decoders
   for every reply and push of sections 4-6. Test: `academy_net_test.gd` with the golden
   bytes of server item 2.
2. **State** — `client/scripts/net/academy_state.gd`: the camp and up to 8 members
   keyed by CharID; applies 0x3C81 / 0xB470 / 0x3C80 (all subs); grade computation
   (10.2); "am I in an academy" for the NPC menu, chat and HUD. Test: each sub.
3. **Academy window** — the pane `GDR_APPRENTICESHIP` (`hud_main_popup.gd` /
   `hud_panels.gd`, a new `client/scripts/ui/hud/academy_window.gd`): section 10.1's
   controls, slot fill order, guardian-only enabling, the notice line and content panel,
   key L, auto-open on join. Test: `academy_window_test.gd` (rows, buttons, labels per
   viewer) and a real-click QA against the lane server.
4. **Slots and boxes** — 10.2's button rule and the four confirm boxes (texts of
   section 7); sends 0x7473 / 0x7474 / 0x7475 / 0x7476. Test.
5. **Evaluation window** — `ifapprenticeshipjudge.txt` (10.3), default "Satisfied",
   byte mapping. Test.
6. **Invitation box** — 0x3080 kind 9 in the request-box code (`guild_ops_net.gd`'s
   pattern): `UIIT_STT_TC_JOIN_REQUEST`, Yes `01 01`, else `02 00 00`; the inviter's
   pending line and the Invite arm-then-click flow. Test.
7. **Notice writer** — the guild notice writer in academy mode (`guild_notice_write.gd`):
   sends 0x7477 only with both fields set. Test.
8. **NPC lines** — `npc_service_reader.gd`: the membership byte from the state; 0x7470
   behind the fee box with the local gold check; 0x7478 opens the ranking window
   (`ifapprenticeshiphonorranking.txt`, 10.4). Test.
9. **Matching window** — `ifmentormatch.txt` (10.5): list, register box (flags, title
   check, full-role refusal), modify, delete, join; the banners of 7.10. Test.
10. **Messages** — every system line and banner of sections 6, 7 and 11 through the
    existing system-message paths (`hud_system_message.gd`), error codes via the table of
    section 11 (no text for the silent codes). Test: code -> text table.
11. **Chat** — `hud_chat.gd`: the client-side refusal outside an academy (choice 3);
    lines already format. Test.
12. **Character window** — "Honor Point" value or "N/A". Test.
13. **Minimap / world map** — `party_map_marks.gd`: the academy signs and edge arrows of
    10.6 from the state's location groups. Test.
14. **Buff icons** — types 7 / 8 with their tooltips and the transfer click (7.11).
    Test.
15. **Char select** — `CharacterSelect.gd` uses the academy byte for the delete box.
    Test.
