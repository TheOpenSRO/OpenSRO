# Round 755 review: the lag hunt

This is an independent, adversarial review of `077caef6` and `9ec5ff12` on
`worktree-agent-a996753313fbe190b`. They are based on `2040e55e`, the swarm tool on v0.1.510, whose
merge base with dev is `b3962b8d`, so round 749 is included.

The review was done in a scratch worktree that merged dev `b7b89bed` (round 752, the party-match
paging fix) into `9ec5ff12`.

- **The merge:** clean, with no conflicts. `docs/WORLD_ISSUES.md` auto-merged.
- **Labels:** READ, MEASURED, COMPUTED, INFERRED, REASONED (from the code, not run).
- **No code was changed.** The probe tests below were written in the scratch tree, run there, and
  deleted.

## Verdict

**Ship.** None of the four server changes breaks play, durability or retail order:

- the `Leave` watcher list;
- the moved position save;
- the party-match entry index;
- the off-by-default pprof listener.

Each one is exactly equivalent to the code it replaces wherever behaviour is observable. Each was
checked against an oracle or by a direct probe (below). `-race` is clean on `world`, `party` and
`session`, the full suite is green, and the darwin/arm64 build links.

The findings are all Low or Info. None blocks the deploy.

## What was checked, and how

### 1. `Leave` returns `[]world.Watcher` (`server/internal/world/world.go:208-248`)

- **Callers (READ).** `hub.Leave` has one production caller, `WorldDisconnectHandler`
  (`session/world.go:1312`). That handler uses `remaining` for one thing only:
  `departPlayer(hub, left, remaining)` (`:1361`).
  - `departPlayer` (`session/playerview.go:551`) reads only `r.Session` and `r.CharacterID` from
    each recipient. That is exactly what `Watcher` carries.
  - The zone change (`warpTo`, `world.go:1695`) converts its `[]Entity` with `world.WatchersOf`.
  - The `guilds.Leave` hits are a different API.
  - Nothing under `cmd/` calls it.
- **The same set (MEASURED).** A probe test filed 600 characters at random positions over two zones
  and checked 300 leaves. For each leave, it compared `Leave`'s watchers with the old
  `viewOthersLocked` snapshot taken under the lock at the same position. All **7,952** watchers
  matched as a set, with the same count every time. Both lists are built after `removeLocked`, with
  the same window walk (`forWindowLocked`) and the same own-session exclusion.
- **Despawns still reach every watcher.** The 0x3016 and the zone notice are decided per recipient
  by `v.known` under the view lock, as before. The recipient list is the same set.
- **The stale-session paths (round 737, N4/N5) are untouched.**
  - `departPlayer` returns before sending when `hub.EntityByCharacterID` names another session.
  - `WorldDisconnectHandler` returns before the save and the departure while `stillLive`.
  - The `playerview737r` and `737v` tests were updated only in their argument type, and pass.
- **Cost (MEASURED).** `BenchmarkLeaveInCrowd`, 200 iterations on this box, base `2040e55e` against
  head:

  | Crowd | Base | Head |
  |---|---|---|
  | 3,000 | 820 us, 3.1 MB, 15 allocs | 55 us, 48 KB, 1 alloc |
  | 7,000 | 1.90 ms, 8.1 MB, 18 allocs | 138 us, 115 KB, 1 alloc |

  These agree with the round's own figures.
- **The pre-sizing** (`viewOthersLocked`, `EntitiesInZone`) only sets a capacity:
  - `windowCountLocked` costs 9 map lookups;
  - a wrong hint just grows the slice.

### 2. The position save after the echo

The save moved in three places:

- `destmove.go:303`;
- `world.go:1821`;
- `buffs.go:676`.

**Durability (REASONED).** The save is still synchronous on the session's goroutine, in the same
handler, a few hundred microseconds to a few milliseconds later than before. That is the time to
queue the echo and the watchers' frames.

- A crash right after the echo loses at most what it lost before: the walk since the last periodic
  save, at most `positionSaveInterval` (30 s, `position.go:60`), plus the in-flight write.
- What is saved is unchanged. It is `r.Entity.Pos`, the position when the click was handled, not
  the leg's end.
- A clean disconnect and a server stop still save the final position:
  - `WorldDisconnectHandler`'s `savePosition`;
  - `SaveAllPositions`.

**Error handling.** This is unchanged. `savePosition` logs and returns false. The clock key is then
not advanced, so the next move retries (see F1).

**The round-749 claim logic (READ).** It is not affected:

- `hub.Claim` and `claimBound` read the hub's own anchor, `Trusted` and the allowance clock. They
  never read the database row.
- The save writes only Postgres and the session's `placeSavedKey`.
- `now` is taken before the relay in all three handlers, as before.

**The off-goroutine warp race (REASONED, round 665 M1).** `returnAfterKill` runs on the monster
AI's goroutine with `-player-dead-state` off, the default. It can warp the mover between the
handler's snapshot and its save. The reorder widens that gap by the relay's duration. It is still
safe: `warpTo` calls `rememberPlace`, which sets `placeSavedKey = now` first. The
`now.Sub(last) < positionSaveInterval` test in `savePositionEvery` then skips the stale save. The
remaining window, between that test and `savePosition`'s own `placeOf` read, is the same as before
the round.

