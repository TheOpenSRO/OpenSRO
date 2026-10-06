# Round 743 review: M1, the economy as transactions

An independent adversarial review of `0cce33ed` (the failing tests) and `da1f7fbb` (the fix), on
branch `worktree-agent-a31702fafba667e05`. This review is Go only; it ran no Godot and changed no
code. Labels:
- **MEASURED**: a run against local Postgres 16 on the Claude workstation, in private databases
  (`opensro_test_r743rev`, `_s`, `_old`, `_mig`, `opensro_bench_old/new`);
- **INFERRED**: from reading the code.

## Verdict

**Do not ship as-is. Fix findings 1 and 2 first.** Both fixes are small.
- **No data-loss bug was found.** The migration is correct, atomic, idempotent and safe to roll
  back. The duplication and loss tests fail before the fix and pass after it.
- **One new deadlock breaks party play.** In an Item Auto Share party, members picking up gold at
  the same moment deadlock against each other. Each deadlock is a stall of a second or more, and
  some pick-ups fail.
- **A trade whose execution errors leaves the partner's trade window open for good.** No message
  reaches the partner.

## Findings, most severe first

### 1. DEADLOCK: party gold pick-ups lock the members' character rows in opposite orders

**Where:**
- `server/internal/session/grounditem.go:608`, `applyPickup`: it credits `shares` in order;
- `server/internal/session/itemshare.go:98`, `splitGold`: it builds `shares` with the picker first,
  then the party in party order.

**The cause.** Member C's pick-up locks C's `characters` row, then D's. Member D's pick-up locks
D's row, then C's. Before round 743, each share was its own autocommit `UPDATE`, so no
transaction held one row while waiting for another. Now the whole split is one transaction, so
the two pick-ups form a cycle.
- Postgres breaks the cycle only after `deadlock_timeout`, which is 1 s by default.
- `txn.Run` then retries at once, with no backoff, and collides again.
- The gateway runs a session's packets in order, so the stalled player's movement and everything
  else they send waits too.

**The evidence (MEASURED).** A scratch test of `applyPickup`'s exact shape: one `txn.Claim`, then
an `AddGold` per share, picker first. It ran on a 32-connection pool, like production.

| Pattern | Retries | Picks slower than 0.5 s | Picks failed | Wall time |
|---|---|---|---|---|
| 4 members each pick ONE pile at the same moment, 20 bursts (80 picks) | 121 | **77 of 80** | **7 of 80** | 116 s |
| 4 members picking back to back, 50 each (200 picks) | 331 | (worst pick: **15.0 s**) | **59 of 200** | 331 s |
| The same 200 picks, shares credited **in character-id order** | 0 | (worst pick: 15 ms) | 0 | 0.26 s |

A failed pick releases the pile and answers `ErrCannotPick`, so nothing is lost or duplicated.
The game simply stalls.

**The fix.**
- In `applyPickup`, credit the shares in ascending `characterID`. Keep `shares`' own order for the
  messages and for `pickedQty`.
- Order the trade's two debits by character id too (`trade.go:825`). That trade path is the other
  multi-owner row lock that could join a cycle with a party split.
- Generally: add a helper that locks a set of character rows in id order at the start of any
  action that spans several characters.
- Give `txn.Run`'s retry a short jittered backoff (finding 4).

### 2. REGRESSION: a trade whose execution errors leaves the partner's window open, with no message

**Where:** `server/internal/session/trade.go:670-672`.

**The cause.** `trades.Finish` removes the trade before the handler returns the error. The
handler's error closes the executor's session, and `TradeDisconnectHandler`'s `End` then finds no
trade, so it notifies nobody.
- **Before round 743**, the trade was still in the hub at that point, so the disconnect handler
  sent the partner `OpTradeCancelled`.
- **Now the partner hears nothing.** Their own cancel finds neither a trade nor a pending request
  (`cancelPendingTrade` returns nil), so it is answered with nothing too.

**The evidence (MEASURED).** A scratch session test. Aria offers and confirms. Bram's confirm
executes the trade, with `txn.SetAfterCommitHookForTest` answering an error after the commit, as
a lost commit acknowledgement would.
- Aria receives **no packets**.
- Aria's `OpTradeCancel` is answered with **no packets**.
- Bram's session is closed ("handler error, closing session").
- The trade did commit: Bram holds the sword.

**What reaches this path:**
- a Postgres error or timeout;
- a deadlock that is still failing after 4 attempts (finding 1 makes these real);
- a commit whose acknowledgement was lost.

