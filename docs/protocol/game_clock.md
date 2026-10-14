# The game clock and the server's wall clock

Two clocks reach the client. **The game clock** (0x3020 / 0x3027) is the in-game day, hour and
minute; it drives the sky's time of day (round 786). **The server's wall clock** (0x34be, every
600 s) is the server machine's local date and time; it feeds the client's `ServerTime` display
and date-based interface (round 224), not the sky.

Labels: READ (sro_client.exe / SR_GameServer.exe on the render box: the decompile dumps in
`/var/tmp/decomp_client`, `/var/tmp/decomp_server`, objdump of the images), MEASURED, INFERRED,
OURS, OPEN.

## The game clock (round 786)

### The server's timer (READ, SR_GameServer.exe)

- The timer lives at +0x10 of the CMainProcess singleton (`DAT_00d6a8e8`): `[0]` the rate, `[1]`
  the GetTickCount it started at, `[2]` the last tick, `[3]` the tick counter's wraps, `[6..7]`
  the base in game seconds; the per-tick update writes the **day (u16) at singleton +0x20, the
  hour at +0x22, the minute at +0x23**.
- `CMainProcess::InitializeGame` starts it through `FUN_00427660` (0x427660): **rate 30**
  (`mov [esi],0x1e` at 0x427677) and **base 0 -- day 0, 00:00:00 when the server starts**.
- Every tick, `FUN_004140b0` calls `FUN_00427720` (0x427720): `elapsed_ms / (rate x 1000 / 1440) +
  base`, all in unsigned integers, split as second = s % 60, minute = s / 60 % 60, hour = s /
  3600 % 24, day = s / 86400. The divisor `30 x 1000 / 1440` is computed with the magic
  0x6c16c16d sequence and **truncates to 20** (MEASURED: the sequence evaluated for 30000 gives
  20). So **one game second is 20 real ms, and a game day is 86400 x 20 ms = 1728 s = 28 min
  48 s** -- not the 30 minutes the rate names. The day is never wrapped.
- The operator's set-hour (`FUN_004154d0` case 10, a GM-tool message -> `FUN_00412be0`): a byte,
  above 22 made 23; the hour stored, the timer re-based at the current day and minute and this
  hour (`FUN_00427690`, rate 30 again, second 0), and **0x3027 broadcast** to every region's
  players (`FUN_00530d60` with param 1).

### The messages (READ)

| Opcode | Built by | Sent | Payload |
|---|---|---|---|
| **0x3020** | `FUN_004e3eb0` | once per `CMainProcess::EnterGame` (0x403020; at 0x403237, right after the character data `FUN_00403730` / `FUN_004e3bb0`, and in its case 3) | u32 the character's unique id (`[ebx+8]`), u16 day, u8 hour, u8 minute -- **8 bytes** |
| **0x3027** | `FUN_00530d60` -> `FUN_004f8240` | when the operator sets the hour, to everyone | u16 day, u8 hour, u8 minute -- **4 bytes** |

Nothing else builds either opcode (the only `0x3020` / `0x3027` pushes in the server are these;
the other `0x3020` constants are an attack-refusal error code). **The server never re-sends the
clock periodically**: both ends run the same integer timer from the minute the server named, so
they agree to within that minute (the client starts it at second 0: up to 59 game seconds, 1.2 s
of real time, behind). `EnterGame` is reached from `SR_ENTERGAME_REQ` (`FUN_00402eb0`): the
entry into a game server, not a teleport within one.

### The client (READ, sro_client.exe)

- The opcode table `FUN_0086fbb0` registers **0x3020 -> `FUN_008a6dc0`** and **0x3027 ->
  `FUN_008a6e80`**.
- `FUN_008a6dc0` reads u32, u16, u8, u8 into the config object (`DAT_0110f7d0 + 0x24`: +0x128 the
  day, +0x12a the hour, +0x12b the minute), hands the u32 to the player object (vtable +0x48),
  sets **dwRealTime = 0x1e** (+0x124) and calls
  `Fun_GetCfgGame()->m_LocalTime.InitTimer(pM->dwRealTime, pM->m_wDay, pM->m_byHour, pM->m_byMin, 0)`
  -- the expression text of the assert at NetProcessInObject.cpp line 0x46e names the fields.
  InitTimer is `FUN_008b00f0` on `FUN_004f9ca0()` (0xeed578) + 0xf8: base = ((day x 24 + hour) x
  60 + minute) x 60 + 0, started at GetTickCount.
- `FUN_008a6e80` (0x3027) reads u16, u8, u8 and, **unless the time is locked** (CGInterface
  `DAT_0110f80c + 0x7cd`), runs the same InitTimer with the stored rate.
- The timer's reading `FUN_008b01b0` is the server's arithmetic, byte for byte (the same
  0x6c16c16d divisor).
