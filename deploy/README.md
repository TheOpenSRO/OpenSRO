# Keeping a deployed server current

A machine that runs the compose stack (`docker compose up -d --build` from the repo root) can
follow `dev` on its own. `update.sh` does one round: fetch, and if
`origin/dev` moved, fast-forward, rebuild the stack, and check that the gateway answers on 15779.
The timer runs it every five minutes, so **pushing to `dev` is deploying**.

```
deploy/install.sh                              # once, as the user that owns the checkout
systemctl list-timers opensro-update.timer    # when it next runs
journalctl -u opensro-update                  # every update, build failure and rollback
sudo systemctl start opensro-update.service   # do not wait for the timer
FORCE=1 deploy/update.sh                       # rebuild even if nothing changed
```

What it refuses to do, and says so in the journal:

- **Throw away local edits.** Uncommitted changes to tracked files stop the update until they
  are committed or stashed. Untracked files are left alone — the deployment's own
  `docker-compose.override.yml` (which pins Postgres to `127.0.0.1`) lives there.
- **Stay on a build that does not come up.** If the build fails or the server never listens
  twice ten seconds apart, the checkout goes back to the commit that was running, that stack is
  rebuilt, and the offending origin commit is recorded in `.git/update-held`. Nothing is tried
  again until `dev` moves past it, or the hold file is removed.

Old image layers are pruned after each successful update so the disk does not fill over months.

## Item instance columns (round 732)

Round 732 stores each item's own plus, blue options and advanced elixir. The server adds the
columns itself the first time it opens each table, so **the update needs no manual step**:

```
-- run by the server at boot, for inventory_slots, account_storage_slots and equipment_slots:
ALTER TABLE <t> ADD COLUMN IF NOT EXISTS opt_level  SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE <t> ADD COLUMN IF NOT EXISTS mag_params BYTEA    NOT NULL DEFAULT ''::bytea;
ALTER TABLE <t> ADD COLUMN IF NOT EXISTS adv_elixir SMALLINT NOT NULL DEFAULT 0;
```

Every existing item reads **+0, no options, no advanced elixir**; variance and durability are
untouched. Re-running is a no-op. To check it took on opensro-01, after the update:

```
docker compose exec postgres psql -U postgres -d opensro -c '\d inventory_slots' | grep -E 'opt_level|mag_params|adv_elixir'
docker compose exec postgres psql -U postgres -d opensro -c 'SELECT count(*) FROM inventory_slots WHERE opt_level <> 0'   # 0 right after
```