**The fix.**
1. When `executeTrade` errors, ask the ledger, as the pick-up does:
   `txn.For(chars, inv).Applied(ctx, tradeLedgerKey(tradeSess))`.
2. If the trade applied, send both sides `OpTradeCompleted`. Otherwise send both the system
   `OpTradeCancelled`.
3. Then return nil, or return the error only after both sides have been notified.

### 3. PERF (INFERRED; not load-tested): all reference data now shares one 8-connection pool, and the economy waits on it while holding locks

**Where:**
- `server/internal/txn/ledger.go:200-210`, `PoolSizes`: the reference data gets a fifth of the
  budget;
- `server/cmd/server/main.go`: `refdata.NewSQLStore(refPool)`.

**The cause.**
- **Before**, the reference data had its own uncapped pool. Now every reference lookup in the
  whole server shares 8 connections: combat, skills, NPCs, the shop catalogue, and `GetMaxStack`
  and `GetItem` inside every bag write.
- **The lookups are not cached.** `refdata.SQLStore.GetMaxStack` and `GetItem` each run a query
  (`refdata/sqlstore.go:393`, `525`).
- **Inside an economy transaction**, `addItem` and `List` (through `initLegacy`) make these
  lookups while the transaction holds a store connection, the owner's advisory lock and its row
  locks. When the 8 connections are busy, the locks are held for longer.

**Why it is not a deadlock.** The reference pool never needs a store connection, so this round's
separation does avoid a self-deadlock. The cost is throughput under load, which matters for the
1000-player target.

**The fix.** Measure a busy zone before shipping. Then do one of these:
- cache the immutable item rows in memory, which also removes these round trips from every
  transaction;
- or give the reference pool a larger share.

### 4. DEADLOCK/MINOR: retries have no backoff, so contended actions collide again and again

**Where:** `server/internal/txn/txn.go:258`.

**The evidence (MEASURED).** A synthetic test: 40 actions on two character rows, half in each
order, with 20 ms between the two writes.
- **130 attempts** for 40 actions.
- **21 of 40 still failed** after 4 attempts, all with 40P01.
- Atomicity held: each committed action changed both rows, and no failed action changed either.

**The fix.** Sleep a jittered few milliseconds, growing per attempt, before retrying. Finding 1's
ordering removes the common cycle; this one is defence in depth.

### 5. BUG/MINOR: a store error during the trade's item take is reported as "offer no longer valid", and a deadlock there is not retried

**Where:** `server/internal/session/trade.go:842` and `:847`.

**The cause.** Any error from `inventory.Take` becomes `refuse("offer no longer valid")`, and the
refusal is not retryable. That includes a 40P01 from the owner lock, a dropped connection, and
`ErrInvalidSlot`.

**The fix.** Refuse only on `ErrSlotEmpty`, `ErrItemChanged` and `ErrInsufficientQuantity`, and
return the other errors as they are, so `Run` can retry them.

**The same pattern in the buy back.** `server/internal/shop/buyback.go:179` wraps the placement
error with `%v` (`fmt.Errorf("%w: %v", ErrBuybackCreate, err)`), so a deadlock there is not
retried either. Use `errors.Join`, or wrap both with `%w`.

### 6. MINOR: no deadline on an action, and the trade latch now depends on the database answering

**Where:**
- `server/internal/txn/txn.go`, `Run`;
- the gateway handlers, which get the server's context with no deadline.

**The cause.** If Postgres hangs (a network partition, a lock held by a stuck backend), an
executing trade's transaction waits forever. While it waits, the latch keeps both players
"already trading" until the process restarts.
- Neither player's cancel nor their disconnect can clear the latch any more; before round 743,
  either one cleared the hub entry.
- No `statement_timeout` or `lock_timeout` is set.
- This is INFERRED; the hang was not simulated.

**The fix.**
- Give each action a deadline: `context.WithTimeout` in `Run`, about 10 to 30 s.
- Or set `lock_timeout` and `statement_timeout` on the pool's connections.

Then the latch always releases, through `Finish` with an error, and finding 2's fix notifies both
sides.

### 7. MINOR: two processes booting the new schema at once: one of them exits

**Where:**
- `server/internal/character/sqlstore.go:125`;
- `server/internal/inventory/sqlstore.go:163`, which runs `txn.Schema`.

