package bus

// Postgres is the bus over PostgreSQL LISTEN/NOTIFY (round 869 lane W2,
// OURS, docs/protocol/game_worlds.md 12.3): one dedicated connection per
// process listens on every channel the process subscribes to; publishing is
// pg_notify on the ordinary pool. A payload is base64 in the notification;
// one too big for NOTIFY's 8,000 bytes goes in a row of bus_spill and travels
// by its id. The listening connection must reach PostgreSQL directly: a
// transaction-pooling PgBouncer drops LISTEN.
//
// Delivery is at most once: a message published while the listening
// connection is down (it reconnects with a backoff and listens again) is
// lost, as the in-process bus drops on a full queue. Every user of the bus
// treats a message as a notification of state the registry or the database
// holds, or as a packet a player may miss (a chat line), never as the only
// copy of a durable change.

import (
	"context"
	"database/sql"
	"encoding/base64"
	"errors"
	"fmt"
	"log/slog"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5"
)

// SpillSchema is the table for payloads too big for one notification.
const SpillSchema = `
CREATE TABLE IF NOT EXISTS bus_spill (
	id      bigserial PRIMARY KEY,
	payload bytea NOT NULL,
	created timestamptz NOT NULL DEFAULT now()
);
`

// inlineLimit is the largest base64 text sent in the notification itself
// (NOTIFY's limit is 8,000 bytes; a margin for the prefix).
const inlineLimit = 7800

// spillKeep is how long a spilled payload is kept for its readers.
const spillKeep = 5 * time.Minute

// Postgres is the LISTEN/NOTIFY Bus.
type Postgres struct {
	db     *sql.DB
	dsn    string
	logger *slog.Logger

	mu        sync.Mutex
	subs      map[string]map[int]*sub
	next      int
	listening map[string]bool
	// wake interrupts the listener's wait so it LISTENs a new channel.
	wake   context.CancelFunc
	closed bool

	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}

	// Published and Received count messages (the load test's bus rate).
	statsMu   sync.Mutex
	published int64
	received  int64
}

// NewPostgres opens the listening connection on dsn and returns the bus.
// db is the pool publishes and spills go through.
func NewPostgres(ctx context.Context, db *sql.DB, dsn string, logger *slog.Logger) (*Postgres, error) {
	if _, err := db.ExecContext(ctx, SpillSchema); err != nil {
		return nil, fmt.Errorf("bus: schema: %w", err)
	}
	if logger == nil {
		logger = slog.Default()
	}
	p := &Postgres{db: db, dsn: dsn, logger: logger, subs: map[string]map[int]*sub{}, listening: map[string]bool{},
		done: make(chan struct{})}
	p.ctx, p.cancel = context.WithCancel(context.Background())
	conn, err := pgx.Connect(ctx, dsn)
	if err != nil {
		return nil, fmt.Errorf("bus: listening connection: %w", err)
	}
	go p.listen(conn)
	go p.sweep()
	return p, nil
}

// Close stops the listener.
func (p *Postgres) Close() {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return
	}
	p.closed = true
	p.mu.Unlock()
	p.cancel()
	<-p.done
}

// Stats is the messages published and received since the start.
func (p *Postgres) Stats() (published, received int64) {
	p.statsMu.Lock()
	defer p.statsMu.Unlock()
	return p.published, p.received
}

// pgChannel is a bus channel's PostgreSQL channel name.
func pgChannel(channel string) string {
	var b strings.Builder
	b.WriteString("opensro_")
	for _, r := range channel {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '_':
			b.WriteRune(r)
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r + 32)
		default:
			b.WriteByte('_')
		}
	}
	s := b.String()
	if len(s) > 63 {
		s = s[:63]
	}
	return s
}

// Publish implements Bus.
func (p *Postgres) Publish(ctx context.Context, channel string, msg []byte) error {
	text := "b" + base64.StdEncoding.EncodeToString(msg)
	if len(text) > inlineLimit {
		var id int64
		if err := p.db.QueryRowContext(ctx, `INSERT INTO bus_spill (payload) VALUES ($1) RETURNING id`, msg).Scan(&id); err != nil {
			return fmt.Errorf("bus: spill: %w", err)
		}
		text = "#" + strconv.FormatInt(id, 10)
	}
	if _, err := p.db.ExecContext(ctx, `SELECT pg_notify($1, $2)`, pgChannel(channel), text); err != nil {
		return fmt.Errorf("bus: notify: %w", err)
	}
	p.statsMu.Lock()
	p.published++
	p.statsMu.Unlock()
	return nil
}

