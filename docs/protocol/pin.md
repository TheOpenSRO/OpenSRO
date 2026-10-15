# The account PIN: "Character Lock" (round 788, lane P)

**The whole feature is OURS.** The retail game has no PIN, secondary password or account lock of
any kind (READ, round 788's research, `/root/opensro-acct788/RESEARCH.md` section 4: no layout, no
art, no text key and no opcode -- 0x6116/0x6117/0xA116/0xA117 included -- in sro_client.exe,
GatewayServer, AgentServer, SR_ShardManager or SR_GameServer). The operator package's vPlus addon
has an "Account Lock Manager" and a 6-digit "Secondary Passcode", but its code is encrypted and
nothing of it is used here. What this server and client do is modelled on a screenshot the user
showed of another private server's addon: a window titled "Character Lock" over the select screen,
an entry box, a message box ("Enter your pin code. Only 4 digits allowed."), a Remove Pin button, a
3x4 keypad `1 2 3 / 4 5 6 / 7 8 9 / C 0 <`, and a "Remember this PC and don't ask for pin" box.
That addon's wire, storage and rules were not seen; everything below is OpenSRO's own design.

## The rules (the user's decisions, 2026-10-15)

- **Per account, at character select.** Asked once per login (connection), the first time the
  player starts, deletes or restores a character. Set up and removed from the select screen.
- **Optional**; the operator can require one (`-require-pin`, env `OPENSRO_REQUIRE_PIN`). Required
  and none set: the player must create one before starting, deleting or restoring.
- **4 digits** (`charlock.PinLength`).
- **Lockout**: the 5th wrong entry in a row (`MaxFailures`) locks the PIN for 30 minutes
  (`LockFor`), for every login, kept in the database (a reconnect or a server restart does not end
  it). A right entry resets the count. A wrong Remove counts on the same counter. While locked the
  right PIN is refused too; at 30 minutes the lock ends and the count starts over.
- **Remember this PC**: the client makes a random device token once per server and keeps it; a
  verify with the box ticked sends it, and the server keeps its hash in the account's list (at
  most 16, the newest; OURS bound). The next login's status request carries the token: a
  remembered PC passes without a prompt. **Changing or removing the PIN forgets every remembered
  PC** (there is no change operation: remove, then create, which is the same).
- OURS: a remembered PC passes **even while the PIN is locked**. The lock stops guessing; a
  remembered PC guesses nothing, and this keeps a stranger's five wrong tries from shutting the
  owner out on their own PC.
- OURS: creating the PIN, entering it, and removing it each unlock the session that did it.

## The wire (OURS)

Our framing (`proto.Packet`), on the game connection. 0x0118..0x011F were free on 2026-10-15 and
are left to round 788's other lanes, which were adding messages at the same time; the PIN takes
0x0120..0x0124. Strings are a u16 length and ASCII bytes, as the lobby's names.

| Opcode | Direction | Payload |
|---|---|---|
| 0x0120 | C -> S | status request: str device token (`""` when this PC has none) |
| 0x0121 | S -> C | reply to every request: u8 op, u8 code, u8 flags, u8 attempts left, u32 seconds locked |
| 0x0122 | C -> S | create: str PIN |
| 0x0123 | C -> S | verify: str PIN, u8 remember, str device token (`""` unless remember) |
| 0x0124 | C -> S | remove: str PIN |

The reply: **op** 0 status, 1 create, 2 verify, 3 remove. **code** (`charlock.Code`): 0 OK, 1 wrong
PIN, 2 locked, 3 a PIN exists (create), 4 no PIN (verify, remove), 5 bad format (not 4 ASCII
digits, a device token outside 16..128 printable bytes, a payload too short), 6 not logged in,
7 the store failed. **flags**: 1 the account has a PIN, 2 the server requires one, 4 this session
passes the gate, 8 locked. **attempts left** before the lock (0 while locked). **seconds locked**:
what is left of the lock, rounded up -- a duration, not a time, so the two clocks need not agree;
the client shows "Locked until HH:MM" on its own clock.

Golden bytes, held on both sides (`TestCharLockCodecs`, `character_lock_net_test.gd`): verify
`1234`, remember, token `ab` is `04 00 31 32 33 34 01 02 00 61 62`; the reply "verify, locked, has a
PIN, 0 left, 1800 s" is `02 02 09 00 08 07 00 00`.

## The gate (server)

`session.CharacterLockGate` wraps the whole handler chain (`cmd/server/main.go`, one line). Before
the lobby sees them it refuses, unless the session passes:

- Start, **0x7001**: `0xB001 {2, 0x40e}`;
- the older OpenSRO **OpEnterWorld 0x0020** (the same way into the world): its result with the
  reason "the character lock is not open: enter the PIN first";
- **0x7007** delete (action 3) and restore (action 5): `0xB007 {action, 2, 0x40e}`.

A session passes when it has unlocked the PIN, or when the account has none and the server does not
require one. A session not logged in passes to the handlers behind, which answer 0x407 as before. A
store error refuses (fails closed). List (2), create (1) and the name check (4) are never held.

**The refusal code (OURS).** 0x40e is READ as "an operation is pending": the ShardManager's own
Start refuses with it (`docs/protocol/charselect.md` section 5). The PIN is that pending operation,
and no retail code means more: the retail client shows its generic "Failed to connect to server."
for it, as for 0x402/0x407/0x40b. Our client never sees it: it asks for the status and the PIN
first.

