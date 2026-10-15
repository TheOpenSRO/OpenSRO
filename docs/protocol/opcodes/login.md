# Login / authentication

Findings from RE work on the gateway-side binary (see `handshake.md` for the infra/process
notes — same policy applies: facts only, no decompiler output). This file's first pass (dated
before 2026-08-22) worked from `sro_client.exe` only; a real, dedicated server binary
(`GatewayServer.exe`, from the same obtained package as the client and DB backups) has since
been imported and analyzed too, which is what let the "Dispatch shape" section below actually get
resolved instead of staying an open question.

## The real, complete wire sequence: found via public documentation (2026-08-23)

**Source**: the same public private-server community documentation
([`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs)) that solved this project's
`.m`/`.t`/`tile2d.ifo` formats — per [`docs/LEGAL.md`](../../LEGAL.md) point 3, real public
protocol documentation (like the real opcode numbers and payload layouts below) is fair game as a
spec to implement against, the same footing already used for the Blowfish key schedule and pk2
container structure. This is genuinely new information for this file, not a restatement of the
decompiled findings below — it gives full payload layouts for opcodes this project had previously
only confirmed *exist* (`0xa103`) or found the *purpose* of without a payload (`0x6111`/`0x6112`'s
neighbors), and fills in the surrounding sequence this project hadn't found at all yet.

**Cross-validated, not blindly trusted**: every opcode below that this project had already
independently harvested from a real binary (`observed_opcodes.md`) or decompiled (`0xa103` above)
matches exactly — `0x6101`/`0xa101` (shard list), `0xa102` (login ack), `0xa103` (agent login
ack, already independently confirmed via decompilation as the real Gateway→Agent login hand-off,
now with its real payload), `0xa106` (shard ping ack), `0x2322`/`0xa323` (already-known IBUV
opcodes — see below), and `0x1001`/`0x2001`/`0x5000`/`0x6004`/`0xa004` (shared `ServerFramework`
infrastructure opcodes, also independently harvested). This agreement across independent RE
methods (binary opcode-harvest, decompiled purpose-tracing, public documentation) is strong,
convergent evidence, not three unrelated leads.

**The real, complete gateway login sequence** (client ↔ gateway, then gateway hands off to agent):

| Opcode | Direction | Name | Real payload |
|---|---|---|---|
| `0x6100` | C→S | `GATEWAY_PATCH_REQ` | `ContentID`(u8) + `Client.Name` (length-prefixed string, e.g. `"SR_Client"`) + `Client.Version`(u32, from `SV.T`) |
| `0xA100` | S→C | `GATEWAY_PATCH_ACK` | `Result`(u8); if `2` (`Update`): download server IP/port, latest version, then a real file-list stream (ID, name, path, size, `IsPacked`) terminated by a `CanRead=false` sentinel |
| `0x6104` | C→S | `GATEWAY_NOTICE_REQ` | `ContentID`(u8, locale) |
| `0xA104` | S→C | `GATEWAY_NOTICE_ACK` | `NoticeCount`(u8) then that many `{Subject, Article, DateTime}` records |
| `0x6101` | C→S | `GATEWAY_SHARD_LIST_REQ` | empty |
| `0xA101` | S→C | `GATEWAY_SHARD_LIST_ACK` | (not fetched in this pass — real opcode confirmed via cross-validation, payload not pulled) |
| `0x6106` | C→S | `GATEWAY_SHARD_LIST_PING_REQ` | empty |
| `0xA106` | S→C | `GATEWAY_SHARD_LIST_PING_ACK` | `Result`(u8); if `1`: `Farm.ID`(u8) + `IPAddress`(u32, IPv4) |
| `0x6102` | C→S | `GATEWAY_LOGIN_REQ` | `ContentID`(u8) + `Username` + `Password` (both length-prefixed strings) + `ShardID`(u16) |
| `0xA102` | S→C | `GATEWAY_LOGIN_ACK` | `Result`(u8); if `1`: `QueueID`(u32) + `AgentServer.IP`/`Port`; if `2`: a `LoginErrorCode`(u8) |
| `0x2322` | S→C | `GATEWAY_LOGIN_IBUV_CHALLENGE` | a real CAPTCHA-style challenge image (flags, remaining/compressed/uncompressed lengths, 200×64 dimensions, compressed image bytes) |
| `0x6323` | C→S | `GATEWAY_LOGIN_IBUV_CONFIRM_REQ` | `Code` (length-prefixed string — the user's typed CAPTCHA answer) |
| `0xA323` | S→C | `GATEWAY_LOGIN_IBUV_CONFIRM_ACK` | `Result`(u8); if `2`: `MaxAttempts`/`CurAttempts`(u32 each) |
| `0x6103` | C→S | `AGENT_LOGIN_AUTH_REQ` | `QueueID`(u32, **from `GATEWAY_LOGIN_ACK`**) + `Username` + `Password` + `ContentID`(u8) + `MACAddress`(6 bytes) — sent to the `AgentServer.IP`/`Port` `GATEWAY_LOGIN_ACK` handed back, not the gateway |
| `0xA103` | S→C | `AGENT_LOGIN_AUTH_ACK` | `Result`(u8); if `2`: an `AuthenticationErrorCode`(u8) — **this is the real payload for the opcode this file's decompiled findings below already independently confirmed as the real Gateway→Agent login hand-off response**, now fully resolved |

**This directly resolves/extends several previously-open items in this file**:

- `0x2322`/`0x6323`/`0xA323` are the real, named **`GATEWAY_LOGIN_IBUV_*`** (Image-Based User
  Validation — a real CAPTCHA challenge/response) opcodes — `0x2322` and `0xA323` were already
  independently harvested in `observed_opcodes.md`, now named and given real payloads. **These are
  distinct from, not the same as,** the `0x6111`/`0x6112` pair the "Real confirmed meaning for two
  more opcodes" section below found — those are a separate, internal gateway→agent relay-tag pair
  for the *result* of this same IBUV check (sent onward via `RelayMsg`, not back to the client),
  not client-facing opcodes themselves. The two findings compose into one real picture: client ↔
  gateway does the actual IBUV challenge/response over `0x2322`/`0x6323`/`0xA323`, and the gateway
  then tells **GlobalManager** (not the agent server, as this bullet first said) which way it went
  over the internal `0x6111` (**failure**) / `0x6112` (**success**) pair. **Corrected in round 788**
  (READ GatewayServer 0x406b45 / 0x406ccf; see "The login reply, READ (round 788)" below): this
  file had the pair the wrong way round.
- `0x6103`'s real payload confirms **why** `AGENT_LOGIN_AUTH_ACK` (`0xA103`) is sent
  *agent*→client, not gateway→client, despite being part of the "gateway login" flow this file is
  about: the client is instructed to open a *new* connection to `AgentServer.IP`/`Port` (from
  `GATEWAY_LOGIN_ACK`) and re-present its credentials there, carrying the real `QueueID` gateway
  issued — a real, concrete confirmation of the "Gateway-to-Agent login hand-off" this file's own
  decompiled tracing already found the *purpose* of but not the full context for.
- Directly informs the still-open checklist item "Design an equivalent auth flow for the Go
  server" — the real sequence and payload shapes above are now available as a concrete reference
  to implement against, independent of the still-unresolved internal Div-ID dispatch mechanism
  below (which is server-internal plumbing, not part of the real wire contract a client needs).

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

## Real confirmed meaning for two more opcodes: `0x6111`/`0x6112`

Found while decompiling `observed_opcodes.md`'s `GatewayServer.exe` cluster for actual payload
info: the real function containing both writes is unmistakably the handler for a real, literal
`FRAMEWORKMSG_IMAGE_BASED_USER_VALIDATE_REQ` message (name confirmed by the same real error string
already found -- `"[OnFRAMEWORKMSG_IMAGE_BASED_USER_VALIDATE_REQ] RelayMsg Failed"`). Real logic
traced directly:

- Looks up a "CertParam" for the connection; if missing, sends `0xa103`'s neighbor `0xa102` with a
  real logged error (`"...No Registered CertParam!!"`) and disconnects -- a real failure path, not
  part of the normal flow.
- Otherwise decodes some real user-supplied data and validates it (`FUN_0040a910`).
  - **Validation succeeds** (the right image code): sends `0xa323` `[1]`, then relays
    **`0x6112`** `[account]` onward.
  - **Validation fails**: relays **`0x6111`** `[account, u8 1]` onward; the answer (`0xA111`)
    becomes `0xa323` `[2, u32 max, u32 used]`.

**Round 788 correction.** This section first had the pair the other way round (`0x6112` on a
failure, `0x6111` on a success) and named `AgentServer.exe` as the receiver. Both were wrong: READ
GatewayServer 0x406b45 (`0x6111`, the failure) and 0x406ccf (`0x6112`, the success); the receiver
is GlobalManager, whose `0xA112` handler clears the account's failure history (0x40f050) and
whose `0xA111` answer carries the attempt counts. `0x6111` also carries every wrong password, type
0, and the gateway's `0xA102 [2,1,max,used]` is built from its answer (see the next section).

So `0x6111`/`0x6112` are a real failure/success pair, sent gateway -> GlobalManager as part of the
relay chain (`dispatch.md`), not client-facing opcodes in the ordinary sense: `0x6111`
`[string account, u8 type]` (0 password, 1 image code, 2 MOTP) and `0x6112` `[string account]`.

## The login reply, READ (round 788)

Recovered in round 788 from GatewayServer.exe (`/var/tmp/retailgw681/gw.asm`), GlobalManager.exe
(`/var/tmp/acct788/gm.asm`), AgentServer.exe and sro_client.exe on the RE box. Addresses are the
gateway's unless named. OpenSRO's server implements it in `server/internal/session/loginservice.go`
(`LoginService`) for every front door; the bytes are `loginack.go`'s, held to the client's by
`client/scripts/net/testdata/login_golden.json`.

### The full chain

1. **0x6102** (client -> gateway, encrypted; READ client `CClientNet::vslot_004` 0x4c9290):
   `u8 contentId, string username, string password, u16 shardId` (strings are u16 length + bytes,
   no terminator). The ID inside 0x6102 is as typed; the client keeps a lower-cased copy for
   0x6103. The client sends nothing (and shows nothing) for an empty ID, an empty password or no
   matching server, and locks the button for 3.0 s.
2. The gateway runs a certify job (content 22: `_CertifyTB_User '%s','%s'`, job 0x415e40). Row
   `u8 result, u32 JID, ...`. Result 0: in. Result 3: blocked -> `_QueryBlockGuide <JID>` fills a
   0x200-byte reason and a 16-byte date (0x415f46). Anything else: a wrong password -> `0x6111`
   type 0 to GlobalManager. A query error: the generic failure. The failure builder 0x40dc40 sends
   `[2,2,1, reason, date]` for the block and `[2,6]` for anything unknown -- **and does not
   disconnect** (no disconnect call, vtable+0x5c, in 0x40dc40 or its caller 0x40dc2a).
3. Certify OK -> 0x40d710: the shard: not found `[2,4]`; full and the account not exempt `[2,5]`
   (0x40d871); age checks `[2,10]`/`[2,11]`; the GM-from-an-unprivileged-PC refusal (13) is patched
   out of this vPLUS build. No disconnect in 0x40d710-0x40de06. Then 0x6200 `[u32 IP, u32 JID,
   u8]` to GlobalManager.
4. GlobalManager answers 0xA200. Its errors (0x401b70: the duplicate first, then the per-IP count;
   inspection after): 1 already logged in `[2,3]`; 2 per-IP limit (`MaxUserForNonePCBangIP`)
   `[2,8]`; 3 inspection `[2,2,2]`; 4 free service over `[2,2,4]`; 5 the JID already under that IP
   `[2,6]`; billing down `[2,9]`. **The gateway disconnects after every 0xA200 error** (0x405e1d).
   Result 1: the image code (IBUV) is prepared and sent, 0x2322.
5. The client answers 0x6323 `[string code]`. Right: 0xA323 `[1]` and `0x6112` -> GlobalManager
   0xA112 (clears the failure history, 0x40f050) -> 0x6203 to the shard -> 0xA203 -> **0xA102
   `[1, u32 token, string agentIP, u16 port]`** (a 192.168.x.x client is given the agent's LAN
   address, 0x405ec7). Wrong: `0x6111 [acct, 1]` -> 0xA111 -> 0xA323 `[2, u32 max, u32 used]`.
6. The client closes the gateway connection and logs in to the agent with 0x6103 `[u32 token,
   string ID (lower-cased), string PW, u8 contentId, u8[6]]`, answered by 0xA103.

### 0xA102 (gateway -> client)

READ: the client's reader `CClientProcess::vslot_017` 0x4cf500 -> `CPSTitle::vslot_006` 0x86bfc0
(jump table 0x86caf8). Success `[1, u32 token, string agentIP, u16 port]`; failure `[2, u8 code]`:

| Code | Extra | What the client shows |
|---|---|---|
| 1 | u32 max, u32 used | `UIIT_STT_GLOBAL_PASSWORD_INPUT_ERROR`, filled (max, used), each cut to 16 bits |
| 2 / 1 | string reason, 16-byte TIMESTAMP_STRUCT (u16 Y,M,D,h,m,s + u32 fraction, ignored) | `UIO_MSG_ERROR_ACCOUNT_STOP` + `..._STOP_BLOCK` + reason + `..._BLOCK_TIME` + the date (`GetDateFormatA` long date + `GetTimeFormatA`) |
| 2 / 2 | - | `UIO_MSG_ERROR_ACCOUNT_CONNECT_IMPOSSIBILE` (inspection) |
| 2 / 3 | - | `UIO_MSG_ERROR_THERE_IS_NO_ACCOUNT_INFO` |
| 2 / 4 | - | `UIO_MSG_ERROR_GRATIS_USER_BLOCKED` |
| 3 | - | `UIO_MSG_ERROR_OVERLAP` (already connected) |
| 4 | - | "Failed to connect to server.(C5)" |
| 5 | - | `UIO_MSG_ERROR_SERVER_BUSY_CONNECT_IMPOSSIBILE` (full) |
| 6 | - | "...(C7)", the generic failure |
| 7 | - | "...(C8)" |
| 8 | - | `UIO_MSG_ERROR_CONTENT_FAIL_INSUFFICIENT_IP` (the per-IP limit) |
| 9 | - | `UIIO_CLIENT_START_CONTENT_FAIL_BILLING_RELATED` |
| 10 / 11 | - | `UIIO_SMERR_ADULT_ONLY_SERVER` / `UIIO_SMERR_TEENOVER_ONLY_SERVER` |
| 12 | - | `UITT_TEENSERVER_ERRMGS_ADULT` |
| 0, 13+ | - | nothing |

"(Cn)" is `"(%c%d)"` with the client's internal number (the wire number + 1, INFERRED) after
`UIO_MSG_ERROR_SEVER_CONNECT`'s text. A '#' in the block reason splits it (INFERRED 0x86c136..):
the text before goes in the box, the rest opens a "[Block Detail]" window. JellyBitz's public docs
give the client's internal numbers as wire codes and a 14-byte date; both are wrong (16 bytes).

### 0xA103 (agent -> client)

READ AgentServer 0x402120: content id mismatch -> no reply, disconnect; server not ready or token
unknown `[2,3]`; credentials differ from the queued login `[2,1]`; registration fails `[2,2]`;
relay fails `[2,3]`; the shard's 0xA201 error 2 -> `[2,5]`, 6 -> `[2,6]`, else `[2,3]`. Client
(vslot_018 0x4cf7a0): `[1]` success; 1 -> "(C9)", 2 and 3 -> "(C10)", 4 -> server busy, 5 ->
insufficient IP, 6 -> `UIIO_CLIENT_START_CONTENT_FAIL_BILLING_FAILED`, other -> nothing.

### Wrong passwords

READ GlobalManager 0x464ac0: failures are counted per account **NAME**, per type (password,
image code, MOTP), server-wide. `max` is `LoginFailureTolerance`: code default 3 (0x40f3ec), the
block `LoginFailureBlockTimeMin` code default 10 minutes (0x40f404); this package's server.cfg
(MEASURED) has tolerance 3 and block time 0. Each failure answers `[2,1,max,used]`. Below `max`
the connection stays open and the player retries on it. When `used >= max`: `EXEC
_RegisterAutomatedPunishment '<acct>',1,'<AutomatedPunisher>','<LoginPunishmentGuide>',
'<LoginPunishmentDescription>',<minutes>` (0x4277a5), the count is cleared, and the gateway sends
the `[2,1,max,used]` and **closes** the connection (0x4071c7 -> the disconnect at 0x4071e3). Only
the image code's success (0x6112) clears the history; a right password alone does not. Whether a
count expires with time: OPEN.

### Already connected

READ GlobalManager 0x401b70 / 0x402220: a JID found in the logged-in table is error 1 ->
`[2,3]`, and the gateway disconnects the **new** client (0x405e1d). The old session is **not**
kicked. (The client's text asks the player to try again in 5 minutes.)

### IBUV (the image code)

Always issued for a login whose password is right and that GlobalManager admits (READ). This
package: `IBUVStringSize 1`, `IBUVCharacterSet "1"` (MEASURED). 0x2322 `u8 flag, u16 n, n bytes`
(gateway 0x4067ea, client 0x4cd3c0; compression OPEN); 0x6323 `string code`; 0xA323 `[1]` or
`[2, u32 max, u32 used]` (`UIIT_STT_GLOBAL_AUTHENTICATION_INPUT_ERROR`, filled (max, used), so it
reads backwards in English). At `IBUVFailureTolerance` (default 3): disconnect and a punishment.
`IBUVFailureIPTolerance` (0 = off) refuses 0x6102 with `[2,6]` past it (0x405ade).

### What OpenSRO does (round 788)

`session.LoginService` decides every login -- the old OpLogin 0x0001 (whose reply stays a reason
string, `LegacyReason`), the 0x6102 on OpenSRO's own connection, and the retail listener. In
retail's order:

| Step | Reply | Close | Label |
|---|---|---|---|
| a login on a connection already logged in | `[2,3]` | no | OURS (retail's client has left the gateway by then) |
| wrong ID or password, below the tolerance | `[2,1,max,used]` | no | READ |
| wrong ID or password reaching the tolerance | `[2,1,max,used]`, the count cleared, a type-1 block of `-login-failure-block-min` minutes (0 = none) | **yes** | READ (defaults 3 / 10 READ; `-login-punishment-guide` text OURS) |
| an active login punishment (types 1 and 2) | `[2,2,1, guide, end]`, the end in the server's local time; no end: the begin + 100 years (what the SMC's "Set Infinite Duration" writes, READ SR_UserPunishment.dll 0x10006610) | no | READ |
| the account store fails | `[2,6]` | no | READ |
| full (characters in the world >= `-max-players`), not a GM account | `[2,5]` | no | READ (the GM exemption OURS, round 679) |
| the account logged in on another live session | `[2,3]` | **yes** | READ; the old session is untouched |
| `-max-users-per-ip` accounts already in from the address (0 = off) | `[2,8]` | **yes** | READ (off by default: OURS) |
| `-inspection`, not a GM account | `[2,2,2]` | **yes** | READ (GM exemption OURS; retail exempts privileged IPs) |
| in | `[1, 0, "", 0]` on OpenSRO's connection | no | OURS (no agent hand-off) |

**On the original client's path** (the retail listeners, `internal/retailsrv`): the gateway's
0x6102 calls `Login` with no session -- the same counting, block, full, already-connected,
per-IP and inspection decisions, the connection closed as above -- and the account is entered in
the logged-in table only on the agent connection, by `LoginService.AdmitSession` after the 0x6103
token checks out; the agent's disconnect releases it. Retail's GlobalManager holds the account from
its admission at the gateway step, so two logins of one account cannot both reach the agent; on
OpenSRO a second login can pass the gateway in the seconds before the first one's 0x6103, and its
0x6103 is then refused with 0xA103 `[2,2]` and the connection closed. AgentServer has no code for
this case (INFERRED nearest: 2 is its own "user registration failed"; the client shows the same
"(C10)" for 2 and 3, READ 0x4cf7a0).

OURS choices, each in the code: a successful login clears the name's count (retail: the image
code's success; OpenSRO has none); a name's count is forgotten an hour after its last failure
(`LoginFailureExpiry`; retail's expiry OPEN); the password is checked before the block (whether
`_CertifyTB_User` does the same is OPEN, the procedure is in the account database we do not
have); an account is released for a new login only after the gateway's OnDisconnect has saved its
character (the last disconnect hook); the reason on the wire is cut at 511 bytes (the gateway's
0x200-byte field, 0x415f4c).

## Punishments (READ, round 788)

- **Retail has no in-game persistent ban.** The GM command `Ban` (client command table
  0x558937..0x559cb3, handler 0x5488b0, one argument) sends 0x7010 `{u16 0x000D, string name}`;
  `bansel` (0x5427a0) the same with the selected object's name. SR_GameServer case 0x0D
  (0x51f2c4..0x51f3e7): a name lookup; not found -> 0xB010 `{2, u16 0x1404}`; found ->
  `FUN_004df050(player, 4)` (the generic force-out), 0xB010 `{1, u16 0x000D}`, the log line
  "BanPlayer: %s". No database write: a **kick** (INFERRED). No Kick, Block or Mute command exists
  in the client's table.
- **Persistent bans are punishment records made from the operator's console** (SMC,
  `SMPlugins/SR_UserPunishment.dll`): "block login" (1), "block login for inspection" (2), "block
  p2p trade" (3), "block chat" (4) (INFERRED order, agreeing with the gateway and the game
  server). Fields: SerialNo, Type, Executor, Shard, CharName, Additional Char Info, Position, Guide
  For Web, Accident Description, Raised Time, Punish Begin Time, Punish End Time, Sentenced Time,
  Email/Template. Durations: "Days", "Hours", "Set By Duration", "Set Infinite Duration". Messages
  "user already blocked" (0x10077d90), "[[NOT Blocked Currently]]" (0x10077e4c).
- **"Set Infinite Duration" is a date, not a flag** (READ, round 788): its click handler
  0x10006610 (control 0x41a, registered at 0x1000401f) calls `GetLocalTime` twice, adds 100 to the
  second one's year (`add WORD PTR [esp+0x10],0x64`, 0x10006635), and puts the first into the
  Punish Begin Time pickers (controls 0x406/0x407) and the second into Punish End Time
  (0x408/0x409) with `DTM_SETSYSTEMTIME` (0x1002, helper 0x10017ef0). So an "infinite" block ends
  100 years after it was set, in the operator's local time. OpenSRO stores no end (NULL) and sends
  the begin + 100 years on the wire.
- GlobalManager's procedures: `_RegisterPunishment` (13 arguments), `_UpdatePunishment`,
  `_QueryActivePunishmet` (sic), `_GetUserJID`, `_RegisterAutomatedPunishment`; `select * from
  _Punishment where UserJID = %d`.
- How the gateway treats type 2 is inside `_CertifyTB_User`, which this package's databases do
  not include (only SRO_VT_SHARD is on the box): the gateway itself knows only certify result 0,
  3 (blocked) and other (0x415f25-0x415f41). OPEN; OpenSRO treats type 2 as a login block.
- The SMC's "Online User Ban" (GlobalManager 0x4463a2): not online -> 0xB201 `{2,1}`; online ->
  0x620D `{u32 JID}` to that user's AgentServer, which disconnects the session (0x403d80, "ban
  user from division manager : %s").
- A kicked player is sent nothing first (INFERRED): the client shows its "disconnected" box.
- Chat and trade blocks (types 4 and 3): the game server keeps `{u8 active, 16-byte end}` per
  type and answers a chat or trade attempt with 0x3405 `{u8 0 chat / 1 trade, u32 packed time}`.
  Not implemented (round 788 stores them only).

OpenSRO (round 788): `account.Punishment` / `account_punishments` (type, executor, guide,
description, raised/begin/end, serial; end NULL = infinite); the old `accounts.blocked` flag is
migrated once into an infinite type-1 block with its reason. The GM console's `/ban` is retail's
kick; `/block`, `/unblock` and `/blockinfo` are OURS, standing in for the SMC
(docs/DEBUG_TOOLS.md).

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