// Subscribe implements Bus.
func (p *Postgres) Subscribe(channel string, handler func(msg []byte)) func() {
	s := &sub{ch: make(chan []byte, 4096), done: make(chan struct{})}
	pc := pgChannel(channel)
	p.mu.Lock()
	p.next++
	id := p.next
	if p.subs[pc] == nil {
		p.subs[pc] = map[int]*sub{}
	}
	p.subs[pc][id] = s
	needListen := !p.listening[pc]
	wake := p.wake
	p.mu.Unlock()
	if needListen && wake != nil {
		wake()
	}
	go func() {
		for {
			select {
			case <-s.done:
				return
			case msg := <-s.ch:
				handler(msg)
			}
		}
	}()
	var once sync.Once
	return func() {
		once.Do(func() {
			p.mu.Lock()
			delete(p.subs[pc], id)
			p.mu.Unlock()
			close(s.done)
		})
	}
}

// WaitListening blocks until every subscribed channel is LISTENed (a test's
// and a boot's barrier: a message published before it may be missed).
func (p *Postgres) WaitListening(ctx context.Context) error {
	for {
		p.mu.Lock()
		all := true
		for pc, subs := range p.subs {
			if len(subs) > 0 && !p.listening[pc] {
				all = false
			}
		}
		wake := p.wake
		p.mu.Unlock()
		if all {
			return nil
		}
		if wake != nil {
			wake()
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(5 * time.Millisecond):
		}
	}
}

// listen owns the listening connection: it LISTENs every subscribed channel,
// waits for notifications and hands each to its channel's subscribers,
// reconnecting when the connection breaks.
func (p *Postgres) listen(conn *pgx.Conn) {
	defer close(p.done)
	backoff := 100 * time.Millisecond
	for {
		err := p.serve(conn)
		conn.Close(context.Background())
		if p.ctx.Err() != nil {
			return
		}
		p.logger.Warn("bus: the listening connection broke; reconnecting", "err", err)
		p.mu.Lock()
		p.listening = map[string]bool{}
		p.mu.Unlock()
		for {
			select {
			case <-p.ctx.Done():
				return
			case <-time.After(backoff):
			}
			if backoff < 5*time.Second {
				backoff *= 2
			}
			c, err := pgx.Connect(p.ctx, p.dsn)
			if err == nil {
				conn = c
				backoff = 100 * time.Millisecond
				break
			}
		}
	}
}

func (p *Postgres) serve(conn *pgx.Conn) error {
	for {
		// LISTEN what is new.
		p.mu.Lock()
		var todo []string
		for pc, subs := range p.subs {
			if len(subs) > 0 && !p.listening[pc] {
				todo = append(todo, pc)
			}
		}
		p.mu.Unlock()
		for _, pc := range todo {
			if _, err := conn.Exec(p.ctx, `LISTEN "`+pc+`"`); err != nil {
				return err
			}
			p.mu.Lock()
			p.listening[pc] = true
			p.mu.Unlock()
		}
		waitCtx, wake := context.WithCancel(p.ctx)
		p.mu.Lock()
		p.wake = wake
		// A subscription that came after the LISTENs above woke the old
		// wait: look again before waiting.
		pending := false
		for pc, subs := range p.subs {
			if len(subs) > 0 && !p.listening[pc] {
				pending = true
			}
		}
		p.mu.Unlock()
		if pending {
			wake()
			continue
		}
		n, err := conn.WaitForNotification(waitCtx)
		wake()
		if err != nil {
			if p.ctx.Err() != nil {
				return p.ctx.Err()
			}
			if errors.Is(err, context.Canceled) || waitCtx.Err() != nil {
				continue // woken to LISTEN a new channel
			}
			return err
		}
		p.deliver(n.Channel, n.Payload)
	}
}

func (p *Postgres) deliver(pc, payload string) {
	var msg []byte
	switch {
	case strings.HasPrefix(payload, "b"):
		b, err := base64.StdEncoding.DecodeString(payload[1:])
		if err != nil {
			return
		}
		msg = b
	case strings.HasPrefix(payload, "#"):
		id, err := strconv.ParseInt(payload[1:], 10, 64)
		if err != nil {
			return
		}
		ctx, cancel := context.WithTimeout(p.ctx, 5*time.Second)
		err = p.db.QueryRowContext(ctx, `SELECT payload FROM bus_spill WHERE id = $1`, id).Scan(&msg)
		cancel()
		if err != nil {
			p.logger.Warn("bus: a spilled payload is gone", "id", id, "err", err)
			return
		}
	default:
		return
	}
	p.statsMu.Lock()
	p.received++
	p.statsMu.Unlock()
	p.mu.Lock()
	var targets []*sub
	for _, s := range p.subs[pc] {
		targets = append(targets, s)
	}
	p.mu.Unlock()
	for i, s := range targets {
		cp := msg
		if i > 0 {
			cp = append([]byte(nil), msg...)
		}
		select {
		case s.ch <- cp:
		default:
		}
	}
}

// sweep deletes spilled payloads older than spillKeep.
func (p *Postgres) sweep() {
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-p.ctx.Done():
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(p.ctx, 10*time.Second)
			p.db.ExecContext(ctx, `DELETE FROM bus_spill WHERE created < now() - make_interval(secs => $1)`, spillKeep.Seconds())
			cancel()
		}
	}
}

var _ Bus = (*Postgres)(nil)