**The evidence (MEASURED).** Two `NewSQLStore` boot sequences started together on a legacy
database. One failed with `duplicate key value violates unique constraint
"pg_class_relname_nsp_index" (SQLSTATE 23505)`, from `CREATE SEQUENCE/TABLE IF NOT EXISTS`
racing. The other completed the migration correctly.

**Impact.** Production runs one server process, and compose restarts a crashed one, so this is
MINOR. It matters for M2.

**The fix.** Take `pg_advisory_lock(<const>)` around the boot-time schema statements.

### 8. MINOR (documentation): the migration holds an ACCESS EXCLUSIVE lock for the whole backfill, not briefly

**Where:** `deploy/README.md:71`.

**The cause.** `schemaFor` is one multi-statement `Exec`. Postgres runs it as one implicit
transaction, so the `ADD COLUMN`'s ACCESS EXCLUSIVE lock is held through the `UPDATE` backfill
and the unique-index build.

**The evidence (MEASURED).**
- 1.44 M bag rows took **7.3 s**, and 600 k warehouse rows **2.6 s**.
- A concurrent `SELECT` on `inventory_slots` waited the whole time.

**Impact.** Harmless while the server is down for the rebuild, as the README says, and the
production tables are far smaller. The sentence is inaccurate, though, and M2's rolling restarts
will meet it.

**The fix.** Reword the sentence. For M2, backfill in batches outside the lock.

### 9. MINOR: the in-memory undo restores whole bag snapshots, and the in-memory ledger never shrinks

**Where:**
- `server/internal/inventory/memstore.go:333` (`journalLocked`);
- `server/internal/txn/ledger.go:44` (`memLedger`).

**The cause.**
- **The undo.** A failed action restores the owner's entire bag as it was at the snapshot. A
  write made outside any action in between is erased. Under `-no-postgres`, `Run` serialises
  actions but not plain store calls, such as a potion's `RemoveItem` or combat durability. So a
  rollback can bring back a consumed potion.
- **The ledger.** `memLedger` is never pruned.

**Impact.** Both only affect `-no-postgres` and the tests; production uses the SQL stores.

**The fix.** Journal per slot (`delta`), not the whole bag. Prune `memLedger` the way
`PruneLedger` prunes the table.

### 10. MINOR, OPEN (not in the round's list): quest kill rewards are two commits

**Where:** `server/internal/session/combat.go:2111`.

**The cause.** `quests.RecordKill` commits the completion, then `AddGold` credits the reward
separately. A failure between them loses the reward. It cannot duplicate it.

**The fix.** Add it to the M1 follow-up list, with the teleport fee, repair, the guild and item
use.

## Checked and found sound

### The migration, on a legacy-shaped live database (MEASURED)

**The test database.**
- It was built with the `0cce33ed` stores, so it has the pre-743 schema.
- It held 1.44 M bag rows: 20,000 characters, sparse slots, stacks of 1 and 250, legacy
  durability -1, and empty and non-empty `mag_params`.
- It held 600 k warehouse rows.

**The backfill and idempotency.**
- Every row got a distinct serial: count = count distinct, and 0 NULL. The bag got 1..1,440,000
  and the warehouse 1,440,001..2,040,000.
- The column is `NOT NULL DEFAULT nextval('item_serial_seq')`, and both `*_serial_key` unique
  indexes exist.
- A second boot took 34 ms and changed nothing.

**A crash mid-migration.**
- **`kill -9` of the client in mid-backfill.** The backend finished the implicit transaction and
  committed. The re-run found everything done.
- **`pg_terminate_backend` in mid-backfill.** Everything rolled back: no `serial` column was left,
  and only sequence values were burned. The re-run completed correctly, with serials starting
  after the burned ones.
- No partial state was possible in either case.

**The unique index cannot brick a boot.** The index is built in the same transaction as the
backfill, which hands out distinct values. Nothing in the code inserts an explicit serial
without the index already present.

**Rolling back to the old server.** The `0cce33ed` stores opened the migrated database without
error. Their `INSERT`s without a serial took the default (2040001, 2040002). Booting the new
server again afterwards was clean.

### Transactions

**Savepoints.**
- Store `Begin` inside an action is a `SAVEPOINT`. Its `Rollback` uses `context.WithoutCancel`
  and releases the savepoint.
- Names come from a per-transaction counter.
- `TestSQLRunSavepoints` passes.

**Pool exhaustion: no transaction asks for a second stores-pool connection.**
- Every store reached from a `Run` fn, from `Equip` or from `Unequip` uses `txn.Conn` or
  `txn.Begin`: character, account, inventory, equipment.
