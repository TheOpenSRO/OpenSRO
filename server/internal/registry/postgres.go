package registry

// Postgres is the registry for several processes (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.3): small, transactional rows in the
// character database every process already shares. A slot allocation takes
// the world's advisory transaction lock; the placement locks the host row it
// picks (FOR UPDATE SKIP LOCKED, so concurrent openings spread over hosts);
// the reaper holds an advisory lock so one process reaps at a time. Times
// are the database's now(), never a host's clock.

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"sync"
	"time"
)

// Schema is the registry's tables (OURS). Applied by NewPostgres.
const Schema = `
CREATE TABLE IF NOT EXISTS world_hosts (
	id          text PRIMARY KEY,
	addr        text NOT NULL DEFAULT '',
	version     text NOT NULL DEFAULT '',
	state       text NOT NULL DEFAULT 'active',
	open_world  boolean NOT NULL DEFAULT false,
	instances   boolean NOT NULL DEFAULT true,
	heartbeat   timestamptz NOT NULL DEFAULT now(),
	started     timestamptz NOT NULL DEFAULT now(),
	players     integer NOT NULL DEFAULT 0,
	live        integer NOT NULL DEFAULT 0,
	load        double precision NOT NULL DEFAULT 0
);
CREATE SEQUENCE IF NOT EXISTS world_instance_key_seq;
CREATE TABLE IF NOT EXISTS world_instances (
	world       integer NOT NULL,
	layer       integer NOT NULL,
	key         bigint NOT NULL,
	host        text NOT NULL DEFAULT '',
	owner       bigint NOT NULL DEFAULT 0,
	party       bigint NOT NULL DEFAULT 0,
	created     timestamptz NOT NULL DEFAULT now(),
	expires     timestamptz,
	empty_since timestamptz,
	state       text NOT NULL DEFAULT 'open',
	PRIMARY KEY (world, layer, key)
);
CREATE UNIQUE INDEX IF NOT EXISTS world_instances_slot ON world_instances (world, layer) WHERE state IN ('open', 'closing');
CREATE INDEX IF NOT EXISTS world_instances_host ON world_instances (host) WHERE state IN ('open', 'closing');
CREATE TABLE IF NOT EXISTS world_instance_members (
	character bigint PRIMARY KEY,
	world     integer NOT NULL,
	layer     integer NOT NULL,
	key       bigint NOT NULL,
	entered   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS world_instance_members_inst ON world_instance_members (world, layer, key);
CREATE TABLE IF NOT EXISTS world_presence (
	character bigint PRIMARY KEY,
	name      text NOT NULL DEFAULT '',
	level     integer NOT NULL DEFAULT 0,
	account   bigint NOT NULL DEFAULT 0,
	username  text NOT NULL DEFAULT '',
	host      text NOT NULL DEFAULT '',
	updated   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS world_presence_host ON world_presence (host);
CREATE TABLE IF NOT EXISTS world_returns (
	character bigint PRIMARY KEY,
	zone      text NOT NULL DEFAULT '',
	bucket    text NOT NULL DEFAULT '',
	frame     text NOT NULL DEFAULT '',
	x         double precision NOT NULL DEFAULT 0,
	y         double precision NOT NULL DEFAULT 0,
	z         double precision NOT NULL DEFAULT 0,
	updated   timestamptz NOT NULL DEFAULT now()
);
`

// Advisory lock keys (OURS): the world's slot allocation (with the world id
// as the second key) and the reaper.
const (
	lockWorldSlots = 869001
	lockReaper     = 869002
)

// Postgres implements Cluster on a database/sql pool (pgx's stdlib driver).
type Postgres struct {
	db    *sql.DB
	lease time.Duration

	// offset is the database's clock less this host's, refreshed by each
	// Beat (Now reads it without a round trip).
	mu     sync.Mutex
	offset time.Duration
}

