# Server dispatch architecture (`GatewayServer.exe`)

Real facts about how `GatewayServer.exe` gets from an accepted TCP connection to an opcode-specific
handler -- found while chasing `login.md`'s "where does a live packet's Div ID get set" question,
but relevant to *every* future opcode this project RE's, not just login. Split out into its own
file for that reason.

## It's a real IOCP (I/O Completion Port) server

Confirmed via real Winsock/IOCP imports actually used: `CreateIoCompletionPort`,
`GetQueuedCompletionStatus`, `WSARecv`, `WSASend`, `AcceptEx`. This matches the `OverlapJob`/
`COverlapJob` naming already found (`login.md`) -- "overlapped I/O" is the Windows term this
architecture is built around.

Two real completion-processing loops exist:

1. **A worker-thread pool loop** (`FUN_0049c7f0` in this project's current Ghidra addressing --
   addresses are per-binary-load and not stable across re-imports, recorded here only to describe
   the shape, not as a citable identifier): a plain `GetQueuedCompletionStatus` loop. The
   completion key it receives back is treated as a C++ object, and **a virtual call through that
   object's own vtable slot at offset `+8` (its third virtual method) is the real per-completed-I/O
   callback**, invoked as `callback(bytesTransferred, lpOverlapped)`. This is almost certainly the
   real per-connection object (a `CSession`/`CBaseSocket`-family instance -- both real class names,
   see below) receiving its own "I/O finished" notification -- i.e. **this vtable slot is where a
   received packet's raw bytes first become available to be parsed**, and is the real next target
   for finding Div ID assignment.
2. **A separate main-thread loop** (inside the top-level app/message-pump function) alternates
   `PeekMessageA`/`GetQueuedCompletionStatus` and, on a completion, calls a *different* vtable slot
   (`+0x40`) on a top-level app/gateway singleton object, passing only the `OVERLAPPED` pointer (no
   completion key or byte count passed through at this call site) -- plausibly a lighter
   GUI-thread-side notification path, distinct from the worker pool's real per-packet handling.

## Real class names found in this binary (via RTTI strings, `.?AV` mangled prefix)

`CSession`, `CBaseSocket`, `CGatewayServer`, `CGatewayMainProcess`, `CDBSessionMgr`,
`CUdpPingClient`, plus the `ServerFramework::COverlapJob*`/`COverlapJobManager` family already in
`login.md`. `CSession` was the natural candidate for the per-connection object whose vtable+8 slot
is the real receive callback -- **not confirmed to be `CSession` specifically**, but a different
technique (searching for real immediate-value comparisons against the known handshake opcodes
`0x5000`/`0x9000`, rather than more RTTI-vtable tracing) found the real pre-handshake receive path
directly: **`ACTIVE_SESSION::_OnMsgReceivedBeforeHandshake()`** (class and method name both real,
read from the binary's own embedded debug strings -- see `handshake.md` for the full real
per-object field-offset table this uncovered: `+0x1050` = the real 16-bit `MsgID`, `+0x1054` = a
size field, `+0x1058`/`+0x105c` = the two outgoing security bytes, `+0x164`/`+0x16c-0x16e` = the
CRC/rolling-byte state). Whether `ACTIVE_SESSION` and the earlier `CSession` guess are the same
class, related, or unrelated is not confirmed -- the method name's own "BeforeHandshake" qualifier
suggests this is specifically a *pre-handshake* special case, and post-handshake per-opcode
dispatch (login and everything else) may route through separate code this project hasn't found
yet.

## Why RTTI-chain vtable tracing stalled here (a real, honest limitation)