A backup first (`pg_dump`) is the usual precaution; rolling back to an older server leaves the
columns in place, unread and harmless. GMs can set the values with `/give <id> [qty] [plus]` and
`/item <bag slot> plus|var|quality|opt|adv|clear ...` (OpenSRO's own test hooks).

## Economy transactions, item serials and one connection pool (round 743)

Round 743 makes every trade, shop sale, buy back, pick-up and warehouse move one Postgres
transaction (`docs/rounds/r743.md`). The server adds what it needs itself the first time it opens
the tables, so **the update needs no manual step**:

```
-- run by the server at boot (txn.Schema, then inventory.schemaFor for inventory_slots and
-- account_storage_slots); every statement is a no-op on a second boot:
CREATE SEQUENCE IF NOT EXISTS item_serial_seq;
CREATE TABLE IF NOT EXISTS economy_ops (op_key TEXT PRIMARY KEY, created_at TIMESTAMPTZ NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS economy_ops_created_at ON economy_ops (created_at);
ALTER TABLE <t> ADD COLUMN IF NOT EXISTS serial BIGINT;                         -- nullable first
UPDATE <t> SET serial = nextval('item_serial_seq') WHERE serial IS NULL;         -- the backfill
ALTER TABLE <t> ALTER COLUMN serial SET DEFAULT nextval('item_serial_seq');
ALTER TABLE <t> ALTER COLUMN serial SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS <t>_serial_key ON <t> (serial);
```

Each table's statements run as one implicit transaction, so the `ADD COLUMN`'s ACCESS EXCLUSIVE
lock is held through the backfill and the index build: measured by round 743's review, 7.3 s for
1.44 M bag rows and 2.6 s for 600 k warehouse rows, during which any other query on the table
waits. That is harmless here -- the server is down for the rebuild, the boot runs the migration
before it serves, and production's tables are far smaller -- but a rolling restart of several
servers (the spec's M2) would need the backfill batched outside the lock. Two processes booting at
once take turns (one advisory lock around every store's schema). Every existing stack gets its own
serial; nothing else about an item changes. To check it took on opensro-01, after the
update:

```
docker compose exec postgres psql -U postgres -d opensro -c "SELECT count(*), count(DISTINCT serial), count(*) FILTER (WHERE serial IS NULL) FROM inventory_slots"
docker compose exec postgres psql -U postgres -d opensro -c "SELECT count(*), count(DISTINCT serial), count(*) FILTER (WHERE serial IS NULL) FROM account_storage_slots"
#   the first two numbers equal, the third 0
docker compose exec postgres psql -U postgres -d opensro -c "SELECT count(*) FROM economy_ops"   # grows with trades and pick-ups; rows older than a day are pruned hourly
```

**Connections.** The server now opens one capped pool for its stores and a small one for the
reference data, instead of ten uncapped pools. `OPENSRO_PG_MAX_CONNS` is the whole budget (default
40: 32 for the stores, 8 for the reference data; a value under 4 is ignored). It is optional; to
set it, add it to the server service in the untracked `docker-compose.override.yml`:

```
services:
  server:
    environment:
      OPENSRO_PG_MAX_CONNS: "40"
```

The boot log says what it used: `postgres pools stores=32 refdata=8`. Keep the budget of every
process that shares the database under Postgres's `max_connections` (100 by default).

**Rolling back** to an older server leaves the column, the sequence and the ledger in place: an
older server's inserts take the column's default, so nothing breaks; it simply does not use them.
A `pg_dump` first is the usual precaution.

## The Test Items NPC (round 783)

An NPC of OpenSRO's own -- "Test Items", in Jangan's square between the Storage-Keeper and So-Ok,
wearing Alexandria's Potion Merchant Thiara -- selling every 11th degree alchemy item and every Seal
of Nova item, **for free** (docs/protocol/test_items_npc.md). **Off by default.** It needs no new
export and no new file: its goods are rules in the server binary
(`server/internal/testnpc/test_items.json`) resolved at boot against the item reference data the
server already loads (the refdata database, or `-items-csv`), and its body is the NPC table's
`NPC_SD_T_AREA_POTION` row (`-npcs-csv`, which every `-npcpos-csv` server already has). To switch it
on, add one line to the server service in the untracked `docker-compose.override.yml`:

```
services:
  server:
    environment:
      OPENSRO_TEST_ITEMS_NPC: "1"
```

then `docker compose up -d` (or let the updater restart it). The boot log says what it built:

```
msg="Test Items NPC resolved (round 783, OURS): line/tab label=goods" items=15338 goods=189 tabs="1/1:Elixir=26 1/2:Magic=19 ..."
msg="Test Items NPC spawned (round 783, OURS)" name="Test Items" uid=... body=NPC_SD_T_AREA_POTION ref=26823 region=25000 ... free=true listed_instance_messages=1
```

(the counts are the box's archive's, MEASURED; yours are your archive's). An ERROR line instead names
what is missing: no NPC rows (`-npcpos-csv` / `-npcs-csv`), an item import without code names (older
than round 497: re-run `export-refdata -mode items` and `import-refdata`), or an NPC table without
Thiara's row. The players' clients need this round's release (the NPC's lines and tabs arrive in
OpenSRO's own message 0x00BA; an older client draws the NPC and its name but shows no store line).

Round 786: its Seal of Nova goods are the unlocked, level-101 rows (`_A_RARE_ACTIVE`), and a bought
piece is +12, full variance and full blue. The store lists each piece that way too, in OpenSRO's own
message 0x00BB sent after 0x00BA (`listed_instance_messages` in the line above; 0 without
`-magic-option-assign-csv`, whose item table the instance needs). The server and the clients can be
updated in either order: a client from before round 786 ignores 0x00BB and shows the reference items.

**Its goods are free and sell at their own price** at any NPC (a Seal of Nova piece 250,000, a Magic
stone of luck (Lvl.11) 15,000,000 on the box's archive): with it on, a player can make gold. Switch it
off (remove the line) to close that.

## Avatars (round 789)

The avatar inventory is a new table, `avatar_inventory_slots` (the bag's columns, serial included);
the server creates it at boot, so the update needs no manual step for it. Check after the update:

```
docker compose exec postgres psql -U postgres -d opensro -c '\d avatar_inventory_slots'
```

**One re-export for the attachments.** Whether a dress takes an attachment is itemdata column 159
(ChildItemCount), a new item CSV column (89). Until the item export is re-run with the new
`export-refdata` and re-imported (`import-refdata`; the import adds `items.child_item_count`), every
dress reads 0 and **every attachment is refused** (0x180e); hats, dresses, flags and devil's spirits
work. Check: `SELECT count(*) FROM items WHERE child_item_count <> 0;` answers 396 on the box's
archive (the unique dresses that take one, of 454; MEASURED, AVATAR_RESEARCH.md section 9).

The blacksmith's grant reads the magic option table the alchemy already loads (`-magic-options-csv`,
round 768); without it every grant is refused 0xa. The players' clients need this round's release for
the avatar slots, the list (OpenSRO's own 0x0044/0x0045) and the grant window. Rolling back leaves the
table in place, unread: the avatars worn then are invisible to an older server until it is updated
again (nothing is lost).

## Moving an install from srrevamp to OpenSRO (round 704)

The project was called srrevamp until 2026-10-03. The rename changed every name a deployed
server depends on, so a server installed before it needs moving once, by hand:

| What | Before | After |
|---|---|---|
| Compose project, volume | folder name (`srrevamp`), `srrevamp_srrevamp-postgres-data` | `name: opensro`, `opensro_opensro-postgres-data` |
| Database | `srrevamp` | `opensro` |
| Environment variables | `SRREVAMP_*` | `OPENSRO_*` (a clean break: the old names are not read) |
| Updater units | `srrevamp-update.service` / `.timer` | `opensro-update.service` / `.timer` |
| Host, user, checkout, data | `srrevamp-01`, `srrevamp`, `~/srrevamp`, `~/srrevamp-data` | `opensro-01`, `opensro`, `~/opensro`, `~/opensro-data` |
| Repository | `github.com/OpenSRO/srrevamp` | `github.com/OpenSRO/OpenSRO`, since 2026-10-13 `github.com/TheOpenSRO/OpenSRO` |

**Stop the old updater first, before the rename reaches `dev`.** Left running, it pulls the
renamed commit by itself, and `docker compose up` then builds a second stack (project `opensro`,
an empty database) beside the old one, which still holds port 5432 and 15779: the update fails
and is rolled back and held, or worse, a server comes up on an empty database.

The move runs in three parts, in this order: **A** as the install's user (`srrevamp`) in the old
checkout, **B** as root from outside any `srrevamp` session, **C** as the install's user again
(`opensro` if B renamed it, still `srrevamp` if it did not).

**A. As `srrevamp`, in the old checkout** (steps 1-2; `-p srrevamp` names the old project
explicitly -- the old `docker-compose.yml` has no `name:`, so its project is the folder's name):

```
sudo systemctl disable --now srrevamp-update.timer
cd ~/srrevamp

# 1. A backup, then the database rename (no session may be connected to it: stop the server).
docker compose -p srrevamp exec -T postgres pg_dumpall -U postgres > ~/srrevamp-before-rename.sql
docker compose -p srrevamp stop server
docker compose -p srrevamp exec -T postgres psql -U postgres -d postgres -c 'ALTER DATABASE srrevamp RENAME TO opensro;'
docker compose -p srrevamp down          # never -v: that deletes the data

# 2. Copy the data into the volume the new project name uses. Check the old name first:
docker volume ls | grep postgres-data    # srrevamp_srrevamp-postgres-data, for a ~/srrevamp checkout
docker volume create opensro_opensro-postgres-data
docker run --rm -v srrevamp_srrevamp-postgres-data:/from:ro -v opensro_opensro-postgres-data:/to \
  postgres:16 sh -c 'cp -a /from/. /to/'
```

Then log out: no `srrevamp` session may be left for part B.

**B. As root, from outside the `srrevamp` session** (step 3; optional -- skip it to keep the user
and the host name, and part C says what changes). `usermod` refuses to rename a user with a live
process, and on a cloud-init VM the user's sudo rule lives in
`/etc/sudoers.d/90-cloud-init-users` and names `srrevamp`; `usermod -l` does not touch it, so
renaming the user from its own sudo session leaves `opensro` without sudo. So run it from a root
login on the console, or from the Proxmox host through the guest agent:
`qm guest exec <vmid> -- bash -c '<the lines below>'`.

```
# 3a. Nothing of srrevamp's may be running.
loginctl terminate-user srrevamp 2>/dev/null; pkill -KILL -u srrevamp; sleep 1
pgrep -u srrevamp && echo "srrevamp still has processes -- stop them first"

# 3b. The user, its home and its group.
usermod -l opensro -d /home/opensro -m srrevamp
groupmod -n opensro srrevamp
[ -f /var/spool/cron/crontabs/srrevamp ] && mv /var/spool/cron/crontabs/srrevamp /var/spool/cron/crontabs/opensro

# 3c. The sudo rule names the user: rename it there, then check sudo's files parse.
grep -rl '\bsrrevamp\b' /etc/sudoers /etc/sudoers.d/      # normally only 90-cloud-init-users
sed -i 's/\bsrrevamp\b/opensro/g' /etc/sudoers.d/90-cloud-init-users
visudo -c                                # must say "parsed OK" for every file

# 3d. The host name, in /etc/hosts as well (or sudo complains it cannot resolve the host).
hostnamectl set-hostname opensro-01
sed -i 's/\bsrrevamp-01\b/opensro-01/g' /etc/hosts

# 3e. Keep cloud-init from setting the old host name back at the next boot.
echo 'preserve_hostname: true' > /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
```

Instead of 3e, the Proxmox VM's name can be renamed to `opensro-01` too (cloud-init takes the
host name from it). Changing the VM's cloud-init settings regenerates its cloud-init drive, which
can make cloud-init treat the next boot as a new instance and re-run its first-boot steps (new SSH
host keys, the drive's `ciuser` created again); with 3e in place, the VM name can stay as it is.

**C. As the install's user** (`ssh opensro@opensro-01` after B; `srrevamp@srrevamp-01` if B was
skipped), steps 4-7:

```
# 4. The checkout and the data folder, under the new home.
mv ~/srrevamp ~/opensro && mv ~/srrevamp-data ~/opensro-data && cd ~/opensro

# 5. The remote. Look before changing it: the checkout may reach GitHub through a Host alias or
#    a deploy key named in ~/.ssh/config, or through core.sshCommand.
git remote get-url origin
git config --get core.sshCommand
grep -n -A4 -i 'github\|IdentityFile' ~/.ssh/config
#    Keep whatever alias it uses, and change only the repository's name, e.g.
#    git@github-deploy:OpenSRO/srrevamp.git -> git@github-deploy:TheOpenSRO/OpenSRO.git.
#    An IdentityFile or core.sshCommand that names /home/srrevamp/... must name /home/opensro/...
#    after B (or say ~/.ssh/...). Without an alias:
git remote set-url origin git@github.com:TheOpenSRO/OpenSRO.git
git pull --ff-only                       # to a commit that has `name: opensro`
rm -f .git/update-held                   # a hold left by an update rolled back before A, if any

# 6. The untracked override: the variable names, the DSN's database and the mounted paths.
#    $HOME is /home/opensro after B and /home/srrevamp without it, so the mount becomes
#    /home/opensro/opensro-data or /home/srrevamp/opensro-data -- step 4 moved the folder to it.
cp docker-compose.override.yml ~/override-before-rename.yml
sed -i -e 's/SRREVAMP_/OPENSRO_/g' -e 's#5432/srrevamp?#5432/opensro?#g' \
  -e "s#/home/srrevamp/srrevamp-data#$HOME/opensro-data#g" -e 's#srrevamp-data#opensro-data#g' \
  docker-compose.override.yml
grep -in srrevamp docker-compose.override.yml   # after B: nothing; without B: nothing but /home/srrevamp

# 7. Start the stack under its new name and check it, then swap the updater's units.
docker compose up -d --build
docker compose exec -T postgres psql -U postgres -d opensro -c 'SELECT count(*) FROM characters;'
docker compose logs server | tail       # the boot lines; every flag the override set is named
sudo rm /etc/systemd/system/srrevamp-update.service /etc/systemd/system/srrevamp-update.timer
sudo systemctl daemon-reload
deploy/install.sh                        # installs and starts opensro-update.timer
```

`docker compose up` warns that the volume `opensro_opensro-postgres-data` "already exists but was
not created by Docker Compose". That is harmless: the stack uses it as it is (step 2 made it by
hand). Creating it in step 2 with `--label com.docker.compose.project=opensro --label
com.docker.compose.volume=opensro-postgres-data` avoids the warning.

The old volume stays until it is removed by hand (`docker volume rm srrevamp_srrevamp-postgres-data`,
once the new stack has run for a while). Any reference-data tool run by hand afterwards takes the
new DSN (`.../5432/opensro?sslmode=disable`). A deployment that keeps `-postgres-dsn` in a script
or a shell history, or sets a variable outside the override, needs the same renaming there.

Players' clients: the executable is `OpenSRO.exe` (Linux `OpenSRO.x86_64`), and the release zips
are `opensro-windows.zip` / `opensro-linux.zip` on the renamed repository. A client from before
the rename looks for the old zip names and does not update itself; it is replaced by downloading
the new zip. The new client copies its settings from the old user folder once (`UserDataMigration`;
docs/WORLD_ISSUES.md, round 704), and still reads `type: srrevamp` in `setting/config.yaml` as
`opensro`, with a warning.

## Reference data: making EXP, real weapon damage and skills work (BYO)

**The server ships with no reference data, and until an operator loads it a kill pays no EXP,
every hit deals the floor-band 1-2, the shop sells nothing and no skill can be learned.** The
public test server ran that way from 2026-09-11 to 2026-09-19 without anyone noticing, because
only the EXP curve warned in the log. The data comes from the operator's own client archives
(`Media.pk2` -> `server_dep\silkroad\textdata\`), never from this repo.

Three tables matter and they load two different ways: **items and skills** go into Postgres with
`cmd/import-refdata`; **leveldata is CSV-only** and is passed to the server on its command line.

Round 789: the exporters can also read the tables straight through the archives and any asset
packs (`-archives`, no extraction step, the same CSVs byte for byte): "Asset packs" below.

```
# 1. On a machine with the client's Media.pk2 (BYO). Build the tools:
cd server && for t in pk2list export-refdata export-leveldata import-refdata; do
  CGO_ENABLED=0 GOOS=linux go build -o /tmp/$t ./cmd/$t; done

# 2. Extract the text tables. The archive carries more itemdata_*/skilldata_* parts than the
#    client loads; the index files itemdata.txt / skilldata.txt name the ones it does, in order,
#    and the exporter keeps the LAST definition of a duplicated id -- so feed the parts in the
#    index's order, not glob order (they differ: 1000,2000,... vs 1000,10000,11000,...).
MEDIA=/path/to/Media.pk2; mkdir refsrc && cd refsrc
for f in itemdata.txt skilldata.txt characterdata.txt leveldata.txt levelgold.txt textdata_object.txt; do
  /tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\\silkroad\\textdata\\$f" -out $f; done
/tmp/pk2list -pk2 "$MEDIA" -filter 'textdata\' | awk '{print $2}' \
  | grep -iE 'textdata\\(itemdata|skilldata|characterdata)_[0-9]+\.txt$' | while IFS= read -r p; do
    /tmp/pk2list -pk2 "$MEDIA" -extract "$p" -out "$(basename "$(echo "$p" | tr '\\' /)")"; done
order() { iconv -f UTF-16LE -t UTF-8 "$1" | tr -d '\r' | sed 's/^\xef\xbb\xbf//' | grep -v '^$' \
          | tr 'A-Z' 'a-z' | while read -r n; do [ -f "$n" ] && echo "$n"; done; }
/tmp/export-refdata  -mode items  -out items.csv  $(order itemdata.txt)     # 15,338 rows from a retail archive
for f in skilldataenc.txt; do /tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\\silkroad\\textdata\\$f" -out $f; done
/tmp/pk2list -pk2 "$MEDIA" -filter 'textdata\' | awk '{print $2}' | grep -iE 'textdata\\skilldata_[0-9]+enc\.txt$' \
  | while IFS= read -r p; do /tmp/pk2list -pk2 "$MEDIA" -extract "$p" -out "$(basename "$(echo "$p" | tr '\\' /)" | tr A-Z a-z)"; done
/tmp/export-refdata  -mode skills -enc-exe /path/to/your/sro_client.exe -out skills.csv $(order skilldataenc.txt)
                     # 33,632 rows (round 785: the ENC tables retail's client loads, decrypted with your
                     # own client's key tables; the plain skilldata.txt index gives 33,698, 66 of them ids retail lacks)
/tmp/export-refdata  -mode monsters -out monsters.csv $(order characterdata.txt) levelgold.txt textdata_object.txt
                     # 7,604 monster species (round 654); the server reads it with -monsters-csv
/tmp/export-leveldata -out leveldata.csv leveldata.txt                      # 140 levels
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\npcpos.txt" -out npcpos.txt
/tmp/export-refdata  -mode npcpos -out npcpos.csv npcpos.txt                # 12,367 placements; the server reads it with -npcpos-csv
for f in teleportdata.txt teleportlink.txt teleportbuilding.txt refoptionalteleport.txt; do
  /tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\\silkroad\\textdata\\$f" -out $f; done
/tmp/export-refdata  -mode teleport -out teleport teleportdata.txt teleportlink.txt teleportbuilding.txt refoptionalteleport.txt
                     # a DIRECTORY of CSVs: 222 points, 292 links, 77 buildings, and (round 778) the reverse
                     # return scroll's 39 map points (optionalteleport.csv); the server reads it with -teleport-dir
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\refregion.txt" -out refregion.txt
/tmp/export-refdata  -mode regions -out regions.csv refregion.txt         # 3,194 regions, 103 towns; the server reads it with -regions-csv (round 674)
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\magicoption.txt" -out magicoption.txt
/tmp/export-refdata  -mode magicoptions -out magicoptions.csv magicoption.txt  # 402 rows; the server reads it with -magic-options-csv (round 768)
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\magicoptionassign.txt" -out magicoptionassign.txt
/tmp/export-refdata  -mode magicoptassign -out magicoptassign.csv magicoptionassign.txt  # 74 rows; -magic-option-assign-csv (round 770): drops roll blues
/tmp/export-refdata  -mode chargen -out chargen.csv $(order characterdata.txt) $(order itemdata.txt)
                     # 104 creatable ids (52 bodies, 52 items) and 2 ammunition rows; the server reads it with -chargen-csv (round 682)
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\refshopgroup.txt" -out refshopgroup.txt
/tmp/export-refdata  -mode npcs -out npcs.csv $(order characterdata.txt) refshopgroup.txt
                     # 313 NPC rows, 84 named by refshopgroup (round 708); REQUIRED with -npcpos-csv since round 727 (-npcs-csv)
rm -f itemdata.txt itemdata_* skilldata.txt skilldata_* skilldataenc.txt characterdata.txt characterdata_* leveldata.txt \
      levelgold.txt textdata_object.txt npcpos.txt teleport*.txt refoptionalteleport.txt refregion.txt refshopgroup.txt magicoption.txt magicoptionassign.txt
                     # the extracted tables are game data; keep only the CSVs (and the teleport/ directory)

# The exporter grows a strict-suffix column now and then (latest: item column 89, ChildItemCount,
# round 789 -- a dress that takes an attachment; before it 88, Param6, round 786; 87, Rarity, round 770 --
# a Seal item always drops with blue options; before it item columns 79-86, round 769 -- the
# per-plus increments, so a reinforced item's plus counts; before them item columns 73-78, round 768 -- the
# alchemy columns CashItem, Param1, Param5, Desc128_1, Desc128_4 and MaxMagicOptCount; before them skill columns 47-61, round 616 -- the buff
# and self-cast columns; before them 45 CooldownGroup, round 504,
# and 46 SitGate, round 607 -- the skill-use gate's sitting refusals; before them item columns 61-65 -- the three
# elixir reinforce-rate dwords and the cooltime group/ms, rounds 262-263, 2026-09-19; and the six skill
# prerequisite columns, round 250);
# an older CSV still loads, but the new column reads as 0 until the export is re-run.
# Re-run steps 1-3 after pulling such a change.
#
# ROUND 607 (sitting) NEEDS THIS ON opensro-01: re-run `export-refdata -mode skills` with the NEW
# binary (step 2), then the NEW `import-refdata` (step 3) -- the import is what applies the schema
# change: its store adds the skills.sit_gate column before it writes the rows. The server restart
# (`docker compose up -d` after the pull) is only to run the new server binary, which reads the
# column. Until then every skill's SitGate is 0 and the gate FAILS OPEN: the 59 skills the
# retail server refuses to a seated caster (the Cold/Fire walls, the fortress repair kits, the
# monster transform) can be cast sitting. Check: `SELECT count(*) FROM skills WHERE sit_gate <> 0;`
# answers 59 on a retail archive.
#
# ROUND 616 (buffs, Grass Walk, Ghost Walk) NEEDS THE SAME ON opensro-01: re-run `export-refdata
# -mode skills` with the NEW binary (step 2; the CSV grows to 62 columns), then the NEW
# `import-refdata` (step 3) -- its store adds the fifteen columns (skills.action_kind,
# target_required, target_land, target_self/ally/party, dura_ms, cbuf, nbuf, bbuf, lnks, tele0,
# tele1, buff_params, lks2) before it writes the rows -- then restart the server. Until then every
# skill loads action kind 0 with no 'tele': no buff starts (Grass Walk and the imbues cast as
# before and do nothing) and Ghost Walk is refused for want of a ground move. Check:
# `SELECT count(*) FROM skills WHERE action_kind = 3;` answers 2348, and
# `SELECT count(*) FROM skills WHERE tele1 <> 0;` answers 19, and
# `SELECT count(*) FROM skills WHERE lks2;` answers 160, on a retail archive.
# ROUND 622 (Heal on another player) adds two more columns, TargetHealHP/MP (the CSV is 64
# columns; the store adds skills.target_heal_hp and target_heal_mp): the same re-export and
# re-import. Until then Heal is cast at the named player and heals nobody. Check:
# `SELECT count(*) FROM skills WHERE target_heal_hp > 0;` answers 27 on a retail archive.
# ROUND 636 (buffs that must not stack) adds thirteen columns, the recast rule's (the CSV is 77
# columns; the store adds skills.action_overlap, ovl2, has_dttp, dttp0, dttp1, efr2, offensive,
# msch1, hide, skc_end, basic_group, activity, dtt): the same re-export and re-import, then restart.
# Until then every state byte loads 0 and Fire Protection stacks and the Grass Walks run together,
# as before. Check: `SELECT count(*) FROM skills WHERE action_overlap <> 0;` answers 1835 on a
# retail archive.
# ROUND 636'S REVIEW (one trap at a time, one guard link too many) adds six more, FUN_0059dc80's and
# the collector flag (the CSV is 83 columns; the store adds skills.lnks_group, lnks_max, efr3, qest,
# trap, efr1): the same re-export and re-import. Until then a Fire Trap can be cast again while one
# runs and a Warrior guard links any number of party members. Check:
# `SELECT count(*) FROM skills WHERE efr3 AND lnks;` answers 32 on a retail archive (every one a
# Target_Required 0 row: the Fire Traps and seven quest traps).
# ROUND 640 (the protection walls) adds four columns, 'pw' value[0..3] (the CSV is 87 columns; the
# store adds skills.pw0..pw3): the same re-export and re-import, then restart. Until then no wall
# takes a blow (the toggles' MP drain and switch-off work without them: 'onff' rides in
# BuffParams). Check: `SELECT count(*) FROM skills WHERE pw0 <> 0;` answers 55 on a retail archive.
# ROUND 632 (berserk potions, the Energy of life scroll) NEEDS THE ITEMS RE-EXPORT ON opensro-01:
# re-run `export-refdata -mode items` with the NEW binary (step 1; items.csv grows to 72 columns --
# column 70 CodeName, round 497, which an older CSV may also lack, and the new column 71
# CompositeDesc), then the NEW `import-refdata` (step 3) -- its store adds items.composite_desc and
# the items_code_name_idx index before it writes the rows -- then restart the server. Until then
# the scroll (23944-23947) is refused and the fill it grants cannot be resolved by code. Check:
# `SELECT composite_desc FROM items WHERE id = 23944;` answers
# `[UIL1:ITEM_ETC_SECOND_HWAN,A,3600,1],[UIU1:ITEM_ETC_INCREASE_HWAN_TIME_01]`, and
# `SELECT code_name FROM items WHERE id = 23937;` answers `ITEM_ETC_SECOND_HWAN`, on a retail
# archive. A client that predates round 632 ignores the new opcodes 0x0104-0x0108.
# ROUND 654 (the monster species table) NEEDS THREE THINGS ON opensro-01, in this order:
#   a. re-run `export-refdata -mode skills` with the NEW binary (step 2; the CSV grew to 90
#      columns here -- 91 since round 659, see "Deploying the monster-epic release" -- column 89 is AI_AttackChance, skilldata column 66), then the NEW `import-refdata`
#      (step 3) -- its store adds skills.ai_attack_chance (default -1, "unknown") before it writes
#      the rows. Check: `SELECT count(*) FROM skills WHERE ai_attack_chance > 0;` answers 26650,
#      and `... WHERE ai_attack_chance < 0;` answers 0, on a retail archive.
#   b. run the NEW `export-refdata -mode monsters` line from step 2 (characterdata parts in the
#      index's order, plus levelgold.txt and textdata_object.txt) and copy monsters.csv to
#      ~/opensro-data. It reports 7,604 species, 156 of them drawing their Org row's model, 7,604
#      with a levelgold row and 7,509 whose name key resolves, on a retail archive.
#   c. add "-monsters-csv=/data/monsters.csv" to the override's command (step 4) and restart.
#   The boot log then reads `monster species table loaded ... species=7604 roster_overlaid=11
#   roster_missing=0 roster_changed=0` and `npcpos placements loaded ... roster_species_placed=11
#   npcpos_species_in_monster_table=355`. A WARN naming `kept` means (a) or the levelgold/
#   textdata_object inputs of (b) were skipped: those roster fields keep their hand-typed values.
# ROUND 659 (status effects) -- THE MONSTER-EPIC RELEASE NEEDS THE SKILLS RE-EXPORTED AND
# RE-IMPORTED, even on a server that did round 654's: the skills CSV is 91 columns, column 90
# StatusParams (every status run of the Param block), stored as skills.status_params. A skills
# table imported before round 659 loads with the column empty on every row and NO skill lands a
# status -- no poison, bleeding, burn, stun or freeze, on players or monsters -- and nothing
# fails. Re-run `export-refdata -mode skills` with the NEW binary (step 2), then the NEW
# `import-refdata` (step 3), then restart. Check both:
#   `SELECT count(*) FROM skills WHERE status_params <> '';` must answer MORE THAN 0, and
#   `SELECT count(*) FROM skills WHERE ai_attack_chance > 0;` should answer about 26650 (round
#   654's count on a retail archive).
# Since round 666 the server also WARNs at every boot while no skill carries status params:
# `skills store has NO status params (N skills, 0 with status_params) ... RE-EXPORT skills.csv`.
# ROUND 785 (the skills, server side) NEEDS THE SKILLS AND MONSTERS RE-EXPORTED AND RE-IMPORTED:
#   a. skills.csv now comes from the files the RETAIL CLIENT loads, the ENC tables its
#      skilldataenc.txt names (SkillData_1000ENC.txt .. 47000ENC.txt), decrypted with the key
#      tables of YOUR OWN sro_client.exe (never copied into the repo). Extract them beside the
#      others (the `grep -iE 'textdata\\(itemdata|skilldata|characterdata)_[0-9]+\.txt$'` filter in
#      step 2 does not match the `enc` names -- extract `textdata\skilldataenc.txt` and every
#      `textdata\skilldata_<n>enc.txt`), then:
#        /tmp/export-refdata -mode skills -enc-exe /path/to/sro_client.exe -out skills.csv $(order skilldataenc.txt)
#      It writes 33,632 rows on a retail archive (the plain index wrote 33,698: 66 ids retail lacks,
#      and 36791 at mastery level 10 where retail says 110). The CSV is 94 columns: 91 Params (the
#      raw Param block), 92/93 Mastery2/MasteryLevel2. Then the NEW import-refdata (its store adds
#      skills.param_words, mastery2, mastery_level2) and restart. Check:
#      `SELECT count(*) FROM skills WHERE param_words <> '';` answers 33632. Until then every
#      round-785 mechanic that reads the Param block (area targets, knockdown/knockback, imbues,
#      chains, buff and passive stats, debuffs, cures, resurrection, the MAAT gate) is off and
#      skills behave as before (one target, hits summed).
#   b. re-run `export-refdata -mode monsters` (step 2): monsters.csv grows two columns,
#      Knockdown and KORecoverTime (characterdata cols 81/82). Without them every monster is
#      knockable (3) with a 3000 ms recovery -- the table's commonest values.
# ROUND 829 (the repair's restore fee) NEEDS THE ITEMS RE-EXPORT: re-run `export-refdata -mode items`
# with the NEW binary (items.csv grows to 92 columns, the new column 91 ReviveCost, itemdata column 28),
# then the NEW `import-refdata -items-csv` (its store adds items.revive_cost BIGINT NOT NULL DEFAULT 0),
# then restart the server. Until then a broken item is mended without its restore fee while the client
# quotes it. Check: `SELECT revive_cost FROM items WHERE id = 71;` answers 297 (ITEM_CH_SWORD_01_A).

# ROUND 728 (the warehouse deposit fee) NEEDS THE ITEMS RE-EXPORT ON opensro-01: re-run
# `export-refdata -mode items` with the NEW binary (step 1; items.csv grows to 73 columns, the new
# column 72 KeepingFee, itemdata column 30), then the NEW `import-refdata` (step 3) -- its store adds
# items.keeping_fee BIGINT NOT NULL DEFAULT 0 before it writes the rows -- then restart the server.
# Until then keeping_fee is 0 on every row and EVERY DEPOSIT COSTS 1 GOLD (before round 728 deposits
# were free, so players see a change either way). Check:
# `SELECT keeping_fee FROM items WHERE id = 8;` answers 11 (ITEM_ETC_HP_POTION_05) on a retail
# archive. The client needs no step: the release build compiles the native library with the new
# column; an older library shows a fee of 1 in the deposit box while the server charges the real one.

# ROUND 691 (Europe's masteries and skills) NEEDS NO RE-EXPORT AND NO RE-IMPORT: the race filter
# reads two columns every skills table already has -- skills.mastery1 and skills.req_learn_race
# (CSV fields 22 and 20, exported since 2026-09-12) -- and the Europe rows were always in the
# export (the exporter keeps every Service row). Deploy the new server binary and restart. Check
# before: `SELECT count(*) FROM skills WHERE mastery1 BETWEEN 513 AND 518;` and
# `... AND req_learn_race = 1;` both answer 3242 on a retail archive (MEASURED on the render box's
# re-export, 2026-10-02); 0 means a table imported without the column, and then every Europe
# skill is refused "not your race's skill" -- re-export and re-import as in steps 2-3. The new
# client reads the Europe skill files itself (skilldata_9000/10000/12000/15000/22000/35000 from
# the player's Media.pk2). Existing characters: a China character's stored rows are unchanged; a
# Europe character created since round 682 that raised a China mastery keeps the row in the
# database, but it is no longer sent, summed into the cap or raisable. The held list is the
# Country's; round 692 also seeds a new character's race masteries as level-0 rows from the same
# table, and the two agree.
# ROUND 691'S REVIEW (monster skills learnable for free): a skill with no learn cost (ReqLearn_SP
# 0) is now refused (retail's 0x3409), and a held skill a player may not hold -- a mastery-less,
# cost-less row that is not a base attack (the monster/pet/guard/trap rows), or another race's --
# is refused at the cast and DROPPED, logged as "dropped a learned skill no player may hold"; the
# skill-state request the client sends drops them too. To see what opensro-01 holds BEFORE the
# deploy (the deploy then drops these at each character's next login or cast):
#   SELECT c.name, c.gender, cs.skill_id, s.basic_code, s.req_learn_race, s.mastery1
#   FROM character_skills cs JOIN skills s ON s.id = cs.skill_id JOIN characters c ON c.id = cs.character_id
#   WHERE (s.req_learn_sp <= 0 AND s.mastery1 = 0
#          AND cs.skill_id NOT IN (1,2,40,70,8419,8420,8421,9354,9355,9944,10625,11162,11526))
#      OR (c.gender IN ('europe_man','europe_woman') AND (s.req_learn_race NOT IN (1,3)
#          OR (s.mastery1 > 0 AND s.mastery1 NOT IN (513,514,515,516,517,518))))
#      OR (c.gender NOT IN ('europe_man','europe_woman') AND (s.req_learn_race NOT IN (0,3)
#          OR (s.mastery1 > 0 AND s.mastery1 NOT IN (257,258,259,273,274,275,276))))
#   ORDER BY c.name, cs.skill_id;
# This mirrors playerHoldRefusal exactly (round 691's review: an earlier version missed the
# mastery clause -- 807 race-3 item/mall/quest rows on Mastery1 1, and China base attacks held by a
# Europe character). An empty answer means nothing will be dropped. Run on opensro-01 on
# 2026-10-02 before the deploy: empty.
# 3. On the server host (CSVs and import-refdata copied to ~/opensro-data; Postgres is pinned to
#    127.0.0.1:5432 by docker-compose.override.yml):
~/opensro-data/import-refdata -items-csv ~/opensro-data/items.csv -skills-csv ~/opensro-data/skills.csv \
    -postgres-dsn 'postgres://postgres:postgres@127.0.0.1:5432/opensro?sslmode=disable'

# 4. leveldata is a command-line flag: mount the directory and restate the command in the
#    (untracked) docker-compose.override.yml -- `command` in an override REPLACES the base list:
#   services:
#     server:
#       volumes:
#         - /home/opensro/opensro-data:/data:ro
#       command:
#         - "-addr=:15779"
#         - "-postgres-dsn=postgres://postgres:postgres@postgres:5432/opensro?sslmode=disable"
#         - "-leveldata-csv=/data/leveldata.csv"
#         - "-npcpos-csv=/data/npcpos.csv"       # real monster placements (round 253); omit for the town anchors
#         - "-npcs-csv=/data/npcs.csv"           # the NPC table (round 708); REQUIRED with -npcpos-csv since round 727: the talk menus
#         - "-teleport-dir=/data/teleport"       # the teleport network (round 575); the town teleporters use it (round 576)
#         - "-monsters-csv=/data/monsters.csv"   # the monster species table (round 654); see "Monster species table"
#         - "-regions-csv=/data/regions.csv"     # the towns (round 674): a monster entering one is removed; see "Towns"
#         - "-magic-options-csv=/data/magicoptions.csv" # the blue options (round 768): the alchemy stones; see "Alchemy"
#         - "-magic-option-assign-csv=/data/magicoptassign.csv" # which blues drop (round 770); see "Alchemy"
#         - "-chargen-csv=/data/chargen.csv"     # the creatable catalogue (round 682): without it every create is refused; see "Character lobby"
#         - "-chardefaults-dir=/data/chardefaults" # a new character's default masteries/skills/quests (round 692, EXTERNAL); see "Character defaults"
docker compose up -d
```

**At a host's boot** Docker restarts the server and postgres containers together and ignores the
compose file's `depends_on: condition: service_healthy`, which applies only to `docker compose up`.
The server therefore waits for postgres itself: `-postgres-wait` (default 60s) retries every second,
logging `waiting for postgres` each time. Before this, every reboot of opensro-01 logged one
`opening account store ... connection refused` and a Docker restart of the server.

The boot log then reads `loaded EXP curve path=/data/leveldata.csv maxLevel=140` and
`reference data in PostgreSQL items=15338 skills=33698 ...`; an empty items table logs a WARN
naming this section. Verified on the public server on 2026-09-19 by a level-1 QA character at a
real Mangyang spawn (97/168 local 130,2280): hits of 12-14 (26 on a crit) instead of 1, a
Mangyang dead in four, and after five kills the character's row read level 2, exp 3, gold +267,
str/int 21, 3 stat points.

The exporter maps only the columns this project has measured (see its package doc and
`docs/protocol/ITEM_FORMAT.md`); fields it has not pinned are honest defaults, not guesses.
**This changes live gameplay**, so it is the operator's call to run, not something the deploy loop
does. It is reversible: `TRUNCATE items, skills;` returns the server to the empty state, and
removing the `-leveldata-csv` line stops levelling. The QA harness on the render box reads the
same three CSVs from beside the pk2s (`PK2_DIR`), so keep a copy there too -- and the teleport
directory as `PK2_DIR/teleport` (`qa_shot.sh` passes `-teleport-dir` when
`teleport/teleportdata.csv` is there).

The teleport directory (round 575) is what the town teleporters charge and move by (round 576,
"Town teleporters" below): the boot log gains `msg="teleport network loaded" dir=... points=222
links=292 buildings=77`, and a directory that is configured but does not load (a missing file, a
header that is not the exporter's, a link to a point the table lacks) stops the server at boot, as a
bad `-npcpos-csv` does. Without the directory every teleport is refused.

**Re-export the teleport directory after round 642.** teleportdata.csv gained a twelfth column,
`WorldID` (teleportdata.txt column 12). A directory exported before round 642 still loads, and every
NPC teleporter works with it. But without the column, a link into an instanced area is not refused
up front: the fortress, tomb, temple, survival and Roc gates. To re-export:
1. Re-run the `pk2list` loop and the `export-refdata -mode teleport` line from step 1 into a
   directory named `teleport`.
2. Copy it over `~/opensro-data/teleport` on the server host. It is mounted as `/data/teleport`.
3. Run `docker compose up -d`.

The new `teleportdata.csv` header ends in `Interaction9,WorldID`. There is no database step.

Reference data is otherwise not touched by the update loop.

## Asset packs (`.pk3`): converting, building, exporting through them (round 789)

A `.pk3` is a zip holding files at their pk2 paths; it layers over the retail archives, so a mod
or a new item ships without touching a `.pk2`. The rules (which archive wins, case, safety) are
docs/protocol/asset_packs.md; all of it is OURS (retail has only `.pk2`). **Packs, converted
archives and everything extracted from them are game data: never commit them** (docs/LEGAL.md).
The server reads no archive at runtime; packs reach it through the exported CSVs.

```
cd server && for t in pk2list pk2topk3 pk3pack export-refdata export-leveldata; do
  CGO_ENABLED=0 GOOS=linux go build -o /tmp/$t ./cmd/$t; done
```

**Converting the retail archives** (once; the output drops in for the original: same paths,
every file read back byte-identical before the `.pk3` is renamed into place). Free disk: about
2.8 GB for all five. Measured on the render box: Data.pk2 (3.9 GB) in about 20 s, the five in
about 30 s, 2.7 GB out (docs/protocol/asset_packs.md has the table).
```
mkdir -p /srv/sro/pk3 && for n in Data Map Media Music Particles; do
  /tmp/pk2topk3 -in /srv/sro/client/$n.pk2 -o /srv/sro/pk3/$n.pk3; done
# -measure -in <pk2>: the deflate ratio by extension, nothing written
# -store .ddj: keep textures uncompressed (Data.pk3 about 0.63 GB larger)
```

**Building a pack** from a folder whose files sit at their pk2 paths (case does not matter):
```
mymod/server_dep/silkroad/textdata/itemdata.txt        # the index, with the new part added
mymod/server_dep/silkroad/textdata/itemdata_90000.txt  # the new rows
mymod/prim/mtrl/item/robe_red.ddj                      # a new or replaced texture
/tmp/pk3pack -dir mymod -o /srv/sro/client/z_mymod.pk3
```
It refuses symbolic links, two paths differing only in case, names a reader calls unsafe and
files over 256 MiB, and reads the pack back before renaming it into place. Drop the pack beside
the base archives; a later name wins (`z_` over `a_`), `.pk3` over a `.pk2` of the same name.

**Looking at the layers**:
```
/tmp/pk2list -archives /srv/sro/client -layers        # the stack, highest first
/tmp/pk2list -archives /srv/sro/client -overrides     # every pack file that hides a retail one
/tmp/pk2list -archives /srv/sro/client -which 'server_dep\silkroad\textdata\itemdata.txt'
/tmp/pk2list -archives /srv/sro/client -filter itemdata -l    # list, with the serving layer
/tmp/pk2list -archives /srv/sro/client -volume Media -extract 'server_dep\silkroad\textdata\itemdata.txt' -out itemdata.txt
```
`-source pk2|pk3|mixed` (default mixed) picks the archive types; `-custom <dir>` a loose overlay
folder (default the `custom` folder beside the archive folder, where the client has it, when it exists). `-pk2` also opens one `.pk3`.

**Exporting the reference data through the packs.** `-archives <folder>` makes the exporters read
the tables straight from the layers (a bare name is a file of `server_dep\silkroad\textdata\` in
Media, then any layer, then the disk); `@<index>` expands to the parts an index lists, in its
order -- the `order` shell function of step 2, done for you. So a pack's added rows reach the CSVs
with no extraction step. Measured on the render box (round 789): every CSV of step 2 (items,
skills, monsters, leveldata, npcpos, teleport with walk-ins, regions, magic options, chargen, npcs,
quests) is **byte-identical** whether made the old way (`pk2list -extract` + loose files), through
the `.pk2`s, or through the converted `.pk3`s alone (`-source pk3`). With a test pack adding one
itemdata part and its index line, items.csv grew by exactly that row.
```
A=/srv/sro/client; E="/tmp/export-refdata -archives $A"
$E -mode items  -out items.csv  @itemdata.txt
$E -mode skills -enc-exe $A/sro_client.exe -out skills.csv @skilldataenc.txt
$E -mode monsters -out monsters.csv @characterdata.txt levelgold.txt textdata_object.txt
/tmp/export-leveldata -archives $A -out leveldata.csv leveldata.txt
$E -mode npcpos -out npcpos.csv npcpos.txt
$E -mode teleport -out teleport teleportdata.txt teleportlink.txt teleportbuilding.txt refoptionalteleport.txt \
   eventzonedata.txt 'navmesh\objectstring.ifo'          # objectstring.ifo is Data.pk2's: found in the other layers
$E -mode regions -out regions.csv refregion.txt
$E -mode magicoptions -out magicoptions.csv magicoption.txt
$E -mode magicoptassign -out magicoptassign.csv magicoptionassign.txt
$E -mode chargen -out chargen.csv @characterdata.txt @itemdata.txt
$E -mode npcs -out npcs.csv @characterdata.txt refshopgroup.txt
```
The exporters open the folder strictly: a pack they cannot read, or an entry the reader refuses,
stops the export instead of silently dropping rows; every override is printed. Without
`-archives` they read loose files exactly as before (and `@<index>` works there too, beside the
index file).

## Monster species table

`-monsters-csv` (env `OPENSRO_MONSTERS_CSV`, round 654) loads every monster species in the
client's characterdata: `cmd/export-refdata -mode monsters` writes one row per TypeID (1,2,1,x)
row -- id, code name, the Org code name and id, the name key and its English, TypeID4, rarity,
level, HP, walk/run speed, collision radius, the eight combat columns 71-78, the ten attack-skill
ids 83-92, the model (or the Org row's, flagged) and the levelgold range at its level. See
`server/internal/species` for what each column is and how it is known.

**Round 712 added a 36th column, `ExpToGive`** (characterdata column 79, the kill's base EXP,
READ through the monster's vtable slot 332 -> `0x449340`). A CSV exported before round 712 still
loads, and the kill then falls back to the level table's EXP unit (the old base, which pays
anyone below the monster too little). So after deploying round 712, re-run the
`export-refdata -mode monsters` line from step 2 with the new binary, copy `monsters.csv` to
`~/opensro-data`, and restart the server. A retail archive gives 7,604 rows; Gunpowder Ghost
(1965) carries 749.

What it changes, and what it does not:

- **Without `-full-map`, who spawns where does not change.** The roster in `cmd/server` (eleven
  species) is still what spawns, where it spawned before; with `-npcpos-csv` those eleven take
  their real rows as before. Measured on a retail export: 413 monsters spawn with the table and
  413 without, the same species, zones and levels. **With `-full-map`** (round 660) the table is
  what every field nest hatches from, and the roster's placements are replaced -- see "The full
  map (round 660)".
- Each roster species takes its numbers from its row (level, rarity, HP, the combat columns,
  radius, speeds, gold, and the attack list through the skill store). On a retail export all
  eleven come back identical to the hand-typed values (`roster_changed=0`); a difference is
  logged as a WARN naming both.
- The GM console's `/spawn` finds any species in the table by code name, characterdata id or
  English name (`/spawn 1933 3`, `/spawn MOB_CH_TIGERWOMAN`), with its own level, HP (scaled
  by rarity as the engine scales it) and rarity in the monster list. `/goto` refuses a species
  the server does not place.
- The attack lists need the round-654 skills re-export (AI_AttackChance); with an older skills
  table a non-roster species swings its primary skill only, and the roster keeps its hand-typed
  lists (logged as `kept`).

A configured path that does not load is fatal at boot, the `-npcpos-csv` rule. Without the flag
the server behaves exactly as before.

## NPCs (round 708): the server spawns them

Since round 708 the client places no NPC of its own: as in the original, every NPC is an object the
server spawns and sends as the retail group spawn (0x3017 / 0x3019 / 0x3018) when its 320-unit block
comes into a player's 3 x 3 window, and despawns when it goes out (`docs/protocol/npc_spawn.md`).

- **What the server needs:** `-npcpos-csv` (where the NPCs stand) and a way to tell an NPC row from a
  monster's: `-monsters-csv` (an NPC row is one it does not name) or the new `-npcs-csv`.
  `-nest-db-dir` gives each NPC its nest's position and `wInitialDir` -- the direction it faces --
  where the shard has a nest of its own for it; the others stand at their npcpos position and the
  client faces them by its stand-in. opensro-01 runs with `-npcpos-csv`, `-monsters-csv` and `-nest-db-dir` (and `-full-map`, so the
  NPCs are filed in the one world frame); **since round 727 it needs `-npcs-csv` too** (below). The boot log says what it did: `NPCs spawned by the server (round 708) ...
  rows=257 from_nest=230 from_npcpos=27 near_nest=2`.
- **Required with `-npcpos-csv` since round 727: `-npcs-csv` (`OPENSRO_NPCS_CSV`).** The NPC
  code names and which NPCs run a store. The server builds each NPC's interaction ids from it, and
  since round 727 those ids ARE the talk menu: the select reply `0xB045` carries them, and the
  client builds its lines from them alone (`docs/protocol/npc_gui.md` §8). Without the table every
  NPC would offer "End conversation." alone, so the server now refuses to boot:
  `-npcpos-csv spawns NPCs but no -npcs-csv (OPENSRO_NPCS_CSV) is configured` and exit 1. It is a
  CSV the server reads at boot; nothing goes into Postgres.
- **Order of rollout:** a client from round 708 shows no NPC on a server older than round 708 (which
  sends none). A client from round 727 opens no NPC window on a server older than round 727 (its
  `0x7045` select gets no answer). Deploy the server, with `npcs.csv`, first.

### Round 727 on opensro-01: export, copy, restart (before the round-727 client ships)

```
# 1. On a machine with the client's Media.pk2 and the tools of "Reference data" step 1 (built from
#    round 727 or later). In an empty directory:
MEDIA=/path/to/Media.pk2
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\characterdata.txt" -out characterdata.txt
/tmp/pk2list -pk2 "$MEDIA" -filter 'textdata\' | awk '{print $2}' \
  | grep -iE 'textdata\\characterdata_[0-9]+\.txt$' | while IFS= read -r p; do
    /tmp/pk2list -pk2 "$MEDIA" -extract "$p" -out "$(basename "$(echo "$p" | tr '\\' /)")"; done
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\refshopgroup.txt" -out refshopgroup.txt
order() { iconv -f UTF-16LE -t UTF-8 "$1" | tr -d '\r' | sed 's/^\xef\xbb\xbf//' | grep -v '^$' \
          | tr 'A-Z' 'a-z' | while read -r n; do [ -f "$n" ] && echo "$n"; done; }
/tmp/export-refdata -mode npcs -out npcs.csv $(order characterdata.txt) refshopgroup.txt
#    prints: export-refdata: wrote 313 NPC rows (TypeID 1,2,2,x), 84 named by refshopgroup
rm -f characterdata.txt characterdata_* refshopgroup.txt     # game data; keep only npcs.csv

# 2. Copy it next to the other CSVs on the server host:
scp npcs.csv opensro@opensro-01:~/opensro-data/npcs.csv

# 3. On opensro-01, add the flag to the (untracked) override's server command, beside -npcpos-csv:
#      - "-npcs-csv=/data/npcs.csv"
#    (or the environment variable OPENSRO_NPCS_CSV=/data/npcs.csv). Then pull and restart:
cd ~/opensro && git pull && docker compose up -d --build
docker compose logs server | grep -E 'NPC table loaded|NPCs spawned by the server'
#    expect: NPC table loaded path=/data/npcs.csv rows=313
#    and:    NPCs spawned by the server (round 708) ... rows=257 ... npc_table=true
#    A missing flag shows as: -npcpos-csv spawns NPCs but no -npcs-csv ... and the server exits.
```

Check from a client: the Jangan herbalist's window lists "1. Talk to this person." and "2. Purchase/
Sell recovery liquid medicine"; from level 20, "3. Withdrawing Skill" too, then "End conversation."

## Monster AI (off by default)

The server can run the monster AI tick: monsters stand for 2-6 s, then 76 times in 100 walk a
46-124-unit leg at their walk speed, and run home once they stray past their roam radius. Which
numbers a monster runs by depends on the flags: with `-full-map` and `-nest-db-dir` (round 660)
each monster takes its DB nest's radius and its tactics row -- aggressive or passive, its sight,
the 500-unit give-up, its roam rule (EXTERNAL); otherwise the OURS stand-ins (roam radius 200,
give-up 400, and under `-monster-aggro` every monster aggressive at sight +100). On its own (`-monster-ai` alone) a struck monster stops and
stands while anyone keeps auto-attacking it (the interim hold); `-monster-battle` (below) makes it
chase and swing on its own, `-monster-aggro` makes it notice players, and a unique fights with its
own skills and summons (round 661). The players whose area of interest holds a monster see each
move (round 664: the 3 x 3 blocks of 320 units around each player). What is grounded and what is a
stand-in is in `docs/protocol/monster_ai.md`, "OpenSRO's runtime" and the rounds after it.

It is behind the `-monster-ai` flag (env `OPENSRO_MONSTER_AI`), and **the default is off**. Off,
nothing moves and the wire is exactly what it was, so pushing to `dev` changes nothing until the
operator turns it on. After an update the boot log reads
`monster AI off (-monster-ai / OPENSRO_MONSTER_AI)`.

**Turn it on only when both of these hold:**

1. The client release that draws server-driven moves is tagged, CI is green for it (`gh run list`)
   and its zips are published. That is v0.1.435 (round 533) or later. An older client ignores the
   moves (its `NetClient` warns "unhandled opcode 0x007c" for each), so its players see monsters
   jump on each list refresh.
2. The two live checks in `monster_ai.md` ("The live checks") pass on the render box. Both have
   passed: Run 1 in round 538, and Run 2 in round 539. Re-run them after any change to the tick.

Know what it does before turning it on. Legs can cross walls and objects: the server holds no
collision world yet. Under the interim hold (`-monster-battle` off) a monster hit only by skills
that do not hand off to the auto-attack is let go between casts and may wander off. A client that
stops reading its socket no longer stalls the tick: since round 662 every player is written from
its own queue, and a player whose queue passes 2 MB, or whose writes stay blocked past their
budget, is closed without holding anyone else.

**On.** Add the variable under the server's `environment:` in the untracked
`docker-compose.override.yml`, then `docker compose up -d`:

```
services:
  server:
    environment:
      OPENSRO_MONSTER_AI: "1"
      # OPENSRO_AI_TRACE: "1"     # every state change, leg and strike in the log; only for a check
```

Or append `- "-monster-ai=true"` to the `command:` list the override already restates (step 4 of the
reference-data section above). An override's `command` REPLACES the base list, so restate all of
it. The boot log then reads
`monster AI on: tick 100ms (own design), roam radius 200 (own design)`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then `docker compose up -d`. The
update loop never touches the override, so the setting survives updates until it is removed.

## Monster strike push (off by default)

The server can send a monster's counterattack to everyone in its zone, not only to the player it
struck. The message is `OpMonsterAttacked 0x007D` (round 541), and it goes right after the
attacker's own result. Other players then see the monster swing and the number rise over its
target. The counter itself has not changed, and no number changes: the push repeats what the
attacker's result already says. It does not depend on the monster AI. What is grounded and what is
a stand-in is in `docs/protocol/monster_ai.md`, "The strike push's server half (round 541)".

It is behind the `-monster-strike-push` flag (env `OPENSRO_MONSTER_STRIKE_PUSH`), and **the
default is off**. With it off nothing is sent, and the wire is exactly what it was. After an update
the boot log reads `monster strike push off (-monster-strike-push / OPENSRO_MONSTER_STRIKE_PUSH)`.

**Turn it on only when both of these hold:**

1. A client release that carries round 540 is tagged, CI is green for it (`gh run list`), and its
   zips are published. v0.1.436 (round 542) carries it, and its `Release client` run was green on
   2026-09-24. An older client ignores the push and warns "unhandled opcode" once per connection,
   so its players see nothing new.
2. The live check in that `monster_ai.md` section passes on the render box. It passed in round
   543 ("Measured (round 543)" there).

**On.** Add `OPENSRO_MONSTER_STRIKE_PUSH: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `OPENSRO_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-monster-strike-push=true"` to the override's
restated `command:` list. The boot log then reads
`monster strike push on: OpMonsterAttacked 0x007D to the zone after each counterattack`.

**Off.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.

## Monster battle (off by default)

The server can let a struck monster fight on its own (round 546). It chases its attacker to its
attack band at its run speed (every step an `OpMonsterMoved`, mode 1), swings as soon as it is in
the band and then every ReuseDelay of its attack skill (3000 ms for a Mangyang), each blow reaching
everyone in the zone as an `OpMonsterAttacked 0x007D` -- the blow itself is the same one the
counterattack dealt -- and gives up when its target is more than 400 units away (an own-design
stand-in for a server-database column) and walks home. The counterattack inside the attacker's own
`OpAttackResult` is then no longer made: a player standing out of the band takes nothing until the
monster gets there. What is grounded and what is a stand-in is in `docs/protocol/monster_ai.md`,
"BATTLE's chase and the monster's own swing (round 546)".

Since round 553 the flag also carries the **aggro link**: a party member's first blow on a monster that
is not yet fighting pulls in as many of the ten nearest other monsters -- within the struck monster's
detection radius, scaled by the level gap between it and the attacker -- as the party has members
within 1000 units of the attacker; each runs at the attacker and swings like a struck monster. A solo
player links nothing, and an older client needs nothing new: the linked monsters' legs and blows are
the same `OpMonsterMoved` and `OpMonsterAttacked` a struck monster's are. There is no separate switch;
turning this flag off turns the link off. Its reading and stand-ins: `docs/protocol/monster_ai.md`,
"The aggro link: the runtime (round 553)".

Since round 554 the flag also carries the **second attack skill**: four species -- Mangyang, Water
Ghost slave, Water Ghost and Yeoha -- carry two attack skills in the client's own tables, and a
monster in BATTLE draws each swing between them (by the skill's AI_AttackChance and how far inside
its reach the target stands), walks to the drawn skill's band and cools down for its ReuseDelay. A
Yeoha may therefore open from up to ~115 units with its harder ATTACK03 instead of closing to 22,
and a Water Ghost's ATTACK02 (a status skill this server has no system for) lands a blow of 0. An
older client needs nothing new: the legs and blows are the same `OpMonsterMoved` and
`OpMonsterAttacked`. The other seven species and the flag-off counterattack are unchanged. No
separate switch. Its reading and stand-ins: `docs/protocol/monster_ai.md`, "The second attack
skill: the runtime (round 554)".

It is behind the `-monster-battle` flag (env `OPENSRO_MONSTER_BATTLE`), and **the default is
off**. Off, the interim hold and the counter are exactly what they were. It also **needs
`OPENSRO_MONSTER_AI` and `OPENSRO_MONSTER_STRIKE_PUSH` both on**: without them the boot log reads
`monster battle forced off why=...` and the flag does nothing (never an exit, so the update loop
never rolls back over a flag combination). After an update the boot log reads
`monster battle off (-monster-battle / OPENSRO_MONSTER_BATTLE)`.

**Turn it on only when all of these hold:**

1. The monster AI and the strike push are on (the two sections above), with their own conditions
   met.
2. A client release that carries round 546 is tagged, CI is green for it (`gh run list`), and its
   zips are published. An older client that carries round 540 still shows the monster's swing and
   the other players' blows, but a blow on the player itself is drawn as the swing alone, with no
   hit reaction, number or HP repaint, because that client pairs a blow on itself with its own
   counter result and there is none any more. A client older than round 540 shows no monster
   blow at all and takes silent HP loss.
3. The live check in that `monster_ai.md` section passes on the render box (its "Measured"
   paragraph says whether it has).

**On.** Add `OPENSRO_MONSTER_BATTLE: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, beside `OPENSRO_MONSTER_AI` and `OPENSRO_MONSTER_STRIKE_PUSH`, then
run `docker compose up -d`. You can instead append `- "-monster-battle=true"` to the override's
restated `command:` list. The boot log then reads
`monster battle on: a struck monster chases to its attack band ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Turning `OPENSRO_MONSTER_AI` off also turns this off (the chase runs in the AI tick).

## Monster spawn push (off by default)

The server can send a monster that has just appeared to everyone in its zone the moment it
appears. That covers a roster monster's respawn (10 s after its death) and every monster a GM's
`/spawn` makes. Without it, a client finds the monster only on its next monster list. The message
is `OpMonsterSpawned 0x007E` (round 542): the list's own record for the monster, then the heading
it hatched facing. A client faces a standing body whose model front was measured (round 533) along
that heading; a body walking a leg, or a model with no measured front, is left as it is
(`World3D._face_monster_heading`). The heading is the engine's hatch
roll, `rand() / 32767 * 2pi`, and the monster AI starts the monster from the same heading. The push
does not depend on the monster AI. What is grounded and what is a stand-in is in
`docs/protocol/monster_ai.md`, "The spawn push's server half (round 542)".

It is behind the `-monster-spawn-push` flag (env `OPENSRO_MONSTER_SPAWN_PUSH`), and **the default
is off**. With it off nothing is sent, and the wire is exactly what it was. After an update the
boot log reads `monster spawn push off (-monster-spawn-push / OPENSRO_MONSTER_SPAWN_PUSH)`.

**Turn it on only when both of these hold:**

1. A client release that carries round 540 is tagged, CI is green for it (`gh run list`), and its
   zips are published. It is the release the strike push needs too: v0.1.436 (round 542), whose
   `Release client` run was green on 2026-09-24. An older client ignores the push and warns
   "unhandled opcode" once per connection, so its players still find the monster on their next
   list.
2. The live check in that `monster_ai.md` section passes on the render box. It has not been run
   yet.

**On.** Add `OPENSRO_MONSTER_SPAWN_PUSH: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `OPENSRO_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-monster-spawn-push=true"` to the override's
restated `command:` list. The boot log then reads
`monster spawn push on: OpMonsterSpawned 0x007E to the zone for each respawn and GM /spawn`.

**Off.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.

## Player dead state (off by default)

The server can leave a player a monster kills dead (round 549). The killing blow's result and
push then carry HP 0 (not the respawned 40 %), and the client that carries round 548 holds the
die pose, locks movement and attacks, and shows a Revive button. While dead the server refuses the
character's moves (neither stored nor relayed), attacks, casts, items, pick-ups, duel blows, trade
requests, zone changes, GM `/tp`/`/goto` and guild founding and level-ups, empties its potion
queue, and no monster targets it.
Since round 665 the client offers retail's two choices and `OpRevive 0x0028` carries the
option: "Resurrect at the specified point." takes the character to its return point and revives
it there at 40 % HP -- OpenSRO's return point is the world entry in Jangan, a stand-in for
retail's designated gate -- and "Resurrect at the present point." revives it where it lies (HP at
1 + 40 % of the maximum, the retail handler's arithmetic), at level 10 or under only, as retail.
Nothing revives a dead player unasked any more: retail has no timed revive outside a fortress war,
and round 549's 30 s in-place fallback revived players among the monsters that had killed them.
A character that logs out dead is saved at the return point (with `-persist-position`).
What is grounded and what is a stand-in is in `docs/protocol/character_state.md`, "The
resurrect choices (round 665)".

It is behind the `-player-dead-state` flag (env `OPENSRO_PLAYER_DEAD_STATE`), and **the default
is off**. Off, a kill respawns the player at once, and since round 665 the respawn is moved to the
return point after the kill's messages (an `OpChangeZoneResult` to Jangan), so it no longer comes
back among its killers; the one other flag-independent piece is the entry revive of a stored HP 0
(the last paragraph). It does not
depend on the monster flags: it covers the counterattack inside the attacker's result and the
monster's own swings under `-monster-battle` alike. After an update the boot log reads
`player dead state off (-player-dead-state / OPENSRO_PLAYER_DEAD_STATE): a monster's kill respawns
the player at once at the return point`.

**Turn it on only when both of these hold:**

1. A client release that carries round 665 is tagged, CI is green for it (`gh run list`), and its
   zips are published. **A client older than round 548 stays dead until it logs out**: it sees
   HP 0 and no Revive button after a kill, and since round 665 nothing revives a player unasked;
   it comes back alive (at 40 %) only by logging in again, at its return point with
   `-persist-position`, else at the world entry. Retail is the same above level 10 for a player
   who never picks a button. A client between rounds 548 and 665 has one Revive button, which the
   server reads as the present point at level 10 or under and the return point above it.
2. Round 665's live check (`docs/WORLD_ISSUES.md`, round 665, section 4: a death in the densest
   window, "Resurrect at the specified point.", the arrival in Jangan alive with one EXP loss)
   passes on the render box with the release's server and client. It passed on 2026-09-30 with
   the round's own build. (The round-549 check in `monster_ai.md` asserted the 30 s auto-revive,
   which is gone.)

**On.** Add `OPENSRO_PLAYER_DEAD_STATE: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `OPENSRO_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-player-dead-state=true"` to the override's
restated `command:` list. The boot log then reads
`player dead state on: a monster's kill leaves the player dead ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
A character that was dead at the restart enters alive at 40 % on its next login (the load path's
own rule for a stored zero pool).

## Monster aggro (off by default)

The server can let monsters notice players (round 552). A monster idle, wandering or, once its
blackout has passed, running home scans on its own timer -- every 1001-1500 ms, rolled once per
spawn, the first scan at once -- for the nearest LIVING player within its acquisition radius, its
collision radius + 100 units (the detection distance is an own-design stand-in for a
server-database column; the roster's radii are 104-111 units), and engages it exactly as a blow
would: `-monster-battle`'s chase (`OpMonsterMoved` mode 1) and swings (`OpMonsterAttacked 0x007D`),
the give-up by distance and the walk home. A monster running home ignores players for the time it
takes to run its own radius (4818 ms for a Mangyang, a value derived from the stand-in). A dead
player is never noticed. What is grounded and what is a stand-in is in
`docs/protocol/monster_ai.md`, "Target acquisition: the runtime (round 552)".

It is behind the `-monster-aggro` flag (env `OPENSRO_MONSTER_AGGRO`), and **the default is off**:
off, a monster fights only when struck, exactly as before. It also **needs `OPENSRO_MONSTER_BATTLE`
in effect (so `OPENSRO_MONSTER_AI` and `OPENSRO_MONSTER_STRIKE_PUSH` too) and
`OPENSRO_PLAYER_DEAD_STATE` on**: a noticed player is engaged by the chase and the monster's own
swings, and a monster that seeks players out kills ones who never struck it, who must then stay
dead rather than respawn in place. Without them the boot log reads `monster aggro forced off
why=...` and the flag does nothing (never an exit, so the update loop never rolls back over a flag
combination). After an update the boot log reads
`monster aggro off (-monster-aggro / OPENSRO_MONSTER_AGGRO)`.

**Turn it on only when all of these hold:**

1. The monster battle and the player dead state are on (the two sections above), with their own
   conditions met -- in particular the client releases they need (rounds 546 and 548), since a
   noticed player is chased, struck and killed by a monster it never touched.
2. The live check in that `monster_ai.md` section passes on the render box (its "Measured"
   paragraph says whether it has).
3. You want EVERY roster species aggressive at 100 units. That is the stand-in; there is no
   per-species setting yet, and the only other setting is this flag off.

**On.** Add `OPENSRO_MONSTER_AGGRO: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, beside the four flags above, then run `docker compose up -d`. You
can instead append `- "-monster-aggro=true"` to the override's restated `command:` list. The boot
log then reads `monster aggro on: a monster notices the nearest living player ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Turning `OPENSRO_MONSTER_BATTLE` or `OPENSRO_PLAYER_DEAD_STATE` off also turns this off.

## Single world frame (off by default)

The server can put the whole world in ONE coordinate frame (round 571), so a player who walks out
of Jangan toward Donwhang stays in everyone else's coordinates and meets Donwhang's monsters. Every
zone the server knows a frame for -- the named towns and any `x/y` region label -- is then named in
Jangan's frame (`FrameRegion` "97/168" on `OpEnterWorldResult` and `OpChangeZoneResult`) and kept in
ONE broadcast bucket, and every roster monster with it: each npcpos row is converted against 97/168,
and an own-design anchor is moved into that frame. A zone change (and so a GM `/goto <town>`) lands
at the middle of the town's centre region named in that frame -- the same place it lands with the
flag off, in the other frame's numbers (Donwhang: `ToWorld(102, 153, 960, 960, 97, 168)`). The zone
label stays the client's grid-centre hint. What the choice is and what it is not is in
`docs/RE_COMPLETION.md`, round 571: the frame and the bucket are OWN DESIGN.

What changes for players with it on: a change to a town is always a warp to its landing, never
"already in that zone", and the rest of the world sees the mover leave and re-enter (a flicker).
One bucket has no spatial filter, so moves, local chat and the monster list (413 monsters with
`-npcpos-csv`) reach every player. A label with no frame (a typo, "Jangan" with a capital) keeps its
own bucket and the old wire.

It is behind the `-single-frame` flag (env `OPENSRO_SINGLE_FRAME`), and **the default is off**:
off, every zone keeps its own frame and bucket and the wire is what it was. After an update the boot
log reads `single frame off (-single-frame / OPENSRO_SINGLE_FRAME)`.

**Turn it on only when all of these hold:**

1. A client release that carries rounds 569 to 571 is tagged, CI is green for it (`gh run list`),
   and its zips are published. Round 570's client builds a zone's grid inside the server's
   `FrameRegion`; an older client ignores the field, builds each zone in its own centre's frame and
   puts a zone change's one-frame coordinates inside that grid -- Donwhang's landing, 28,800 units
   out in X, lands it regions away, off the ground it built. Round 569's client resolves the
   server's "donwhang" label and builds the towns' corrected centres. Round 571's client finds the
   grid's corner without the centre's terrain: before it, a town whose centre region failed to load
   streamed its grid around the wrong region (Donwhang's landing as 107/138, not 102/153).
2. You accept these limits of that client, which the flag does not fix:
   - `/unstuck` returns to the ENTRY position, which in the one frame is Jangan's middle wherever
     the player is.
   - The GM console compares a `/goto` reply's zone with the zone the player ENTERED with, so a GM
     who walked to Donwhang and types `/goto jangan` stays put (the zone box's change works).
   - A monster is first drawn at the server's y 0 when no terrain is loaded under it, and nothing
     lowers or lifts a standing one when its region loads later; only the next monster list does
     (an attack, a kill, a GM refresh, the Refresh button). With the flag on, a player in Jangan is
     sent the Earth Ghost's 65 rows while Donwhang is unloaded, so after a walk there each ghost can
     stand up to 116.78 above or 124.44 below its ground until that list (round 571's heights).
   - The far towns sit up to 170,880 units from the origin, where a float32 position steps by 1/64
     of a unit (Constantinople) -- recorded, not rebased.
   - A player who warps to a far town is drawn by the others at the server's y 0: the client places
     another player's body at the snapshot's height with no snap to the ground
     (`World3D._spawn_or_update_other`), and the landings' ground draws 104.07 below that point
     (Donwhang) to 86.23, 182.49 and 246.32 above it (Constantinople, Samarkand, Hotan) under the
     one frame (round 571's heights). It rights itself when the mover's own client lifts it onto the
     ground or lets it fall, a move past `MIN_SEND_DISTANCE` that sends an `OpMove` -- read from the
     code, not measured (round 571's review, recorded in round 574).
   - Two regions near Samarkand come out of the +-1000 / -500 height envelope under the one frame
     and not without it: the peaks of 108/105 and 108/106 draw at 1052.1 and 1108.7 (869.6 and
     926.2 under Samarkand's own anchor). Nothing is placed there at y 0 today; round 571 gated no
     town on the envelope, because Jangan's own 99/170 already breaks it with the flag off
     (1075.41), and checked the places the client puts something at a server-given height instead
     (`docs/RE_COMPLETION.md`, round 571, "Heights under ONE frame").
3. You accept the monster list's size. It is one packet, capped at 32,767 payload bytes (`sizeMask`,
   `internal/proto/packet.go`), and each monster costs 40 bytes plus its name and code name
   (`MonsterSnapshot.Encode`). With `-npcpos-csv` Jangan's 348 roster monsters are 23,769 bytes
   today; the one bucket holds them and the Earth Ghost's 65, 28,189 bytes, for every player.
   72 more Mangyang-sized entries (64 bytes each; four GM `/spawn 20`s, which nothing respawns and
   `combat.Hub` drops only when they die) push it over the cap: every list request then fails in
   `proto.Write` (`payload ... too large for a single frame`) and the gateway closes that player's
   session (`handler error, closing session`). With the flag off it takes 141 in Jangan's bucket
   alone; with it on, 72 anywhere, and every player's list fails -- so under the flag one GM's
   four `/spawn 20`s close every player's session on their next list. No hard guard (a cap, or a
   list split over several packets in `handleMonsterList`) is built; it is a `docs/TODO.md` item to
   close before the flip (round 571's review).

**On.** Add `OPENSRO_SINGLE_FRAME: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `OPENSRO_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-single-frame=true"` to the override's restated
`command:` list. The boot log then reads `single frame on: origin 97/168 ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Every zone is back in its own frame on the next login. A position `-persist-position` saved in the
one frame (below) carries that frame and is named in the zone's own on the next login.

## Saved position (off by default)

The server can put a character back where it left off (round 573). With the flag on it saves the
character's zone label, the frame region its coordinates are in and its position on the character
row -- on a disconnect or logout, on each zone change, at most every 30 s while it walks, and for
everyone still in the world when the server stops (so a deploy keeps them too) -- and the next
login's `OpEnterWorldResult` answers them: the saved label, that label's bucket and frame as they
are that day, and the saved point named in that frame, with a trailing `Restored` byte after
`FrameRegion`. The engine keeps the same fields on its own row (`_CHAR.LatestRegion`, `PosX`,
`PosY`, `PosZ`, bound to charData +0x94..+0xa0 in `docs/protocol/db_bind_offsets.tsv`); when
OpenSRO saves them, their shape and the frame rule are own design -- `docs/RE_COMPLETION.md`,
round 573.

The columns (`latest_zone`, `latest_frame`, `pos_x`, `pos_y`, `pos_z`) are added by the character
store's usual `ADD COLUMN IF NOT EXISTS` migration on the first start of this build, flag or no
flag; an existing row reads "nothing saved" and enters at the spawn.

What changes for players with it on:

- A disconnect, a logout or a server restart no longer sends them back to Jangan's square: they
  enter where they stood, in the zone they were in.
- A save made in one frame and read under another -- `-single-frame` flipped between the two, or a
  town's centre corrected by a later round -- is the same place named in the new frame
  (`worldmap.Rebase`: saved under 98/157 and read under 97/168, a point moves by
  `ToWorld(98, 157, 960, 960, 97, 168)` = (-21120, -1920)), at height 0, which the client lifts onto
  the ground. A save whose frame cannot be converted enters at the spawn.
- A character saved inside a building stays inside it: the client lifts a player only when the
  saved height is below the drawn ground, and moves one out from under a roof only after such a
  lift. `/unstuck` (round 573's client) then takes it to the zone's landing spot.
- A position more than two regions from the zone's centre -- reachable only by walking there, e.g.
  from Jangan toward Donwhang under `-single-frame`, where the label stays "jangan" -- is outside
  the grid the entry builds around the label's centre; the stream then builds around the player,
  as after a GM `/tp` far away. Not measured.
- With `-player-dead-state` on as well, a character that logs out dead is saved at its return
  point (round 665; retail's leave path writes the return point for a dead PC, `FUN_004df050`) and
  re-enters there, revived to 40 % by the entry rule that applies whatever the flags say
  (`handleEnterWorld`'s revive of a stored HP 0, `character.RespawnFraction`). Before round 665 it
  was saved where it fell and re-entered beside the monster that killed it.

It is behind the `-persist-position` flag (env `OPENSRO_PERSIST_POSITION`), and **the default is
off**: off, nothing is saved or read, every entry lands at the zone spawn, and the wire is what it
was. After an update the boot log reads
`persist position off (-persist-position / OPENSRO_PERSIST_POSITION)`.

**Turn it on only when:** a client release that carries round 573 is tagged, CI is green for it
(`gh run list`), and its zips are published. An older client ignores the `Restored` byte: it moves
a restored Jangan entry on to Jangan's landing spot (local 1002, 1020 of 97/168) as it moves every
Jangan entry -- the flag then does nothing in Jangan, where testers log out, and until the player's
first move the server and everyone else hold it at the saved point, not at the landing spot -- keeps
a restored entry in any other zone where the server put it, and its `/unstuck` returns such a
player to the saved point itself.

**On.** Add `OPENSRO_PERSIST_POSITION: "1"` under the server's `environment:` in the untracked
`docker-compose.override.yml`, the same way as `OPENSRO_MONSTER_AI` above, then run
`docker compose up -d`. You can instead append `- "-persist-position=true"` to the override's
restated `command:` list. The boot log then reads `persist position on: a character re-enters
where it last stood ...`.

**Off, the kill switch.** Remove that line (or set it to `"0"`), then run `docker compose up -d`.
Every login is back at the spawn. The saved columns stay; nothing reads or writes them while the
flag is off, so turning it on again restores each character to where it stood when the flag was
last on.

## Town teleporters

The Dimensional Gate in each town moves a player to another town for the link's fee (round 576).
The client sends `OpTeleportUse 0x00F3` with the gate and the destination (teleportdata ids); the
server checks the link and its restrictions (a level range refuses `0x1c15`), charges the fee from
the table (refusing `0x1c07`, with nothing charged or moved, when the gold is short), answers
`OpTeleportResult 0x00F4` with the fee and the destination's name, and moves the player with an
ordinary `OpChangeZoneResult` to the destination gate's own point -- the client reloads the zone
behind its loading screen, as for any zone change. Every teleport is logged:
`msg=teleport account=... character=... gate=STORE_CH_GATE from=GATE_CH dest=GATE_WC zone=donwhang
... fee=5000 waiver=0`. What is grounded and what is a stand-in: `docs/RE_COMPLETION.md`, round
576, and `docs/protocol/teleport_network.md`, "What OpenSRO built".

It needs the teleport directory above (`-teleport-dir`). There is no flag for the teleport itself:
the request is new, and a client release before round 576's client half never sends it, so pushing
to `dev` changes nothing for tagged clients until the release that carries the gate and its board
(round 578: Talk -> 'Select teleport area' -> the Dimensional Teleporter -> Move).

**The teleport NPCs (round 642)** use the same request and rules. These are:
- the ferry and boat ticket sellers at the river crossings (500 gold);
- the airship sellers between Hotan's Karakoram docks, Roc Mountain and Central Asia (500);
- the Samarkand/Taklamakan tunnel managers (500);
- the Constantinople harbour and the pirates (500, or 5,000 and level 95 to Alexandria's Paros
  Light House);
- Jangan's four gate soldiers and Constantinople's three guides (free);
- the two NPCs that lead to Thief Town (free).

Since round 642's review the server also measures the retail interaction range from the
player: 300 units from an NPC and 800 from a gate structure, and the player's own region or a
neighbouring one. It measures NPCs from their npcpos rows, so it needs `-npcpos-csv`
(`/data/npcpos.csv` on opensro-01). Without it the boot log warns `teleport NPCs' interaction
range is not measured`, and NPC teleports are served from anywhere. A teleport directory
exported before round 642 logs `teleport network has no WorldID column` at boot; re-export it as
described above.

Talk to one, then 'Select teleport area', then a destination. The log names the NPC's point:
`gate=GATE_NPC_CH_FERRY`. A destination in an instanced area (a fortress, tomb, temple, arena or
survival map) is refused with nothing charged: OpenSRO has only the open world.

**Who pays.** Everyone pays the link's fee from the table (5,000 gold from Jangan to Donwhang),
except:

- characters below level 21 -- the engine's own waiver (`GObjPC::HandleTeleportUse`, `0x513590`);
- GM accounts (`-gm-accounts` / `OPENSRO_GM_ACCOUNTS`), always -- own design, the user's ask;
- everyone, while `-teleport-free` (env `OPENSRO_TELEPORT_FREE`) is on -- own design, the
  free-while-testing switch. **The default is off**; after an update the boot log reads
  `teleport free off (-teleport-free / OPENSRO_TELEPORT_FREE): ...`.

**Whether the public server runs `-teleport-free` on is the user's decision**, not the deploy
loop's. To turn it on, add `OPENSRO_TELEPORT_FREE: "1"` under the server's `environment:` in the
untracked `docker-compose.override.yml` (or append `- "-teleport-free=true"` to the override's
restated `command:` list), then run `docker compose up -d`; the boot log then reads `teleport free
on: every gate teleport costs nothing ...`. Remove the line (or set it to `"0"`) and run
`docker compose up -d` to charge fees again.

**Return points (round 686).** A town gate's "Designate as return/recall point" makes that gate
the character's return point: the dead window's "Resurrect at the specified point.", the respawn
with `-player-dead-state` off and a logout while dead all go to the gate's point. A character that
never designated one returns to its race's gate -- Jangan's for China, Constantinople's for Europe
(the race is the body's, round 682). It needs the teleport directory above and nothing else:
there is no flag. The boot log reads `return points: designated at a town gate, else the race's
gate ... china_found=true europe_found=true`; without `-teleport-dir` it reads `no teleport network:
every return point is the zone arrival` and returns go where they went before. The database gains
one column at boot (`characters.appointed_teleport`, 0 for every existing character -- its race's
gate); no data is rewritten. The designate line needs a client release that carries round 686; an
older client says "... is not available yet" for it, and everything else works with it.

## Unique monster notices (on by default)

Round 657: when a unique monster (characterdata rank 3) appears or dies, every character in the
world sees it -- a line in the system window and the blue banner at the top of the screen, as the
original does. The kill line names the player who dealt the most damage in the group (party) that
dealt the most. The message is `OpUniqueNotice 0x0110`, carrying the original's `0x300C` payload
(`0x0C05` appeared / `0x0C06` killed). `docs/protocol/unique_notice.md` has the read.

With `-full-map` and `-nest-db-dir` the seven field uniques are placed and rotate over their spots
(round 661, "The full map (round 660)" below): each hatch and each kill is announced. Without
them no unique is placed, and a notice follows only a GM's `/spawnunique <id|name>` and its death
(`/damage <n>`, `/kill`, or players' blows).

It is on by default, as the original is with its `CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG` key
absent. The boot log reads `unique notices on: ...`. **Off:** add
`OPENSRO_UNIQUE_NOTICE_OFF: "1"` under the server's `environment:` in the override (or
`- "-unique-notice-off=true"` in its `command:`), then `docker compose up -d`; the boot log then
reads `unique notices off (-unique-notice-off): no nest-hatch or kill notice is sent; a GM spawn is still
announced`. As in the original, the
key silences a nest's hatch and every kill but not a GM's spawn: `/spawnunique` is still announced. A client older than
round 657 ignores the message and warns "unhandled opcode" once per connection.

## Game clock: time of day (on by default)

Round 786: the server keeps the original's game clock -- a game day every 28 min 48 s of real
time, starting at day 0, 00:00 when the server starts -- and tells each character the day, hour
and minute right after its world entry (`0x3020`). The client runs the same clock from there and
draws the time of day from it: the sky, the light, the fog, the sun, the moon and the lens flare
follow the clock's hour (16 clock hours of day, 8 of night). A GM sets the hour with `/hour <0-23>`;
every character is told at once (`0x3027`). `docs/protocol/game_clock.md` has the read.

The boot log reads `game clock sent=true start="day 0 00:00" real_day=28m48s`. **Start at another
hour:** `OPENSRO_WORLD_CLOCK_START: "06:00"` under the server's `environment:` (or
`- "-world-clock-start=06:00"` in its `command:`). **Off:** `- "-world-clock=false"` in the
`command:`; nothing is sent and clients draw a fixed midday, as before round 786.

The server needs a redeploy to send the clock. A client older than round 786 ignores both messages
and warns "unhandled opcode" once per connection; a round-786 client on an older server draws the
fixed midday.

## Inventory size

Round 633 gave every character its own bag size, and the client pages the bag by it: 32 slots a
page, up to three pages ("Page 1 / Page 2 / Page 3" above the grid, the client's own tabs), with the
slots of the last page past the size drawn locked, as the original draws them.

- `-inventory-size` (env `OPENSRO_INVENTORY_SIZE`) is the size of every character nobody has sized:
  **96 by default, three full pages** -- our choice for the test server, not a retail value. Set
  it lower (for example 32, one page) with `- "-inventory-size=32"` in the override's `command`, or
  the env variable, and `docker compose up -d`.
- A GM changes their own with `/invsize <1-96>`, or `/invsize default` to go back to the flag.
  `/invsize` alone prints it.
- The inventory expansion item (ITEM_MALL_INVENTORY_ADDITION, +32) grows a character's bag the way
  the engine allows: only while the engine's array (bag + 13 equipment) stays within 77, so from a
  bag of 32 or fewer. With the 96 default it is refused and kept.

Lowering the size never strands what a character already carries: items held past the new size
stay listed and can be moved out, used or dropped, while every new item (pickups, buys, trades,
withdrawals, moves) keeps within the new size. The server logs this once per character
(`bag size below a held slot: the items past it stay reachable, nothing new is placed there`), and
the bag is at the lower size once those slots are emptied.

The retail starting size is not known: it is a `_CHAR.InventorySize` database default, and neither
the client nor the server executable carries it.

## Branding your front-end (round 678)

The login screen is retail's title screen: an intro flown in 3D over the world's own regions, with
the archive's own letterbox frame, logo, login box and music. Everything a private server usually
re-brands can be changed without repacking any archive, and every piece falls back to the
archive's own when the operator's is missing or broken (the client's log says which and why). The
format and every recovered value: `docs/protocol/intro_script.md`.

**What can be branded, and where it comes from**

| Piece | Server setting (flag / env) | Client file (next to the executable) | Default |
|---|---|---|---|
| The intro (the camera's flight) | `-login-intro` / `OPENSRO_LOGIN_INTRO` | `custom/intro/<name>.txt` | option.txt's `IntroName` (roc) |
| The title music | `-login-bgm` / `OPENSRO_LOGIN_BGM` | -- (a file in the archives) | option.txt's `IntroBGM` |
| The logo above the login box | `-login-logo` / `OPENSRO_LOGIN_LOGO` | `custom/frontend/<file>`, or `custom/frontend/logo.png` | Media.pk2 `interface\outer\logo.ddj` |
| The top band | `-login-band-top` / `OPENSRO_LOGIN_BAND_TOP` | `custom/frontend/<file>`, or `custom/frontend/band_top.png` | `blackbar_up_18.ddj` |
| The bottom band | `-login-band-bottom` / `OPENSRO_LOGIN_BAND_BOTTOM` | `custom/frontend/<file>`, or `custom/frontend/band_bottom.png` | `blackbar_down_copyright.ddj` |
| A copyright / branding line | `-login-copyright` / `OPENSRO_LOGIN_COPYRIGHT` | -- | none (the archive's band art carries its own line) |

All server settings default to empty: with none set, players see retail's screen. Set them in the
compose override's `command` (`- "-login-intro=constantinople"`) or as environment variables, then
`docker compose up -d`. The server logs what it serves at startup (`front-end theme ...`) and warns
about, and refuses, anything that is not a plain file name.

**How the client picks** (per piece): a `OPENSRO_LOGIN_*` variable on the player's own machine
(for previewing, below) > the server's answer > the answer it cached last launch > the client's
`setting/config.yaml` (round 679: only the intro, `global.loginScreen`; next section) > a
`custom/theme.json` shipped with the client > retail's default. The client asks the server it is
about to connect to (the address remembered from the last login) as it starts, waits at most 1.5 s,
and caches the answer per server address -- so a first launch against a new server may show the
default once, and every launch after it that server's choice. The server answers the question once
and closes that connection; it never logs it. `custom/theme.json` is the same structure the server sends:

```json
{"v":1,"intro":"myserver","bgm":"","logo":"mylogo.png","copyright":"(c) 2026 My Server","band_top":"","band_bottom":"","charselect":null,"create":null}
```

(`charselect` and `create` are reserved for the character select and creation scenes of a later
release; leave them `null`.)

**Choosing a built-in intro.** The archives carry these (vSRO's Media.pk2; `docs/protocol/
intro_script.md` has the table): `roc` (the default; `egypt` and `china_whatf` are the same file),
`constantinople`, `china_wharf`, `jupiter_login`, `rm`, `ruby_baghdad`. The last two also script
smoke, crowds and riders, which this client does not play yet -- their cameras fly over an empty
scene. A full archive path (`script\intro\roc.txt`) works too.

**Writing your own intro.** Put `custom/intro/<name>.txt` next to the client's executable (a name of
letters, digits, `_` and `-`), and set `-login-intro=<name>` on the server (or `"intro"` in
`custom/theme.json`). The file is retail's format, in UTF-16 or UTF-8:

```
[CAMERA]
0.0 S_CameraInsert 0.0 168 97 1002 40 900 0.20 3.14 0.0 100
0.0 S_CameraInsert 8.0 168 97 1002 60 1200 0.15 3.40 0.0 120
0.0 S_CameraInsert 16.0 168 97 900 120 1500 0.30 3.80 0.0 100
[END]
```

Each line: an unused first value, `S_CameraInsert`, the time in seconds, the region's two numbers in
the order **lo hi** (Jangan's region 97/168 is written `168 97`), the look-at point x y z inside that
region (it may run past 0..1920 into the neighbours), then pitch (radians, positive looks down), yaw
(radians, 0 looks north), roll, and the camera's distance back from the look-at point. The camera
eases through every point (a Catmull-Rom spline), every position is taken relative to the LAST line's
region, and it stops on the last point, where the login window fades in -- or earlier, on a click or
a key. The client checks the file when it loads it; one that does not parse falls back to the
archive's intro of that name, then to option.txt's, and logs why. A `[SCRIPT]` section is read but not
run yet. Values a camera cannot fly are refused, so the intro falls back: at most 1024 lines, times
0..3600 s, x and z within 32 regions of the named one (+-61440), heights within +-20000, angles within
+-1000 rad, distances 0..100000, and no `inf`/`nan` (our bounds; retail's own files sit far inside them).

**Memory.** The 3D title is always on; it is not a player option. Measured on the Linux render box,
it raises the process's resident memory once in the world by ~200 MB (glibc keeps what the title's worker threads freed in their own
arenas; `MALLOC_ARENA_MAX=2` in the environment removes it, and lowers the world's own footprint by ~215
MB besides). Windows' allocator does not keep per-thread arenas this way; not measured there.

**The music.** `-login-bgm=<file>` names an `.ogg` track in the player's Music.pk2 root (e.g.
`maintheme_cut.ogg`; only `.ogg` names are looked up there, so only `.ogg` is accepted). Retail has one
title track for every intro; choosing one per server is ours. A name that is not in the archive falls
back to IntroBGM.

**The logo and the bands.** PNG (or DDJ) files in `custom/frontend/`. The logo is shown at the size
and place of the archive's own (508 x 172 in retail's 1600 x 1200 layout, centred above the login
box) and keeps its aspect ratio inside that box -- a 508 x 172 image, or larger at the same shape,
fits it exactly. The bands are stretched to the archive's band rectangles (1600 x 172 in the same
layout: the top one at y 0, the bottom one at y 1030), so draw them 1600 x 172. Set
`-login-copyright` and the bottom band switches to the archive's plain one (`blackbar_down.ddj`) with
your line centred where the archive's own line sits, so the two never overlap.

**Previewing on your own machine, no server needed.** Run the client with the same names as
environment variables, e.g. `OPENSRO_LOGIN_INTRO=myserver OPENSRO_LOGIN_LOGO=mylogo.png`, and
`OPENSRO_CUSTOM_DIR=<folder>` to use a folder other than `custom/` next to the executable. They win
over the server's answer, so you see your files at once; the client's log (`FrontEnd:` and `TITLE:`
lines) says what it used and why it fell back. For a render on the box: `OPENSRO_QA_TITLE_SEEK=0,10,20`
stands the camera at those times and logs `QA TITLE SHOT t=.. frame ..`; `OPENSRO_QA_TITLE_HOUR=0..3`
pins the time of day (retail picks 5, 14, 18 or 23 o'clock at random).

## Configuring the client: setting/config.yaml (round 679)

A private server configures the client it hands its players with **data files in a `setting/`
folder next to the client's executable**, beside its `pk2/` folder -- no rebuilding, and no
re-signing of the executable or its DLLs, because nothing in `setting/` is ever run: the client only
reads it. (Retail keeps its own options in a `Setting\` folder beside its exe too: `SROptionSet.dat`,
`wndpos.dat` and others.) This folder will later hold the client's own saved settings as well --
display, sound, hot bar and the rest; for now it holds one file, the general client config,
`setting/config.yaml`. Developers can point the client at another folder with
`OPENSRO_SETTING_DIR=<folder>`.

```yaml
# setting/config.yaml -- every key is optional, except each server's type and gateway.
global:
  loginScreen: constantinople      # the title intro (same names as -login-intro)
  region: US                       # kept, reserved (see below)
assets:
  source: mixed                    # pk2, pk3 or mixed (round 789; "Asset packs in the client")
servers:
  MyServer:                        # the name the login screen shows
    type: opensro                 # this project's server
    gateway: { address: login.example.com, port: 15779 }
    agent:   { address: agent.example.com, port: 15884 }
  SomePrivateServer:
    type: legacy                   # a server speaking the original protocol
    gateway: { address: 203.0.113.7 }      # the port defaults to 15779
```

| Key | Meaning |
|---|---|
| `global.loginScreen` | The title intro: a retail name (`roc`, `constantinople`, `china_wharf`, `jupiter_login`, `rm`, `ruby_baghdad`, ...) or your own `custom/intro/<name>.txt`. The server's `-login-intro` wins over it (below). |
| `global.region` | Kept and reserved: a short code (letters, digits, `_`, `-`). vSRO's client reads no region: its `DIVISIONINFO.TXT` starts with a locale byte (22 in vSRO's archive) that the client's own loader skips, and the iSRO "Located In" bar's art is in the archive but no code names it. A later round may use it for the language or the content id. |
| `assets.source` | Round 789: which archive types the client reads -- `pk2`, `pk3` or `mixed` (the default). See "Asset packs in the client" below. `OPENSRO_ASSET_SOURCE` overrides it. |
| `servers.<name>` | One server. `<name>` is what the Server field and the list show (1-32 characters). The file's order is the list's order. |
| `servers.<name>.type` | **Required** (round 681): the protocol the server speaks. `opensro` -- this project's server: its status is asked with this project's own question. `legacy` -- the original gateway protocol (a retail-style private server): the client asks it for its shard list the way the original client does (the handshake, then the patch check and the list) and shows each shard's real status; it is never sent this project's own messages, the login screen keeps its own intro for it (no theme question). Round 788: logging in works the original way (the image code included) as far as the character list; entering the world there is not supported yet. An entry without a type, or with another word, is skipped with a `SETTING:` line naming the server and the two values. Once this project's server also speaks the original protocol (the superset plan in `docs/protocol/PROTOCOL_DECISION.md`), `opensro` will mean "also has our extensions" rather than a different wire. |
| `servers.<name>.gateway` | Where the client connects: `address` (a host name or IP address) and `port` (default 15779). Required. It plays the part of retail's `DIVISIONINFO.TXT` host and `GATEPORT.TXT` port. |
| `servers.<name>.agent` | `address` and `port`, both required if given. Retail's gateway tells the client which agent server to connect to in its login reply. Round 788: for a `legacy` server a configured agent stands in for the address the gateway names (a proxy feature, OURS); an `opensro` server is one process and has no such hand-off, so it is not used there. |

**What the player sees.** With `servers` listed, the login screen's Server field shows the chosen
server's name (read-only, centred) and a **LIST** button opens the server list -- retail's window,
built from the archive's own layout and art -- with each server's status, asked of every server at
once and again every 5 s while the list is open (retail's own interval). Picking one with Select (or a
double click) puts its name in the field; the client remembers it for the next launch. Without
`servers`, the field is the old editable `host:port`.

**The status** (the words and colours are retail's, from the archive's text table):

| Shown | When |
|---|---|
| Check | the server runs with `-inspection` (env `OPENSRO_INSPECTION`) |
| Easy | fewer than 35 % of `-max-players` in the world |
| Populated | 35 % to under 97 % |
| Crowded | 97 % to under 100 % |
| FULL | 100 % or more |
| Closed | the server did not answer within 2 s (not running, wrong address, blocked port) |

**A `legacy` server's status is its own.** The client asks its gateway for the shard list and shows
one row per shard, `<config name> - <shard name>`, with the words and colours above computed from
the numbers the gateway sends (Check when it marks the shard in inspection). It tells the gateway
the content id and version of the player's own archive (Media.pk2's `DIVISIONINFO.TXT` and
`SV.T`), as the original client does, so the client needs the Media.pk2 of the server's own client
version; a gateway that refuses that version (or is not in service) shows Closed, with the reason in
the log. Closed also means no answer within 4 s. To try it without a real server:
`go run ./cmd/retailgw serve -listen 127.0.0.1:15779 -shards "Test:120/1000:1,Check:0/500:0"` runs a
fake one (`server/README.md`).

The percentages come from the archive's text table (`UIO_STT_SERVER_35` / `UIO_STT_SERVER_75`, 35
and 97 in the English column), as retail's do. `-max-players` (env `OPENSRO_MAX_PLAYERS`, 1-65535,
default 1000) is the capacity; a login is refused with retail's "The server is full, please try
again later." once that many characters are in the world (characters that have entered the world,
not accounts at character select). Under `-inspection` every login is refused with retail's "Cannot
connect to the server because the server is now in inspection." The `-gm-accounts` names are let
through both, so staff can test a server under inspection or a full one.

**Which setting wins when two places set the intro:** the player's `OPENSRO_LOGIN_INTRO` (a preview)
> the server's `-login-intro` (its fresh answer, else the one cached from the last launch) >
`setting/config.yaml`'s `global.loginScreen` > `custom/theme.json`'s `intro` > retail's `option.txt`.
The reasoning: the server's answer is the branding of the server being connected to, which its own
operator controls; a config may list several servers, and its `global` choice is the fallback for
the ones that set nothing. `custom/theme.json` stays the place for the logo and band images. The
theme is asked of the chosen server.

**Mistakes.** The client logs every problem in its log file as a `SETTING:` line and carries on: a
file that does not parse (the line number is in the message) is ignored whole; a server entry
without a usable gateway, or without a `type` of `opensro` or `legacy`, is skipped and the others
kept; an unknown key is ignored. The file is a
strict subset of YAML: maps by indentation (spaces, not tabs), `{ a: 1, b: 2 }` and `[1, 2]` on one
line, `- item` lists, quoted or plain values, `#` comments; no anchors, tags or multi-line strings.

**Later (not built):** a server may also hand the client settings it wants kept out of the file,
during the server list or after login (docs/TODO.md).

## Asset packs in the client: where they go, the order, the source mode (round 789)

New or changed assets ship as **packs**: plain zip files named `*.pk3` (or `*.zip`) put beside the
retail archives, never injected into a `.pk2`. A pack holds files at the pk2's own paths --
`prim/mtrl/foo.ddj` in a pack replaces `Prim\Mtrl\foo.ddj` -- so overriding a retail file and
adding a new one are the same operation. Everything here is OURS: retail has only `.pk2`. The
rules every reader follows (the client and the Go tools alike) are docs/protocol/asset_packs.md;
converting the retail archives and building a pack are "Asset packs (`.pk3`): converting,
building, exporting through them" above. This section is what the client does with them.

**Where packs go.** In the folder the client found the Data archive in (the `pk2/` folder beside
the executable for players; `OPENSRO_PK2_PATH`'s folder for a developer), or in `OPENSRO_PACK_DIR`.
The client reads every `*.pk3`, `*.zip` and `*.pk2` there that the source mode reads and whose name
is not one of the five base names (`Data`, `Map`, `Media`, `Music`, `Particles`). No subfolders.
Nothing to configure: a pack in the folder is read at the next start.

**The order.** A lookup checks, highest priority first, and the first that has the path serves it:

1. the loose `custom/` folder beside the executable (round 678's folder, beside `pk2/`;
   `OPENSRO_CUSTOM_DIR` for a developer): a path overlay, `custom/prim/mtrl/foo.ddj` answers
   `prim\mtrl\foo.ddj`. Read in every source mode. Round 678's branding files live there too;
2. the packs, **by name, case ignored, the later name winning**: `z_assets.pk3` over
   `assets.pk3`. Of one name, `.pk2` < `.zip` < `.pk3`;
3. the base archive the lookup is for -- its **volume**: the client always knows which archive it
   reads (Data, Map, Media, Music or Particles), and the five are not one namespace (Data and Map
   each have their own `object.ifo`). `Data.pk3` sits above `Data.pk2` when both are read.

A pack overlays every volume: its `prim\...` paths override Data's, its `textdata\...` paths
Media's, and a path no base holds appears in all of them. Paths match case-insensitively, `/` and
`\` alike, empty segments ignored.

**The source mode** (`setting/config.yaml`'s `assets.source`, or `OPENSRO_ASSET_SOURCE` for a test):

| Mode | Reads |
|---|---|
| `mixed` (default) | every type: base archives as `.pk3`, `.zip` or `.pk2`, and every pack |
| `pk2` | `.pk2` only: the retail archives as before round 789, plus any extra `.pk2` pack |
| `pk3` | `.pk3`/`.zip` only: `Data.pk3`, `Map.pk3`, ... converted once (no `.pk2` needed), and the `.pk3`/`.zip` packs |

`custom/` is read in every mode. A volume with no base archive is missing: a pack never stands in
for one (OURS).

**Safety.** The client refuses, and logs, any pack entry whose name could escape the archive (`..`,
an absolute path, a drive letter or `:`), any encrypted entry or one compressed with anything but
stored or deflate, any symbolic link, any entry over 256 MiB, and any entry declaring more than
1100 times its packed size; a pack whose entries together declare more than 1100 times the pack's
size is not opened at all. An entry is never inflated past its declared size and its CRC-32 is
checked. A refused entry is left out; the rest of the pack is read. A symbolic link in `custom/` is
refused too.

**The log.** At start the client logs one line per pack (`AssetArchives: pack 2 z_assets.pk3: 120
file(s) (zip, native)`), which packs shadow which, any refused entries, and, the first time each
volume is opened, every path a pack or `custom/` overrides in it (`AssetArchives: Data: 3 path(s)
of Data.pk2 overridden: prim/mtrl/foo.ddj <- z_assets.pk3; ...`; the first 10, or all with
`OPENSRO_PACK_LOG=all`). The debug panel (Shift+F3) lists the mode, the archives and the packs.
Which layer serves a given path: `/layer <path>` in chat, `OPENSRO_QA_WHICH="path;path"`, or
`client/tools/which_layer.gd` (docs/DEBUG_TOOLS.md).

**A server's own packs** (round 789): a server can name packs every player must have; the client
downloads them into `servers/<host>_<port>/` under the pack folder and, while connected to that
server, reads exactly those over the base archives (its own packs and `custom/` set aside unless the
server allows them). "Server packs" below.

## Server packs: the packs every player must have (round 789)

Your server can name the asset packs every player needs -- a custom avatar, a retextured item, new
item names -- and every client that connects downloads exactly those, checks each by its SHA-256,
and layers them over its own retail archives before character select. Players install nothing by
hand, and nobody plays with a different version of them. All of it is OURS (retail has only
`.pk2`); the protocol and every rule are docs/protocol/asset_packs.md, "Server packs". **Packs are
game data or fan content: they live with your game data, never in the repo** (docs/LEGAL.md).

**1. Put the packs in one folder** on the server (`.pk3` or `.zip` only; build one with `pk3pack`,
"Asset packs (`.pk3`)" above; convert a `.pk2` pack with `pk2topk3`):
```
/srv/sro/client-packs/z_akatsuki.pk3
/srv/sro/client-packs/z_mymod.pk3
```
Names are letters, digits, `_`, `-` and `.`, ending `.pk3`/`.zip`, at most 64 characters, never a
base archive's name (`Data`, `Map`, `Media`, `Music`, `Particles`). Up to 32 packs, 4 GiB each, 16
GiB together. Only the folder itself is read; a pack may be a symbolic link. Any other file in it
(a `.pk2`, a `readme.txt`) stops the server, so nothing is half-served.

**2. Start the server with `-client-packs`** (env `OPENSRO_CLIENT_PACKS`):
```
opensro-server ... -client-packs /srv/sro/client-packs
```
At startup it opens every pack the way the clients will (any entry the readers refuse -- an unsafe
name, a zip bomb, a bad CRC -- refuses the whole pack and stops the server), hashes it, and logs:
```
clientpacks: z_akatsuki.pk3: 590825 bytes, 19 files, sha256 d77be1e2...
client packs: named to every client before login dir=/srv/sro/client-packs packs=2 order="z_akatsuki.pk3, z_mymod.pk3" from="this server's listener, port 15780, /packs/<name>"
```
`order` is the layering, lowest first (the same order the client's own pack folder would use: by
name, a later name wins).

**3. Where players download them from.** Two ways, either or both:

- **The server's own listener** (the default when no URL is given): `-client-packs-listen :15780`
  (env `OPENSRO_CLIENT_PACKS_LISTEN`; `off` turns it off). Open that TCP port as you opened 15779
  (a compose file publishes it: `- "15780:15780"`). It serves only the listed packs at
  `/packs/<name>`, with resume, 16 downloads at once and 2 per address, and nothing else (no
  listing, no other file). Players fetch it over plain http from the address they connect the game
  to; the hash (sent over the game connection) is what proves the file.
- **Your own URL** -- a CDN, a web server, a GitHub release: `-client-packs-url
  https://github.com/<owner>/<repo>/releases/download/packs-1` (env `OPENSRO_CLIENT_PACKS_URL`);
  each pack is fetched from `<url>/<name>`, so upload the files there under the same names.
  **Use https** -- clients take plain http only from the game server's own host. With a URL the
  listener is off unless `-client-packs-listen` turns it on (then clients try the URL first and
  the listener second).

**4. Changing a pack** (a new version): replace the file and **restart the server** -- the hash is
taken at startup, and the listener refuses to serve a file that changed since (it logs `a pack
changed since the server started`). If you serve from a URL, upload the new file there too before
the restart. Players download the new version at their next login; the old one is removed from
their folder.

**Optional: `-client-packs-local-extras`** (env `OPENSRO_CLIENT_PACKS_LOCAL_EXTRAS`). By default a
player connected to your server reads **exactly** your packs over the base archives: their own
packs and their `custom/` folder are set aside while they are connected (so a modified local pack
cannot change what your server assumes -- walls, item tables). With this flag their own packs stay
(below yours) and `custom/` stays on top.

**What the player sees.** On Connect the login screen's message line says `Checking the server's
packs...`, then `Downloading z_akatsuki.pk3: 0.3 MB of 0.6 MB (50%)`, then logs in as usual. A
failure is said there in plain words (`Could not download the server's pack z_akatsuki.pk3:
login.example.com:15780: HTTP 404`) and nothing is sent. The packs land in the client's pack
folder under `servers/<host>_<port>/` (`pk2/servers/login.example.com_15779/z_akatsuki.pk3`): one
folder per server, so two servers that ship different packs of the same name never collide; the
client's own pack folder and that subfolder are never mixed. A second login downloads and
re-hashes nothing (the client keeps each pack's hash with its size and modified time,
`packs.json`). The client log has a `PACKS:` line for every step.

**Without `-client-packs`** the server tells clients it names no packs, and they play with their own
packs as before. A client from before round 789 never asks and keeps its own packs; a new client
against a server from before round 789 waits 2.5 s once for an answer that does not come, then
plays with its own packs.

**Checking it.** `pk2list -archives /srv/sro/client-packs -layers` shows the stack the clients get.
On a client: `/layer <path>` in chat or `OPENSRO_QA_WHICH="<path>;..."` names the pack serving a
path (docs/DEBUG_TOOLS.md), and the Shift+F3 panel says `packs of server <host>_<port>`.

## Logging in: wrong passwords, blocks, one session per account (round 788)

Every login -- the old 0x0001 and retail's 0x6102 -- is decided by one set of rules, retail's as
read from its gateway and GlobalManager (docs/protocol/opcodes/login.md, "The login reply, READ
(round 788)"). The settings:

| Flag | Env | Default | What |
|---|---|---|---|
| `-login-failure-tolerance` | `OPENSRO_LOGIN_FAILURE_TOLERANCE` | 3 | wrong passwords an account name may have (1-100). The client shows "Out of a maximum of 3 attempts, you have used N". The one that reaches it closes the connection. Retail's `LoginFailureTolerance`, code default 3. |
| `-login-failure-block-min` | `OPENSRO_LOGIN_FAILURE_BLOCK_MIN` | 10 | minutes the automatic login block lasts after that (0-525600; 0 raises none, as the reference package's server.cfg has it). Retail's `LoginFailureBlockTimeMin`, code default 10. |
| `-login-punishment-guide` | `OPENSRO_LOGIN_PUNISHMENT_GUIDE` | "Too many wrong passwords. Please try again later." | the reason the automatic block shows the player, under retail's "Account Ban Reason:" (1-511 bytes). Retail's `LoginPunishmentGuide`. |
| `-max-users-per-ip` | `OPENSRO_MAX_USERS_PER_IP` | 0 (off) | accounts logged in from one address at once; past it the login is refused with retail's "insufficient IP" message and the connection closed. Retail's `MaxUserForNonePCBangIP`. Leave it off for a LAN party or a bot swarm (`server/cmd/swarm` logs everything in from one address). |

A bad value stops the server at startup with the reason; a non-numeric env value logs a WARN and
keeps the default.

What a player meets:

- **Wrong ID or password**: the attempt count. The count is per account name, server-wide, kept in
  memory (a restart forgets it), forgotten an hour after the last wrong try or at a successful
  login. At the tolerance: the block (if the minutes are not 0) and the connection closes.
- **A blocked account** (right password): retail's box with the reason and the end date and time,
  in the **server's** local time zone. A block with no end shows a date 100 years ahead (what the
  original operator console writes for "infinite").
- **Already connected**: an account logged in anywhere on the server refuses a second login, and
  the second connection closes; the first is not touched. The account is free again once its
  session has ended and its character been saved. A connection that died without closing (a
  pulled cable, a crashed router) holds the account until TCP keep-alive notices: Go's defaults,
  15 s idle then 9 probes 15 s apart, so about 2.5 minutes (READ, Go 1.25 `net/dial.go`; the
  gateway sets no keep-alive of its own). A GM can free it at once with `/ban <character>`, or
  `/block` then `/unblock` the account.
- **Full / inspection**: as before (`-max-players`, `-inspection` above); the `-gm-accounts` pass
  both.

**Blocking an account** is done in game by a GM: `/block`, `/unblock`, `/blockinfo`
(docs/DEBUG_TOOLS.md). Blocks are kept in the `account_punishments` table (PostgreSQL) or in memory
under `-in-memory`. To read them directly:

```sql
SELECT p.serial, a.username, p.type, p.executor, p.guide, p.begin_at, p.end_at
FROM account_punishments p JOIN accounts a ON a.id = p.account_id ORDER BY p.serial DESC;
```

`type` is 1 block login, 2 block login for inspection (treated as 1), 3 block trade, 4 block chat
(3 and 4 are stored but not enforced yet); `end_at` NULL means no end. To lift a block by hand, set
its `end_at` to `now()`.

**Upgrading from before round 788:** the server moves the old `accounts.blocked` flag on its first
start: each blocked account becomes a block with no end whose reason is its `block_reason`, and the
flag is cleared, once. The two old columns stay but nothing reads them; setting `blocked = true`
no longer blocks anyone -- use `/block` or insert a row as above.

## The full map (round 660)

`-full-map` (env `OPENSRO_FULL_MAP`, off by default) places every field monster of the game.
Each monster row of `-npcpos-csv` outside the dungeon regions becomes a nest hatching its species
from `-monsters-csv`, run by the engine's own hatch rules (`server/internal/nest`,
`docs/protocol/monster_ai.md`, "Nests on the map"). Left out: the dungeons (1,915 rows), the
Pharaoh temple's 90 rows (their nests belong to the temple's instance worlds, round 661), MOB_SD_APIS
(no nest of its own) and the shard's custom species.

**The uniques (round 661)** need `-nest-db-dir`: each of the seven field uniques stands at one of its
npcpos spots at a time (its shard hive has a total of 1, EXTERNAL) and, killed, reappears at another
after its hive's window -- 1,200-1,400 s for Tiger Girl, Uruchi, Isyutaru, Cerberus and Captain
Ivy, 2,100-2,200 s for Lord Yarkan and Demon Shaitan (EXTERNAL). It fights with its own skills and
uses its summon skills each time it loses a tenth of its HP -- but only Cerberus's summon anything
(its Ladons): the other six uniques' tuples give a count of 0..0 and the engine's executor spawns
nothing for them (READ). For the summons and Captain Ivy's trigger the directory also needs
`Tab_RefAISkill.csv` and `_RefSkill.csv` (below). Without those two files the uniques still rotate
and fight but summon nothing, and the boot log says so. `-unique-respawn=60s` (env
`OPENSRO_UNIQUE_RESPAWN`) shortens the wait for testing (OURS); `-nest-respawn` does not reach
the uniques. The boot log has one `unique rotation` line per unique, and every hatch, re-pin and
summon is logged (`unique hatched`, `unique rotation: re-pinned`, `unique summons`).

**`-full-map` forces `-single-frame` on**: every zone with a frame is one world and one broadcast
bucket, so local chat, other players' moves and the ground-item lists go world-wide rather than
zone-wide, and players need a client that carries rounds 569-571 (see "Single world frame").

- **With `-nest-db-dir`** (env `OPENSRO_NEST_DB_DIR`, the three CSVs of the section below, mounted
  at `/data/nestdb`): a row whose spot's shard nest hatches the same species (`matched=4063` in this release's boot
  log; round 660 counted 4,068 before round 661's changes) takes that
  nest's numbers -- its cap (up to 17 alive), its respawn window (1-3 s on most, 8-12 s on 459), its
  hatch spread, its champion chance (10 % on most) -- and its tactics: aggressive or passive,
  sight, the 500-unit give-up distance, the roam radius and rule. A row whose nest the shard gave
  to its own custom monster (6,041 rows) places the original species, under its own tactics row
  when it has one (2,346 rows; the stand-in behaviour otherwise), on that nest's own cap, window,
  radii and champion chance (the user's decision, round 660's review). EXTERNAL values throughout.
  `-nest-swapped-stand-in` (env `OPENSRO_NEST_SWAPPED_STAND_IN`, OURS) puts those rows back on a
  one-monster stand-in nest each (10 s, no champion roll) -- half the monsters.
- **Without it**: one monster per row, respawning 10 s after its death, all aggressive with the
  stand-in sight and leash, no champions. The boot log says so.

Measured on the shard in round 660 (its WORLD_ISSUES entry and review follow-up): 10,109 nests,
at most 65,982 monsters alive (34,663 with `-nest-swapped-stand-in`), AI tick p99 under 2 ms with
a player in a matched field and 6.4 ms at the densest window, RSS 127-165 MB. This release's boot
logs `placed=10104` and `matched=4063` (round 661 changed which rows are placed; the difference is
not re-derived here).

**The full population is what opensro-01 runs** (the user's decision, "DB numbers now", round
660's review): `-nest-swapped-stand-in` is NOT set there. Round 660 measured the client at 7-10 fps
where the swapped spots cluster (the Europe starter field 108/77, the densest window) with a
round-655 client; round 664 then made a player be sent only the monsters of the 3 x 3 blocks of 320
units around it (retail's message blocks, READ) and made the client draw a dense field at 60 fps
(its WORLD_ISSUES entry has the numbers). `-nest-swapped-stand-in` stays as an optional OURS
fallback -- one monster per swapped spot, about half the monsters -- for a host that cannot carry
the full population; it is off by default and off on opensro-01.

The flags opensro-01 needs for the monster world, in the override's `command:` (restate the whole
list) or as environment variables:

```
#         - "-npcpos-csv=/data/npcpos.csv"
#         - "-monsters-csv=/data/monsters.csv"
#         - "-skills-csv=/data/skills.csv"        # only with -in-memory; PostgreSQL holds the skills
#         - "-nest-db-dir=/data/nestdb"           # EXTERNAL, the three shard CSVs (+ the two of round 661)
#         - "-full-map=true"                      # turns -single-frame on itself
#         # -nest-swapped-stand-in=true           # OURS fallback, OFF on opensro-01: one monster per swapped spot
#         - "-monster-ai=true"
#         - "-monster-strike-push=true"
#         - "-monster-spawn-push=true"
#         - "-monster-battle=true"
#         - "-player-dead-state=true"
#         - "-monster-aggro=true"
#         # -monster-sleep is on by default; keep it on at this size.
#         # -nest-respawn=30s overrides every nest's window but the uniques', for testing only.
#         # -unique-respawn=60s shortens the uniques' wait after a death, for testing only.
```

A client must be a release that carries round 656 (the paged list and the enter/leave pushes) for
a window this dense; one that also carries round 660 gets the party flag and draws champions,
giants and elites at their retail scale. An older client is sent no party flag and draws every
rank at its species' size. `OPENSRO_AI_TICK_STATS=1` logs the AI tick's p50/p99 once a minute.

## Character lobby (round 682)

Round 682 moves character select and create onto the retail lobby (0x7007 / 0x7001,
`docs/protocol/charselect.md`). Two things change on a deployed server:

- **The database migrates itself** at the server's boot (`character.OpenSQLStore`): the characters
  table gains `ref_obj_id`, `scale`, `deleted_at`, `start_zone`, `start_x`, `start_y`, `start_z`,
  and every existing row with `ref_obj_id` 0 gets 1909 (`china_man`) or 1923 (`china_woman`) at
  scale 0x22 -- the body it is drawn with today. Names are kept even where the new rules would
  refuse them. Idempotent: a second boot changes nothing (`TestMigration682` runs it twice on a
  copy of the old table). Check: `SELECT ref_obj_id, count(*) FROM characters GROUP BY 1;` shows
  only 1909 and 1923 for the old rows.
- **Creating a character needs the creatable catalogue.** Without `-chargen-csv` the server
  refuses every create with 0x403 ("Failed to create a character...") and warns at boot
  (`no creatable catalogue (-chargen-csv / OPENSRO_CHARGEN_CSV): every character create is
  refused`). Existing characters list, start and play as before.

On opensro-01, in this order (round 682's review: nothing breaks at any step, and the data is
backed up before the migration runs):
1. **Before the release reaches the host, stage the catalogue.** Export `chargen.csv` (step 2 of
   "Reference data": the `-mode chargen` line, after the characterdata and itemdata parts are
   extracted; it prints `wrote 104 creatable ids (52 bodies, 52 items) and 2 ammunition rows`),
   then
   `scp chargen.csv opensro@<server-host>:~/opensro-data/ && ssh opensro@<server-host> 'chmod 644 ~/opensro-data/chargen.csv'`.
   Set it in the untracked override as the environment form of `-chargen-csv`, under the server's
   `environment:` (edit only that key): `OPENSRO_CHARGEN_CSV: /data/chargen.csv`, then
   `cd ~/opensro && docker compose up -d`. The server running now is the old one; it does not
   read the variable and runs on unchanged.
2. **Back up the characters table**:
   `docker compose exec -T postgres pg_dump -U postgres -t characters opensro > ~/characters-before-682.sql`.
3. **Merge to dev**; the update timer deploys it within 5 minutes (step 0 of "Deploying the
   monster-epic release"). The new server migrates the table at its first boot.
4. **Check** the boot line, `docker compose logs server | grep 'creatable catalogue loaded'`
   (`... ids=104`), and the migration:
   `docker compose exec -T postgres psql -U postgres opensro -c "SELECT ref_obj_id, count(*) FROM characters GROUP BY 1;"`
   lists only 1909 and 1923. The names the new rules would refuse are kept and still play; to see
   them:
   `... -c "SELECT id, name FROM characters WHERE name ~ '[ ''\"]' OR name ~ '[^ -~]' OR octet_length(name) NOT BETWEEN 2 AND 12;"`
   (a space or a quote, a byte outside printable ASCII, or not 2..12 bytes).
5. **Then tag the client release**, so players get a client that speaks the new lobby.

Players need this release's client. An older one speaks the removed 0x0010-0x0015: the server
answers it in its old format with "this server uses the new character lobby -- update the client",
which its select screen shows as the list's error (round 682's review). A new client against an
older server waits 5 s for the list and then says the server did not answer. A deleted character
waits 7 days (10080 minutes, restorable) and is then removed by the server's once-a-minute purge.

## The original client (round 788, off by default)

The server can let the ORIGINAL client (sro_client.exe, vSRO 1.188) log in as far as its character
list: a retail gateway and a retail agent listener that speak the original wire
(`docs/protocol/opcodes/gateway.md`, "OpenSRO's retail listeners"). The world is not offered to it:
Start is refused with the client's own "GameServer is currently offline" message. OpenSRO's own
client and listener are unaffected.

| Flag (env) | Default | What |
|---|---|---|
| `-retail-gateway-addr` (`OPENSRO_RETAIL_GATEWAY_ADDR`) | empty: both listeners off | where the original client connects first, e.g. `:15780` -- the port its archive names (Media.pk2 `GATEPORT.TXT`) |
| `-retail-agent-addr` (`OPENSRO_RETAIL_AGENT_ADDR`) | `:15781` | where a logged-in client is sent |
| `-retail-agent-public-host` (`OPENSRO_RETAIL_AGENT_PUBLIC_HOST`) | the agent address's host, else 127.0.0.1 (with a warning) | the host the gateway names for the agent: one the CLIENT can reach |
| `-retail-shard-id` (`OPENSRO_RETAIL_SHARD_ID`) | 1 | the shard id in the server list (the client sends it back at login) |
| `-retail-shard-name` (`OPENSRO_RETAIL_SHARD_NAME`) | OpenSRO | the shard name in the server list |
| `-retail-content-id` (`OPENSRO_RETAIL_CONTENT_ID`) | 22 | the client's content id (its DIVISIONINFO.TXT's first byte; vSRO 1.188: 22) -- checked at the agent |
| `-retail-version` (`OPENSRO_RETAIL_VERSION`) | 1000 | the client version accepted (its SV.T; vSRO 1.188: 1000); older is told "(C4)" and quits |

The list's population and "Check" come from `-max-players` and `-inspection`. Accounts are the
server's own (the same login rules as OpenSRO's client). The client finds the gateway by the host
and port in its own archive (`DIVISIONINFO.TXT`, `GATEPORT.TXT` in Media.pk2): point that host at
the server (DNS, the PC's hosts file) and listen on that port, or edit the archive. The client
also binds TCP 15779 on its own PC as a single-instance guard, so OpenSRO's own listener and the
original client cannot share a machine on that port. Every message each way is logged as
`retail gateway packet` / `retail agent packet` with its bytes (passwords withheld; the keep-alive
and the 5-second server-list refresh at Debug).

```sh
./server -retail-gateway-addr :31729 -retail-agent-addr :31730 -retail-agent-public-host 203.0.113.5
```

## Account PIN (Character Lock) (round 788)

A player may protect an account with a 4-digit PIN, asked at character select once per login before
the first Start, Delete or Restore (`docs/protocol/pin.md`; the feature is OpenSRO's own, the
retail game has none). Five wrong entries lock the PIN for 30 minutes, kept in the database.

- **Nothing to do to keep it optional.** The server creates its two tables (`character_locks`,
  `character_lock_devices`) on the accounts' database at boot and logs
  `account PIN (character lock) required=false lock_after=5 lock_for=30m0s`.
- **`-require-pin`** (env `OPENSRO_REQUIRE_PIN=true`): every account must have a PIN; one with none
  is shown the create window before it can start, delete or restore. Default off. A value that is
  not a boolean leaves it off, with a warning at boot.
- **Retail clients.** The original client has no PIN window: on an account with a PIN it can list
  its characters but every Start, Delete and Restore answers "Failed to connect to server." (code
  0x40e); under `-require-pin` it can start no character at all.
- **A player locked out of their PIN** (forgotten, not the 30-minute lock): there is no GM command
  yet. Remove the PIN, its count and its remembered PCs by account id:
  `docker compose exec -T postgres psql -U postgres opensro -c "DELETE FROM character_locks WHERE account_id = <id>; DELETE FROM character_lock_devices WHERE account_id = <id>;"`
  (the id: `SELECT id FROM accounts WHERE username = '<name>';`). The player then has no PIN.
- Players need a client from this release for the window; an older client against this server
  never asks, and is refused Start, Delete and Restore only on an account that has a PIN.

## Character defaults (round 692)

A new character gets its race's default masteries (level 0), skills and level-1 quests, as the
shard DB's `_AddNewChar` gives them (`docs/protocol/charselect.md` section 5, "`_AddNewChar`,
read"). The tables are the shard DB's `_RefCharDefault_SkillMastery`, `_RefCharDefault_Skill` and
`_RefCharDefault_Quest` (EXTERNAL, a private shard's export; **never in this repo**). The server
reads them as exported, from the directory `-chardefaults-dir` (env `OPENSRO_CHARDEFAULTS_DIR`)
names; a `_RefCharGen.csv` in the same directory is compared with the creatable catalogue at boot.

- **Unset** (the default): nothing changes. The server warns at boot, `no character defaults
  (-chardefaults-dir / OPENSRO_CHARDEFAULTS_DIR): new characters get no default masteries, skills
  or quests`, and creates characters as before.
- **Set**: the boot log reads `character defaults loaded ... masteries=13 skills=13 quests=15
  china="7 masteries, 4 skills, 3 quests" europe="6 masteries, 10 skills, 2 quests"` and, with
  `_RefCharGen.csv` beside them, `the creatable catalogue agrees with the shard's _RefCharGen
  ids=104`. A directory that does not load is fatal, like the other reference files.
- **The schema** grows one table, `character_default_quests` (character, quest code, status, time),
  created at boot if absent (`quest.OpenSQLStore`); nothing else changes. Additive and idempotent.
  Default masteries are rows of the existing `character_mastery_levels` at level 0.
- **Only characters created afterwards** get them, as in the original (the procedure runs at
  create). Existing characters are not changed.

On opensro-01:
1. **Stage the tables** (from the render box, where the export lives; the three default tables and
   `_RefCharGen.csv`, nothing else -- the procedures' text is not needed):
   ```
   ssh root@192.168.10.78 'tar cf - -C /opt/sro-files/db/csv/charsel _RefCharDefault_SkillMastery.csv _RefCharDefault_Skill.csv _RefCharDefault_Quest.csv _RefCharGen.csv' \
     | ssh opensro@<server-host> 'mkdir -p ~/opensro-data/chardefaults && tar xf - -C ~/opensro-data/chardefaults && chmod 644 ~/opensro-data/chardefaults/*.csv'
   ```
2. **Check the files are readable** before the server is told about them -- a configured directory
   that does not load stops the server at boot:
   `ssh opensro@<server-host> 'ls -l ~/opensro-data/chardefaults/ && head -1 ~/opensro-data/chardefaults/_RefCharDefault_*.csv'`
   must list four `-rw-r--r--` files and print the headers `Race,MasteryID`, `Race,SkillID` and
   `Service,ID,Race,CodeName,RequiredLevel`. The container reads them as another user, so
   `chmod 644` (step 1) matters; a directory the container cannot enter needs `chmod 755`.
3. **Set it** in the untracked override, under the server's `environment:` (edit only that key):
   `OPENSRO_CHARDEFAULTS_DIR: /data/chardefaults` (the data directory is mounted at `/data`). The
   server running now does not read the variable; nothing changes until the release lands.
4. **Merge to dev**; the update timer deploys it within 5 minutes.
5. **Check** `docker compose logs server | grep -E 'character defaults loaded|agrees with the shard|odd row'`
   (no `odd row` line on the shard's export),
   then create a character and look:
   `docker compose exec -T postgres psql -U postgres opensro -c "SELECT mastery_id, level FROM character_mastery_levels WHERE character_id = <id>;"`
   (7 rows at 0 for China, 6 for Europe),
   `... -c "SELECT skill_id FROM character_skills WHERE character_id = <id>;"` (4 China, 10 Europe), and
   `... -c "SELECT quest_code, status FROM character_default_quests WHERE character_id = <id>;"`.

To undo: remove the variable and `docker compose up -d`; characters already given defaults keep them.

## Name filter (round 788)

A new character's name and a new guild's name pass SR_ShardManager's name rule
(`docs/protocol/charselect.md`, "The name rule: the AbuseFilter test"): 2..12 bytes (else 0x40c /
the guild's length refusal), then no space, no `'` or `"`, none of the 54 SQL words compiled into
the original server, and the AbuseFilter group's test -- its allowed characters, its substring words
and its whole words (else 0x40d / "that guild name is not allowed", 0x4c19). Existing characters
and guilds keep their names.

The word list is the operator's own file, **never in this repo**: the `AbuseFilter.txt` beside
your `SR_ShardManager.exe`, or your client's
`/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\abusefilter.txt" -out AbuseFilter.txt`
(the two retail copies differ a little; the client checks names against its own copy before it
sends them).

- `-abuse-filter <path>` (env `OPENSRO_ABUSE_FILTER`): the file, UTF-16 as shipped. A path that does
  not load is fatal. The boot log reads `name filter loaded ... group=4 allow_rows=4
  substring_words=31 whole_words=462` (the server copy's English group; 733 and 366 for VIETNAM).
- `-abuse-filter-locale <name>` (env `OPENSRO_ABUSE_FILTER_LOCALE`): which group, as server.cfg's
  `LOCALE` names it -- `KOREA`, `CHINA`, `TAIWAN`, `JAPAN`, `VIETNAM`, `ENGLISH`, with or without
  `LOCALE_`. Unset: `ENGLISH` (OpenSRO's default; the reference server.cfg says `LOCALE_VIETNAM`).
  An unknown name reads the English group, as the original does, with a warning.
- **Unset** (no file): the server warns at boot, `no name filter word list (-abuse-filter /
  OPENSRO_ABUSE_FILTER): new names are limited to [0-9A-Za-z_] and the SQL words, no AbuseFilter
  words apply`. Names are then limited to letters, digits and `_` (OpenSRO's choice: the original
  refuses no character without the file).

On opensro-01: extract the file as above, `scp AbuseFilter.txt opensro@<server-host>:~/opensro-data/`
and `chmod 644` it, set `OPENSRO_ABUSE_FILTER: /data/AbuseFilter.txt` in the untracked override
(and `OPENSRO_ABUSE_FILTER_LOCALE` if not English), `docker compose up -d`, then check
`docker compose logs server | grep 'name filter'`. Nothing in the database changes; to undo, remove
the variable.

## Quests (round 785)

NPCs offer their real quests (talk page, accept, kill/gather/deliver/talk, reward window, gold/EXP/
skill EXP/SP/items, give up), from a catalogue exported from the operator's own data
(`docs/protocol/quests.md`). The server reads it from the directory `-quests-dir` (env
`OPENSRO_QUESTS_DIR`) names: `quests.csv`, `quest_missions.csv`, `quest_menus.csv`,
`quest_reward_items.csv`, written by `export-refdata -mode quests`. **Game data: never in this repo.**

- **Unset** (the default): the boot log warns `no quest catalogue (-quests-dir / OPENSRO_QUESTS_DIR): no
  quest is offered`; NPCs keep their static talk stand-in, kills credit nothing.
- **Set**: `quest catalogue loaded: NPCs offer their quests ... quests=696 playable=618 scripted=529
  compiled_not_extracted=154 questdata_only=13` (the user's data, MEASURED; `compiled_not_extracted` counts
  the compiled quests, 149 of which the decompilation filled). A directory that does not load is fatal.
- **The schema** grows one table, `character_quest_state` (character, quest, status, mission counts,
  completions), created at boot if absent (`quest.NewSQLStore`). The old `character_quests` table is left
  in place and no longer read. Additive and idempotent.
- **Needs** the item table (`import-refdata`, for quest items and item rewards by code name), the NPC
  table and placements (`-npcs-csv`, `-npcpos-csv`: the quest NPCs), the monster table (`-monsters-csv`:
  kills are matched by code name) and the level table (`-leveldata-csv`: EXP rewards level up).

The export runs where the inputs are -- the render box holds all of them (the client archive, the server
pack's `Script/VIETNAM/` and `SR_GameServer.exe`, and the project's decompilation of it):
```
cd server && CGO_ENABLED=0 GOOS=linux go build -o /tmp/export-refdata ./cmd/export-refdata && \
  go build -o /tmp/pk2list ./cmd/pk2list && scp /tmp/export-refdata /tmp/pk2list root@192.168.10.78:/var/tmp/
ssh root@192.168.10.78 'set -e; mkdir -p /var/tmp/questexport && cd /var/tmp/questexport
  for f in questdata.txt refqusetreward.txt refquestrewarditems.txt; do
    /var/tmp/pk2list -pk2 /opt/sro-files/client/Media.pk2 -extract "server_dep\\silkroad\\textdata\\$f" -out $f; done
  SRV=/opt/sro-files/server/y0gi_Easy_vPLUS/Blitzkrieq_Bin_Data/Blitzkrieq_Bin_Data
  /var/tmp/export-refdata -mode quests -out quests -decomp-dir /var/tmp/decomp_server -quest-report coverage.csv \
    questdata.txt refqusetreward.txt refquestrewarditems.txt \
    $SRV/Script/VIETNAM/define.sct $SRV/Script/VIETNAM/QuestList.sct $SRV/Script/VIETNAM/Quest.sct $SRV/SR_GameServer.exe
  rm -f questdata.txt refqusetreward.txt refquestrewarditems.txt'
# prints: wrote 696 quests to quests: 529 scripted, 154 compiled (149 read from the decompilation),
#         13 questdata-only; 618 playable, 564 of them reachable ...
```
`-decomp-dir` is optional: without it the 154 compiled quests (half of Europe's Constantinople and
East Europe chains among them) are catalogued but not offered (`playable=520`).

On opensro-01:
1. **Stage the directory**:
   `ssh root@192.168.10.78 'tar cf - -C /var/tmp/questexport quests' | ssh opensro@<server-host> 'tar xf - -C ~/opensro-data && chmod 755 ~/opensro-data/quests && chmod 644 ~/opensro-data/quests/*.csv'`
2. **Check** `ssh opensro@<server-host> 'head -1 ~/opensro-data/quests/quests.csv'` prints the header
   starting `ID,Code,Level,LevelArg2,Source`.
3. **Set it** in the untracked override, under the server's `environment:`: `OPENSRO_QUESTS_DIR: /data/quests`.
4. **Merge to dev**; the update timer deploys it.
5. **Check** `docker compose logs server | grep -E 'quest catalogue loaded|quest:'`, then take
   `QNO_CH_SMITH_1` from the Jangan blacksmith (China) or `QNO_EU_CONS_1` from Constantinople's nun
   (Europe) and look: `docker compose exec -T postgres psql -U postgres opensro -c "SELECT * FROM character_quest_state;"`.

To undo: remove the variable and `docker compose up -d`; the table stays, unread.

**Round 819** adds two columns to `quests.csv` (`DivideType`, `DifferentString`: party-only quests
and the after-one-clear text). A catalogue exported before still loads, without them; re-run the
export above and stage it again to have them.

## Alchemy (round 768)

The alchemy window (Y) reinforces with elixirs and lucky powder, and applies magic and attribute
stones. Two things on the server need refreshing for it:

1. **Re-export and re-import the items.** `items.csv` gained six columns (73-78: `CashItem`, `Param1`,
   `Param5`, `Desc128_1`, `Desc128_4`, `MaxMagicOptCount`), and round 769 eight more (79-86, the
   per-plus increments: without them a plus adds nothing to an item's stats). An older export still loads, but with them
   0 every alchemy attempt is refused: no elixir suits any item (`0x5409`), and no stone matches a degree.
   Run the `-mode items` line of "Reference data" step 2 and `import-refdata -items-csv` again.
2. **Export the magic option table** (the `magicoption.txt` and `-mode magicoptions` lines), copy
   `magicoptions.csv` beside the other CSVs, and add `- "-magic-options-csv=/data/magicoptions.csv"` to
   the override's `command:` list, then `docker compose up -d`. The boot log says
   `magic option table loaded: the alchemy stones write blue options and worn options count ...
   rows=402`. Without it every magic stone is refused, and no worn item's blue option counts toward
   its stats (round 769); elixirs and attribute stones work without it.

3. **Round 770: drops with blue options.** Export the assign table too (the
   `magicoptionassign.txt` and `-mode magicoptassign` lines), copy `magicoptassign.csv` beside the others
   and add `- "-magic-option-assign-csv=/data/magicoptassign.csv"`. The boot log says
   `magic option assign table loaded: equipment drops roll blue options ... rows=74`. A monster's
   equipment drop then gets blues as the original server gives them (31 in 101, every Seal item).
   Re-exporting the items (step 1) brings their Rarity column (87).

Elixirs, powders and stones come from drops or `/give`; a GM can test with
`/give <item id> [qty]` (the weapon elixir `ITEM_ETC_ARCHEMY_REINFORCE_RECIPE_WEAPON_A` is id 3675 in a retail archive).

## Server collision: the navigation meshes (round 812)

The server walks every mover on the game's own navigation mesh when `-navmesh-dir`
(`OPENSRO_NAVMESH_DIR`) names a directory `export-navmesh` wrote from a client's archives. The
data is the user's, never committed. On the render box (where the archives are):

```
go build -o export-navmesh ./server/cmd/export-navmesh
./export-navmesh -data /opt/sro-files/client/Data.pk2 -map /opt/sro-files/client/Map.pk2 -out navdata
tar czf navdata.tgz navdata          # 790 MB -> about 220 MB
```

Copy `navdata.tgz` to the server host, unpack it (the prod Mac mini: `~/opensro/data/navmesh`) and
add `-navmesh-dir="$D/navmesh"` to `run.sh`. The boot log says `navigation meshes: movers walk the
original's navmesh ... objects=2044`; without the flag, `no navigation meshes`. `server/cmd/navprobe`
asks the export about a world point (`-dir DIR -zone jangan -at X,Z[,Y] [-to X,Z]`).

What changes for players: a 0x7021 walk into a wall ends there on the server too, with a 0xB023;
a client that walked further is put back. Clients from v0.1.574 walk to the point they send (the
truncated destination, as retail's walks the echoed one), so they stop where the server does.
Monsters stop at walls and turn back from one 30 units ahead while wandering.

## Towns (round 674)

`-regions-csv` (env `OPENSRO_REGIONS_CSV`) gives the server the game's region table, `_RefRegion`,
whose `IsBattleField` 0 regions are the towns. With the monster AI on, a monster that walks into a
town region -- a monster chasing a player through Jangan's gate, say -- is removed at the line: no
death, no reward, the players who could see it told it left (`OpMonsterLeft`; the client drops the
body). That is SR_GameServer.exe's own rule (`CGObjMob::SetCurRegion` 0x4c1270, which sets life state
3 on every region change into a town; `docs/protocol/monster_ai.md`, "Towns"). A monster outside the
line can still hit a player standing just inside it, as in retail. Without the file no region is a
town and monsters follow players in, as before round 674.

On opensro-01, with this release's server running (the update timer, step 0 of the next section):
1. Export `regions.csv` (step 2 of "Reference data": the `refregion.txt` and `-mode regions` lines).
   The exporter prints `wrote 3194 regions to regions.csv, 103 of them towns (IsBattleField 0)` on
   a retail archive.
2. `scp regions.csv opensro@<server-host>:~/opensro-data/ && ssh opensro@<server-host> 'chmod 644 ~/opensro-data/regions.csv'`
3. Add `- "-regions-csv=/data/regions.csv"` to the override's `command:` list (edit only that key,
   as in step 6 of the next section), then `cd ~/opensro && docker compose up -d`.
4. The boot log (`docker compose logs server`) says
   `region table loaded: a monster entering a town region is removed (IsBattleField 0) ... regions=3194 towns=103`,
   and a monster that walks in logs `monster removed: it entered a town ... name=... how="walked in" ... area=Town_Jangan`
   at INFO. One removed where it was placed (hatched or spawned in a town) is logged at Debug, and
   counted once a minute at INFO: `monsters removed on placement in a town ... count=N`.

Six of the retail archive's 12,110 monster placements stand in a town region (two of Alexandria's
`town_Alex` regions, 90/49 and 91/51: one MOB_SD_UNEG, five MOB_SD_WENEG). With `-full-map` each
hatches, is removed on the first AI pass that runs it (with `-monster-sleep`, the default, once a
player comes near) and hatches again after its nest's window -- what the engine's rule does with a
nest in a town (INFERRED: its placement goes through the same region change). Each nest's window
is 1-3 s with a cap of 24 (EXTERNAL), so near them the per-minute count runs at about 30-60.

## Deploying the monster-epic release to opensro-01 (round 666)

The release that carries rounds 653-666 changes the reference data, adds the shard's nest files
and turns the monster world on. The final release review ran steps 1, 2 and 4 and checked step 7's boot lines on the render box (steps 0, 5 and 6 need opensro-01 and its Postgres, so they were not run there); do them in this order.
`<server-host>` is opensro-01 (`opensro@192.168.5.25`); the checkout there is `~/opensro`, and
`~/opensro-data` is mounted into the server container as `/data`.

0. **First, the host must be running this release's server.** Steps 6-7 pass `-full-map` and
   `-nest-db-dir`; a server built before them (dev at ab66d9c has neither) exits with `flag
   provided but not defined`, and Docker restarts it in a loop. opensro-01 follows `dev` by
   itself: `deploy/update.sh` runs from the `opensro-update.timer` (enabled there, every 5 min,
   `OnUnitActiveSec=5min`; checked 2026-09-30), fetches `origin/dev`, fast-forwards, rebuilds and
   restarts the stack, and rolls back a build that does not come up. So once the release is merged
   to `dev`, either wait for the timer or run it now, then check the host's commit:
   ```
   ssh opensro@<server-host> 'sudo systemctl start opensro-update.service; journalctl -u opensro-update -n 5 --no-pager'
   ssh opensro@<server-host> 'cd ~/opensro && git log --oneline -1'
   ```
   The journal line `server at <commit> listening on 15779` and a `git log` at the release's
   commit (or later) mean it is running. (By hand, the same thing: `cd ~/opensro && git pull &&
   docker compose up -d --build`.) Until then, change nothing in the override: the old server
   runs happily on the old one, and the new server boots on it too (without `-full-map` it places
   the roster as before).
1. **Build the tools** on the machine with the client's `Media.pk2`, with `CGO_ENABLED=0` (static
   binaries, as step 1 of "Reference data" builds them):
   ```
   cd server && for t in pk2list export-refdata export-leveldata import-refdata; do
     CGO_ENABLED=0 GOOS=linux go build -o /tmp/$t ./cmd/$t; done
   ```
2. **Export the reference data**: run step 2 of "Reference data" above in full, with these new
   binaries. It writes `skills.csv`, `monsters.csv`, `npcpos.csv`, `items.csv`, `leveldata.csv`
   and the `teleport/` directory, and its last `rm` deletes the extracted text tables (`ls *.txt`
   then finds nothing). `skills.csv` has no header, and a StatusParams cell is quoted with commas
   inside (`"bl:30000,100,1,200,0"`), so count its columns with a CSV reader, not `tr`:
   ```
   python3 -c 'import csv; print(sorted({len(r) for r in csv.reader(open("skills.csv"))}))'
   ```
   must print `[91]` (every row 91 columns, column 90 StatusParams).
3. **Copy the three changed CSVs and the importer** to the host, and make them readable by the
   container:
   ```
   scp skills.csv monsters.csv npcpos.csv /tmp/import-refdata opensro@<server-host>:~/opensro-data/
   ssh opensro@<server-host> 'chmod 644 ~/opensro-data/*.csv'
   ```
4. **Copy exactly the five shard files** into `~/opensro-data/nestdb/` -- `Tab_RefTactics.csv`,
   `tab_refnest.csv`, `tab_refhive.csv`, `Tab_RefAISkill.csv`, `_RefSkill.csv` (EXTERNAL; from the
   render box's `/opt/sro-files/db/csv/`, or exported as in "The three files `-nest-db-dir`
   reads" below) -- then, on the host:
   ```
   chmod 755 ~/opensro-data/nestdb; chmod 644 ~/opensro-data/nestdb/*.csv
   ```
   Without the chmod the nonroot container cannot read them and the server crash-loops (see that
   section).
5. **Re-import the skills** into Postgres on the host, then check them. The `psql` goes through
   compose, so it runs from the checkout (after `ssh` the working directory is `~`, where compose
   finds no file):
   ```
   ~/opensro-data/import-refdata -skills-csv ~/opensro-data/skills.csv \
       -postgres-dsn 'postgres://postgres:postgres@127.0.0.1:5432/opensro?sslmode=disable'
   cd ~/opensro && docker compose exec postgres psql -U postgres -d opensro \
       -c "SELECT count(*) FROM skills WHERE status_params <> '';" \
       -c "SELECT count(*) FROM skills WHERE ai_attack_chance > 0;"
   ```
   The first count must be **above 0** (0 means the import read an old CSV: no skill would land a
   status); the second should be about **26650**.
6. **Edit only the `command:` key of the override** (`~/opensro/docker-compose.override.yml`,
   untracked). Leave its `environment:` and `volumes:` as they are: opensro-01's override sets
   the GM accounts, `OPENSRO_PERSIST_POSITION` and the six monster flags there (checked
   2026-09-30), and a pasted `services:` block would drop them. `command` REPLACES the base list,
   so it restates all of it; add the last three lines below to what is there. No
   `-nest-swapped-stand-in`, no `-unique-respawn`:
   ```
       command:
         - "-addr=:15779"
         - "-postgres-dsn=postgres://postgres:postgres@postgres:5432/opensro?sslmode=disable"
         - "-leveldata-csv=/data/leveldata.csv"
         - "-npcpos-csv=/data/npcpos.csv"
         - "-teleport-dir=/data/teleport"
         - "-monsters-csv=/data/monsters.csv"
         - "-nest-db-dir=/data/nestdb"
         - "-full-map=true"
   ```
   The six monster flags -- `-monster-ai`, `-monster-strike-push`, `-monster-spawn-push`,
   `-monster-battle`, `-player-dead-state`, `-monster-aggro` -- must be on too: as
   `OPENSRO_MONSTER_AI: "1"` and the rest under `environment:` (opensro-01's way), or as
   `- "-monster-ai=true"` lines in `command:`. One of the two is enough.
7. **Start it and read the boot log**, from the checkout:
   `cd ~/opensro && docker compose up -d && docker compose logs server`.
   Expect:
   - `nest DB loaded (EXTERNAL ...) ... tactics=1743 nests=16381 hives=1170 ai_skill_tactics=132 skills=36144`
   - `full map: npcpos joined to nests ... placed=10104 ...`
   - seven `unique rotation` lines, one per field unique;
   - seven `unique hatched` lines;
   - and NO `skills store has NO status params` WARN (round 666; if it is there, step 5 imported
     an old CSV).

   A `loading the nest DB ... permission denied: chmod 644 ...` error means step 4's chmod was
   missed; `flag provided but not defined: -full-map` means step 0 was skipped (put the override's
   `command:` back and do step 0). **Players need this release's client**: an older one cannot
   draw the paged list, the area-of-interest pushes or the unique banner (the sections above name
   the round each needs).

## External shard DB: restore and export (user-supplied, EXTERNAL)

The monster AI's four tables (`Tab_RefTactics`, `tab_refnest`, `tab_refhive`, `Tab_RefAISkill`)
and a few others exist only as SQL Server rows. The client carries none of them
(`docs/protocol/monster_ai.md`). Round 658 restored a private shard's backup the user supplied and
exported it to CSV. **The backup, the database and the CSVs never enter this repo.** The CSVs live
on the render box at `/opt/sro-files/db/csv/`. What the export is worth (its layouts match the
parsers, but much of it is modded) is in `monster_ai.md`, "External shard DB".

SQL Server needs about 2 GB of RAM, so run it in a throwaway container on the Proxmox host, not on
the render box or the dev machine. Round 658 used CT 104 `mssql-temp` on `pve`: Debian 13, 4 cores,
8 GB, 40 GB on local-lvm, unprivileged with `nesting=1,keyctl=1`. **It is left stopped, not
deleted.** `pct start 104` brings it back with the database already restored.

```
# 1. The container (on the Proxmox host):
pct create 104 local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst --hostname mssql-temp \
  --cores 4 --memory 8192 --swap 2048 --rootfs local-lvm:40 --unprivileged 1 \
  --features nesting=1,keyctl=1 --net0 name=eth0,bridge=vmbr0,ip=dhcp \
  --ssh-public-keys /root/.ssh/authorized_keys --ostype debian --onboot 0
pct start 104

# 2. Inside it: docker and SQL Server 2022. The SA password is generated here, is kept only
#    in /root/.sa_pass (mode 600), and is never written anywhere else.
apt-get update && apt-get install -y docker.io python3-venv
umask 077; echo "Sa$(openssl rand -hex 12)#9x" > /root/.sa_pass
mkdir -p /srv/mssql/data /srv/mssql/backup && chown -R 10001:0 /srv/mssql
docker run -d --name mssql -e ACCEPT_EULA=Y -e MSSQL_SA_PASSWORD="$(cat /root/.sa_pass)" \
  -e MSSQL_MEMORY_LIMIT_MB=6144 -v /srv/mssql/data:/var/opt/mssql -v /srv/mssql/backup:/backup \
  mcr.microsoft.com/mssql/server:2022-latest

# 3. Copy the .bak into /srv/mssql/backup/ (check its md5sum on both ends), then restore.
#    FILELISTONLY gives the logical names that MOVE needs (this backup: SRO_VT_SHARD_Data / _Log).
S="docker exec mssql /opt/mssql-tools18/bin/sqlcmd -C -S localhost -U sa -P $(cat /root/.sa_pass)"
$S -Q "RESTORE FILELISTONLY FROM DISK=N'/backup/SRO_VT_SHARD.bak'"
$S -Q "RESTORE DATABASE SRO_VT_SHARD FROM DISK=N'/backup/SRO_VT_SHARD.bak' WITH
       MOVE N'SRO_VT_SHARD_Data' TO N'/var/opt/mssql/data/SRO_VT_SHARD.mdf',
       MOVE N'SRO_VT_SHARD_Log'  TO N'/var/opt/mssql/data/SRO_VT_SHARD_log.ldf', STATS=20"

# 4. Export with pymssql (python3 -m venv /root/venv && /root/venv/bin/pip install pymssql).
#    One CSV per table, header = the DB's own column names, written with Python's csv module.
#    Cells: NULL is empty, a SQL `real` is written as the shortest decimal that round-trips the
#    float32, and binary is 0x-hex. Also write _tables.csv (every table with its rows and
#    columns from sys.partitions/sys.columns). Round 658 exported the four AI tables,
#    _RefHWANLevel, the drop tables (_RefMonster_AssignedItemDrop, _RefMonster_AssignedItemRndDrop,
#    _RefDropGold, _RefDropItemAssign, _RefDropItemGroup, _RefDropOptLvlSel,
#    _RefCustomizingReservedItemDropForMonster, every _RefDropClassSel_*), _RefObjCommon,
#    _RefObjChar, _RefSkill, _UniqueInfo, _RefGame_World, _RefGame_World_Config,
#    _RefGameWorldGroup_Config, _RefServerEventReward_SpawnMonster and _RefGameWorldNPC. It also
#    wrote world_config_keys.csv (the PARTYMONSTER_SPAWN / GiantMonster* /
#    CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG rows) and _UniqueKillList_summary.csv (kills and gaps
#    between kills for each unique; the per-character rows are not exported).
#    Tar the directory to the render box's /opt/sro-files/db/csv/.

# 5. When done: pct stop 104 (on the host). pct destroy 104 only once nobody needs the DB.
```

Traps:

- The Korean description strings (`szDescString128` and similar) are cp949 bytes in
  `SQL_Latin1_General_CP1_CI_AS` varchar columns, so they export as mojibake. Nothing reads
  them. Recover a string with `.encode('latin1').decode('cp949')` if one is ever needed.
- `nRegionDBID` is a signed smallint. Mask it with `& 0xffff` before comparing it with
  npcpos's region: dungeon regions (>= 0x8000) come out negative.
- `tab_refnest.fLocalPosY` is NULL on 145 rows.

### The three files `-nest-db-dir` reads (round 660)

`-full-map` with `-nest-db-dir` joins every npcpos row to its shard nest (see "The full map
(round 660)" above). It reads three of the CSVs step 4 writes, under the table's own name, with the
DB's own column names as the header: `Tab_RefTactics.csv`, `tab_refnest.csv`, `tab_refhive.csv`.
Round 661 reads two more when they are there -- `Tab_RefAISkill.csv` (the uniques' triggers) and
`_RefSkill.csv` (their summon skills' Param blocks; 14 MB) -- and boots without them.
Round 658's full export (`/opt/sro-files/db/validation/export_db.py` on the render box) writes them;
to export only those three from the restored database (CT 104, step 4's venv):

```
# In CT 104 (pct start 104), with the database restored as above:
/root/venv/bin/python - /srv/export <<'PY'
import csv, os, struct, sys, pymssql
out = sys.argv[1]; os.makedirs(out, exist_ok=True)
cn = pymssql.connect(server="127.0.0.1", user="sa", password=open("/root/.sa_pass").read().strip(),
                     database="SRO_VT_SHARD", charset="UTF-8")
cur = cn.cursor()
def f32(v):  # the shortest decimal that round-trips the float32 (a SQL `real`)
    b = struct.pack("<f", v)
    return next((s for s in ("%.*g" % (p, v) for p in range(6, 10)) if struct.pack("<f", float(s)) == b), repr(v))
for t in ("Tab_RefTactics", "tab_refnest", "tab_refhive", "Tab_RefAISkill", "_RefSkill"):
    cur.execute("SELECT c.name, ty.name FROM sys.columns c JOIN sys.types ty ON ty.user_type_id=c.user_type_id "
                "WHERE c.object_id=OBJECT_ID(%s) ORDER BY c.column_id", ("dbo." + t,))
    cols = cur.fetchall()
    cur.execute("SELECT * FROM dbo.[%s] ORDER BY [%s]" % (t, cols[0][0]))
    with open(os.path.join(out, t + ".csv"), "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f); w.writerow([c[0] for c in cols])
        for row in cur:
            w.writerow(["" if v is None else f32(v) if cols[i][1] == "real" else str(v) for i, v in enumerate(row)])
PY
# From the host: pct pull 104 /srv/export/tab_refnest.csv ./tab_refnest.csv (and the other four), then
# copy the five to the server host's ~/opensro-data/nestdb/ -- mounted as /data/nestdb:
scp Tab_RefTactics.csv tab_refnest.csv tab_refhive.csv Tab_RefAISkill.csv _RefSkill.csv \
  opensro@<server-host>:~/opensro-data/nestdb/
# Then, ON THE SERVER HOST, make them readable by the container:
chmod 755 ~/opensro-data/nestdb; chmod 644 ~/opensro-data/nestdb/*.csv
# The render box already holds all five, from round 658's full export: /opt/sro-files/db/csv/.
```

**The chmod is not optional.** The server image runs as distroless `nonroot` (`server/Dockerfile`),
not as the host user that owns `~/opensro-data`. The export above runs under `umask 077`, so its
CSVs are mode 0600, and scp keeps that mode on a new file: the container cannot read them, the
boot fails, and Docker restarts it in a loop. Since round 666 that boot error reads
`loading the nest DB ... permission denied: chmod 644 the nest DB's CSVs and chmod 755 their
directory ...` (before it, a bare `open ...: permission denied`).

They are EXTERNAL data from a private shard's backup, like the rest of this section: never commit
them. The loader reads the columns by name (43, 17 and 10 columns; `tab_refhive`'s last,
`szDescString128`, is not read), masks `nRegionDBID` to the engine's u16 itself, and treats an
empty `fLocalPosY` as NULL. A missing file or column is fatal at boot.

## A bot crowd for load and looks (`server/cmd/swarm`)

`swarm` stands bot players on Jangan's plaza: accounts `PREFIX0000..` (5-8 lowercase letters,
default `swarm`), a mixed China/Europe crowd created through the retail lobby, worn gear with
pluses and seals picked from the database's own `items` table and written into
`equipment_slots` before each bot enters, about 10 % of them click-moving (0x7021), each listing
a party-match entry and accepting every join request and invitation. It changes no server
setting and makes no GM. Run it on another machine than the server (it is a client load of its
own: at 10,000 it took about 6 cores, below). It needs the gateway and the server's Postgres;
for opensro-01, tunnel Postgres first (it is pinned to the host's 127.0.0.1:5432):

```
ssh -N -L 15432:127.0.0.1:5432 opensro@192.168.5.25 &
cd server && go build -o /tmp/swarm ./cmd/swarm
PG='postgres://postgres:postgres@127.0.0.1:15432/opensro?sslmode=disable'
/tmp/swarm items  -pg "$PG" -n 5                       # read-only: the gear it would pick
/tmp/swarm up     -addr 192.168.5.25:15779 -pg "$PG" -n 1000 -prefix swarm   # runs until stopped
/tmp/swarm status -prefix swarm -addr 192.168.5.25:15779 -pg "$PG"
/tmp/swarm down   -prefix swarm -pg "$PG"              # logs them out, deletes every bot row
/tmp/swarm probe  -addr 192.168.5.25:15779 -pg "$PG" -prefix probe   # the latency probe, below
/tmp/swarm down   -prefix probe -pg "$PG"              # removes the probe's account
```

Stopping `up` (Ctrl-C, SIGTERM) logs the bots out and keeps their accounts; the next `up`
re-seeds their gear, level and spot. `down` deletes them.

- **Where they stand.** On the plaza deck's height, -30.117 in the Jangan frame (MEASURED, see
  `cmd/swarm/db.go`; a client draws a standing body at the height the server gives it), in a disc
  whose north edge is the deck's railing line (97/168 local z 960), radius 85 x sqrt(n/1000) by
  default (`-radius`). Where the deck was measured flat: x 946..1031, z 953..1418; a larger disc
  reaches ground not measured.
- **Capacity.** Bots count against `-max-players` (default 1000; `OPENSRO_MAX_PLAYERS`). `up`
  reads the server's status first and runs no more bots than there is room for, warning when it
  cuts `-n`; a full server turns non-GM logins away (GM accounts still log in). `-headroom N`
  keeps N slots free. 10,000 bots need the server's maximum raised to at least 10,000 first.
- **Load.** Logins are paced at `-rate` a second (default 20; 10,000 take about 8.5 minutes).
  Accounts are written with a minimum-cost bcrypt, so a login costs the server about a
  millisecond of hashing instead of the default cost's tens. Every walker's click goes to every
  player in view, so the cost grows with walkers x crowd: at 10,000 in one plaza with `-walk 10`
  the server delivered about 0.9 M packets a second (MEASURED locally, server and swarm on one
  16-thread box: server 8.3 cores and 6.7 GB, swarm 6.3 cores and 600 MB). `-walk 2` or
  `-walk-every 20s` cuts that in proportion.
- **Party matching.** Each bot lists an entry open to levels 1..140 (the server takes a creator
  of level 5 or more, so the bot's level is seeded from its gear's requirement, 5..110) and
  confirms every join request (0x306e). A player holding an entry cannot be invited (the
  server's 0x2c25, retail's rule); `-party=false` turns all of it off.
- **Keeping the entries listed.** An entry expires 60 minutes after it was registered or last
  changed (swept every minute), and the owner is told nothing: the server sends no 0xb06b and no
  state change, as retail's ShardManager sends its client nothing (`internal/party/match.go`,
  `Sweep`). A swarm built before this listed once, so an hour after `up` the party-matching
  window was empty. Each bot now re-sends its own entry unchanged (0x706a) every 52..58 minutes,
  which renews its time; a refusal 0x2c1c (gone) makes it list again (0x7069), and so does its
  party dissolving or its leaving one (0x3864). The summary counts `checks`, `renewed` and
  `relisted`. A swarm already running keeps the old behaviour until it is restarted with the new
  binary.
- **The latency probe** (`swarm probe`, or `up -probe` alongside a crowd, as `-probe-prefix`
  default `probe`): one bot standing in a quiet field, region 98/171 local (960, 960) by default
  (three regions from the plaza, no nest in it; `-probe-region`, `-probe-x`, `-probe-z`,
  `-probe-y`), clicks (0x7021) between two points 8 units apart every 250 ms (`-probe-every`) and
  times its own 0xB021 echo -- the server's answer to a click, through the move handler and the
  world hub. Every 10 s (`-probe-report`) it logs `rtt p50 / p99 / max`; any round trip over
  200 ms (`-probe-spike`) gets its own `SPIKE` line with the send and echo times to the
  millisecond, in local time with the zone, for lining up with the server's log (mind the clocks
  of the two machines); a click with no echo in 5 s is a `NO ECHO` line, a dropped connection a
  `DISCONNECTED` one. One click is in flight at a time, so a stall shows as one long round trip.
  Run it from the swarm's machine or any other: it is one connection.
- **down** stops the running `up` (its pid is in `$TMPDIR/opensro-swarm-PREFIX.json`, checked to
  be a `swarm up` before it is signalled), then in one transaction deletes the accounts named
  exactly `^PREFIX[0-9]{4}$`, their characters and every row that names them (equipment, bag,
  warehouse, skills, masteries, quests, friends, guild rows; any other `character_id` /
  `account_id` column it finds). Re-running is a no-op.

## Profiling a lagging server (`-pprof-addr`, off by default)

`-pprof-addr ADDR` (env `OPENSRO_PPROF_ADDR`) serves Go's `net/http/pprof` on ADDR and, while it
is on, logs a `runtime stats` line every 30 s: `gc_total` / `gc_window` (GC cycles), `gc_pause_last`
and `gc_pause_max_window`, `heap_inuse_mb`, `heap_alloc_mb`, `sys_mb`, `goroutines`, and the
scheduler latency over the window (`sched_lat_p50` / `p99` / `max`: how long a runnable goroutine
waited for a thread; it climbs when the process is CPU-starved). Contended locks are sampled for
`/debug/pprof/mutex` too. It is OURS and debug only: empty (the default) serves nothing and logs
nothing. **Bind it to 127.0.0.1** -- it serves stacks and the command line (the Postgres DSN is in
it); the server warns when ADDR is not a loopback address. Reach it over ssh.

On the Mac mini (launch agent `com.opensro.server`; the script it starts is the plist's
`ProgramArguments`, `~/opensro/run.sh` on the current install), with a binary that has the flag:

```
# on the Mac: in run.sh, with the other exports (before its exec line), add
#   export OPENSRO_PPROF_ADDR=127.0.0.1:6060
# then restart the agent and check
launchctl kickstart -k gui/$(id -u)/com.opensro.server
grep 'pprof on\|runtime stats' ~/opensro/logs/server.log | tail

# from a workstation: tunnel, then profile
ssh -N -L 6060:127.0.0.1:6060 opensro@192.168.10.146 &
go tool pprof -top 'http://127.0.0.1:6060/debug/pprof/profile?seconds=30'     # CPU
go tool pprof -top 'http://127.0.0.1:6060/debug/pprof/mutex'                  # lock waits
curl -o trace.out 'http://127.0.0.1:6060/debug/pprof/trace?seconds=5' && go tool trace trace.out
curl 'http://127.0.0.1:6060/debug/pprof/goroutine?debug=2' > stacks.txt        # during a stall
```

Delete the line and kickstart again to turn it off. Line a `swarm probe` `SPIKE` up with the
`runtime stats` line of the same half minute, and with a goroutine dump or a trace taken while
it happens.

## Metrics, logs and their rotation (round 858)

The server serves Prometheus metrics on `127.0.0.1:9469` by default (`-metrics-addr`) and, with
`-log-file` (env `OPENSRO_LOG_FILE`), writes and rotates its own log. Grafana Alloy on the host
feeds both to the monitoring stack (CT 111, `192.168.10.86`). What runs where, the metric list,
the dashboards, the alert rules and what to set on the Mac mini: `deploy/observability/README.md`.
