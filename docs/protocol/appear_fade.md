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
| Per frame | `CIDecoAppear::vslot_009` (0xa48ae0) | alpha += rate x dt (the float at 0x110f7fc: the frame's elapsed **seconds**, clamped to 3.0 (float 0xd8adc4), written beside the milliseconds at 0x110f7f8 (clamped to 3000) at 0xba40fb-0xba4136, and set together with it at 0x84c343); if alpha <= 255: `SetAlpha(trunc(alpha) & 0xff)` -- **truncated**: asm 0xa48b5f-0xa48b75 is `fnstcw; or eax, 0xc00` (rounding control = chop); `fldcw; fistp`, MSVC's float-to-int idiom -- so 63 / 127 / 191 at 0.5 / 1.0 / 1.5 s; else `SetAlpha(0xff)` and the deco deletes itself (`entitymanager::FUN_00ba3770`). A target that is gone also deletes it. **Linear.** |
| SetAlpha | `CCompChar` vslot 5 (0xc25590), vtable 0xe0cd3c | `+0x4c = alpha << 24`. Reached as `(*(obj+0x9c)+4)->vslot 5`, the character's compound model. |
| Another writer | `FUN_009ce950` | Called from the CICharactor update (`FUN_009d1d60`) for every character but the player's own: sets 0 (invisible), 0x50 (stealth seen) or **0xff** every frame. That the deco's write lands after it in a frame is INFERRED from the fade being visible in play (the user's report, 2026-10-01). |

So monsters, NPCs, guards, pets and other players all fade in over the same 2.0 s, on every
spawn -- a single spawn and a group spawn alike, a fresh spawn and an object entering view alike
(there is no separate path). Ground items pop in.

## The disappear fade (READ, round 677)

| What | Where | Detail |
|---|---|---|
| Despawn | `FUN_008a6cc0` (0x3016) | Reads the id, looks the object up (`IGIDObject::FUN_009c31a0`) and tail-calls its vslot 0x4c with 0. (Its test against the player's own id only logs, `FUN_0049d640`: "My Player ... destroy".) |
| Group despawn | `FUN_008a6d20`, type byte 2 | A count, then `FUN_008a6cc0` per id: the same path. |
| Remove | `IGIDObject::FUN_009c32f0` (base; CICNPC's vslot 0x4c is a thunk to it); `FUN_009d3c90` (CICMonster); `CICCos::vslot_019` 0x9c66e0; `CIItem::vslot_019` 0x9e21c0 | vslot 0x3c(1, 0) first (for a CICMonster `FUN_009d3e70` -> `FUN_009cf1b0` case 1 -> `FUN_009ccf50`, which calls vslot 8(1) on each entry of the object's list at +0x288 and empties it -- INFERRED its attached effects); then `IGIDObject::FUN_009c3270`: the object leaves the game-id hash `g_sHashGID` and its id +0xf8 becomes 0. With 0 and a model (`+0x9c`, its `+4`): `FUN_00ba36d0(0x110a790)` makes a `CIDecoDisappear`, initialised on the object's entity id (+0x30) with the float at **0xd819ec = 1.5 s** -- or 0 s for a CICMonster (`FUN_00b94b70(0xef1a84)`, the runtime class registered at 0xd764ab with the name string 0xde281c `CICMonster`) whose +0x7b0 is set. With 1, or no model: deleted at once (`entitymanager::FUN_00ba3770`). CICMonster and CICCos also fade the object `FUN_009ce930` returns when `+0x728`'s +0x24 is set (a linked object, INFERRED). |
| Players | CICUser vslot 0x4c, 0x9daf10 | Passes **1** (no fade) when its byte +0x2c2 is 4, 6 or 7 (the setter `FUN_009cf880` writes alpha 0x50 for mode 4 -- INFERRED a stealth mode), else `FUN_009c3580(+0x110)` and the base with 0: the 1.5 s fade. |
| Init | `CIDecoDisappear::FUN_00a49970` | +0x54 alpha = **255.0** (float 0xd85284); +0x5c target entity id; +0x58 rate = 255.0 (double 0xd83108) / duration. |
| Per frame | `CIDecoDisappear::vslot_009` (0xa49a30) | alpha -= rate x dt (the float at 0x110f7fc, as the appear). While alpha >= 0 (asm 0xa49aaa: `fcomp` with 0, `test ah, 0x41`) the model's `CCompChar` vslot 5 gets it **truncated**, & 0xff (asm 0xa49ab9-0xa49ad4: `fnstcw`, `or eax, 0xc00`, `fldcw`, `fistp` -- the decompiler's `ROUND` is wrong here, as for the appear). Below 0 it deletes itself and the object (`FUN_00ba3770`, asm 0xa49b34-0xa49b71). A target already gone deletes the deco. So **255 at 0, 170 at 0.5 s, 127 at 0.75 s, 85 at 1.0 s, 0 at 1.5 s, gone the frame after. Linear.** |
| Items | `CIItem::vslot_019` (0x9e21c0) | The same 1.5 s on a despawn. `CIItem::FUN_009e1670` (1.8 s, float 0xdd81e8) is reached only from `CIItem::vslot_005` message 0xff, the end of an item's own 0x101/0x102 timer sequence, not from a despawn. |
| Other despawns | `FUN_009c2c20` (from 0x84abaf, 0x84b75e) | Walks the id hash calling vslot 0x4c with **1**: every object deleted at once, no fade (a zone change / world reset). `CICScriptObj::vslot_019` 0x9e45d0 and `FUN_009e48c0` make decos for script objects. These are every `CIDecoDisappear` creator (`push 0x110a790` in the asm). |

**Death.** No death path makes a `CIDecoDisappear`. A dead monster stays until the server deletes
it, and the server's delete is a despawn (READ, SR_GameServer.exe):

- `CGObj::Update` (0x484d10, slot 211; reached from `CGObjMob::Update` 0x4c1700 -> `CGObjChar::Update`
  0x4a88f0 -> `CGObjMobile::Update` 0x48b8c0): while the life state is 2 it adds the tick's
  seconds to +0x3c and, once the sum reaches the float at `ref+0x18 -> +0x84` -- the ref record's
  DecayTime, kept in seconds (round 227) -- calls slot 218 (0x484cf0, `SetLifeState(3)`).
  (Asm 0x484d3f: `fcompp; test ah, 0x41; jp` -- it fires when DecayTime <= the sum.)
- The main loop (`CMainProcess::FUN_00413b30`) hands a state-3 non-player to `FUN_00417090`,
  whose `FUN_00489fc0` releases the object: slot 0x354 (`CGObjMob::ReleaseAndClear` 0x4c0eb0) ->
  slot 0x358 (0x4c10b0 -> `CGObjChar::vslot_214` 0x4a72e0 -> `CGObjMobile::vslot_214` ->
  `CGObj::vslot_214` 0x484a80) -> slot 0x364 (0x485150, the leave-world: with the object in a
  block, slot 0x3b0(0, 0, 0)) -> CGObjMob's slot 0x3b0 (0x4c1e00 -> 0x485bb0) -> the block's
  slot 3 (`FUN_005344b0`) -> `FUN_00534050`: **0x3016** with the object's id to the players of
  the block and its 8 neighbours.
- Monster DecayTime (characterdata column 13, ms; MEASURED over the distinct MOB_ codes of the
  box's extracted parts, `/var/tmp/characterdata_*.txt`, Service 1): **5000** for 7,459
  (MOB_CH_MANGNYANG among them), 10000 for 697 (MOB_CH_TIGERWOMAN), 8000 for 6, one each of
  3000 / 15000 / 30000 / 0. The player bodies read 1000000000. A client reading Media.pk2 takes
  7,495 MOB_ rows (MEASURED, round 677's live log).

So a monster's corpse lies **DecayTime from its death** (5 s for most) and then fades out over
1.5 s. A monster removed in a town (`CGObjMob::SetCurRegion` -> `SetLifeState(3)`, round 674)
goes through the same `FUN_00417090` and so reaches the client as the same despawn: it fades.

**The name plate.** A character's draw (vslot 10, `FUN_009d20d0`) draws the model
(`FUN_009c4aa0`), its attached effects and the name (`FUN_009d0a80`) with no test of the id or of
a deco: the name stays, at 0xff, until the object is deleted at the end of the fade. Nothing on
the despawn path sets the +0xd4 bit 2 that hides it (its setter `FUN_009c4160` is called only by
script/event objects: 0x51ae40, 0x535750, 0x556370).

**Clicks.** The pick (`FUN_0078ee20`) walks the list at 0xec4ae4 -- `CIGIDObject`'s class link,
added in its constructor (`FUN_009c1e30` from 0x9c2340) and removed in its destructor -- so a
fading object can still be hit; its id is 0 by then. What the click does with it is OPEN.

## What is not read (OPEN)

- Whether the shadow or attached effects take the compound's alpha. (The name plate does not: it
  is drawn at full alpha, `FUN_008b4d90(point, 0xff)`, READ in round 673.) Only `CCompChar`'s
  +0x4c is written; who reads it in the draw was not followed far enough
  (`FUN_00aac913` picks a render mode from it: 0xff000000 -> 0x20, 0 -> 0x21; the env-map mod
  `CRTModEnvMap::vslot_004` draws only when it is 0xff000000).
- NPCs (CICNPC), guards (CICGuard) and pets (CICCos) fade in retail -- their vslot 0x6c is
  `FUN_009d17e0` -- but this client builds NPCs from the map's data at region load and has no
  guards or pets yet: none of them fades here.
- The player's own character: `CICPlayer::vslot_009` (0x9d8d30) writes its alpha every frame
  from its own interpolator at +0x2068 (`FUN_009d4e80`) or 0xff/0x50, so whether it shows a
  spawn fade is not settled.

## This client (round 676, OURS; the fade-out round 677)

`client/scripts/world/appear_fade.gd`. Godot 4.2's GL Compatibility renderer ignores
`GeometryInstance3D.transparency` (MEASURED: a model at 1.0 covered all its pixels), so a fading
model draws with blended twins of its materials, shared by every model whose fade started in the
same frame, and gets its own back at 2.0 s. A plain StandardMaterial3D's twin is a small shader
(`AppearFade.STANDARD_FADE_CODE`) whose alpha is the fade's alone: the opaque original ignores its
texture's alpha, and a blended duplicate that multiplied it in showed holes mid-fade (round 676's
review, MEASURED in WORLD_ISSUES). The twin shaders are compiled while the world loads (`AppearFade.warm`): with
empty Godot and Mesa shader caches a monster's first frame took 135-199 ms on its twin, and 30-31
ms after the warm-up (MEASURED, WORLD_ISSUES round 676, Review).

The fade-out (round 677, `AppearFade.Fades.start_out`) uses the same twins in reverse: the meshes
take blended twins at alpha 255 (`out_alpha_at`: 255 - 170 x t, truncated), and when the value
goes below 0 the body is freed (`out_done_at`). A body fading in is put back on its own materials
first and fades out from 255 (INFERRED: the later deco's write is the one drawn). World3D hands a
body over with `_fade_out_body`: it leaves the id maps first, so the same id spawning again builds
a fresh body (as retail's object leaves `g_sHashGID`), loses its click collider (OURS), and keeps
its name plate and party mark as they are. Paths: `OpMonsterLeft` (leaving the area, or a town
removal, round 674), `OpEntityLeft` (another player), a ground item's removal, and a dead
monster's corpse after its species' DecayTime (the corpse's click collider goes at the death, and
dying ids are not picked: round 677's review, OURS) (`World3D._monster_corpse_seconds`; the time is the
client's, OURS -- this server drops a dead monster at once and sends no despawn). A zone change
frees every body still fading at once (`Fades.free_out_now`). A monster's list refresh dropping
it (`_sync_monster_bodies`, mostly a zone change) and a region unloading under a body still free
it at once (OURS: neither is a despawn).
