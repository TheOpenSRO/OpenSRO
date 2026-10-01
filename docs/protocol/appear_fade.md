# Characters fade into existence: CIDecoAppear and CIDecoDisappear (round 676)

READ from the decompiled client (`/var/tmp/decomp_client`, `/var/tmp/sro_client.asm` on the
render box; constants read out of `sro_client.exe`'s data). Labels: READ, MEASURED, INFERRED,
OURS, OPEN.

## The appear fade (READ)

| What | Where | Detail |
|---|---|---|
| Spawn | `FUN_008a6ca0` (0x3015) -> `FUN_008a6bd0(stream, 1)` | Creates the object by its ref id (`IGIDObject::FUN_009c1fa0`), runs its body reader (vslot 0x64), then vslot 0x68 (`FUN_009c2180`, reads one byte to +0xf4). |
| Group spawn | `FUN_008a6d20`, type byte 1 | `FUN_008a6bd0(stream, 0)` per object: sets byte +0xec = 1, runs the body reader, no vslot 0x68. |
| The start | vslot 0x6c, `FUN_009d17e0` (CICharactor) | `cmp byte [esi+0x770], 0` (asm 0x9d18f0); when set: `FUN_00ba36d0(0x110a770, 0)` makes the deco, then `CIDecoAppear::FUN_00a48a20(obj+0x30 (its id), [0xd86ecc])` (asm 0x9d190b-0x9d191b). |
| Who reaches it | body readers | `CICMonster::vslot_025` (0x9d3850) calls vslot 0x6c directly. Vslot 0x6c is `FUN_009d17e0` for CICMonster, CICNPC, CICCos, CICGuard and CICMonsterNPC (vtables 0xde26c4, 0xde293c, 0xde211c, 0xde225c, 0xd870b4); `FUN_009dbcc0` for CICUser (0xde2e7c), which ends in `FUN_009d17e0`; CICPlayer's `CICPlayer::vslot_027` (0x9d53d0) calls `FUN_009dbcc0`. CIItem and CITeleportGate have `FUN_009c1890`: no appear. |
| The class | class link 0x110a770 | Registered at 0xd77090: CreateObject 0xa48a50, size 0x60, name string 0xde5610 = `CIDecoAppear`. |
| The flag | CICharactor +0x770 | 1 in the constructor (`CICharactor::FUN_009d2ad0`, asm 0x9d2e50). Its only setter `FUN_009c7b10` (asm 0x9c7b14) is called with 0 at three places, all objects the client makes itself: a game script's CICUser (0x518514, CGScript), an icscriptobj (0x9e26de), and `FUN_0050f1b0` (0x50f24a). No packet path clears it. |
| Duration | float 0xd86ecc | **2.0** seconds. |
| Init | `CIDecoAppear::FUN_00a48a20` | +0x54 alpha = 0; +0x5c target id; +0x58 rate = 255.0 (double 0xd83108) / duration. |
| Per frame | `CIDecoAppear::vslot_009` (0xa48ae0) | alpha += rate x dt (the float at 0x110f7fc, the frame's elapsed time; that it is in seconds is INFERRED, as BSR_FORMAT.md records for the map objects' fade, which steps by the same float); if alpha <= 255: `SetAlpha(round(alpha) & 0xff)`; else `SetAlpha(0xff)` and the deco deletes itself (`entitymanager::FUN_00ba3770`). A target that is gone also deletes it. **Linear.** |
| SetAlpha | `CCompChar` vslot 5 (0xc25590), vtable 0xe0cd3c | `+0x4c = alpha << 24`. Reached as `(*(obj+0x9c)+4)->vslot 5`, the character's compound model. |
| Another writer | `FUN_009ce950` | Called from the CICharactor update (`FUN_009d1d60`) for every character but the player's own: sets 0 (invisible), 0x50 (stealth seen) or **0xff** every frame. That the deco's write lands after it in a frame is INFERRED from the fade being visible in play (the user's report, 2026-10-01). |

So monsters, NPCs, guards, pets and other players all fade in over the same 2.0 s, on every
spawn -- a single spawn and a group spawn alike, a fresh spawn and an object entering view alike
(there is no separate path). Ground items pop in.

## The disappear fade (READ)

| What | Where | Detail |
|---|---|---|
| Despawn | `FUN_008a6cc0` (0x3016); group despawn `FUN_008a6d20` type 2 | Looks the object up and tail-calls its vslot 0x4c with 0. |
| Remove | `IGIDObject::FUN_009c32f0` (base); `FUN_009d3c90` (CICMonster) | With 0 and a model: makes a `CIDecoDisappear` (0x110a790) on its id with [0xd819ec] = **1.5 s** -- or 0 s for a CICMonster whose +0x7b0 is set (set in `CICMonster::vslot_025` when its ref is `DAT_00ef1a7c`; what that is, OPEN). With 1 or no model: deleted at once. |
| Per frame | `CIDecoDisappear::vslot_009` (0xa49a30) | Starts at 255.0 (float 0xd85284), alpha -= 255 / duration x dt; while >= 0 sets it; below 0 deletes the deco **and the object**. For a character it also fades the object `FUN_009ce930` / `FUN_009ce910` return (a ridden or linked object, INFERRED). |
| Items | `CIItem::vslot_019` (0x9e21c0) | 1.5 s; `CIItem::FUN_009e1670` 1.8 s (float 0xdd81e8; which removal, OPEN). |

## What is not read (OPEN)

- Whether the name plate, the HP bar, the shadow or attached effects take the compound's alpha.
  Only `CCompChar`'s +0x4c is written; who reads it in the draw was not followed far enough
  (`FUN_00aac913` picks a render mode from it: 0xff000000 -> 0x20, 0 -> 0x21; the env-map mod
  `CRTModEnvMap::vslot_004` draws only when it is 0xff000000).
- The player's own character: `CICPlayer::vslot_009` (0x9d8d30) writes its alpha every frame
  from its own interpolator at +0x2068 (`FUN_009d4e80`) or 0xff/0x50, so whether it shows a
  spawn fade is not settled.

## This client (round 676, OURS)

`client/scripts/world/appear_fade.gd`. Godot 4.2's GL Compatibility renderer ignores
`GeometryInstance3D.transparency` (MEASURED: a model at 1.0 covered all its pixels), so a fading
model draws with blended twins of its materials, shared by every model whose fade started in the
same frame, and gets its own back at 2.0 s.
