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

## Reference data (items): making the shop and real weapon damage work

The server ships with no item reference data — its `items` table is empty until an operator
imports it, and until then the shop catalogue is empty and combat falls back to a flat unarmed
damage (5) for every weapon. `export-refdata` turns a client's own itemdata tables into the CSV
`import-refdata` loads:

```
# on a machine with the extracted itemdata tables (BYO, not in the repo):
export-refdata -out items.csv itemdata_1000.txt itemdata_5000.txt ...   # all parts

# on the server (the CSV copied in):
docker compose cp items.csv server:/tmp/items.csv
docker compose exec server import-refdata -items-csv /tmp/items.csv \
    -postgres-dsn postgres://postgres:postgres@postgres:5432/srrevamp?sslmode=disable
```

The exporter maps only the columns this project has measured and, where a ground truth existed,
verified against a real tooltip: weapon physical/magical attack, durability, attack rate,
critical, the type ids, country, gender and level requirement (see its own package doc and
`docs/protocol/ITEM_FORMAT.md`). Fields it has not pinned are honest defaults, not guesses:
`MaxStack` is 1 (the server already treats every item as one-to-a-slot, so this changes nothing),
and armour **defence is 0** (armour keeps its defence in different columns than a weapon's attack,
and there is no ground-truth armour tooltip yet to label them; combat does not read defence, so the
only effect is that the shop prices armour at its base price).

**This changes live gameplay** — with it imported, a weapon deals its real attack instead of 5, and
the equipment rules enforce the real race/gender/level requirements — so it is the operator's call
to run, not something the deploy loop does. It is reversible: `TRUNCATE items;` in the database
returns the server to the flat-damage, empty-shop state.

Reference data is otherwise not touched by the update loop.
