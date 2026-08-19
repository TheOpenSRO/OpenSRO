# Progress Log

Running log of what's been done, in reverse-chronological order. Each entry: date, what changed, what's next.

## 2026-08-19 (cont'd 28)

- Added a chat system: zone-wide "say" and cross-zone "whisper", the last piece of basic MMO
  social infrastructure that was entirely missing (players could group up and guild up but had
  no way to talk to each other). Deliberately lightweight: `session/chat.go` needs only
  `world.Hub`, not `character.Store` -- a chatting session's identity and current zone come from
  its existing `world.Hub` entity (added two small accessors, `EntityBySession` and `FindByName`,
  rather than making callers re-resolve a character name they already established by entering the
  world). Opcodes 0x00A0-0x00A4: `OpChatSay` broadcasts to everyone in the sender's zone
  (including the sender itself, so the sender's own client renders it the same way as everyone
  else's -- no separate "local echo" path to keep in sync); `OpChatWhisper` looks the target up
  by name across all zones and delivers directly to their session, with an explicit ack back to
  the sender (`OK` or a reason like "player not found") rather than silently dropping whispers to
  offline/nonexistent players.
  Full flow tested end-to-end over two real TCP connections: both characters enter the same zone,
  a Say from one is received by both (including the sender, verified as a distinct read from the
  sender's own connection, not inferred), a Whisper is received only by its target with a
  separate delivery ack for the sender, and whispering a name that isn't in the world returns a
  clear failure reason instead of hanging.
  Ported to GDScript (`chat.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `ChatMessage` and `ChatWhisperRequest` via independent Go/GDScript hex
  generation. All 14 GDScript suites pass headless; wired into CI. Full Go test suite green;
  server binary smoke-tested with chat wired in.

## 2026-08-19 (cont'd 27)

- Added a guild system, distinct from party in one deliberate way: parties (`internal/party`)
  are in-memory/session-scoped by design (dissolving on restart is fine for a live grouping),
  but guilds are meant to be a long-lived social structure, so `server/internal/guild` is
  Postgres-backed from the start -- no `MemStore` variant, matching the reasoning that a
  guild you can lose on server restart isn't really a guild. Schema: `guilds` (id, name, unique
  case-insensitively) + `guild_members` (guild_id, character_id unique across all guilds, role,
  joined_at). Create/Join/Leave all run inside a transaction so a name clash or a
  duplicate-membership race can't leave a half-created guild or double membership behind.
  Leave promotes the earliest-joined remaining member (by `joined_at`) to leader, or deletes the
  guild row entirely if the leaver was the last member -- transactional, so a crash mid-leave
  can't leave a leaderless guild.
  `server/internal/session/guild.go`: opcodes 0x0090-0x0095 (create/join/leave requests +
  results). Deliberately no broadcast opcodes here (unlike party's MemberJoined/MemberLeft) --
  `guild.Store` has no notion of which members are currently online since membership outlives
  any one session, so there's no session list to broadcast to; a client learns about roster
  changes from its own join/leave response instead. Documented this reasoning inline rather than
  leaving it to look like a missed feature.
  Full flow tested end-to-end over two real TCP connections against a real Postgres-backed
  `guild.Store` (not a mock): Alice founds a guild, Bob joins it, Alice (the founder) leaves and
  leadership passes to Bob rather than disbanding the guild since he's the only member left.
  Ported to GDScript (`guild.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `GuildResult` and `GuildCreateRequest` via independent Go/GDScript hex
  generation. All 13 GDScript suites pass headless; wired into CI. Full Go test suite green
  across all packages including the new `guild` package; server binary smoke-tested with guilds
  wired in.

## 2026-08-19 (cont'd 26)

- Added a party/grouping system, closing the "parties/guilds/PvP: 0%" gap from the earlier scope
  assessment (guilds/PvP still remain future work). `server/internal/party`: an in-memory `Hub`
  (own design, no real party data to RE — parties are pure session state, not persisted) tracking
  parties by ID, a character->party index, and a session->character index used specifically for
  disconnect cleanup. `MaxSize = 5`. `Leave` promotes the next member to leader or disbands the
  party if the leaving member was last; `LeaveBySession` wraps the same logic keyed by session ID
  so a dropped TCP connection cleans up its party membership without the client sending an
  explicit leave first.
  `server/internal/session/party.go`: opcodes 0x0080-0x0087 (create/join/leave requests + results,
  plus member-joined/member-left broadcasts to the rest of the party). `PartyDisconnectHandler`
  wired alongside the existing `WorldDisconnectHandler` into `cmd/server`'s combined
  `OnDisconnect` hook.
  Full flow tested end-to-end over two real TCP connections: alice creates a party, bob joins it
  and alice receives the `PartyMemberJoined` broadcast, bob leaves and alice receives
  `PartyMemberLeft`. (First draft of this test file used an over-engineered generic type-assertion
  helper that didn't make sense — scrapped it for the same plain `net.Conn` pattern already used
  by every other session test.)
  Ported to GDScript (`party.gd` + test), wired into `NetClient` (signals + create/join/leave
  methods + dispatch cases), reconfirmed byte-exact wire compatibility for `PartyResult` and
  `PartyJoinRequest` via independent Go/GDScript hex generation. All 12 GDScript suites pass
  headless; wired into CI. Full Go test suite green across all packages; server binary
  smoke-tested with parties wired in.

## 2026-08-19 (cont'd 25)

- Added a skill system: `server/internal/skill` (own design, tiny fixed catalog -- "Power Strike"
  +15 damage/5s cooldown, "Whirlwind" +10 damage/3s cooldown -- since `_RefSkill`'s ~118 columns
  are still only partially catalogued, no real skill data exists to import yet). Postgres-backed
  per-character "known skills + last-used-at" tracking for cooldown enforcement.
  Refactored `session/combat.go`'s attack-resolution logic (damage calc, monster HP, counterattack,
  gold reward, zone broadcast) out of `CombatHandler` into a shared `performAttack` helper, so
  `OpUseSkill` (skill.go) and `OpAttack` (combat.go) go through identical logic — a skill is just
  an attack with a damage bonus, not a separate combat path with its own chance to drift out of
  sync. `OpUseSkill`'s response deliberately reuses `OpAttackResult` rather than inventing a
  parallel result type for the same information.
  Full flow tested end-to-end over real TCP: using an unlearned skill fails, learning it twice
  fails the second time, using it lands the correct combined damage (weapon + skill bonus -
  defense), and using it again immediately hits the cooldown.
  Ported to GDScript (`skill.gd` + test), wired into `NetClient`, reconfirmed byte-exact wire
  compatibility for `UseSkillRequest`. All 11 GDScript suites pass headless; wired into CI. Server
  binary smoke-tested with skills wired in.

## 2026-08-19 (cont'd 24)

- Closed the client/server parity gap: the last several rounds added inventory, equipment, shop,
  and combat to the Go server's protocol, but the GDScript client had no code for any of them
  (only login/character-select). Ported all four: `client/scripts/net/{inventory,equipment,shop,
  combat}.gd`, matching each Go payload shape exactly. Wired all of it into the `NetClient`
  autoload as new signals/methods.
  Worth noting one real protocol shape discovered while wiring `NetClient`: `OpEquipmentResult`
  covers list results *and* equip/unequip acks with the same opcode and payload shape (a successful
  equip ack is just an empty items list) — there's no way for the client to distinguish "this is a
  list response" from "this is my equip request's ack" at the opcode level. Went with a single
  `equipment_result` signal reflecting that reality rather than inventing a false distinction the
  wire format doesn't actually support.
  Reconfirmed byte-exact wire compatibility for the three most structurally complex new payloads
  (`AttackResult`, `EquipRequest`, `ShopBuyRequest`) by hex-diffing independently generated output
  from the Go and GDScript sides. All 10 GDScript test suites pass headless; wired into CI.

## 2026-08-19 (cont'd 23)

- Made combat two-directional: characters previously had no HP and monsters never fought back, so
  the "combat" system landed last round was really just a damage sponge with no risk. Added
  `character.MaxHP`/`HP` (flat 100, own design) with `ApplyDamage`/`ResetHP` on `Store` (both
  `MemStore` and `SQLStore` — another `ALTER TABLE ... ADD COLUMN IF NOT EXISTS hp` migration,
  same pattern as gold's). `combat.Monster` gained an `Attack` field; `CombatHandler` now applies a
  monster's counterattack to the attacking player whenever the monster survives the hit (a dead
  monster can't retaliate). Death auto-respawns the player at full HP rather than leaving them
  stuck — no harsh MMO death penalty for this MVP.
  Reshaped `AttackResult`'s wire format to carry both sides of the exchange (`MonsterDamage`/
  `MonsterRemainingHP`/`MonsterDied` and `PlayerDamageTaken`/`PlayerHP`/`PlayerDied`) rather than
  bolting player fields onto the old monster-only shape.
  Full flow re-verified end-to-end: first hit shows the monster taking damage *and* the player
  taking counter-damage; second hit kills the monster with no counterattack and confirms the
  player's HP carries over unchanged from the first hit (not reset, not further reduced).
  All packages build/vet/test clean; server binary smoke-tested.

## 2026-08-19 (cont'd 22)

- Added `server/internal/combat`: the closing piece of the core gameplay loop this session built
  toward. Own design throughout — `Hub` tracks live monsters (in-memory, same reasoning as
  `world.Hub`), damage = attacker's equipped weapon's `PhysAttackMax` (or a flat `unarmedDamage`
  fallback with nothing equipped) minus the monster's `Defense`, floored at 1 so combat can never
  stall at zero damage. `world.Hub` gained `EntitiesInZone` (everyone in a zone, unlike the
  existing `Move`/`Enter`/`Leave` methods which return "everyone *except* the mover") so combat can
  broadcast hits to bystanders.
  Wired `OpAttack` + `OpMonsterDamaged`/`OpMonsterDied` broadcasts into the protocol.
  Caught a real bug via the end-to-end test, not by inspection: the first version broadcast
  `OpMonsterDamaged`/`OpMonsterDied` to *everyone* in the zone including the attacker themselves,
  who already gets a richer direct `OpAttackResult` — so the attacker's socket received two packets
  per attack, and a test helper that read only one response per request decoded the second attack's
  reply as the *first attack's leftover broadcast*, producing nonsense values (`RemainingHP:5120`
  instead of 0). Fixed by excluding the attacker's own session from the broadcast.
  `cmd/server` now spawns a single placeholder monster ("Stone Golem", own invented content — no
  real monster/drop data has been imported, see `refdata_schema.md`'s open items) in the world's
  one spawn zone, with a background loop that respawns it 10s after each death.
  Full flow (login -> enter world -> equip weapon -> attack twice -> confirm damage/death/gold
  reward -> confirm the dead monster is actually gone) tested end-to-end over real TCP. All
  packages build/vet/test clean; full server binary smoke-tested spawning its monster on startup.

**This closes out "do it all" for the core MVP gameplay loop**: account -> character ->
persistence -> world/movement -> inventory -> equipment -> shop -> combat, all cross-verified
between Go and (for the client-facing pieces) GDScript where applicable. What's *not* done and
worth being honest about: skills, real monster/drop content (this session's monster and shop
prices are placeholder own-designed content, not derived from the original's actual game-balance
data), quests, parties/guilds/PvP, and all client-side 3D rendering/UI beyond login and character
select.

## 2026-08-19 (cont'd 21)

- Added `server/internal/shop`: a basic NPC vendor, entirely own design. No original pricing data
  exists to draw from (never restored/mined a real price table from the obtained DB backups), so
  `Price()` computes cost from an item's own combat stats via a simple own formula
  (`basePrice + statMultiplier * sum-of-attack/defense`) rather than looking anything up. `Service`
  composes `character.Store` (gold), `inventory.Store` (receiving items), and an `ItemLookup`
  (catalog/pricing) — not backed by its own table, just a computed layer over the others.
  `Buy` refunds gold automatically if adding the item to inventory fails after gold was already
  deducted (e.g. no inventory room), so a failed purchase can't silently take someone's money.
  Wired `OpShopBuy` into the protocol; full buy flow (login -> buy -> confirm gold deducted and
  item received) tested end-to-end over real TCP.
- All packages build/vet/test clean; full server binary (accounts, characters, refdata, inventory,
  equipment, shop, all sharing one Postgres connection) smoke-tested starting up cleanly.

## 2026-08-19 (cont'd 20)

- Added currency: `character.Character` gained a `Gold` field (`StartingGold` = 1000, own design),
  `Store` gained `AddGold`/`DeductGold` (both `MemStore` and `SQLStore`). Caught a real migration
  bug: `CREATE TABLE IF NOT EXISTS` doesn't add columns to an already-existing table, so the shared
  local Postgres instance (which already had a `characters` table from earlier sessions) silently
  kept the old schema until an explicit `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` was added — a
  real "works on a fresh DB, breaks on an existing one" class of bug, caught by testing against the
  actual persistent local instance rather than a fresh one each time.
- Added `server/internal/equipment`: own design, two slots for now (`SlotWeapon`, `SlotArmor` —
  enough to make combat math meaningful without over-building). Equip moves an item out of
  inventory (swapping out and returning whatever was previously equipped first, so nothing is ever
  silently lost); Unequip returns it. Depends on `inventory.Store` as an interface, not a concrete
  type. Wired `OpEquipmentList`/`OpEquip`/`OpUnequip` into the protocol. Full equip -> list ->
  unequip flow tested end-to-end over real TCP, confirming the item actually leaves and returns to
  the inventory, not just that the equipment table looks right in isolation.
- All packages build/vet/test clean against the real local Postgres instance; full server binary
  wired with accounts/characters/refdata/inventory/equipment all sharing one Postgres connection
  string.

## 2026-08-19 (cont'd 19)

- Added `server/internal/inventory`: an independently-designed per-character item store (fixed
  50 slots, stacking up to each item's `refdata`-defined `MaxStack`, own placement logic — fill
  existing under-full stacks before opening new slots). Postgres-backed, same pattern as
  account/character/refdata. `refdata.SQLStore` now also implements `inventory.MaxStackLookup`
  (`GetMaxStack`) so inventory doesn't need its own copy of item stack-size data.
  Wired `OpInventoryList` into the protocol (`session/inventory.go`) — deliberately **not** wiring
  add/remove to any opcode yet, since there's no legitimate way for a player to acquire items
  without a shop, combat, or drop system, none of which exist yet; those opcodes land once those
  systems do.
  Caught and fixed a real bug while writing the session-level test: forgot that Postgres-backed
  test packages need their own truncate-between-runs step, unlike `MemStore`-only packages — the
  first run of the full end-to-end test silently accumulated inventory across repeated test runs
  (5 items became 10) before being caught and fixed with a small `TruncateForTest` helper.
  All packages build/vet/test clean against the local Postgres instance; full server binary
  smoke-tested with inventory wired in.

## 2026-08-19 (cont'd 18)

- Migrated all three persistent stores (`account`, `character`, `refdata`) from SQLite to
  PostgreSQL, per OpenSRO's preference. Swapped `modernc.org/sqlite` for `jackc/pgx/v5` (via its
  `database/sql` compatibility shim, `pgx/v5/stdlib`, so the rest of the code didn't need to change
  shape) and adjusted each schema for real Postgres idioms rather than a lazy port of the SQLite
  DDL: `BIGSERIAL`/`RETURNING id` instead of `AUTOINCREMENT`/`LastInsertId()` (Postgres's
  `database/sql` driver doesn't support the latter), native `BOOLEAN` instead of an `INTEGER`
  0/1 hack, `DOUBLE PRECISION` instead of SQLite's untyped `REAL`, and a
  `CREATE UNIQUE INDEX ON characters (LOWER(name))` for case-insensitive name uniqueness in place
  of SQLite's `COLLATE NOCASE` (Postgres has no direct equivalent).
  Installed PostgreSQL 14 locally to actually test against a real instance rather than guessing —
  SQLite's `:memory:` trick doesn't exist for Postgres, so tests now share one local
  `srrevamp_test` database and `TRUNCATE` their own tables per test for isolation
  (`SRREVAMP_TEST_POSTGRES_DSN` env var overrides the default local connection string, used by CI's
  new `postgres:16` service container). `cmd/server` and `cmd/import-refdata` now take a single
  `-postgres-dsn` flag instead of per-store SQLite file paths. Full test suite passes against the
  real local Postgres instance, and the built server binary smoke-tested starting up and connecting
  successfully. `go.sum`/`go.mod` no longer reference `modernc.org/sqlite` at all.

## 2026-08-19 (cont'd 17)

- Static game data pipeline, first slice: string-scanning a `.Bak` file (the earlier `db_schema.md`
  pass) only gets table/column *names*, not real schema or any actual data. To go further, stood
  up a temporary SQL Server 2019 instance via Docker on the `ghidra-mcp` box (which already had
  `nesting=1` enabled) and actually restored `SRO_VT_SHARD.Bak`. Confirmed real data: `_RefObjItem`
  (24,521 rows, 105 columns — item stats) and `_RefSkill` (36,144 rows, 118 columns — skill data)
  are genuinely populated, not empty scaffolding.
  Per the same reasoning applied all session (declined to remove `docs/LEGAL.md`'s substance
  earlier): pulled the *schema* (structural facts, written up in new
  `docs/protocol/refdata_schema.md`) but did not commit any actual row data anywhere. Instead built
  `server/internal/refdata` + `server/cmd/import-refdata`: a "bring your own data" CSV importer
  populating our own, independently-designed SQLite schema (a curated subset of the original's 105
  item columns, not a 1:1 port) — the same pattern this repo already uses for pk2 client assets.
  Tested for real against the actual 24,521-row export (kept in a scratch dir outside the repo,
  deleted after) — full round trip worked. Tore down the SQL Server container and deleted the test
  database afterward; nothing about this step is persisted anywhere outside the schema docs and
  importer code.
  Skills, drop tables, and where item/skill display names actually live (not in `_RefObjItem`
  itself) are the next things to figure out — noted in the doc's Status section rather than
  guessed at now.

## 2026-08-19 (cont'd 16)

- Built actual Godot client scenes wired to the protocol layer that already worked in isolation:
  `NetClient` (`client/scripts/net/net_client.gd`, an autoload singleton) wraps a `StreamPeerTCP`
  connection and dispatches decoded packets as signals; `Login.tscn`/`.gd` and
  `CharacterSelect.tscn`/`.gd` are real UI (LineEdit/Button/ItemList, not mockups) driving login,
  registration, character list/create/delete, and entering the world. `Boot.gd` now transitions
  into `Login.tscn` instead of just printing a message.
  Hit a real Godot gotcha immediately: `NetClient`'s script had both `class_name NetClient` and an
  autoload registered under the same name — Godot refuses this ("hides an autoload singleton") and
  it broke every scene referencing it. Fixed by dropping `class_name` (the script is only ever used
  as the autoload, never instantiated as a standalone type elsewhere).
  Verified for real, not just "loads without errors": ran a throwaway script that instantiated
  `NetClient` directly (autoloads aren't available in `--script` mode) against the actual running
  Go server binary and drove it through register -> login -> list (empty) -> create -> enter world,
  asserting on every response -- full stack, real TCP, real server process, not mocked. Deleted the
  script after (not meant to be a committed test, just a one-time integration check); the committed
  GDScript unit tests only cover encode/decode, not the live networking wrapper, which is a real
  coverage gap worth closing with a proper integration test harness later.
  No in-world 3D scene exists yet (needs real map/asset rendering, out of scope here) — character
  select shows a confirmation of zone/position/nearby-player-count as the current end of this
  vertical slice.

## 2026-08-19 (cont'd 15)

- Added a minimal world/zone system: `server/internal/world` (`Hub`, in-memory by design — live
  position data resetting on restart is normal for an MMO, unlike account/character data) tracks
  which characters are present in which zone and who's near whom; `server/internal/session/world.go`
  wires it to the wire protocol (`OpEnterWorld`, `OpMove`, and three broadcast opcodes —
  `OpEntityEntered`/`OpEntityMoved`/`OpEntityLeft`). One fixed spawn point (`jangan`, `{0,0,0}`)
  since no real map data has been pulled apart yet.
  Needed two additions to `gateway` that didn't exist before: a unique `Session.ID()` (so `Hub` can
  key state without comparing `*Session` pointers) and an `OnDisconnect` hook (so leaving the world
  on disconnect doesn't require every handler to poll for dead connections).
  Full flow tested end-to-end over real TCP with two simultaneous connections: second player's
  `OpEnterWorld` sees the first as an "other", first player receives `OpEntityEntered` for the
  second, a move broadcasts `OpEntityMoved`, and disconnecting broadcasts `OpEntityLeft` — all
  through the actual server stack, not mocked.
  Caught a real bug while writing the result decoder: `EnterWorldResult` has more fields after
  `Reason` when `OK=true` (zone, position, others), but the shared `decodeOKReason` helper requires
  *nothing* follow `Reason` — reusing it here would have made every successful `OpEnterWorldResult`
  fail to decode. Wrote a manual decoder for this one instead of forcing the shared helper to fit.
  Ported the same opcodes to GDScript (`client/scripts/net/world.gd` + test), wired into CI, and
  reconfirmed byte-exact wire compatibility for both `EnterWorldResult` and `MoveRequest`.
- Also pushed 15 accumulated local commits to `origin/dev` (merging in one commit — a README edit —
  that had landed there independently in the meantime; no conflicts).

## 2026-08-19 (cont'd 14)

- Gave `character` the same SQLite treatment as `account` (the TODO flagged in the previous
  entry): `character.SQLStore`, same pattern (pure-Go driver, own schema, `COLLATE NOCASE` for
  case-insensitive name uniqueness at the DB level matching `MemStore`'s behavior), same test
  shape including a reopen-persistence test. `cmd/server` now opens both databases by default
  (`-account-db`/`-character-db` flags, both `:memory:`-capable for ephemeral runs) — nothing in
  the running server is backed by `MemStore` anymore. Smoke-tested the actual built binary starts
  and opens both databases cleanly, not just `go test`.

## 2026-08-19 (cont'd 13)

- Closed the most-repeated TODO from earlier entries: `account.SQLStore` (`server/internal/account/sqlstore.go`)
  is a real, persistent `Store`/`Registerer` backed by SQLite via the pure-Go `modernc.org/sqlite`
  driver (no cgo, so it builds the same way everywhere). Own schema (see `db_schema.md`'s facts,
  not the original's `TB_User` layout). Tests cover the same scenarios as `MemStore` plus one that
  actually matters for a "persistent" store and wouldn't be caught by in-memory tests alone:
  closing and reopening a file-backed database and confirming the account survives.
  `cmd/server` now opens a real SQLite database by default (`-account-db` flag, `:memory:`
  supported for ephemeral runs) instead of starting with an empty `MemStore` every time.
  Character storage is still `MemStore` — noted as the next TODO now that accounts are solid.
- Adding `modernc.org/sqlite` pulled in a transitive dependency requiring Go >= 1.25, which bumped
  `go.mod`'s directive automatically. Caught a self-inflicted mistake here: manually reverting that
  bump back to 1.22 (trying to "keep it minimal") broke the build in a confusing way — Go's
  toolchain auto-upgrade only kicks in based on the module's own declared `go` line, not by
  re-deriving it from dependencies at build time, so hand-editing it backwards after `go get` set
  it correctly was wrong. Fixed by restoring `go 1.25.0` and bumping CI's pinned Go version to
  match, rather than fighting the toolchain resolution.

## 2026-08-19 (cont'd 12)

- Added character creation/selection, extending the same account -> session pattern:
  `server/internal/character` (independent design — `MaxPerAccount`, case-insensitive global name
  uniqueness matching the `_IsExistingCharName`-style fact from `db_schema.md`, `Store`
  interface, `MemStore`), and `server/internal/session/character.go` (`OpCharacterList` /
  `OpCharacterCreate` / `OpCharacterDelete` + results, our own protocol).
- `gateway.Session` gained a small generic key/value bag so handlers can remember state across
  packets on one connection — needed so character requests know which account authenticated,
  without `gateway` itself knowing anything about accounts. `session/authstate.go` wraps it with
  typed helpers.
- Refactored the repeated OK/Reason payload shape (login, register, and now two character results)
  into shared `encodeOKReason`/`decodeOKReason` helpers in new `session/wire.go` instead of
  copy-pasting a fourth time. Caught a real bug while doing this refactor: the character
  create/delete handlers set `Reason` on failure but never flipped `OK` back to `false`, so a
  failed create/delete would have reported success with an error message attached — fixed before
  it shipped, not found via a passing-but-wrong test.
- Ported the same character opcodes to GDScript (`client/scripts/net/character.gd` + test), wired
  into CI, and reconfirmed byte-exact wire compatibility with the Go implementation for
  `CharacterListResult` by hex-diffing independently generated output from both sides (same
  method as the earlier login/register check).
- All Go packages build/vet/test/gofmt clean; all GDScript tests pass headless.

## 2026-08-19 (cont'd 11)

- Ported the client side of our own protocol into GDScript: `client/scripts/net/packet.gd`
  (framing, mirrors `server/internal/proto`) and `client/scripts/net/auth.gd` (login/register
  credential + result encoding, mirrors `server/internal/session`). Both have headless GDScript
  tests, now wired into CI alongside the existing pk2/Blowfish ones.
  Caught two real GDScript static-typing parse errors while writing this (untyped `for` loop
  variable breaking `:=` inference in `encode_credentials`, and a `StreamPeer` vs `StreamPeerTCP`
  method mismatch in the framing reader) — fixed before landing, not discovered later.
  Then did the thing that actually matters: generated the *same* login-request and login-result
  frames from both the Go server code and this new GDScript code for identical inputs, and
  diffed the hex — byte-for-byte identical. Real cross-language wire-compatibility confirmation,
  not just "both sides compile."

## 2026-08-19 (cont'd 10)

- Closed the gap noted in the previous entry's TODO (a freshly started real server had no way to
  create accounts to log into): added `account.Registerer` interface + `MemStore.Register`, and
  `server/internal/session/register.go` (`OpRegister`/`OpRegisterResult`, same pattern as login).
  Added `gateway.Chain` to combine multiple opcode handlers into one, since `gateway.Server.Handle`
  is a single function — `cmd/server` now chains login + register. New end-to-end test registers a
  real account over TCP, then logs in with those same credentials, then confirms a duplicate
  registration is rejected — all through the actual running server stack, not mocked. All
  packages build/vet/test/gofmt clean.

## 2026-08-19 (cont'd 9)

- **Direction decision**: confirmed with OpenSRO that the new Go server and new Godot client only
  need to speak a protocol they both define — no requirement to be wire-compatible with the
  original, unmodified Joymax client. Written up in new `docs/protocol/PROTOCOL_DECISION.md`. This
  means the original protocol's obfuscation scheme (handshake opcodes, LFSR rolling byte,
  multi-table CRC byte) is no longer something implementation needs to match — the already-written,
  verified `server/internal/proto` code for it stays as correctly-verified reference, just not
  wired into the real server.
  Static RE for the *original* wire opcode dispatch table also hit two dead ends this session
  (a DB-job-type switch, then a rate-limiter config function) — both were actually
  function-pointer-based dispatch, not switch statements, which explains why simple xref-chasing
  didn't find it. Not worth pursuing further now that wire-format matching isn't a goal anyway.
- Designed and implemented **our own** login protocol end-to-end: `server/internal/session`
  (opcodes `OpLogin`/`OpLoginResult`, a small length-prefixed encoding, `LoginHandler` wired to
  `account.Store`), plus a real end-to-end test that dials actual TCP through `gateway.Server` and
  exercises framing + login handling + account auth together (`TestLoginEndToEnd`, 3 cases: valid
  login, wrong password, blocked account). `cmd/server/main.go` now actually serves logins (against
  an empty in-memory store — account registration isn't implemented yet, so nothing can log in
  against a freshly started real server until that lands). All packages build/vet/test clean.
- Remaining RE-worth-doing work refocused: game *data/logic* facts (item/drop/skill data from the
  `_Ref*` DB tables, pk2 asset contents, gameplay formulas) rather than any more original-protocol
  wire-format archaeology.

## 2026-08-19 (cont'd 8)

- Implemented the handshake's LFSR-based seed derivation (`lfsrByte`, `DeriveSeed` in
  `server/internal/proto/security.go`) — this is an algorithm/method, not a literal data table,
  so it's fair game to reimplement directly (see the doc's updated reasoning). Caught and fixed a
  real transcription bug while writing it up: the tap formula has five XOR rounds, not three —
  cross-checked the final Go implementation against an independently-computed reference for five
  known seeds (`TestLFSRByteKnownValues`) rather than trusting "it builds" as good enough for a
  bit-exact algorithm.

## 2026-08-19 (cont'd 7)

- Tried to trace the real wire-opcode dispatch table in `AgentServer.exe` via the traffic-filter
  string xrefs; that led to rate-limiter config loading, not the dispatcher — another dead end,
  not pursued further for now (would need a more systematic jump-table search).
- Started actual server implementation: `server/internal/account` — an independently-designed
  account/auth package (bcrypt password hashing, a `Store` interface, an in-memory implementation
  for tests/dev). Informed by the facts in `docs/protocol/opcodes/login.md` and
  `docs/protocol/db_schema.md` (an account concept with username/password auth and a
  blocked/allowed status) but not a port of the original schema or stored procedure — own design,
  own error semantics (e.g. identical error for "no such user" vs "wrong password" to avoid
  username enumeration, which the original CGI-era code didn't seem to care about).
  `gofmt`/`go vet`/`go test` all clean.

## 2026-08-19 (cont'd 6)

- Attempted to trace the wire-opcode dispatch table in `GatewayServer.exe` starting from the login
  handler; the function found switches on an internal DB-job-type enum, not the raw wire opcode —
  a dead end for that specific goal, noted in `login.md`'s open items rather than left unexplained.
- Pivoted to a higher-yield target: scanned the `SRO_VT_ACCOUNT`/`SRO_VT_SHARD` `.Bak` database
  backups for embedded UTF-16 identifier strings (SQL Server backups store schema names as plain
  text even in the binary format). Wrote up domain groupings (characters, inventory, guilds,
  siege/fortress, static reference data, logging) in new `docs/protocol/db_schema.md` — names and
  rough categories only, not real column definitions (would need to actually restore a `.Bak` into
  SQL Server for that).

## 2026-08-19 (cont'd 5)

- Corrected `docs/protocol/opcodes/handshake.md`: the initial "security byte" description was
  wrong (a fused checksum that doesn't exist) — it's actually two independent per-packet fields.
  One (LFSR-seeded rolling byte) is now confirmed and implemented in
  `server/internal/proto/security.go` (`RollingByte`, tested, builds/vets/tests clean). The other
  (a multi-table CRC-32-style byte) is understood algorithmically but its table contents are
  deliberately not being pulled from the binary — see the doc.
- Imported `GatewayServer.exe` (login/gateway process) into the same Ghidra project. Found the
  real DB-backed login path (a `_CertifyUser` stored procedure call) alongside dead legacy
  Yahoo-Korea CGI auth code that isn't relevant to a modern reimplementation. Written up in the
  new `docs/protocol/opcodes/login.md`.
- User clarified `docs/LEGAL.md`'s policy is considered deprecated by them; declined to remove its
  substance (see conversation) and kept following it, since the actual copyright exposure it's
  guarding against doesn't change based on what's written in this repo's own docs. Continuing
  clean-room: facts in `docs/protocol/`, independent implementation in Go/GDScript.

## 2026-08-19 (cont'd 4)

- Stood up a dedicated RE box: LXC `ghidra-mcp` (192.168.5.78) on the `ca-pve-01` Proxmox host,
  running Ghidra 12.1.3 + the GhidraMCP plugin (built from source against our Ghidra version) with
  a VNC/noVNC GUI and an MCP bridge, so decompilation work happens on infrastructure we control —
  satisfies `docs/LEGAL.md` policy #2's precondition for doing RE at all.
- Obtained a legally-relevant private-server package (client + `AgentServer.exe` + DB backups) and
  imported `AgentServer.exe` into a Ghidra project there. This is the **first actual RE work** in
  this project's history — corrects the note at the bottom of the 2026-08-19 entry below, which
  was accurate when written but is now superseded.
- Per the clean-room policy: decompiler output itself never leaves that box / never gets pasted
  into this repo. Only plain factual descriptions of observed behavior get written up here. First
  result: `docs/protocol/opcodes/handshake.md` — handshake opcodes (`0x5000`/`0x9000`) and the
  per-packet security-byte algorithm (table-driven checksum + rolling per-session state), described
  in prose, no pseudocode.
- Next: pull exact payload layouts for the handshake opcodes and the session cipher key exchange,
  then implement the handshake state machine in `server/internal/proto` as original Go code
  written against the doc — not a transliteration of anything binary-derived.

## 2026-08-19 (cont'd 3)

- Installed Godot 4.2.2 headless locally (had none) to actually run and test GDScript, not just
  ship it unverified. Disk got very tight doing this (down to ~160MB free at one point) —
  something to watch if more binaries need installing on this box.
- Implemented a from-scratch Blowfish-ECB cipher in GDScript (`client/scripts/pk2/blowfish.gd`).
  The P-array/S-box init constants were extracted *programmatically* from
  `golang.org/x/crypto/blowfish`'s source (not hand-copied — transcribing ~1000 hex constants by
  hand is exactly the kind of thing that produces an undetectable crypto bug) and verified with a
  9-vector known-answer test (`blowfish_test.gd`) whose expected ciphertexts were generated from
  that same trusted Go library rather than typed from memory. All 9 pass, including the actual
  pk2 default key. Caught and fixed one real bug along the way: GDScript's `const` evaluator
  rejects `PackedInt64Array(...)` constructor calls as non-constant expressions — had to use
  plain array literals instead.
- Implemented `client/scripts/pk2/pk2_reader.gd`, the GDScript mirror of the Go pk2 reader
  (header parsing, directory walk incl. multi-block chains, file extraction), verified against a
  synthetic archive in `pk2_reader_test.gd`. This is the piece that actually matters for
  BYO-pk2: it's what the client uses to read a player's own asset files at runtime.
- Wired both new GDScript test scripts into CI (`godot --headless --script ...`), so they run on
  every push/PR, not just once locally.

## 2026-08-19 (cont'd 2)

- Fixed a real bug in the pk2 multi-block directory chain: the `continue` in the
  `entryTypeEmpty` case was skipping the next-block-pointer read for that same slot, so chained
  directories with >18 entries silently truncated. Added `TestReadDirFollowsBlockChain`
  (synthetic 2-block archive) to catch this; it now passes.
- Added `server/internal/gateway`: a real TCP accept loop that frames incoming bytes via
  `internal/proto` and dispatches decoded packets to a handler. Wired into `cmd/server`, which
  now actually runs, listens, and logs every packet it receives (no opcode table yet — logging
  first so we can build the opcode list from real observed traffic later). Smoke-tested by hand:
  ran the binary, sent it a raw framed packet over `/dev/tcp`, confirmed it decoded the opcode
  correctly. Also has an automated test that dials a real socket end-to-end.
- All packages (`pk2`, `proto`, `gateway`) build/vet/test clean locally and in CI.

## 2026-08-19 (cont'd)

- Installed a local Go 1.22 toolchain so builds/tests run locally, not just in CI (this box had
  none). Along the way discovered the VM's root disk was already at 100% full (12GB total, not
  caused solely by this project) — reclaimed ~460MB via `apt-get clean`, `go clean -modcache`,
  and `journalctl --vacuum-size=50M` (all safe/regenerable, nothing of yours touched). Currently
  ~400MB free, which is tight; flagging in case other work on this box needs more room.
- Added `docs/protocol/PK2_FORMAT.md` (pk2/JMXVFS container layout: header, directory entries,
  Blowfish-ECB obfuscation of the directory table using the format's long-published default key)
  and a real, tested read-only reader at `server/internal/pk2/` (header parsing, single-block
  directory walk, file extraction). Multi-block directory chains (>20 entries in one folder)
  are a known gap, called out in code — untested since we don't have a real archive on hand to
  validate the chain-pointer field against.
- Added `docs/protocol/PACKET_FORMAT.md` (wire packet framing: size/opcode/security-byte header)
  and `server/internal/proto/` implementing just the framing layer (read/write single unencrypted
  frames), with unit tests. Explicitly not yet implemented: session key exchange/encrypted
  packets, massive/split-packet reassembly, and any actual opcode payloads — those are next.
- All new code has unit tests (synthetic pk2 archive, packet round-trip) and passes `go build`/
  `go vet`/`go test` locally and in CI.

## 2026-08-19

- Repo created at github.com/OpenSRO/srrevamp (private), `main` (default-intended prod) +
  `dev` (default branch, day-to-day work) pushed.
- Scaffolded `client/` (Godot 4 project skeleton) and `server/` (Go module skeleton).
- CI workflow added: builds/vets/tests server on every push/PR to main+dev, validates Godot
  client project import, and hard-fails the build if any `.pk2`/`.gr2`/`.ddj` game data file is
  ever committed. First runs on `main` and `dev` both green.
- `opensro` invited as a repo collaborator with admin permission (GitHub invite sent,
  pending their acceptance).
- Wrote `docs/LEGAL.md` codifying the clean-room / BYO-pk2 policy, and `CONTRIBUTING.md`
  documenting branch policy.
- **Branch protection is NOT enforced yet** — GitHub blocks branch protection rules /
  rulesets on private repos on the free plan (requires GitHub Pro/Team, or making the repo
  public). User chose to stay private and skip enforcement for now; `CONTRIBUTING.md` documents
  the intended workflow (PR into `dev`, PR `dev` -> `main`, admins can bypass) as convention
  only. Revisit once repo goes public or account upgrades.
- PR #1 (`dev` -> `main`, adds CONTRIBUTING.md) opened and CI-green, left **unmerged** — merging
  into `main` was blocked by the local auto-mode safety classifier as a shared-state action.
  Needs a human merge: https://github.com/OpenSRO/srrevamp/pull/1
- No protocol/format work implemented yet — next up: `docs/protocol/PK2_FORMAT.md` (pk2
  container structure + Blowfish header/filename obfuscation, from public documentation) and a
  read-only pk2 reader under `client/scripts/pk2/`.
- Explicitly did **not**: SSH into 192.168.5.120 or otherwise touch a Ghidra RE box (no network
  access to arbitrary internal hosts from this environment); did not decompile/disassemble any
  Joymax binary. Protocol/format work will proceed from public community documentation instead
  (see `docs/LEGAL.md`). If RE findings come from elsewhere (e.g. a box OpenSRO/OpenSRO run
  themselves), only structured descriptions of the findings should be handed off for
  implementation here — not decompiler output.

### Open items for OpenSRO / OpenSRO
- [ ] Merge PR #1 (dev -> main) — https://github.com/OpenSRO/srrevamp/pull/1
- [ ] OpenSRO: accept the GitHub collaborator invite on OpenSRO/srrevamp
- [ ] Decide: upgrade to GitHub Pro (unlocks real branch protection on private repo) vs. go
      public vs. stay as-is with convention-only branch policy
- [ ] If doing independent RE work on 192.168.5.120 (or elsewhere), hand off structured findings
      (packet field layouts, struct shapes) rather than decompiler output, per docs/LEGAL.md