- The capacity functions (`BagCapacity` → `InventorySize`, `CapacityOf` → `ChestSize`,
  `HighestSlot`) all go through the context's transaction.
- The unconverted skill, guild, quest and friend stores are never called inside a transaction. A
  probe for nested `s.db` use inside their `BeginTx` blocks, or during open `rows`, found none.
- `Serials.Next` and `Applied` run outside transactions.

**The trade latch.** `Finish` runs on every return path of the confirm handler. A handler panic
would kill the process, since the gateway has no `recover`, so it cannot leave a latch behind.
Nothing else deletes from `active`.

**The pick-up ledger, when the commit is in doubt.**
- `Applied` is consulted when the outcome is unknown.
- A pick-up that is retried while the first commit is still in flight blocks on the ledger row
  (`ON CONFLICT DO NOTHING`), and then answers `ErrAlreadyApplied`.
- So the item is granted once.

**Serials.**
- A whole stack keeps its serial across a trade, the warehouse and a buy back. The source row is
  always deleted earlier in the same transaction, so the immediate unique index is satisfied.
- A swap re-inserts both rows with their own serials.
- A split gets a new serial.

**Every remaining gold write is relative** (`gold = gold ± $1`). No logout path writes an
absolute purse that could overwrite a trade.

### Coverage

**Already single-sided, so no transaction is needed:**
- the bag-to-bag move and split (now locked);
- monster drops, which are ground items;
- the direct-loot `AddItem` (`combat.go:991`);
- the GM gold commands;
- the global-chat item cost.

**Not present in OpenSRO yet:** stalls, COS or pet inventory, death drops and a player drop.

**The round's listed opens are accurate:** the teleport fee, repair, the guild, item use,
equipment serials and cross-table uniqueness.

## Performance (MEASURED, noisy)

The box is shared and the numbers are fsync-dominated. Three interleaved rounds of
`-benchtime 3s` ran on fresh databases. The pick-up row runs `applyPickup`'s shape: claim plus
`AddItem` in one `Run`, against a plain `AddItem` before the round.

| Benchmark | Before (`0cce33ed` stores) | After (`da1f7fbb`) |
|---|---|---|
| Shop buy, 1 thread | 2.0 – 5.4 ms/op | 1.2 – 3.0 ms/op (**faster**: one commit instead of two) |
| Shop buy, 16 parallel | 0.32 – 0.81 ms/op | 0.15 – 0.40 ms/op |
| Pick-up, 1 thread | 1.2 – 2.8 ms/op | 1.2 – 3.2 ms/op (about **+5 – 20 %**) |
| Pick-up, 16 parallel | 0.13 – 0.36 ms/op | 0.16 – 0.42 ms/op (about **+10 – 25 %**) |

The pick-up pays four more round trips: the ledger `INSERT`, the `SAVEPOINT`, the advisory lock
and the `RELEASE`. That is acceptable. The cost that matters is finding 1's deadlock stall, not
this.

## Gates (MEASURED, on `da1f7fbb`)

- `go build ./... && go vet ./...`: clean. `gofmt -l` on the round's changed files: clean.
- `go test -count=1 -p 1 ./...`:
  - **68 packages ok.** The first run's only failure was `systems.TestUnwiredPackagesAreDeclared`,
    caught by the reviewer's own scratch benchmark package. After it was deleted, `systems`
    passed.
- `go test -race -count=1 -p 1` on `txn`, `trade`, `inventory`, `equipment`, `grounditem`,
  `shop` and `storage`: **all ok**.
- `go test -race -count=1 -p 1 -timeout 90m ./internal/session/`: **ok, 939.0 s**.

**The "before" tests on `0cce33ed`:**
- `TestTradeResentConfirmDuplicatesItem`: **FAIL 2 of 2** ("Aria holds 0, Bram holds 3").
- `TestTradeFailedCreditLosesNothing`: **FAIL 2 of 2** ("Aria gold 950 bag [], Bram gold 1050 bag
  []").
- `TestSQLRemoveItemRacedRemovesOnce` and `TestSQLMoveItemRacedMergeConserves`: **FAIL**.
- The equipment race tests are not in `0cce33ed`. Copied onto that tree, both **FAIL**: two
  swords from one unequip, and a sword both worn and in the bag.

**The scratch tests** behind findings 1, 2 and 4 and the benchmarks were not committed. The
private databases were dropped afterwards, along with the stale `opensro_test_r743` and
`opensro_test_r743b`.
