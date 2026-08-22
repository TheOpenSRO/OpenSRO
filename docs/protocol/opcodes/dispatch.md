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
`login.md`. `CSession` is the natural candidate for the per-connection object whose vtable+8 slot
is the real receive callback, but this project has **not yet confirmed** that link directly.

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
- [ ] Confirm `CSession` (or whichever class it turns out to be) is really what implements that
      `+8` vtable slot, and decompile that method directly -- this is where a raw receive buffer
      should first get parsed, and thus where Div ID/wire-opcode translation should actually be
      findable. Needs a different technique than RTTI-vtable-backward-scan (see above) -- possibly
      searching for the real header-layout constants (`Size`/`Opcode`/`Security` field offsets)
      directly, the same way `.bsr`'s magic bytes were used to find `ResObject::Load`, rather than
      going through class identification first.
- [ ] Once found, revisit `login.md`'s open Div-ID-translation question with this as the entry
      point.