### 3. The party-match entry index (`party.go:372-424`, `match.go:154`)

- **Every write goes through the two helpers (READ).** `grep` shows that every write to
  `Hub.listings` now goes through `setListingLocked` or `clearListingLocked`:
  - `SetListing`;
  - `ClearListing`;
  - the dissolve in `removeLocked`;
  - the leader hand-over.

  `byEntry` is read only by `ListingOwner`, under `h.mu`. The lock order, `Matcher.mu` then
  `Hub.mu`, is unchanged.
- **Consistency against the old scan (MEASURED).** A randomized probe ran 200 seeds × 400 steps of
  these operations over 30 characters:
  - register, delete, change, page;
  - form, add, remove (leave, leader hand-over, dissolve);
  - withdraw (a disconnect);
  - expiry sweeps with the clock moved 0-40 minutes.

  After every step it checked three things, under `-race`, with no failure:
  - `len(byEntry) == len(listings)`;
  - every listing indexed to its holder;
  - `ListingOwner(n)` equal to the old full-map scan for every number up to the counter + 1.
- **Duplicate entries cannot occur (READ).** `setListingLocked` evicts a different holder of the
  same entry number. That cannot happen, because numbers come from an only-growing counter that
  skips 0 (`newNumberLocked`, READ SM 0x451290) and are never reused. So the old scan and the index
  never disagree on an owner.
- **Page order is unchanged (READ).** `Matcher.Page` and `rowLocked` were not modified:
  - entry-number order;
  - `PageSize` 23 (`cmp al,0x17`, `party_protocol.md:243`);
  - at most `MaxPages`;
  - the requester's or its leader's own entry first, and again on its own page
    (`party_protocol.md:247`).

  The round-752 tests (`partymatch_pages_test.go`, `partymatch_test.go`) pass on the merge.
- **Reconnect.** The index changes nothing about the disconnect paths:
  - `PartyMatchDisconnectHandler` → `Matcher.Disconnect` → `Withdraw` → `ClearListing`.
  - A party member's entry moves with leadership in `removeLocked`.

  Both keep the index in step, as the probe exercised.

### 4. pprof (`server/cmd/server/pprof.go`, `main.go:1111-1114`, `:1204-1207`)

These were MEASURED with a throwaway test against `startDebug`:

- **Off by default.** An empty address returns nil, logs nothing, starts no goroutine and leaves the
  mutex fraction at 0.
- **Not reachable unless configured (READ).** Importing `net/http/pprof` registers on
  `http.DefaultServeMux`. Nothing in the server binary serves that mux: `grep` finds no
  `ListenAndServe`, `http.Serve` or `DefaultServeMux` outside `pprof.go`, whose server uses its own
  `ServeMux`.
- **On 127.0.0.1:** the following all answered 200, with no warning:
  - `/debug/pprof/`;
  - `/mutex`;
  - `/goroutine?debug=1`;
  - `/heap`.
- **On `:16062`:** the server logged the non-loopback WARN, with `addr=[::]:16062`.
- **A second listen on a taken port** returned an error, so the boot exits (see F3).
- **Shutdown.** After the context ended, the listener was closed.
- **The `runtime stats` line** was produced with sane windowed values:
  - GC count, last and max pause;
  - heap;
  - goroutines;
  - scheduler latency p50/p99/max.

### 5. Concurrency and builds

These are the test lines (MEASURED). Each Postgres-backed run used a private database, created for
this review and dropped afterwards:

- `opensro_test_r755`;
- `opensro_test_r755race`.

```
go test -race -count=1 ./internal/world/ ./internal/party/
ok  	.../internal/world	1.219s
ok  	.../internal/party	1.085s
go test -race -count=1 -timeout 90m ./internal/session/
ok  	.../internal/session	1124.362s           # no race reported
go test -count=1 -p 1 ./...                       # exit 0, 70 packages ok, 0 FAIL
ok  	.../cmd/server	10.615s
ok  	.../cmd/swarm	0.730s
ok  	.../internal/party	0.013s
ok  	.../internal/session	185.488s
ok  	.../internal/world	0.052s
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build ./cmd/server   # ok: Mach-O 64-bit arm64
GOOS=darwin GOARCH=arm64 CGO_ENABLED=0 go build ./cmd/swarm    # ok
GOOS=windows GOARCH=amd64 go build ./cmd/swarm                 # ok
go vet ./cmd/server ./cmd/swarm ./internal/world ./internal/party ./internal/session   # clean
```

The toolchain was go1.25.0 (`go.mod` `go 1.25.0`, `GOTOOLCHAIN=auto`).

## Findings, most severe first

### F1. Low (existing before this round): a failing save has no back-off, so a sick database stalls every walker's session

- **Where:** `server/internal/session/position.go:177-179`, with `positionSaveTimeout` 5 s at
  `:64`.
