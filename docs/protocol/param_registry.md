# The ParamKeeper registry: every param id, with its min, max and default

Recovered whole from `SR_GameServer.exe` on 2026-09-15. This is **real data read
out of the binary**, not an inference: a static table of 20-byte records at VA
`0x00c64110` (file offset `0x864110`), terminated by an id of `0xFFFF`.

## How it was found, and why it is authoritative

`CMainProcess::ParamRegistry_Register` (`0x004b3960`) is a plain loop over that
table, inserting each record into a global map keyed by param id:

```asm
mov  ax, ds:0xc64110        ; first record's id
mov  esi, 0xc64110          ; table base
cmp  ax, 0xffff / je done   ; 0xFFFF terminates
loop:
  mov  WORD  [esp+0xc], ax  ; key   = id
  mov  DWORD [esp+0x10],esi ; value = pointer to this record
  call 0x4b3ff0             ; map[id] = record
  movzx eax, WORD [esi+0x14]
  add  esi, 0x14            ; stride 20 bytes
  cmp  ax, 0xffff / jne loop
```

The record layout is fixed by `ParamKeeper_EnsureParam`, which converts four of
its fields and passes them to `Param_Init`:

```c
struct ParamDesc {          // 20 bytes
    uint16 id;  uint16 pad;
    int32  min;             // +0x04 -> param+0x20
    int32  max;             // +0x08 -> param+0x24
    int32  default;         // +0x0c -> param+0x1c AND +0x28
    int32  flag;            // +0x10 -> param+0x2c   (0 or -1)
};
```

`min`/`max` are pinned by `ParamKeeper_EvaluateParam`'s own clamp assert, which
prints `+0x20` as `min` and `+0x24` as `max`.

**Why this table is the whole story.** There is exactly **one** `CParam`
allocation site in the entire binary, inside `ParamKeeper_EnsureParam`, and it
runs only when the id is present in this map. An id that is absent asserts and
creates nothing; the read wrapper then tail-jumps into `Param_GetValue`, which
dereferences the pointer with no null check. So:

- every param that can exist is in this table, and
- **an unwritten param evaluates to the `default` column here** -- not to zero by
  assumption, and not to some unrecoverable runtime value.

## Two independent checks on the layout

1. **Param 0 is `min=1, max=140`** -- the level cap, which matches `leveldata`'s
   own 140 exactly. Nothing about the parse was tuned to produce that.
2. The magnitudes sort correctly by kind without being told to: HP/MP (3/4) cap
   at 2,100,000,000 (~INT_MAX), percentage stats (10 `bri`, 12 `cri`, 25 `hprg`,
   26 `mprg`, 56 `evbl`, 57 `evcr`) cap at 100, and the rate stats (9 `era`,
   11 `hra`) cap at 65535.

## What it settles

- **Only 7 of 120 params have a non-zero default**, and every one of them is
  `100`: ids **34, 35, 36, 37, 50, 51, 140**. Everything else defaults to **0**.