// NewPostgres applies Schema and returns the registry. lease is the
// heartbeat lease (0: DefaultLease).
func NewPostgres(ctx context.Context, db *sql.DB, lease time.Duration) (*Postgres, error) {
	if lease <= 0 {
		lease = DefaultLease
	}
	// Two processes starting at once both create the tables: serialise.
	tx, err := db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock(869000)`); err != nil {
		return nil, err
	}
	if _, err := tx.ExecContext(ctx, Schema); err != nil {
		return nil, fmt.Errorf("registry: schema: %w", err)
	}
	if err := tx.Commit(); err != nil {
		return nil, err
	}
	p := &Postgres{db: db, lease: lease}
	p.syncClock(ctx)
	return p, nil
}

// DB is the pool.
func (p *Postgres) DB() *sql.DB { return p.db }

func (p *Postgres) syncClock(ctx context.Context) {
	before := time.Now()
	var dbNow time.Time
	if err := p.db.QueryRowContext(ctx, `SELECT now()`).Scan(&dbNow); err != nil {
		return
	}
	after := time.Now()
	local := before.Add(after.Sub(before) / 2)
	p.mu.Lock()
	p.offset = dbNow.Sub(local)
	p.mu.Unlock()
}

// Now implements Registry: the database's clock.
func (p *Postgres) Now() time.Time {
	p.mu.Lock()
	off := p.offset
	p.mu.Unlock()
	return time.Now().Add(off)
}

func keyOf(seq int64) uint32 {
	k := uint32(seq % 0xFFFFFFFF)
	if k == 0 {
		k = 1
	}
	return k
}

// Open implements Registry.
func (p *Postgres) Open(ctx context.Context, req OpenRequest) (Instance, error) {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return Instance{}, err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `SELECT pg_advisory_xact_lock($1, $2)`, lockWorldSlots, int(req.World)); err != nil {
		return Instance{}, err
	}
	var layer int
	if req.Layer != 0 {
		var used bool
		if err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM world_instances WHERE world = $1 AND layer = $2
			AND state IN ('open', 'closing'))`, int(req.World), int(req.Layer)).Scan(&used); err != nil {
			return Instance{}, err
		}
		if used {
			return Instance{}, ErrNoSlot
		}
		layer = int(req.Layer)
	} else {
		n := req.Layers
		if n > 0xFFFF {
			n = 0xFFFF
		}
		err := tx.QueryRowContext(ctx, `SELECT s FROM generate_series(1, $2::int) s WHERE NOT EXISTS (
			SELECT 1 FROM world_instances i WHERE i.world = $1 AND i.layer = s AND i.state IN ('open', 'closing'))
			ORDER BY s LIMIT 1`, int(req.World), n).Scan(&layer)
		if errors.Is(err, sql.ErrNoRows) {
			return Instance{}, ErrNoSlot
		}
		if err != nil {
			return Instance{}, err
		}
	}
	host := req.Host
	if req.Pick {
		h, err := pickTx(ctx, tx, req.Version, p.lease)
		if err != nil {
			return Instance{}, err
		}
		host = h.ID
	}
	var seq int64
	if err := tx.QueryRowContext(ctx, `SELECT nextval('world_instance_key_seq')`).Scan(&seq); err != nil {
		return Instance{}, err
	}
	key := keyOf(seq)
	var lifetime any
	if req.Lifetime > 0 {
		lifetime = req.Lifetime.Microseconds()
	}
	var created time.Time
	var expires sql.NullTime
	if err := tx.QueryRowContext(ctx, `INSERT INTO world_instances (world, layer, key, host, owner, party, created, expires, empty_since, state)
		VALUES ($1, $2, $3, $4, $5, $6, now(), now() + make_interval(secs => $7::bigint / 1000000.0), now(), 'open')
		RETURNING created, expires`, int(req.World), layer, int64(key), host, req.Owner, req.Party, lifetime).Scan(&created, &expires); err != nil {
		return Instance{}, err
	}
	if err := tx.Commit(); err != nil {
		return Instance{}, err
	}
	in := Instance{ID: InstanceID{req.World, uint16(layer)}, Key: key, Host: host, Owner: req.Owner, Party: req.Party,
		Created: created, State: StateOpen, EmptySince: created}
	if expires.Valid {
		in.Expires = expires.Time
	}
	return in, nil
}

