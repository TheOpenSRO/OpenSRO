# Login / authentication

Findings from RE work on the gateway-side binary (see `handshake.md` for the infra/process
notes — same policy applies: facts only, no decompiler output). This file's first pass (dated
before 2026-08-22) worked from `sro_client.exe` only; a real, dedicated server binary
(`GatewayServer.exe`, from the same obtained package as the client and DB backups) has since
been imported and analyzed too, which is what let the "Dispatch shape" section below actually get
resolved instead of staying an open question.

## Dispatch shape (resolved)

Incoming messages get mapped to a small dense integer before being switched on -- **the real,
internal name for this value is "Div ID"** (confirmed by a real, literal error string the
dispatcher logs when it sees one it doesn't recognize: `"There is no certification handler!!! you
must register it first!!! [Div ID: %d]"`). This is a single byte, read from a fixed offset
(`+2`) into a small per-connection structure the dispatcher holds a live pointer to -- consistent
with that offset being this project's own real, confirmed wire-header layout's Opcode field
(`Size(2) + Opcode(2) + ...`, see `PACKET_FORMAT.md`), read as one byte rather than the full
16-bit value. This project has **not yet confirmed** whether Div ID is simply the low byte of the
real 16-bit wire opcode (i.e. `DivID = wire_opcode & 0xFF`) or is produced by some other real
translation step in between -- the single write site found for the pointer this byte is read
through turned out to be one-time server-startup config-table setup, not the actual per-packet
receive path, so the real place a fresh Div ID gets stamped onto an incoming connection per-packet
is still unlocated. Recorded here as the next concrete step, not guessed at further.

The real dispatcher (`GatewayServer.exe`) recognizes real Div ID values `0`-`0x1a` (0-26) for the
authentication switch specifically, each routed to one of two real stored-procedure call shapes
(see below) or a shared "unhandled" fallback. Several distinct Div IDs route to the exact same
handler code (e.g. `1`, `0xb`, `0x12`, and `0x13` all reach the same `_CertifyUser` call site) --
consistent with these being genuinely different real login variants/regions/clients sharing one
handler, not evidence that Div ID and wire opcode are unrelated.

## Credential verification: database-backed, not the legacy CGI path

The gateway binary contains **two** separate authentication code paths:

1. A legacy HTTP-CGI flow (calls out to a Yahoo Korea ISP verification endpoint, and a separate
   `cgi.joymax.com` "login fail" reporting endpoint). This is dead weight from an old regional
   integration — not relevant to a modern reimplementation, and not documented further here.
2. The real path: a direct call to one of **two** real SQL Server stored procedures, confirmed
   directly in `GatewayServer.exe` (not just inferred from the client):
   - `_CertifyUser '<username>', '<password>', '48dac2be2e0a23c6ca04e22896f24b13'` -- the third
     argument is a real, fixed literal baked into the binary (looks like an MD5-shaped hex string;
     reads like a fixed service/schema-version tag rather than a per-user credential). Used by Div
     IDs `0`/`1`/`0xb`/`0x12`/`0x13`/`0x18`/`0x19`.
   - `_CertifyTB_User '<username>', '<password>'` -- a second, real, distinct stored procedure
     with no third argument, used by Div IDs `3`/`5`/`6`/`7`/`8`/`9`/`0xa`/`0xc`/`0xd`/`0xe`/
     `0xf`/`0x10`/`0x11`/`0x15`/`0x16`/`0x17`/`0x1a`. Not previously documented in this file --
     only found once `GatewayServer.exe` itself was analyzed. "TB" is unconfirmed shorthand
     (plausibly "test bed"/an alternate account-table variant); not guessed at further.
   This matches the general shape of stored-procedure-based auth that's been publicly documented
   by the private-server community for this MMO family for a long time (multiple independent
   open-source server projects implement an equivalent `_CertifyUser`-style stored procedure).
3. Two distinct real "blocked account" status encodings were found, one per stored procedure:
   the `_CertifyUser` path checks two specific result bytes for `0x7F`/`0x7F`; the
   `_CertifyTB_User` path instead checks a single result byte for the literal value `3`. Both,
   when matched, call a real third stored procedure, `_QueryBlockGuide %d`, instead of returning
   the normal success/fail shape -- a block-reason lookup, not just a boolean flag. A real,
   literal `"Incorrect ID or PWD: %s"` error string exists on at least one of the `_CertifyTB_User`
   paths, confirming a third (plain failure, no result row) outcome distinct from both "success"
   and "blocked."

## Status / next steps

- [x] Map the internal dispatch index (real name: **Div ID**) back to *a* real wire concept -- it's
      read from the same header offset this project's own wire format keeps its Opcode field at,
      one byte only. Exact translation formula from the real 16-bit wire opcode to this one-byte
      Div ID is the new, more specific open question (see above) -- not yet the same as "pull the
      exact payload layout," which is still open too.
- [ ] Find where a live incoming packet actually gets a fresh Div ID stamped onto it. Traced
      significantly further this pass via real RTTI data (the same technique that found
      `ResObject::Load` for `.bsr`): the dispatch switch's virtual-method wrapper belongs to a
      real class, **`CUserCertifier_OverlapJob`** -- confirmed by reading its
      `RTTICompleteObjectLocator`/`TypeDescriptor` chain directly (mangled name
      `.?AVCUserCertifier_OverlapJob@@`). This reveals real architecture beyond just login:
      `GatewayServer.exe` has a small family of real `ServerFramework::COverlapJob`-derived async
      job classes (`CUserCertifier_OverlapJob`, `COverlapJob_InitializeLocalData`,
      `COverlapJob_RelayMsg`, `COverlapJob_Local`, managed by a real `COverlapJobManager`) --
      **not** one job class per opcode, though; `CUserCertifier_OverlapJob` alone owns the entire
      Div ID `0`-`0x1a` switch internally. Traced its constructor to a real object-pool
      initializer (`CChunkAllocatorST`-style, pre-allocating a pool of these job objects at server
      startup) -- a real, useful architectural fact, but a dead end for *this specific* question,
      since pool init doesn't touch per-packet opcode data. The real code that reads an incoming
      packet's actual wire opcode and picks/dispatches a pooled job for it is presumably in
      `COverlapJobManager` itself. Looked for its vtable via the same RTTI-chain technique this
      pass; found its `TypeDescriptor` but the `RTTICompleteObjectLocator`s referencing it didn't
      lead to a directly-instantiated vtable the way `CUserCertifier_OverlapJob`'s did (plausibly
      an abstract base class with no direct instance in this binary, or one this search technique
      didn't hit) -- a real, honest dead end for this specific pass, not pursued further right
      now. Flagged as the next concrete target for a future session.
- [ ] Pull the exact `_CertifyUser`/`_CertifyTB_User` result-set column meanings beyond "some
      bytes signal blocked/failed" (now two confirmed distinct encodings, see above)
- [ ] Cross-reference the SRO_VT_ACCOUNT database backup (`db.rar` in the obtained package) against
      both stored procedures' apparent parameter/result shape once we have a way to actually open
      a SQL Server `.Bak` file to inspect schema
- [ ] Design an equivalent auth flow for the Go server (own schema, own password hashing — no
      reason to match the original's storage format even once the wire protocol is understood)