- `hprg`/`mprg` (25/26) default to **0**, so the game's baseline passive
  regeneration rate is zero -- which is consistent with there being no
  timer-driven pool writer at all (see `mana`'s package comment).
- `257` (death-penalty reduction) defaults to **0**, so a character with no
  premium benefit really does take the full penalty. That value is RECOVERED.
- The damage-pipeline params `128-131, 178, 180, 187, 188, 259` all default to
  **0**, so an unbuffed character's damage really is complete without them.

## Unregistered ids

These ids in `0..259` are **not** in the table, so nothing can ever read them --
a "recovered" param id landing in one of these ranges is wrong by construction:

> 61-127, 142, 151-168, 201, 203-255

## The table

The `flag` column is the fourth field (`0` or `-1`); its meaning is not
recovered, so it is reported rather than interpreted. The `known tag` column is
this project's own id->tag mapping from `Stat_ApplyTaggedModifier`, included
only where already established elsewhere.

| id | hex | min | max | default | flag | known tag |
|---:|----:|----:|----:|--------:|-----:|---|
| 0 | 0x000 | 1 | 140 | **0** | 0 | level |
| 1 | 0x001 | 0 | 9999999 | **0** | 0 |  |
| 2 | 0x002 | 0 | 9999999 | **0** | 0 | int |
| 3 | 0x003 | 0 | 2100000000 | **0** | 0 | hp/hpa |
| 4 | 0x004 | 0 | 2100000000 | **0** | 0 | mp/mpa |
| 5 | 0x005 | 0 | 9999999 | **0** | 0 |  |
| 6 | 0x006 | 0 | 9999999 | **0** | 0 |  |
| 7 | 0x007 | 0 | 10000 | **0** | 0 |  |
| 8 | 0x008 | 0 | 10000 | **0** | 0 |  |
| 9 | 0x009 | 0 | 65535 | **0** | 0 | era (parry rate) |
| 10 | 0x00a | 0 | 100 | **0** | 0 | bri (blocking) |
| 11 | 0x00b | 0 | 65535 | **0** | 0 | hra (attack rate) |
| 12 | 0x00c | 0 | 100 | **0** | 0 | cri (critical) |
| 13 | 0x00d | 0 | 9999999 | **0** | 0 | phys damage low |
| 14 | 0x00e | 0 | 9999999 | **0** | 0 | phys damage high |
| 15 | 0x00f | 0 | 9999999 | **0** | 0 | mag damage low |
| 16 | 0x010 | 0 | 9999999 | **0** | 0 | mag damage high |
| 17 | 0x011 | 0 | 9999999 | **0** | 0 |  |
| 18 | 0x012 | 0 | 9999999 | **0** | 0 |  |
| 19 | 0x013 | 0 | 9999999 | **0** | 0 |  |
| 20 | 0x014 | 0 | 9999999 | **0** | 0 |  |
| 21 | 0x015 | 0 | 9999999 | **0** | 0 |  |
| 22 | 0x016 | 0 | 9999999 | **0** | 0 |  |
| 23 | 0x017 | 0 | 9999999 | **0** | -1 |  |
| 24 | 0x018 | 0 | 9999999 | **0** | -1 |  |
| 25 | 0x019 | 0 | 100 | **0** | 0 | hprg |
| 26 | 0x01a | 0 | 100 | **0** | 0 | mprg |
| 27 | 0x01b | 0 | 100 | **0** | 0 | rals |
| 28 | 0x01c | 0 | 100 | **0** | 0 |  |
| 29 | 0x01d | 0 | 100 | **0** | 0 |  |
| 30 | 0x01e | 0 | 100 | **0** | 0 |  |
| 31 | 0x01f | 0 | 100 | **0** | 0 |  |
| 32 | 0x020 | 0 | 100 | **0** | 0 |  |
| 33 | 0x021 | 0 | 9999999 | **0** | 0 |  |
| 34 | 0x022 | 0 | 1000 | **100** | 0 |  |
| 35 | 0x023 | 0 | 1000 | **100** | 0 |  |
| 36 | 0x024 | 0 | 1000 | **100** | 0 |  |
| 37 | 0x025 | 0 | 1000 | **100** | 0 |  |
| 38 | 0x026 | 0 | 1000 | **0** | 0 |  |
| 39 | 0x027 | 0 | 1000 | **0** | 0 |  |
| 40 | 0x028 | 0 | 1000 | **0** | 0 |  |
| 41 | 0x029 | 0 | 1000 | **0** | 0 |  |
| 42 | 0x02a | 0 | 1000 | **0** | 0 |  |
| 43 | 0x02b | 0 | 1000 | **0** | 0 |  |
| 44 | 0x02c | 0 | 1000 | **0** | 0 |  |
| 45 | 0x02d | 0 | 1000 | **0** | 0 |  |
| 46 | 0x02e | 0 | 1000 | **0** | 0 |  |
| 47 | 0x02f | 0 | 1000 | **0** | 0 |  |
| 48 | 0x030 | 0 | 1000 | **0** | 0 |  |
| 49 | 0x031 | 0 | 1000 | **0** | 0 |  |
| 50 | 0x032 | 0 | 1000 | **100** | -1 |  |
| 51 | 0x033 | 0 | 1000 | **100** | -1 |  |
| 52 | 0x034 | 0 | 9999999 | **0** | 0 | hpna |
| 53 | 0x035 | 0 | 9999999 | **0** | 0 | mpna |
| 54 | 0x036 | 0 | 9999999 | **0** | 0 |  |
| 55 | 0x037 | 0 | 9999999 | **0** | 0 |  |
| 56 | 0x038 | 0 | 100 | **0** | -1 | evbl |
| 57 | 0x039 | 0 | 100 | **0** | -1 | evcr |
| 58 | 0x03a | 0 | 1000 | **0** | -1 |  |
| 59 | 0x03b | 0 | 1000 | **0** | -1 |  |
| 60 | 0x03c | 0 | 9999999 | **0** | 0 |  |
| 128 | 0x080 | 0 | 1000 | **0** | 0 | drua |
| 129 | 0x081 | 0 | 1000 | **0** | 0 | drua |
| 130 | 0x082 | 0 | 1000 | **0** | 0 | drua |
| 131 | 0x083 | 0 | 1000 | **0** | 0 |  |
| 132 | 0x084 | 0 | 100 | **0** | 0 |  |
| 133 | 0x085 | 0 | 100 | **0** | 0 |  |
| 134 | 0x086 | 0 | 100 | **0** | 0 |  |
| 135 | 0x087 | 0 | 100 | **0** | 0 |  |
| 136 | 0x088 | 0 | 100 | **0** | 0 |  |
| 137 | 0x089 | 0 | 100 | **0** | 0 |  |
| 138 | 0x08a | 0 | 100 | **0** | 0 |  |
| 139 | 0x08b | 0 | 100 | **0** | 0 |  |
| 140 | 0x08c | 0 | 1000 | **100** | 0 |  |
| 141 | 0x08d | 0 | 100 | **0** | 0 |  |
| 143 | 0x08f | 0 | 100 | **0** | 0 | recover HP |
| 144 | 0x090 | 0 | 100 | **0** | 0 | recover MP |
| 145 | 0x091 | 0 | 9999999 | **0** | 0 |  |
| 146 | 0x092 | 0 | 9999999 | **0** | 0 |  |
| 147 | 0x093 | 0 | 9999999 | **0** | 0 |  |
| 148 | 0x094 | 0 | 9999999 | **0** | 0 |  |
| 149 | 0x095 | 0 | 9999999 | **0** | 0 |  |
| 150 | 0x096 | 0 | 9999999 | **0** | 0 |  |
| 169 | 0x0a9 | 0 | 100 | **0** | -1 |  |
| 170 | 0x0aa | 0 | 100 | **0** | 0 |  |
| 171 | 0x0ab | 0 | 100 | **0** | 0 |  |
| 172 | 0x0ac | 0 | 100 | **0** | 0 |  |
| 173 | 0x0ad | 0 | 100 | **0** | 0 |  |
| 174 | 0x0ae | 0 | 100 | **0** | 0 | dara |
| 175 | 0x0af | 0 | 100 | **0** | 0 | dara |
| 176 | 0x0b0 | 0 | 100 | **0** | 0 | dara |
| 177 | 0x0b1 | 0 | 100 | **0** | 0 | dara |
| 178 | 0x0b2 | 0 | 100 | **0** | 0 |  |
| 179 | 0x0b3 | 0 | 100 | **0** | 0 |  |
| 180 | 0x0b4 | 0 | 100 | **0** | 0 |  |
| 181 | 0x0b5 | 0 | 100 | **0** | 0 |  |
| 182 | 0x0b6 | 0 | 100 | **0** | 0 |  |
| 183 | 0x0b7 | 0 | 100 | **0** | 0 |  |
| 184 | 0x0b8 | 0 | 1000 | **0** | 0 |  |
| 185 | 0x0b9 | 0 | 9999999 | **0** | 0 |  |
| 186 | 0x0ba | 0 | 1000 | **0** | 0 |  |
| 187 | 0x0bb | 0 | 100 | **0** | 0 |  |
| 188 | 0x0bc | 0 | 100 | **0** | 0 |  |
| 189 | 0x0bd | 0 | 100 | **0** | 0 |  |
| 190 | 0x0be | 0 | 999999 | **0** | 0 |  |
| 191 | 0x0bf | 0 | 999999 | **0** | 0 |  |
| 192 | 0x0c0 | 0 | 999999 | **0** | 0 |  |
| 193 | 0x0c1 | 0 | 999999 | **0** | 0 |  |
| 194 | 0x0c2 | 0 | 100 | **0** | 0 |  |
| 195 | 0x0c3 | 0 | 100 | **0** | 0 |  |
| 196 | 0x0c4 | 0 | 100 | **0** | 0 |  |
| 197 | 0x0c5 | 0 | 100 | **0** | 0 |  |
| 198 | 0x0c6 | 0 | 100 | **0** | 0 |  |
| 199 | 0x0c7 | 0 | 100 | **0** | 0 |  |
| 200 | 0x0c8 | 0 | 100 | **0** | 0 |  |
| 202 | 0x0ca | 0 | 1000 | **0** | 0 |  |
| 256 | 0x100 | 0 | 1000 | **0** | -1 | premium |
| 257 | 0x101 | 0 | 1000 | **0** | -1 | death-penalty reduction (premium) |
| 258 | 0x102 | 0 | 1000 | **0** | -1 | premium |
| 259 | 0x103 | 0 | 100 | **0** | 0 |  |