- **Every frame**, `CPSMission::vslot_012` (0x84c300; it returns early while the zone loads)
  calls **`FUN_0084ac90`**. Unless the time is locked it reads the timer's hour, minute and second,
  and:
  - h = (second + (minute + hour x 60) x 60) / 86400.0 x 24.0 (the doubles at 0xdd43e8, 0xd830a0;
    stored to a float between);
  - passes the truncated hour (control word | 0xc00) to the object at 0xee73c0 (`FUN_004e8890`);
  - **between 4.0 and 20.0 inclusive** (0xd8ada8, 0xd88108): sky hour = (h - 4) x 12 x 0.0625 +
    6 (0xe1b860, 0xd89248, 0xdd43e0, 0xd99a68), night flag 0; **otherwise** h + 24 below 4, sky
    hour = (h - 20) x 12 x 0.125 + 18 (0xe1b830, 0xdd43d8, 0xdd43d0), less 24 at or past 24
    (0xd880e0), night flag 1;
  - hands the night flag to the sound manager (`DAT_0110aad8`, vtable +0x6c);
  - **sets SWorld's day phase = sky hour / 24** through vtable +0x50 (`SWorld::vslot_020`, `ret
    8`, storing +0x26a3) on `FUN_009edd60()`, which returns **0x1101950 -- the SWorld global**
    built by the static initialiser 0xd768f0 -> `Map::FUN_00a2f370`;
  - sets SWorld's day (+0x6778, `SWorld::vslot_021`) from the timer's day -- the moon's picture.

So the clock's 16 hours 04:00-20:00 are the sky's 06:00-18:00 (19 min 12 s of real time) and its
8 hours 20:00-04:00 the sky's 18:00-06:00 (9 min 36 s):

| Clock | Sky hour | Phase |
|---|---|---|
| 00:00 | 00:00 | 0.0 |
| 02:00 | 03:00 | 0.125 |
| 04:00 | 06:00 | 0.25 (sunrise) |
| 12:00 | 12:00 | 0.5 |
| 20:00 | 18:00 | 0.75 (sunset) |
| 22:00 | 21:00 | 0.875 |

- **The lock** is the debug console's: `TimeOff` (0x53a430) sets +0x7cd, `TimeOn` (0x53a480)
  clears it, `Day` (0x53a4d0) sets the phase 0.5, `Night` (0x53a520) 1.0 (the command names are
  the UTF-16 strings at 0xd88858, 0xd88848, 0xd88834, 0xd88828; `Time` is 0x54ba30). In play the
  lock is clear: the CGInterface constructor zeroes it (0x78d3b2) and nothing else writes it.

### Corrected: "the sky's clock is not this one" (round 226)

Round 226 read SWorld's own phase machinery -- the constructor's 0.5 (0xe1b7e0), the per-frame
`phase += dt x 0.0005` behind a flag (+0x2f18) nothing sets -- and concluded that the retail
client draws a fixed midday and that the clock feeds nothing in the sky. **That missed the
caller above:** `FUN_0084ac90` sets the phase from the clock every frame through the vtable call,
which the round's search for `SWorld::vslot_020` callers did not find (the call is `call [edx+0x50]`
on the return of `FUN_009edd60`, not a direct reference). Round 688's review had noted the same
call (TODO.md's "the day phase" item). The front end is different: there only `CPSTitle::OnCreate`
sets the phase (`rand() & 3` over 5, 14, 18 and 23 o'clock, TitleIntro), and nothing advances it.

### What OpenSRO does (round 786)

- **Server** (`server/internal/worldclock`, `session/celestial.go`): the clock as above, started
  when the server starts; **0x3020 right after `OpEnterWorldResult`** (OpenSRO's stand-in for the
  character data), once per world entry; **0x3027 to everyone on the GM's `/hour <0-23>`** (the
  operator's set-hour). Flags: `-world-clock` (default on; off sends nothing, the kill switch) and
  `-world-clock-start HH:MM` (OURS; empty is retail's 00:00). **The day length is not a flag**: the
  client's rate is fixed in its binary, so a server running another rate would put the two clocks
  apart (an OpenSRO client would follow 0x3027 re-sends; retail sends none).
- **Client** (`scripts/net/game_clock.gd`, `GameClock`, kept in the NetClient autoload): the two
  handlers, the timer's integer arithmetic, `day_phase()` = FUN_0084ac90's map, and
  `is_night_hour()` for the ambient sound (MusicDirector). Before any message -- a server older
  than round 786 or `-world-clock` off -- the phase is the fixed 0.5 the client drew before
  (OURS fallback). The lock is not reproduced (no console).
- **Compatibility:** an older client receiving 0x3020 / 0x3027 logs each once as unhandled and
  ignores it; a newer client on an older server draws midday as before. The uid in 0x3020 is
  decoded and logged only (OpSelfID already names the player).
- **QA** (OURS): `OPENSRO_QA_CLOCK="HH:MM"` pins the clock for a run, `"name=HH:MM,..."` per QA
  shot; `OPENSRO_QA_CLOCK_RUN=<x>` runs a pinned clock x times faster.

### OURS on the clock's night (round 786)

The user: "It doesn't appear to actually get dark out" and "change shadow positions based off sun
position". Retail's night is exactly as dark as the zone's environment keys, which are mild in
Jangan and as bright as noon around Bandit's Mountain Stronghold (READ and MEASURED in
[ENVIRONMENT_FORMAT.md](ENVIRONMENT_FORMAT.md), "What lights the world at night"). Two OURS Video
rows (`NightLight`, `VideoOptions.NIGHT` / `SUN_SHADOWS`) sit on the clock's phase:

| Clock | Sky hour | Phase | Night Darkness (OURS) | Shadow light (OURS, Shadow Detail = Detail) |
|---|---|---|---|---|
| 04:30 | 06:23 | 0.266 | day from here | the sun, held at 15 degrees up, fading in |
| 08:00 | 09:00 | 0.375 | day | the sun in the east, 45 degrees up |
| 12:00 | 12:00 | 0.5 | day | overhead |
| 17:00 | 15:45 | 0.656 | day | the sun in the west, 34 degrees up |
| 19:29 | 17:37 | 0.734 | night begins to fall | the sun, 15 degrees, fading out |
| 20:39 | 18:58 | 0.790 | full night | the moon from moonrise (phase 0.792), at half strength once 9 degrees up |
| 03:21 | 05:02 | 0.210 | night begins to lift | the moon until it sets (phase 0.208) |

The night amount is `1 - smoothstep(-0.25, 0.1, sin(sun height))` of the READ sun (DayCycle); at
full night the zone's light is Dim 0.5 / Dark 0.3 (the default) of its own noon light, Original
leaves retail's values. The moon casts only while retail draws it (the clock's day below 29): on a
server up 29 game days or more (13.9 hours) the nights have no moon and no night shadows (the
day-wrap question is the user's to decide; not changed here). The front end's fixed title hour is
not darkened.

## The server's wall clock: 0x34be every ten minutes (round 224)

Recovered 2026-09-19 (round 224) from both binaries' decompiled dumps on the render box and the
client image's `.rdata`.

### Server: the 600-second job

`CGObjChar::Create` registers a timer job on every character with interval **600.0 s** (slot 367's
thunk `0x4ac710`, constant at `0xb46198`; the timer vector and its one-second ticking are in
[character_state.md](character_state.md)). Its body, `CGObjPC::vslot_367` ->
`GObjPC::FUN_004f1560` (`0x4f1560`), packs the server's `GetLocalTime()` (`FUN_004f9320`,
`0x4f9320`) into one 32-bit word and sends it as opcode **`0x34be`**:

```
bits  0.. 5  (year - 16) & 0x3f      (2026 -> 26; the client reads it as 2000 + v)
bits  6.. 9  month
bits 10..14  day of month
bits 15..19  hour
bits 20..25  minute
bits 26..31  second
```

So every connected character is re-synced to the server's local time every ten minutes.
`FUN_004f1560` is the only sender of 0x34be (round 786: its one caller is `CGObjPC::vslot_367`).

### Client: decode, set, advance

- The opcode table registers `0x34be -> FUN_0089a250` (`0x89a250`). It unpacks exactly the fields
  above into a `tm` (`tm_year = (v & 0x3f) + 100`, `tm_mon = ((v >> 6) & 0xf) - 1`, `tm_mday =
  (v >> 10) & 0x1f`, `tm_hour = (v >> 15) & 0x1f`, `tm_min = (v >> 20) & 0x3f`, `tm_sec = v >>
  26`), runs `mktime`, and -- unless the clock is **locked** -- calls the setter.
- The clock object (`CGame`, fields `+0x8f8..+0x958`): `FUN_00834bf0` stores the `tm` at `+0x934`;
  `FUN_00834df0` seeds the millisecond clock `+0x918` as `((sec + (min + (hour + wday*24)*60)*60)
  * 1000` -- milliseconds since the start of the server-local **week**; `FUN_00834e60` re-syncs
  it, measuring drift against the locally advanced value and resetting the smoothing when the
  drift exceeds 2000 ms.
- `CGame::vslot_011` (the per-frame update) advances it with real elapsed milliseconds and
  publishes `+0x92c = ms * 0.001`: world time in seconds, advancing 1:1 with real time.
  `FUN_00834c70` renders it back into a `tm` (splitting by 86400 / 3600 / 60) for display; its
  readers include the debug console's `ServerTime <asctime> [LOCKED]` / `[UNLOCKED]`
  (`FUN_00542580`) and the silk mall's windows (`UI_SILKMALL::FUN_007dde60`, `FUN_007e0510`).
- The lock: `FUN_00834de0` returns the byte at `+0x931`, set by the scene command
  `S_SetWorldTime` (`Process_S_SetWorldTime`, `0x529580`).

**OpenSRO does not send 0x34be** (OPEN): nothing this client draws reads it yet.