- **Evidence (READ):**
  - When `savePosition` fails, `placeSavedKey` is not advanced, so **every** later move of that
    session retries the two writes.
  - Each retry can wait up to 5 s on the session's goroutine: the context is shared by
    `SavePosition` and `SetHeading`.
  - The reorder means the echo now goes out first. But the session's *next* message (the next
    click, an attack) still queues behind the stalled write.
  - With the Mac's Postgres on another host (192.168.5.25), a database outage turns into
    multi-second input lag for every walking player, for as long as it lasts.
- **This round did not introduce it.** It is the main remaining exposure on the save path.
- **Fix (suggested, OURS):** on failure, advance the clock anyway, or set a short back-off such as
  `sess.Set(placeSavedKey, now.Add(-positionSaveInterval+5*time.Second))`. This retries in 5 s, not
  on every move. Optionally, move the periodic save off the session goroutine with a per-session
  latest-wins slot. The disconnect's final save would then have to wait for or supersede it.

### F2. Low: the skill move's own answer still waits behind the save

- **Where:** `server/internal/session/buffs.go:676`, called from `skill.go:1402`. The
  `OpAttackResult` is sent at `skill.go:1413`.
- **Evidence (READ):**
  - `moveBySkill` now sends `OpSkillMove` before the save.
  - But its caller sends the cast's `OpAttackResult` only after `moveBySkill` returns.
  - So, once every 30 s of ground-skill moves, the caster's result is still a save late.
  - The WORLD_ISSUES entry lists "the skill move" as fixed, which is half true.
- **Fix:** have `moveBySkill` return without saving, and save in `skill.go` after the
  `OpAttackResult` is sent. Or record it as a known half-fix. This is rare: ground-targeted
  movement skills only.

### F3. Low: pprof on a non-loopback address only warns, and a taken port stops the boot

- **Where:** `server/cmd/server/pprof.go:62-65`, `main.go:1204-1207`.
- **Evidence (MEASURED, above):**
  - `-pprof-addr :6060` serves stacks, heap and the command line on every interface. The command
    line includes the Postgres DSN when it is passed as a flag. The server only logs a WARN.
  - Separately, a port already in use makes `startDebug` fail. The boot then calls `os.Exit(1)`.
    Under the Mac's launch agent (KeepAlive), that is a restart loop until the env line is removed.

  Both are documented (`server/README.md`, `deploy/README.md`) and opt-in.
- **Fix (suggested):**
  - refuse a non-loopback address unless it is explicitly forced, for example by a
    `OPENSRO_PPROF_PUBLIC=1` or a `-pprof-allow-public` flag;
  - and/or log the listen error and continue without the profiler, rather than exiting. A debug aid
    should not be able to keep the production server down.

### F4. Info: a wall-clock assertion in `TestSweepOfManyEntriesIsLinear`

- **Where:** `server/internal/party/match_index_test.go:77`, a 250 ms bound on a page plus a sweep
  over 10,000 entries.
- **Evidence:** it passed under `-race` here (the whole package took 1.1 s), with about 50x margin
  on an idle box. A time bound in a unit test can still flake on a loaded CI runner.
- **Fix (optional):** assert on the operation count, or loosen the bound to about 2 s. That still
  catches the old O(n²) cost of about 560 ms × the race factor.

### F5. Info, docs: the expiry time is stated two ways

- **Where:**
  - `deploy/README.md:1774` says "expires 60 minutes after".
  - `docs/WORLD_ISSUES.md:7203` says "61..62 minutes".
- **Evidence (READ):** `Sweep` deletes when the whole minutes elapsed exceed 60. It runs every
  minute, so 61..62 is the precise figure, and `relist.go`'s 52..58-minute check is inside both.
- **Fix:** say "after more than 60 whole minutes (61-62 in practice)" in `deploy/README.md`.

### F6. Info: the probe's spot is not protected from a kill

- **Where:** `server/cmd/swarm/probe.go`, the click loop.
- **Evidence (REASONED):**
  - The probe computes its region once, at login.
  - If a monster ever kills it, the server returns it home: `returnAfterKill`, with dead state off.
    Its clicks then fall outside the 3 × 3 regions and are silently refused.
  - Every click after that logs `NO ECHO`, which reads as a server stall.
  - The default spot has no nest, so this is unlikely.
- **Fix (optional):**
  - recompute the region from a 0x3016/teleport or a large position change;
  - or reconnect after N consecutive `NO ECHO`s.

## Not regressions, noted for the record

- **(INFERRED, not examined in depth)** `PartyMatchDisconnectHandler` finds the character by the
  *disconnecting* session. During a reconnect race, a stale session still in `bySession` would
  withdraw the live character's party-less entry. This round neither adds nor changes that path,
  and the index stays consistent either way. The swarm's relist recovers within one check, at most
  58 minutes.
- **The per-blow `EntitiesInZone` scans and the `AllEntities` copies under `-single-frame`.** The
  round leaves them as a write-up, correctly scoped.
