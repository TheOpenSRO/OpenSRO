# Keeping a deployed server current

A machine that runs the compose stack (`docker compose up -d --build` from the repo root, see
`docs/HANDOFF_OPENSRO.md`) can follow `dev` on its own. `update.sh` does one round: fetch, and if
`origin/dev` moved, fast-forward, rebuild the stack, and check that the gateway answers on 15779.
The timer runs it every five minutes, so **pushing to `dev` is deploying**.

```
deploy/install.sh                              # once, as the user that owns the checkout
systemctl list-timers srrevamp-update.timer    # when it next runs
journalctl -u srrevamp-update                  # every update, build failure and rollback
sudo systemctl start srrevamp-update.service   # do not wait for the timer
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

## Reference data: making EXP, real weapon damage and skills work (BYO)

**The server ships with no reference data, and until an operator loads it a kill pays no EXP,
every hit deals the floor-band 1-2, the shop sells nothing and no skill can be learned.** The
public test server ran that way from 2026-09-11 to 2026-09-19 without anyone noticing, because
only the EXP curve warned in the log. The data comes from the operator's own client archives
(`Media.pk2` -> `server_dep\silkroad\textdata\`), never from this repo.

Three tables matter and they load two different ways: **items and skills** go into Postgres with
`cmd/import-refdata`; **leveldata is CSV-only** and is passed to the server on its command line.

```
# 1. On a machine with the client's Media.pk2 (BYO). Build the tools:
cd server && for t in pk2list export-refdata export-leveldata import-refdata; do
  CGO_ENABLED=0 GOOS=linux go build -o /tmp/$t ./cmd/$t; done

# 2. Extract the text tables. The archive carries more itemdata_*/skilldata_* parts than the
#    client loads; the index files itemdata.txt / skilldata.txt name the ones it does, in order,
#    and the exporter keeps the LAST definition of a duplicated id -- so feed the parts in the
#    index's order, not glob order (they differ: 1000,2000,... vs 1000,10000,11000,...).
MEDIA=/path/to/Media.pk2; mkdir refsrc && cd refsrc
for f in itemdata.txt skilldata.txt leveldata.txt; do
  /tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\$f" -out $f; done
/tmp/pk2list -pk2 "$MEDIA" -filter 'textdata\' | awk '{print $2}' \
  | grep -iE 'textdata\\(itemdata|skilldata)_[0-9]+\.txt$' | while IFS= read -r p; do
    /tmp/pk2list -pk2 "$MEDIA" -extract "$p" -out "$(basename "$(echo "$p" | tr '\\' /)")"; done
order() { iconv -f UTF-16LE -t UTF-8 "$1" | tr -d '\r' | sed 's/^\xef\xbb\xbf//' | grep -v '^$' \
          | tr 'A-Z' 'a-z' | while read -r n; do [ -f "$n" ] && echo "$n"; done; }
/tmp/export-refdata  -mode items  -out items.csv  $(order itemdata.txt)     # 15,338 rows from a retail archive
/tmp/export-refdata  -mode skills -out skills.csv $(order skilldata.txt)    # 33,698 rows
/tmp/export-leveldata -out leveldata.csv leveldata.txt                      # 140 levels
/tmp/pk2list -pk2 "$MEDIA" -extract "server_dep\silkroad\textdata\npcpos.txt" -out npcpos.txt
/tmp/export-refdata  -mode npcpos -out npcpos.csv npcpos.txt                # 12,367 placements; the server reads it with -npcpos-csv
rm -f itemdata_* skilldata_* npcpos.txt   # the extracted tables are game data; keep only the CSVs

# The exporter grows a strict-suffix column now and then (latest: the three elixir reinforce-rate columns 61-63, round 262, 2026-09-19; before that the six skill prerequisite columns, round 250 -- re-run the SKILLS export too);
# an older items.csv still loads, but the new column reads as 0 until the export is re-run.
# Re-run steps 1-3 after pulling such a change.

# 3. On the server host (CSVs and import-refdata copied to ~/srrevamp-data; Postgres is pinned to
#    127.0.0.1:5432 by docker-compose.override.yml):
~/srrevamp-data/import-refdata -items-csv ~/srrevamp-data/items.csv -skills-csv ~/srrevamp-data/skills.csv \
    -postgres-dsn 'postgres://postgres:postgres@127.0.0.1:5432/srrevamp?sslmode=disable'

# 4. leveldata is a command-line flag: mount the directory and restate the command in the
#    (untracked) docker-compose.override.yml -- `command` in an override REPLACES the base list:
#   services:
#     server:
#       volumes:
#         - /home/srrevamp/srrevamp-data:/data:ro
#       command:
#         - "-addr=:15779"
#         - "-postgres-dsn=postgres://postgres:postgres@postgres:5432/srrevamp?sslmode=disable"
#         - "-leveldata-csv=/data/leveldata.csv"
#         - "-npcpos-csv=/data/npcpos.csv"       # real monster placements (round 253); omit for the town anchors
docker compose up -d
```

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
same three CSVs from beside the pk2s (`PK2_DIR`), so keep a copy there too.

Reference data is otherwise not touched by the update loop.
