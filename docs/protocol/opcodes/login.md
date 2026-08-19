# Login / authentication

Findings from RE work on the gateway-side binary (see `handshake.md` for the infra/process
notes — same policy applies: facts only, no decompiler output).

## Dispatch shape

Incoming messages get mapped to a small dense integer (not the raw 16-bit wire opcode directly)
before being switched on. We haven't yet pinned down the exact mapping from wire opcode to this
internal index — that's needed before this can turn into a real opcode table entry with a hex
`0x____` number like the ones in `handshake.md`.

## Credential verification: database-backed, not the legacy CGI path

The gateway binary contains **two** separate authentication code paths:

1. A legacy HTTP-CGI flow (calls out to a Yahoo Korea ISP verification endpoint, and a separate
   `cgi.joymax.com` "login fail" reporting endpoint). This is dead weight from an old regional
   integration — not relevant to a modern reimplementation, and not documented further here.
2. The real path: a direct call to a SQL Server stored procedure, shaped like
   `_CertifyUser '<username>', '<password>', '<fixed-literal>'` — the third argument is a
   constant value baked into the binary (not secret-looking in the way a real secret would be;
   reads like a fixed service/schema-version tag rather than a credential). This matches the
   general shape of stored-procedure-based auth that's been publicly documented by the
   private-server community for this MMO family for a long time (multiple independent
   open-source server projects implement an equivalent `_CertifyUser`-style stored procedure).
3. The stored procedure's result set is used to determine account status — two single-byte
   fields in the result are compared against `0x7F` as an apparent "blocked/restricted account"
   sentinel value, taking a different code path (a block-guide/reason lookup) when matched.

## Status / next steps

- [ ] Map the internal dispatch index back to real wire opcodes (need to find where the dispatch
      index gets derived from an incoming packet)
- [ ] Pull the exact `_CertifyUser` result-set column meanings (currently only "two status bytes,
      0x7F seems to mean blocked" is confirmed)
- [ ] Cross-reference the SRO_VT_ACCOUNT database backup (`db.rar` in the obtained package) against
      this stored procedure's apparent parameter/result shape once we have a way to actually open
      a SQL Server `.Bak` file to inspect schema
- [ ] Design an equivalent auth flow for the Go server (own schema, own password hashing — no
      reason to match the original's storage format even once the wire protocol is understood)
