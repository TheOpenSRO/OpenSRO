# Protocol direction: full wire-level reimplementation (reversed 2026-08-22)

## Addendum (2026-10-01): a superset of the retail protocol

**The user's goal:**
- Keep wire compatibility with the original opcodes, and add our own features on top as a
  superset. An original client can talk to our server.
- Our client can talk to an old (retail-protocol) server, with the extras unavailable there.
- If that needs a compatibility layer, build one.

**State on 2026-10-01 (MEASURED):** the wire we run is still the placeholder scaffolding described
below. None of OpenSRO's 143 opcodes is a real one (SYSTEMS.md, round 324). The groundwork exists:
- `payload_layouts.tsv` maps 262 real opcodes' field widths;
- the reply envelope is known: result byte 1 = ok, 2 = u16 error code (rounds 467-468);
- the handshake is implemented in `server/internal/proto` but not wired in.

Round 678's front-end theme request (0x0005 -> 0x0006) is also our own opcode, and so is round
679's server status request (0x0007 -> 0x0008: version, current, max, state -- retail's shard-entry
fields; `docs/protocol/server_list.md`).

**The first step (round 681): our client speaks the retail gateway protocol as far as the server
list.** A `setting/config.yaml` server marked `type: legacy` is asked the way the original client
asks (`docs/protocol/opcodes/gateway.md`): the 0x5000 key exchange, the security bytes and Blowfish
(`handshake.md`, "The client's side, READ"), 0x2001, 0x6100 with the archive's own content id and
version, 0x6101 -> 0xA101 -- and its shards' real Check / Easy / Populated / Crowded / FULL are shown.
Nothing past the list (no login). Built twice, `client/scripts/net/retail/` and
`server/internal/retailgw` (with a fake retail gateway for tests and `cmd/retailgw`), held to the same
bytes. The `type` key is the user's decision (2026-10-01): required, `legacy` or `opensro`; once our
server speaks the retail wire too, `opensro` will mean "also has our extensions". Two limits found:
37 of the 255 checksum tables cannot be generated without the binary's bytes (the client reconnects
instead; `handshake.md`), and which 0xA101 layout the client reads hangs on a mode word whose
writer is OPEN (the gateway's rule is used). Our server still speaks only its own wire.

**Round 708: the first retail opcodes on OpenSRO's game connection.** The user decided (2026-10-03)
that NPCs reach the client "exactly as the original game does it, down to the exact opcodes": the
server spawns them with the retail group spawn 0x3017 / 0x3019 / 0x3018 (and the client also reads
0x3015 / 0x3016), the CICNPC record byte for byte (`docs/protocol/npc_spawn.md`). One OpenSRO
extension rides beside them, OpNpcFacingUnknown 0x00B6 (the NPCs with no nest angle), sent only ahead
of a group that holds such an NPC. Monsters and players still use OpenSRO's own messages.

**Noted by the user (2026-10-01), not designed:** a server may want to hand the client settings it
keeps out of the client's `setting/config.yaml` -- during the server list or after login. That would
be one more extension message of the kind item 2 below describes (docs/TODO.md).

**Proposed design (OPEN: Claude's recommendation, not yet decided by the user):**
1. **The compatibility layer is the architecture.** Game logic works on internal commands and
   events and never sees an opcode. Each wire protocol is a codec in front of it: a retail codec
   (per client version: vSRO, iSRO, ...) and an extension codec.
2. **Extensions on the same game connection, negotiated.**
   - Keep retail's framing on the one TCP stream.
   - Our client advertises "OpenSRO extensions vN" during the handshake.
   - Only then does the server use extension packets, in an opcode range retail never uses, with
     Protobuf payloads so they can evolve.
   - An original client never negotiates, so it never sees them. Our client facing an old server
     gets no answer, speaks pure retail, and hides what it lacks.
   - Our own opcodes (such as 0x0005/0x0006) move into that range.
3. **gRPC for everything that is not the game client:** server to server (gateway, shards,
   database), admin and web panels, and the planned external bot API. It stays off the game
   connection, because Godot has no native gRPC and it would need a second transport.

**Decision reversed (2026-08-22, superseding the 2026-08-19 decision below):** the goal is a true
end-to-end rewrite of the original server *and* protocol — not just an own-designed client/server
pair that happens to implement similar game systems. That means the real wire protocol (real
opcodes, real payload layouts, real handshake/security-byte scheme, eventually real encryption)
needs to be reverse-engineered and reimplemented opcode by opcode, so that this server can
ultimately speak the protocol a real (or lightly modified) client speaks — not just this project's
own Godot client.

**What this actually changes, concretely:**

- The own-designed opcodes currently in `server/internal/session/{login,world,combat,...}.go`
  (`OpLogin = 0x0001`, `OpEnterWorld = 0x0020`, etc.) are **placeholder scaffolding**, not the
  destination. They stay functional (and tested) while the real opcode-by-opcode RE work happens
  in parallel, but every one of them is expected to eventually be replaced by its real counterpart
  once that opcode's real wire number and payload layout are confirmed.
- The handshake reference implementation already sitting in `server/internal/proto`
  (`RollingByte`, `DeriveSeed`, `PacketChecksum`, `OpHandshakeRequest`/`OpHandshakeAccept`) is no
  longer just a "verified reference, not wired in" — it's the first real piece of the actual
  target protocol, and should get wired into the live gateway/session layer as real work resumes.
- `PacketChecksum`'s from-scratch table family (see `docs/protocol/opcodes/handshake.md`) was
  built specifically to *avoid* reproducing the original's proprietary CRC table contents, under
  the old "own protocol, no reason to match" framing. That reasoning no longer applies at the same
  strength — real wire compatibility now needs the *real* per-session table selection behavior
  even if the literal table bytes still shouldn't be copied verbatim from the binary (see
  `docs/LEGAL.md` policy #2). This is an open question to revisit once handshake wiring resumes,
  not resolved by this doc.
- Every opcode this project hasn't RE'd yet (i.e. nearly all of them — `docs/protocol/opcodes/`
  currently only has `handshake.md` and a still-incomplete `login.md`) is real, scoped,
  outstanding work, not a "won't do."

**Honest scope/timeline note:** this is a large undertaking. The original protocol has on the
order of hundreds of real opcodes across login, character select, world sync, inventory,
combat, skills, trade, party, guild, chat, and more — each needs its real payload layout pulled
from the binary (not just confirmed to exist), the way `docs/protocol/opcodes/login.md`'s own
status section shows is still unfinished even for the *first* real opcode looked at. This will
span many sessions, worked through incrementally (one opcode/system at a time), the same way this
project's asset-format RE (`.bsr`, `.bms`, `.mapm`, ...) was done one format at a time rather than
all at once. Track progress in `docs/protocol/opcodes/` (one file per opcode group) and
`docs/PROGRESS.md`, the same way this project already tracks everything else.

**Still true and unaffected by this reversal:** RE work on game data/logic — item stats, drop
tables, skill formulas, DB domain model (`db_schema.md`), pk2 asset container format
(`PK2_FORMAT.md`) — was never blocked on this decision either way; it stays exactly as valuable as
before.

---

## Superseded: the 2026-08-19 "own protocol" decision

The text below is kept for history — it's what this doc said before the reversal above, and
explains why the handshake reference code was originally built but not wired in. No longer the
operative decision.

Decision (2026-08-19): the new Go server and new Godot client only need to agree with **each
other**. This project is not trying to make the new server accept connections from the original,
unmodified Joymax client — the client is being rewritten too. That changes what the RE work in
`docs/protocol/opcodes/` is *for*:

- **Still valuable**: facts about game data/logic — item stats, drop tables, skill formulas, DB
  domain model (`db_schema.md`), pk2 asset container format (`PK2_FORMAT.md`) — anything that
  describes *what the game does*, independent of how bytes moved over the original wire.
- **No longer load-bearing for implementation**: the original protocol's specific obfuscation
  scheme — handshake opcodes `0x5000`/`0x9000`, the LFSR-seeded rolling byte, the multi-table
  CRC-32-style byte (`opcodes/handshake.md`). That was the original client/server's own security
  theater; a from-scratch client and server talking to each other over a connection we control
  (TLS available if wanted) has no reason to replicate it.

The `RollingByte`/`DeriveSeed`/`PacketChecksum`/`OpHandshakeRequest`/`OpHandshakeAccept` code
already written in `server/internal/proto` stayed in the tree as a correctly-verified reference
implementation of what was actually found (the commit history documents real work, including two
caught-and-fixed mistakes) — but was **not wired into the real server**. The actual client<->server
protocol was defined fresh, opcode-by-opcode alongside each feature (e.g.
`OpLogin`/`OpEnterWorld`/`OpAttack` in `server/internal/session/{login,world,combat}.go`, mirrored
in `client/scripts/net/`) rather than one consolidated file.
