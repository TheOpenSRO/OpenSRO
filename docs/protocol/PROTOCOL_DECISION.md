# Protocol direction: our own, not a wire-compatible clone

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
already written in `server/internal/proto` stays in the tree as a correctly-verified reference
implementation of what was actually found (the commit history documents real work, including two
caught-and-fixed mistakes) — but it is **not wired into the real server**. The actual
client<->server protocol going forward is defined fresh, opcode-by-opcode alongside each feature
(e.g. `OpLogin`/`OpEnterWorld`/`OpAttack` in `server/internal/session/{login,world,combat}.go`,
mirrored in `client/scripts/net/`) rather than one consolidated file — there is no single
`opcodes_own.go` or `OWN_PROTOCOL.md`, despite this doc originally saying there would be.