The technique that successfully identified `CUserCertifier_OverlapJob` (walk
`RTTICompleteObjectLocator` -> `TypeDescriptor` -> mangled name, then scan backward from a known
vtable-slot address to find the vtable's start) does **not** generalize to every class in this
binary. Tried on `COverlapJobManager` and `CSession`: both have a real, findable `TypeDescriptor`,
but neither's `RTTICompleteObjectLocator` led to a directly-instantiated vtable the way the
certifier job's did. Two real, plausible reasons, not yet distinguished: these may be abstract base
classes with no single direct instantiation site to scan backward from, or their vtable-store
instruction at construction time uses a code shape this project's simple "scan backward for
consecutive function pointers" script doesn't recognize (e.g. an inlined constructor, or a
non-`MOV`-based store). Static automated tracing of the `CreateIoCompletionPort` call graph (the
more reliable-looking path, since it's a small number of real API call sites) also didn't reach a
concrete "here's the completion key value" answer this pass, because the `AssociateSocket`-style
functions found are themselves virtual methods on a generic reusable framework class, called
through further vtable indirection rather than directly.

## Status / next steps

- [x] Confirmed this is a real IOCP server, found the real worker-pool completion loop and its
      vtable-dispatched per-I/O callback (`+8` slot)
- [x] Found the real class names most likely involved (`CSession`, `CBaseSocket`)
- [x] Found the real pre-handshake per-packet receive method, `ACTIVE_SESSION::
      _OnMsgReceivedBeforeHandshake()`, by switching technique -- searching for real immediate-value
      comparisons against known opcodes (`0x5000`/`0x9000`) instead of more RTTI-vtable tracing.
      This is the technique that should generalize best to future opcode RE work: once *any* real
      opcode value for a target message is known (from the client or elsewhere), searching for
      literal `CMP`/`MOV` instructions using that exact value directly finds real comparison sites,
      without needing to identify an owning class first.
- [x] ~~Found the real post-handshake per-opcode dispatch mechanism: a global `MsgID`-keyed
      registry~~ -- **retracted**, see the correction below: traced further and found this global
      map is actually a real *connected-user* registry (duplicate-login detection), not an
      opcode-handler table. The general per-opcode dispatch mechanism is still genuinely
      unfound.
- [x] Found a real, concrete Gateway-to-Agent login hand-off sequence with two new real opcodes
      (`0xa103`, `0x6201`) while chasing the above -- see the dedicated section below. Real,
      valuable, just not an answer to the original question.
- [ ] Find the *actual* general per-opcode dispatch mechanism -- still open. Tried three more
      angles this session, all real negative/tooling results rather than progress, recorded
      honestly:
      - Searching for direct calls against the map-insert candidate's address, and against a
        two-instruction "load offset `+0xa8` into a register, then call that register" pattern:
        zero hits both times. Real conclusion: either that specific vtable slot genuinely has no
        static call site in this compiled binary, or (more likely, see next point) real call sites
        don't fit either simple pattern this project's tooling can check for.
      - Traced the confirmed real "SUSPECT DETECTED" anti-spoofing logger (fires when a message's
        sender isn't a currently-registered user) back to the same connected-user-registry lookup
        already found -- consistent, but still not the opcode-dispatch answer, just more evidence
        this registry is a security gate that runs *before* whatever real per-opcode routing
        happens next.
      - Tried harvesting every real outgoing `MsgID` value wholesale, by scanning for
        `MOV word ptr [reg+0x1050], imm16` in one instruction across the whole binary (the pattern
        directly observed at the `0xa103`/`0x6201` write sites). Zero hits -- **a real, useful
        negative result**: those writes are actually two separate instructions (an address
        computation like `LEA reg, [base+0x1050]`, then a plain `MOV word ptr [reg], imm16` with no
        visible displacement), not one fused instruction. A future wholesale-opcode-harvest attempt
        needs to match that two-instruction shape, not a single-instruction one.
      This sub-thread has hit real, identified tooling limits three times in a row -- worth
      building better static-analysis tooling before continuing to push on it by hand, rather than
      repeating manual single-function decompiles indefinitely.
- [ ] Confirm or refute whether `ACTIVE_SESSION` and the earlier `CSession`/`CBaseSocket` RTTI
      names refer to the same real class.
- [ ] `CBlowFish`/`CKeyExchangeBase`/`CKeyRepicient`/`CKeySender` (found in `AgentServer.exe`) are
      real, unexplored leads for `handshake.md`'s still-open session-cipher key-exchange question.

## A real, hand-rolled callback table (not a C++ vtable) found on the session object

Found `_OnMsgReceivedBeforeHandshake`'s own real constructor/init code (the one function that
stores its address into the session object). It doesn't build a standard compiler-generated C++
vtable -- it writes real function pointers directly into a handful of fixed offsets on the object,
mode-dependent (two real branches, plausibly a protocol-version or region switch):

| Offset  | Real role (confirmed/plausible)                                                  |
|---------|-------------------------------------------------------------------------------------|
| `+0x22c`| `_OnMsgReceivedBeforeHandshake` (confirmed, both branches set the same function)     |
| `+0x230`| The real "send a reply" callback -- called elsewhere with a constructed outgoing buffer, matches the two `(**(code**)(this+0x230))(...)` call sites already found in the handshake handler |
| `+0x218`| Set unconditionally to `FUN_0046f8e0` -- decompiled, but this turned out to build an
error-reply message (real opcode `0x1001` observed being written into a fresh outgoing buffer)
when some queue/capacity check fails, not a general incoming-opcode dispatcher. Real, but a dead
end for *this* question -- ruled out, not the thing we're looking for. |
| `+0x20c`/`+0x210`| Both set to the same label address (`LAB_0046fb20`, not yet decompiled as its own function) -- plausibly a shared no-op/default handler for the two mode branches |
| `+0x214`| Mode-dependent: a real label or `FUN_0046f770` -- not yet decompiled |

None of these six slots is obviously "the general post-handshake per-opcode dispatcher" -- the
real mechanism connecting an ordinary gameplay `MsgID` to its handler is still not found. Decompiled
`+0x214` too: it's a real send-queue-flush function (copies pending outgoing bytes into a
0x2000-byte send buffer), not a dispatcher either -- also ruled out. Recorded here so a future pass
doesn't re-decompile either slot expecting a different answer.