const instanceCols = `i.world, i.layer, i.key, i.host, i.owner, i.party, i.created, i.expires, i.empty_since, i.state,
	COALESCE((SELECT array_agg(m.character ORDER BY m.entered, m.character) FROM world_instance_members m
		WHERE m.world = i.world AND m.layer = i.layer AND m.key = i.key), '{}')`

type rowScanner interface{ Scan(dest ...any) error }

func scanInstance(r rowScanner) (Instance, error) {
	var world, layer int
	var key int64
	var expires, empty sql.NullTime
	var state string
	var members int64Array
	var in Instance
	if err := r.Scan(&world, &layer, &key, &in.Host, &in.Owner, &in.Party, &in.Created, &expires, &empty, &state, &members); err != nil {
		return Instance{}, err
	}
	in.ID = InstanceID{uint16(world), uint16(layer)}
	in.Key = uint32(key)
	in.State = State(state)
	if expires.Valid {
		in.Expires = expires.Time
	}
	if empty.Valid && len(members) == 0 {
		in.EmptySince = empty.Time
	}
	in.Members = []int64(members)
	return in, nil
}

// Get implements Registry.
func (p *Postgres) Get(ctx context.Context, id InstanceID) (Instance, error) {
	in, err := scanInstance(p.db.QueryRowContext(ctx, `SELECT `+instanceCols+` FROM world_instances i
		WHERE i.world = $1 AND i.layer = $2 AND i.state IN ('open', 'closing')`, int(id.World), int(id.Layer)))
	if errors.Is(err, sql.ErrNoRows) {
		return Instance{}, ErrNoInstance
	}
	return in, err
}

