# Login / authentication

Findings from RE work on the gateway-side binary (see `handshake.md` for the infra/process
notes — same policy applies: facts only, no decompiler output). This file's first pass (dated
before 2026-08-22) worked from `sro_client.exe` only; a real, dedicated server binary
(`GatewayServer.exe`, from the same obtained package as the client and DB backups) has since
been imported and analyzed too, which is what let the "Dispatch shape" section below actually get
resolved instead of staying an open question.

## Dispatch shape (revised -- "Div ID" is probably not the wire opcode at all)

Incoming messages get mapped to a small dense integer before being switched on -- **the real,
internal name for this value is "Div ID"** (confirmed by a real, literal error string the
dispatcher logs when it sees one it doesn't recognize: `"There is no certification handler!!! you
must register it first!!! [Div ID: %d]"`). This is a single byte, read from offset `+2` of a small
structure the dispatcher holds a live pointer to, and the *only* write site found for that pointer
turned out to be one-time server-startup config-table setup, not a per-packet receive path.

An earlier pass through this file guessed this offset-`+2` byte was likely the low byte of the
real wire opcode, by analogy with this project's own header layout. **Revising that guess** now
that `dispatch.md` has found the real per-packet receive method
(`ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake()`) and confirmed the real wire opcode field is
called **"MsgID"**, read and compared as a *full 16-bit value* (`0x5000`, `0x9000` compared
directly, not masked to one byte) at a completely different offset (`+0x1050` on `ACTIVE_SESSION`,
see `handshake.md`) on a completely different object than the one Div ID comes from. Given Div
ID's value only ever gets set once, at startup, from what looks like a config/registration-table
traversal, **"Div ID" most plausibly means "Division ID"** -- a real, known Silkroad server concept
(which login "division"/channel a given gateway/certifier instance is registered to serve), not a
per-packet opcode translation at all. Not conclusively proven either way yet, but this is now the
better-supported reading, and this project is **not** treating "Div ID = wire-opcode-derived
dispatch index" as resolved any more -- that framing from the previous pass was a real, corrected
mistake, not a confirmed fact. The genuine remaining question -- how a live `MsgID` actually
selects a handler -- is `dispatch.md`'s open item, not this file's.

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

- [x] ~~Map the internal dispatch index ("Div ID") back to the real wire opcode~~ -- **retracted**,
      see the revised "Dispatch shape" section above: Div ID is most plausibly a real
      "Division ID" registration concept, unrelated to per-packet opcode dispatch, not a translated
      form of the wire `MsgID`. The real earlier framing of this checklist item was a mistake, not
      a fact -- corrected rather than left standing.
- [x] Identified the real class owning the login-specific `_CertifyUser`/`_CertifyTB_User` switch:
      **`CUserCertifier_OverlapJob`**, found via its real `RTTICompleteObjectLocator`/
      `TypeDescriptor` chain (mangled name `.?AVCUserCertifier_OverlapJob@@`) -- the same technique
      that found `ResObject::Load` for `.bsr`. This surfaced a small real family of
      `ServerFramework::COverlapJob`-derived async job classes (`CUserCertifier_OverlapJob`,
      `COverlapJob_InitializeLocalData`, `COverlapJob_RelayMsg`, `COverlapJob_Local`, managed by a
      real `COverlapJobManager`) -- not one job class per opcode; `CUserCertifier_OverlapJob` alone
      owns the whole Div ID `0`-`0x1a` switch internally.
- [x] Found the real, broader per-packet receive path -- **`ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake()`**,
      confirmed via real embedded debug strings (see `handshake.md`), reads the real 16-bit `MsgID`
      field directly (not Div ID -- a different object entirely from the certifier job above). This
      is genuinely the real entry point a raw received packet's opcode is first inspected at,
      pre-handshake-completion. Whether/how this connects onward to Div ID-based dispatch for
      post-handshake opcodes (login included) is the open question now, not the translation
      formula this checklist item used to ask for.
- [ ] Trace from `ACTIVE_SESSION`'s real per-packet path (now found, see `handshake.md`/
      `dispatch.md`) forward to wherever `CUserCertifier_OverlapJob` actually gets picked and
      populated for a login-shaped `MsgID` -- the genuine remaining link between "a raw packet
      arrived" and "the certifier switch ran with some Div ID." Not yet traced. (An earlier version
      of this note pointed at a global `std::map`-based registry found in the sibling
      `AgentServer.exe` binary as a well-grounded hypothesis for the mechanism -- retracted, see
      `dispatch.md`'s correction: that registry turned out to be a connected-user table, not an
      opcode-handler map. The real mechanism is still unfound in both binaries.) `dispatch.md` did
      find two new real opcodes (`0xa103`, `0x6201`) and a real Gateway-to-Agent login hand-off
      sequence while chasing this -- real, useful, but not this specific answer.
- [ ] Pull the exact `_CertifyUser`/`_CertifyTB_User` result-set column meanings beyond "some
      bytes signal blocked/failed" (now two confirmed distinct encodings, see above)
- [ ] Cross-reference the SRO_VT_ACCOUNT database backup (`db.rar` in the obtained package) against
      both stored procedures' apparent parameter/result shape once we have a way to actually open
      a SQL Server `.Bak` file to inspect schema
- [ ] Design an equivalent auth flow for the Go server (own schema, own password hashing — no
      reason to match the original's storage format even once the wire protocol is understood)