**What a retail client sees** (another lane makes the server accept the original client). It has no
PIN window. On an account with **no** PIN, on a server that does not require one, nothing changes.
On an account **with** a PIN it can log in, list its characters, check a name and create a
character, but Start, Delete and Restore each answer "Failed to connect to server." -- the player
must enter the PIN once with OpenSRO's client, or remove it there. Under `-require-pin` a retail
client can start no character at all.

## Storage (server)

`server/internal/charlock` (a new package, so the account package lane S also edits stays apart):
`MemStore` and `SQLStore`, held to one contract by `store_test.go`. The SQL schema migrates itself
at boot on the accounts' database (`characterLock` in `cmd/server/charlock.go`), memory without one:

```
character_locks        (account_id BIGINT PRIMARY KEY, pin_hash BYTEA, failures INTEGER,
                        locked_until TIMESTAMPTZ)
character_lock_devices (account_id BIGINT, token_hash BYTEA, added_at TIMESTAMPTZ,
                        PRIMARY KEY (account_id, token_hash))
```

- The PIN is stored as **bcrypt**, the account password's own scheme. Said plainly: a 4-digit PIN
  has 10,000 values, so a stolen hash falls to an offline search whatever the hash is; the PIN's
  strength is the online lockout, not the hash.
- A device token is stored as its **SHA-256** (the token is 32 random bytes; there is nothing to
  search). The token itself is never stored or logged by the server.
- A wrong entry is counted in one `UPDATE ... RETURNING` statement, so two sessions' wrong entries
  cannot both read the same count. A check that started before another session's lock landed can
  still finish; it can only let one more guess through, not reset the lock.
- No foreign key to `accounts` (the store must not depend on the account store's migration order);
  `server/cmd/swarm`'s cleanup deletes both tables' rows by account id.

## The client

- `client/scripts/net/character_lock_net.gd` (`CharacterLockNet`): the codec; `NetClient`
  `char_lock_status/create/verify/remove` and the `character_lock_reply` signal. Nothing about the
  PIN or the token is printed.
- `client/scripts/ui/character_lock_pad.gd` (`CharacterLockPad`): the state machine -- create (in
  order; 4 digits, then the same 4 again; a mismatch starts over), verify (the ten digits shuffled
  into the digit cells each time the window opens, C and < fixed in the bottom corners; the
  shuffle is seeded from the OS's random source), remove, locked. No OK button: the fourth digit
  submits. C clears, < takes one digit off, nothing past 4 digits. The entry shows `*` per digit.
- **Keyboard digits do not type** (OURS). The shuffled pad defeats a recording of where the clicks
  land; typing on the keyboard would hand the PIN to a key logger, the other way PINs are stolen. So
  the window takes the pad only, in every mode, so the habit it teaches is one. Escape closes it.
- `client/scripts/ui/character_lock_window.gd` (`CharacterLockWindow`): the window, built through
  `UiBuilder` from the archive's generic art -- `msgbox2_window_` frame, `com_bg_tile_b` body,
  `com_blacksquare_` over `com_bg_tile_e` boxes, `com_button` (Remove Pin),
  `com_checkbutton_off/_on` (remember), `com_windowclose` -- and OURS keypad tiles made of
  `com_blu_button` (digits) and `com_red_button` (C, <) drawn square at 40x40 with their 5-pixel
  border kept, `<` as `com_left_arrow.ddj`. Every size and gap is OURS (the header lists them): a
  reskin of the screenshot's proportions, 318 x 294.
- `client/scripts/ui/character_lock_device.gd` (`CharacterLockDevice`): this PC's token per server
  (`host:port`), 32 random bytes as 64 hex characters, in `user://character_lock.cfg` -- not in
  `settings.cfg`, which a tester passes around and which by its own rule holds nothing secret.
- `client/scripts/frontend/charselect_lock.gd` (`CharSelectLock`): the select screen's side. The
  screen asks it before Start and before the delete/restore confirm (`hold`); it asks for the
  status when the screen opens and opens the window when needed, running the held action again on
  success. A server that does not answer the status within 3 s (an OpenSRO server from before
  round 788) is taken to have no PIN. The **Pin Code** button (OURS placement) stands in the bottom
  band one column (0x68) left of Start, where the retail layout has nothing: set up a PIN, or
  verify with Remove Pin offered.
- The words are OURS English (no textdata key exists): "Enter your pin code. Only 4 digits
  allowed.", "Choose a pin code.", "Enter the same pin code again.", "The pin codes did not match.
  Choose again.", "Wrong pin code. N attempts left.", "Too many wrong entries. Locked until HH:MM.",
  "Pin code created.", "Pin code removed.".

## OPEN

- The retail-protocol (legacy) select path that round 788's lane C adds must not send 0x0120 to a
  retail server; `CharSelectLock.query()` is called unconditionally from `CharacterSelect._setup_lock`
  today (the merge note in `docs/rounds/r788p.md`).
- No GM tool to clear a player's PIN or lock (an operator can `DELETE FROM character_locks WHERE
  account_id = ...`, which also needs the devices' rows removed).
- The 30-minute lock and the 5 tries are constants, not flags.
