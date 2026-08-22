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
- [ ] Find the real **post-handshake** per-opcode dispatch path -- `_OnMsgReceivedBeforeHandshake`'s
      own name implies it's a special case only for the handshake's own two opcodes, not the
      general mechanism login (or any other real opcode) actually dispatches through once a
      session is past that stage. This is the genuine remaining gap connecting "a raw packet with
      some real `MsgID` arrived" to "some specific handler function ran" for ordinary gameplay
      opcodes -- the real next target, findable via the same technique (search for comparisons
      against whichever real opcode value is targeted next).
- [ ] Confirm or refute whether `ACTIVE_SESSION` and the earlier `CSession`/`CBaseSocket` RTTI
      names refer to the same real class.

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

**A real hypothesis for where the actual mechanism lives**, based on the earlier `"There is no
certification handler!!! you must register it first!!!"` error string (`login.md`): this reads
like a real handler-registration pattern -- various subsystems each real-register themselves
against a numeric ID at startup (into some global table this project hasn't located), rather than
the session object holding a small fixed callback set. If true, the real next step is finding that
registration call (something like `RegisterHandler(id, callback)`) and its call sites across
`GatewayServer.exe`'s startup code, not more exploration of the session object itself. Not
confirmed -- a hypothesis to test, not a fact.

## A real, unreconciled discrepancy: `+6`, not `+5`, in one real frame-size calculation

While tracing `+0x218`'s and `+0x214`'s handlers, found the same real `+6` frame-size
reconstruction (payload size to total frame size) repeated across three separate real functions
now, not a one-off -- see `PACKET_FORMAT.md`'s note on this. This project's wire-framing doc was
written from public private-server documentation describing a 5-byte header
(`Size(2)+Opcode(2)+Security(1)`), not from binary analysis; this is the first real, first-party
data point bearing on that header's actual size, and it doesn't cleanly match, now reinforced by
repetition across independent call sites. Not resolved -- recorded as a real, open discrepancy in
both docs rather than quietly picking one.