**Superseded by a real architectural finding below**: the "registration table" hypothesis assumed
`GatewayServer.exe` itself dispatches ordinary gameplay opcodes. Real evidence now points the
other way -- `GatewayServer.exe` mostly just relays them elsewhere. See the next section.

## Real architecture: Gateway relays to Agent -- most opcode dispatch isn't in this binary at all

Only 5 real `On<MESSAGE_NAME>`-shaped handler method names exist anywhere in `GatewayServer.exe`
(`OnMsgReceivedBeforeHandshake`, `OnFileSent`, and three `OnFRAMEWORKMSG_*` inter-server messages)
-- far too few for a binary that's supposed to handle the full range of real gameplay opcodes.
Real strings confirm why: `COverlapJob_RelayMsg` (already found, `ServerFramework` namespace) is a
real message-relay job, and a real, literal debug string names its actual per-message field:
`"unhandled relay msg error : wRealMsgID : 0x%X : dwParam : 0x%X"`. Combined with
`"there is unfurnished shard does not have any agent server : %d - %s"` and the literal string
`AgentServer`, this confirms the real architecture this project's own `db_schema.md`/public
knowledge already implied: **`GatewayServer.exe` is a thin login/handshake front door that relays
most real gameplay messages onward to a separate `AgentServer.exe` process (one per shard), by
their real `wRealMsgID`, without itself dispatching or even necessarily parsing them.**

This means the real per-opcode gameplay dispatch mechanism this project has been searching for in
`GatewayServer.exe` mostly **isn't in this binary at all** for anything past login. `GatewayServer.exe`
itself remains the right binary for login/handshake/account-certification specifically
(`login.md`), since that traffic terminates here rather than relaying onward.

## Found in `AgentServer.exe`: the real dispatch mechanism (a global MsgID-keyed registry)

Imported and analyzed `AgentServer.exe` (same obtained package, same `Blitzkrieq_Bin_Data`
folder, real dedicated agent-server binary). Same `ServerFramework` codebase as `GatewayServer.exe`
(shares `COverlapJob`/`CSession`/`CBaseSocket` and adds real agent-specific classes:
`CAgentMainProcess`, `CAgentServer`, `CUserManager`, `CBlowFish`, `CKeyExchangeBase`, and more --
see the class list below).

Searching for a real "unhandled message" fallback string (`"unhandled msg received %s : %s"`)
traced to a real, concrete chain:

1. **`CAgentMainProcess`** (confirmed via the same RTTI-chain technique used throughout this
   project) has a real virtual method (one of ~30 vtable slots) that gatekeeps every incoming
   message. Decompiled it directly: it reads a real 16-bit message-type field from the incoming
   message object (a different object/offset than `GatewayServer.exe`'s `ACTIVE_SESSION::MsgID`,
   consistent with these being separate binaries/classes) and **explicitly exempts two real opcode
   ranges from a traffic-flood filter**: `0x6314`-`0x6316` (a contiguous 3-value range) and
   `0xa314` (a single value) -- real opcode numbers, plausibly high-frequency messages like
   movement/heartbeat that shouldn't trip flood protection. Everything else goes through a
   traffic-filter lookup before being allowed through, real strings confirm
   (`"[TrafficFilter] Heavy traffic is occured by [%s]. disconnected."`).