// Close implements Registry.
func (p *Postgres) Close(ctx context.Context, id InstanceID, key uint32) error {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer tx.Rollback()
	if _, err := tx.ExecContext(ctx, `DELETE FROM world_instance_members WHERE world = $1 AND layer = $2 AND key = $3`,
		int(id.World), int(id.Layer), int64(key)); err != nil {
		return err
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM world_instances WHERE world = $1 AND layer = $2 AND key = $3 AND state <> 'lost'`,
		int(id.World), int(id.Layer), int64(key)); err != nil {
		return err
	}
	return tx.Commit()
}

func (p *Postgres) live(ctx context.Context, tx *sql.Tx, id InstanceID, key uint32) (bool, error) {
	var ok bool
	err := tx.QueryRowContext(ctx, `SELECT EXISTS (SELECT 1 FROM world_instances WHERE world = $1 AND layer = $2 AND key = $3
		AND state IN ('open', 'closing'))`, int(id.World), int(id.Layer), int64(key)).Scan(&ok)
	return ok, err
}

func countMembers(ctx context.Context, tx *sql.Tx, id InstanceID, key uint32) (int, error) {
	var n int
	err := tx.QueryRowContext(ctx, `SELECT count(*) FROM world_instance_members WHERE world = $1 AND layer = $2 AND key = $3`,
		int(id.World), int(id.Layer), int64(key)).Scan(&n)
	return n, err
}

// Join implements Registry.
func (p *Postgres) Join(ctx context.Context, id InstanceID, key uint32, char int64) (int, error) {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	ok, err := p.live(ctx, tx, id, key)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 0, ErrNoInstance
	}
	if _, err := tx.ExecContext(ctx, `INSERT INTO world_instance_members (character, world, layer, key) VALUES ($1, $2, $3, $4)
		ON CONFLICT (character) DO UPDATE SET world = EXCLUDED.world, layer = EXCLUDED.layer, key = EXCLUDED.key,
		entered = CASE WHEN world_instance_members.key = EXCLUDED.key THEN world_instance_members.entered ELSE now() END`,
		char, int(id.World), int(id.Layer), int64(key)); err != nil {
		return 0, err
	}
	n, err := countMembers(ctx, tx, id, key)
	if err != nil {
		return 0, err
	}
	return n, tx.Commit()
}

// Leave implements Registry.
func (p *Postgres) Leave(ctx context.Context, id InstanceID, key uint32, char int64) (int, error) {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return 0, err
	}
	defer tx.Rollback()
	ok, err := p.live(ctx, tx, id, key)
	if err != nil {
		return 0, err
	}
	if !ok {
		return 0, ErrNoInstance
	}
	if _, err := tx.ExecContext(ctx, `DELETE FROM world_instance_members WHERE character = $1 AND world = $2 AND layer = $3 AND key = $4`,
		char, int(id.World), int(id.Layer), int64(key)); err != nil {
		return 0, err
	}
	n, err := countMembers(ctx, tx, id, key)
	if err != nil {
		return 0, err
	}
	if n == 0 {
		// Re-stamped at 0 users (m:0x658f10).
		if _, err := tx.ExecContext(ctx, `UPDATE world_instances SET empty_since = now() WHERE world = $1 AND layer = $2 AND key = $3`,
			int(id.World), int(id.Layer), int64(key)); err != nil {
			return 0, err
		}
	}
	return n, tx.Commit()
}

// Presence implements Registry.
func (p *Postgres) Presence(ctx context.Context, char int64) (Place, bool, error) {
	var world, layer int
	var key int64
	var host string
	err := p.db.QueryRowContext(ctx, `SELECT m.world, m.layer, m.key, i.host FROM world_instance_members m
		JOIN world_instances i ON i.world = m.world AND i.layer = m.layer AND i.key = m.key AND i.state IN ('open', 'closing')
		WHERE m.character = $1`, char).Scan(&world, &layer, &key, &host)
	if errors.Is(err, sql.ErrNoRows) {
		return Place{}, false, nil
	}
	if err != nil {
		return Place{}, false, err
	}
	return Place{Instance: InstanceID{uint16(world), uint16(layer)}, Key: uint32(key), Host: host}, true, nil
}

// List implements Registry.
func (p *Postgres) List(ctx context.Context) ([]Instance, error) {
	rows, err := p.db.QueryContext(ctx, `SELECT `+instanceCols+` FROM world_instances i WHERE i.state IN ('open', 'closing')
		ORDER BY i.world, i.layer`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Instance
	for rows.Next() {
		in, err := scanInstance(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, in)
	}
	return out, rows.Err()
}

// Beat implements Cluster.
func (p *Postgres) Beat(ctx context.Context, h Host) error {
	var state string
	st := h.State
	if st == "" {
		st = HostActive
	}
	err := p.db.QueryRowContext(ctx, `INSERT INTO world_hosts (id, addr, version, state, open_world, instances, heartbeat, started, players, live, load)
		VALUES ($1, $2, $3, $4, $5, $6, now(), COALESCE($11, now()), $7, $8, $9)
		ON CONFLICT (id) DO UPDATE SET addr = EXCLUDED.addr, version = EXCLUDED.version,
			started = COALESCE($11, world_hosts.started),
			state = CASE WHEN world_hosts.state = 'dead' THEN 'dead' WHEN $10 THEN EXCLUDED.state ELSE world_hosts.state END,
			open_world = EXCLUDED.open_world, instances = EXCLUDED.instances,
			heartbeat = CASE WHEN world_hosts.state = 'dead' THEN world_hosts.heartbeat ELSE now() END,
			players = EXCLUDED.players, live = EXCLUDED.live, load = EXCLUDED.load
		RETURNING state`, h.ID, h.Addr, h.Version, string(st), h.OpenWorld, h.Instances, h.Players, h.Live, h.Load,
		h.State != "", startedArg(h.Started)).Scan(&state)
	if err != nil {
		return err
	}
	p.syncClock(ctx)
	if HostState(state) == HostDead {
		return ErrHostDead
	}
	return nil
}

func startedArg(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}

const hostCols = `id, addr, version, state, open_world, instances, heartbeat, started, players, live, load`

func scanHost(r rowScanner) (Host, error) {
	var h Host
	var st string
	err := r.Scan(&h.ID, &h.Addr, &h.Version, &st, &h.OpenWorld, &h.Instances, &h.Heartbeat, &h.Started, &h.Players, &h.Live, &h.Load)
	h.State = HostState(st)
	return h, err
}

// Hosts implements Cluster.
func (p *Postgres) Hosts(ctx context.Context) ([]Host, error) {
	rows, err := p.db.QueryContext(ctx, `SELECT `+hostCols+` FROM world_hosts ORDER BY id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Host
	for rows.Next() {
		h, err := scanHost(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

// SetHostState implements Cluster.
func (p *Postgres) SetHostState(ctx context.Context, id string, s HostState) error {
	_, err := p.db.ExecContext(ctx, `UPDATE world_hosts SET state = $2 WHERE id = $1 AND state <> 'dead'`, id, string(s))
	return err
}

func pickTx(ctx context.Context, tx *sql.Tx, version string, lease time.Duration) (Host, error) {
	q := `SELECT ` + hostCols + ` FROM world_hosts h WHERE h.state = 'active' AND h.instances
		AND h.heartbeat > now() - make_interval(secs => $2::bigint / 1000000.0)
		ORDER BY (h.version = $1) DESC,
			(SELECT count(*) FROM world_instances i WHERE i.host = h.id AND i.state IN ('open', 'closing')),
			h.players, h.load, h.id
		LIMIT 1 FOR UPDATE `
	// SKIP LOCKED first, so concurrent openings take different hosts; when
	// every live host is locked by another opening, wait for the best one.
	for _, tail := range []string{"SKIP LOCKED", ""} {
		h, err := scanHost(tx.QueryRowContext(ctx, q+tail, version, lease.Microseconds()))
		if err == nil {
			return h, nil
		}
		if !errors.Is(err, sql.ErrNoRows) {
			return Host{}, err
		}
	}
	return Host{}, ErrNoHost
}

// Pick implements Cluster.
func (p *Postgres) Pick(ctx context.Context, version string) (Host, error) {
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return Host{}, err
	}
	defer tx.Rollback()
	h, err := pickTx(ctx, tx, version, p.lease)
	if err != nil {
		return Host{}, err
	}
	return h, tx.Commit()
}

// Reap implements Cluster.
func (p *Postgres) Reap(ctx context.Context) (Reaped, error) {
	var r Reaped
	tx, err := p.db.BeginTx(ctx, nil)
	if err != nil {
		return r, err
	}
	defer tx.Rollback()
	var got bool
	if err := tx.QueryRowContext(ctx, `SELECT pg_try_advisory_xact_lock($1)`, lockReaper).Scan(&got); err != nil || !got {
		return r, err
	}
	rows, err := tx.QueryContext(ctx, `UPDATE world_hosts SET state = 'dead' WHERE state <> 'dead'
		AND heartbeat < now() - make_interval(secs => $1::bigint / 1000000.0) RETURNING `+hostCols, p.lease.Microseconds())
	if err != nil {
		return r, err
	}
	var ids []string
	for rows.Next() {
		h, err := scanHost(rows)
		if err != nil {
			rows.Close()
			return r, err
		}
		r.Dead = append(r.Dead, h)
		ids = append(ids, h.ID)
	}
	rows.Close()
	if len(ids) == 0 {
		return r, tx.Commit()
	}
	sortHosts(r.Dead)
	for _, id := range ids {
		lrows, err := tx.QueryContext(ctx, `SELECT `+instanceCols+` FROM world_instances i WHERE i.host = $1 AND i.state IN ('open', 'closing')
			ORDER BY i.world, i.layer`, id)
		if err != nil {
			return r, err
		}
		for lrows.Next() {
			in, err := scanInstance(lrows)
			if err != nil {
				lrows.Close()
				return r, err
			}
			in.State = StateLost
			r.Lost = append(r.Lost, in)
		}
		lrows.Close()
		if _, err := tx.ExecContext(ctx, `DELETE FROM world_instance_members m USING world_instances i
			WHERE i.host = $1 AND i.state IN ('open', 'closing') AND m.world = i.world AND m.layer = i.layer AND m.key = i.key`, id); err != nil {
			return r, err
		}
		if _, err := tx.ExecContext(ctx, `UPDATE world_instances SET state = 'lost' WHERE host = $1 AND state IN ('open', 'closing')`, id); err != nil {
			return r, err
		}
		if _, err := tx.ExecContext(ctx, `DELETE FROM world_presence WHERE host = $1`, id); err != nil {
			return r, err
		}
	}
	// Lost rows are history: kept a day.
	if _, err := tx.ExecContext(ctx, `DELETE FROM world_instances WHERE state = 'lost' AND created < now() - interval '1 day'`); err != nil {
		return r, err
	}
	sortInstances(r.Lost)
	return r, tx.Commit()
}

// SetOnline implements Cluster.
func (p *Postgres) SetOnline(ctx context.Context, c Character) error {
	_, err := p.db.ExecContext(ctx, `INSERT INTO world_presence (character, name, level, account, username, host, updated)
		VALUES ($1, $2, $3, $4, $5, $6, now()) ON CONFLICT (character) DO UPDATE SET name = EXCLUDED.name, level = EXCLUDED.level,
		account = EXCLUDED.account, username = EXCLUDED.username, host = EXCLUDED.host, updated = now()`,
		c.ID, c.Name, c.Level, c.Account, c.Username, c.Host)
	return err
}

// SetOffline implements Cluster.
func (p *Postgres) SetOffline(ctx context.Context, char int64, host string) error {
	_, err := p.db.ExecContext(ctx, `DELETE FROM world_presence WHERE character = $1 AND host = $2`, char, host)
	return err
}

// Online implements Cluster.
func (p *Postgres) Online(ctx context.Context) ([]Character, error) {
	rows, err := p.db.QueryContext(ctx, `SELECT pr.character, pr.name, pr.level, pr.account, pr.username, pr.host FROM world_presence pr
		JOIN world_hosts h ON h.id = pr.host AND h.state <> 'dead'`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Character
	for rows.Next() {
		var c Character
		if err := rows.Scan(&c.ID, &c.Name, &c.Level, &c.Account, &c.Username, &c.Host); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

// SetReturn implements Cluster.
func (p *Postgres) SetReturn(ctx context.Context, char int64, r Return) error {
	_, err := p.db.ExecContext(ctx, `INSERT INTO world_returns (character, zone, bucket, frame, x, y, z, updated)
		VALUES ($1, $2, $3, $4, $5, $6, $7, now()) ON CONFLICT (character) DO UPDATE SET zone = EXCLUDED.zone,
		bucket = EXCLUDED.bucket, frame = EXCLUDED.frame, x = EXCLUDED.x, y = EXCLUDED.y, z = EXCLUDED.z, updated = now()`,
		char, r.Zone, r.Bucket, r.Frame, r.X, r.Y, r.Z)
	return err
}

// ReturnOf implements Cluster.
func (p *Postgres) ReturnOf(ctx context.Context, char int64) (Return, bool, error) {
	var r Return
	err := p.db.QueryRowContext(ctx, `SELECT zone, bucket, frame, x, y, z FROM world_returns WHERE character = $1`, char).
		Scan(&r.Zone, &r.Bucket, &r.Frame, &r.X, &r.Y, &r.Z)
	if errors.Is(err, sql.ErrNoRows) {
		return Return{}, false, nil
	}
	return r, err == nil, err
}

// ClearReturn implements Cluster.
func (p *Postgres) ClearReturn(ctx context.Context, char int64) error {
	_, err := p.db.ExecContext(ctx, `DELETE FROM world_returns WHERE character = $1`, char)
	return err
}

var _ Cluster = (*Postgres)(nil)

// int64Array scans a PostgreSQL bigint[] in its text form ("{1,2,3}").
type int64Array []int64

func (a *int64Array) Scan(src any) error {
	var s string
	switch v := src.(type) {
	case nil:
		*a = nil
		return nil
	case string:
		s = v
	case []byte:
		s = string(v)
	default:
		return fmt.Errorf("registry: cannot scan %T as bigint[]", src)
	}
	out := []int64{}
	if len(s) >= 2 && s[0] == '{' && s[len(s)-1] == '}' {
		body := s[1 : len(s)-1]
		var cur int64
		var neg, any bool
		for i := 0; i <= len(body); i++ {
			if i == len(body) || body[i] == ',' {
				if any {
					if neg {
						cur = -cur
					}
					out = append(out, cur)
				}
				cur, neg, any = 0, false, false
				continue
			}
			c := body[i]
			switch {
			case c == '-':
				neg = true
			case c >= '0' && c <= '9':
				cur = cur*10 + int64(c-'0')
				any = true
			}
		}
	}
	*a = out
	return nil
}