2. That lookup (`FUN_0040bdc0` in this project's current addressing) is a real
   **`std::map`-shaped lookup** (recognizable MSVC red-black-tree `find()` pattern: fetch an
   iterator, compare against the container's own `end()` sentinel, and on a hit return a mapped
   value from a fixed offset in the tree node) against a **global map instance**. When the lookup
   misses, the real fallback (`FUN_004315d0`) logs `"unhandled msg received"` and does nothing
   further.

**Correction (same session, traced one step further):** the paragraph above originally called
this "almost certainly the real per-MsgID handler registry." That was premature -- tracing the
map's real insert function (`FUN_0040bce0`) to its one real caller showed this specific global map
is actually a **connected-user registry**, not an opcode-handler table. Real evidence: `FUN_0040bce0`
logs a real `"user register duplicated : %d, %d"` error on a hit (i.e. "this key is already
registered" -- duplicate-login detection, not "opcode already has a handler"), and its one real
caller is the Agent-side half of the login hand-off from `GatewayServer.exe` (see the next section)
-- unmistakably about registering a newly-certified *user*, not registering a *message handler*.
Revised understanding: `CAgentMainProcess`'s message gatekeeper (step 1 above) most plausibly uses
this same lookup to check "is this message's associated user currently a registered/logged-in
session" as a validity gate, not "does this opcode have a handler." The real general
per-opcode-to-handler dispatch mechanism is therefore **still not found** -- this was a genuine,
useful architectural finding (a real user-session registry, with real duplicate-login detection),
just not the one originally claimed. Corrected here rather than left standing, same as `login.md`'s
own earlier Div ID correction.

## Found in `AgentServer.exe`: the real Gateway-to-Agent login hand-off, with two new real opcodes

Tracing `FUN_0040bce0`'s one real caller led to real, rich, unambiguous material: the Agent-side
function that finishes certifying a user right after `GatewayServer.exe` relays a successful
login over. Real, literal strings confirm exactly what this is:
`"Someone tried to login using strange client that has another content id"` (a real client-version/
content-ID mismatch check) and `"You check the 'Cert', this problem is Cert's input sequence is
wrong, check the Agent & GameServer Sequence"` (confirms this is specifically the real
Agent<->GameServer certification hand-off sequence).

Two new real, concrete opcode values were found here, both server -> client:

| Opcode   | Real context observed                                                          |
|----------|----------------------------------------------------------------------------------|
| `0xa103` | Sent early in this flow, before the user-registration outcome is known -- plausibly a certification/session-info message. |
| `0x6201` | Sent specifically on the success path, right after the user is registered into the connected-user table above -- plausibly the real "you're in" / world-entry notification. |

Neither payload layout is pulled yet -- these are confirmed-real opcode *numbers* with rough
*context*, the same level of confidence this project already treats other found-but-unparsed
opcodes at (e.g. `handshake.md`'s `0x5000`/`0x9000` before their fields were pulled).

**Not yet done**: enumerating what populates the (now correctly understood) connected-user
registry further isn't the priority -- finding the *actual* opcode-to-handler dispatch mechanism
still is, and this session didn't locate it. Two live leads for a future pass: (1) build the
vtable-indirect-call-scanning tool this session identified as missing (see the tooling-gap note
below) and retry on `CAgentMainProcess`'s other vtable slots, since the gatekeeper method (step 1
above) is only one of ~30; (2) `0xa103`/`0x6201` are two more real, concrete opcode values to
anchor a fresh "search for literal comparisons against this value" pass, the technique that's
worked best all session.

### Real class list found in `AgentServer.exe` (via RTTI, `.?AV` mangled prefix)

`CAgentMainProcess`, `CAgentServer`, `CBase`, `CBaseSocket`, `CBlowFish`, `CEventHandler`,
`CFileLegacy`/`CFileMM`/`CFileMem`/`CFileSystem`, `CIDPool`, `CInternalException`,
`CKeyExchangeBase`, `CKeyRepicient`, `CKeySender`, `CMaintainer`, `CMsgException`, `CNetEngine`,
`CPeerProcessIOCP`, `CPeerProcessOverlapped`, `CProactorEvent`, `CProactorIOCP`, `CRegistry`,
`CServiceObject`/`CServiceObjectSock`, `CSession`, `CSimpleThread`, `CSockDatagram`/
`CSockListener`/`CSockStream`/`CSockSystem`, `CSynchObject`, `CSystem`, `CTask`/`CTaskManager`,
`CThreadControl`/`CThreadManager`, `CToken`/`CTokenManager`, `CUserManager`, plus the
`ServerFramework::COverlapJob*`/`CServerProcessBase`/`CServerProcessMain`/`CServerProcessOverlap`
family already partly known from `GatewayServer.exe`. `CBlowFish` and `CKeyExchangeBase`/
`CKeyRepicient`/`CKeySender` are real, promising, not-yet-explored leads for the still-open session
encryption/key-exchange question (`handshake.md`'s "Encryption" section).

## A real, unreconciled discrepancy: `+6`, not `+5`, in one real frame-size calculation

While tracing `+0x218`'s and `+0x214`'s handlers, found the same real `+6` frame-size
reconstruction (payload size to total frame size) repeated across three separate real functions
now, not a one-off -- see `PACKET_FORMAT.md`'s note on this. This project's wire-framing doc was
written from public private-server documentation describing a 5-byte header
(`Size(2)+Opcode(2)+Security(1)`), not from binary analysis; this is the first real, first-party
data point bearing on that header's actual size, and it doesn't cleanly match, now reinforced by
repetition across independent call sites. Not resolved -- recorded as a real, open discrepancy in
both docs rather than quietly picking one.
