package metrics

import (
	"context"
	"database/sql"
	"database/sql/driver"
	"errors"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// The database's families. Every statement the stores run goes through one
// of the server's two pools (txn.OpenPool: "stores" and "refdata"), and each
// pool's driver connector is wrapped once here (WrapConnector), so no store
// is touched. A query's time is until the driver returns its first answer
// (for a SELECT, before the rows are read).
var (
	dbQueries = factory.counterVec("db_queries_total",
		"Statements run, by pool (stores, refdata), op (the SQL verb: select, insert, update, delete, with, ddl, other) and table (the first table the statement names).",
		"pool", "op", "table")
	dbErrors = factory.counterVec("db_errors_total",
		"Statements and transaction ends that returned an error, by pool, op and table.", "pool", "op", "table")
	dbSeconds = factory.histogramVec("db_query_seconds",
		"Statement time to the driver's answer, by pool and op.", LatencyBuckets, "pool", "op")
	dbTx = factory.counterVec("db_transactions_total",
		"Transactions ended, by pool and result: commit, rollback, commit_error.", "pool", "result")
)

// RegisterDBStats exports db's pool stats (go_sql_* with db_name=pool: open,
// in use, idle, wait count and duration, closed for max idle/lifetime).
func RegisterDBStats(db *sql.DB, pool string) {
	_ = Registry.Register(collectors.NewDBStatsCollector(db, pool))
}

// WrapConnector returns c with every statement counted and timed under pool.
func WrapConnector(c driver.Connector, pool string) driver.Connector {
	return &connector{inner: c, pool: pool}
}

type connector struct {
	inner driver.Connector
	pool  string
}

func (c *connector) Connect(ctx context.Context) (driver.Conn, error) {
	conn, err := c.inner.Connect(ctx)
	if err != nil {
		return nil, err
	}
	return &conn_{Conn: conn, pool: c.pool}, nil
}

func (c *connector) Driver() driver.Driver { return c.inner.Driver() }

// queryInfo is a statement's pre-resolved children.
type queryInfo struct {
	count   prometheus.Counter
	errs    prometheus.Counter
	seconds prometheus.Observer
}

var (
	queryCache     sync.Map // pool + "\x00" + query -> *queryInfo
	queryCacheSize atomic.Int64
	tableSet       sync.Map // table -> struct{}
	tableCount     atomic.Int64
)

// The caches' bounds: statements are static strings, but a store that builds
// one (an IN list's placeholders) must not grow the cache or the table
// label without end.
const (
	maxCachedQueries = 4096
	maxTables        = 128
)

var tableRE = regexp.MustCompile(`(?i)\b(?:from|into|update|join|table(?:\s+if\s+(?:not\s+)?exists)?|index(?:\s+if\s+not\s+exists)?\s+\S+\s+on)\s+"?([a-z_][a-z0-9_]*)`)

// QueryLabels is the op and table a statement is counted under.
func QueryLabels(query string) (op, table string) {
	q := strings.TrimSpace(query)
	for strings.HasPrefix(q, "--") || strings.HasPrefix(q, "/*") {
		if strings.HasPrefix(q, "--") {
			if i := strings.IndexByte(q, '\n'); i >= 0 {
				q = strings.TrimSpace(q[i+1:])
			} else {
				q = ""
			}
		} else if i := strings.Index(q, "*/"); i >= 0 {
			q = strings.TrimSpace(q[i+2:])
		} else {
			q = ""
		}
	}
	verb := q
	if i := strings.IndexAny(q, " \t\r\n("); i >= 0 {
		verb = q[:i]
	}
	switch v := strings.ToLower(verb); v {
	case "select", "insert", "update", "delete", "with":
		op = v
	case "create", "alter", "drop", "truncate":
		op = "ddl"
	default:
		op = "other"
	}
	table = "none"
	if m := tableRE.FindStringSubmatch(q); m != nil {
		table = strings.ToLower(m[1])
		if _, ok := tableSet.Load(table); !ok {
			if tableCount.Load() >= maxTables {
				table = "other"
			} else if _, loaded := tableSet.LoadOrStore(table, struct{}{}); !loaded {
				tableCount.Add(1)
			}
		}
	}
	return op, table
}

func infoFor(pool, query string) *queryInfo {
	key := pool + "\x00" + query
	if v, ok := queryCache.Load(key); ok {
		return v.(*queryInfo)
	}
	op, table := QueryLabels(query)
	qi := &queryInfo{
		count:   dbQueries.WithLabelValues(pool, op, table),
		errs:    dbErrors.WithLabelValues(pool, op, table),
		seconds: dbSeconds.WithLabelValues(pool, op),
	}
	if queryCacheSize.Load() < maxCachedQueries {
		if _, loaded := queryCache.LoadOrStore(key, qi); !loaded {
			queryCacheSize.Add(1)
		}
	}
	return qi
}

func observe(pool, query string, start time.Time, err error) {
	if errors.Is(err, driver.ErrSkip) {
		return // database/sql retries another way; that one is counted
	}
	qi := infoFor(pool, query)
	qi.count.Inc()
	qi.seconds.Observe(time.Since(start).Seconds())
	if err != nil && !errors.Is(err, driver.ErrBadConn) {
		qi.errs.Inc()
	}
}

// conn_ wraps a driver connection; every optional interface database/sql
// looks for is implemented and passed through (ErrSkip when the inner one
// lacks it, which database/sql answers by its fallback).
type conn_ struct {
	driver.Conn
	pool string
}

var (
	_ driver.ConnBeginTx        = (*conn_)(nil)
	_ driver.ConnPrepareContext = (*conn_)(nil)
	_ driver.ExecerContext      = (*conn_)(nil)
	_ driver.QueryerContext     = (*conn_)(nil)
	_ driver.Pinger             = (*conn_)(nil)
	_ driver.SessionResetter    = (*conn_)(nil)
	_ driver.Validator          = (*conn_)(nil)
	_ driver.NamedValueChecker  = (*conn_)(nil)
	_ driver.StmtExecContext    = (*stmt_)(nil)
	_ driver.StmtQueryContext   = (*stmt_)(nil)
	_ driver.NamedValueChecker  = (*stmt_)(nil)
)

func (c *conn_) Prepare(query string) (driver.Stmt, error) {
	return c.PrepareContext(context.Background(), query)
}

func (c *conn_) PrepareContext(ctx context.Context, query string) (driver.Stmt, error) {
	var s driver.Stmt
	var err error
	if p, ok := c.Conn.(driver.ConnPrepareContext); ok {
		s, err = p.PrepareContext(ctx, query)
	} else {
		s, err = c.Conn.Prepare(query)
	}
	if err != nil {
		return nil, err
	}
	return &stmt_{Stmt: s, pool: c.pool, query: query}, nil
}

func (c *conn_) BeginTx(ctx context.Context, opts driver.TxOptions) (driver.Tx, error) {
	var tx driver.Tx
	var err error
	if b, ok := c.Conn.(driver.ConnBeginTx); ok {
		tx, err = b.BeginTx(ctx, opts)
	} else {
		tx, err = c.Conn.Begin() //nolint:staticcheck // the fallback database/sql would take
	}
	if err != nil {
		return nil, err
	}
	return &tx_{Tx: tx, pool: c.pool}, nil
}

func (c *conn_) ExecContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Result, error) {
	e, ok := c.Conn.(driver.ExecerContext)
	if !ok {
		return nil, driver.ErrSkip
	}
	start := time.Now()
	r, err := e.ExecContext(ctx, query, args)
	observe(c.pool, query, start, err)
	return r, err
}

func (c *conn_) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
	q, ok := c.Conn.(driver.QueryerContext)
	if !ok {
		return nil, driver.ErrSkip
	}
	start := time.Now()
	r, err := q.QueryContext(ctx, query, args)
	observe(c.pool, query, start, err)
	return r, err
}

func (c *conn_) Ping(ctx context.Context) error {
	if p, ok := c.Conn.(driver.Pinger); ok {
		return p.Ping(ctx)
	}
	return nil
}

func (c *conn_) ResetSession(ctx context.Context) error {
	if r, ok := c.Conn.(driver.SessionResetter); ok {
		return r.ResetSession(ctx)
	}
	return nil
}

func (c *conn_) IsValid() bool {
	if v, ok := c.Conn.(driver.Validator); ok {
		return v.IsValid()
	}
	return true
}

func (c *conn_) CheckNamedValue(nv *driver.NamedValue) error {
	if ch, ok := c.Conn.(driver.NamedValueChecker); ok {
		return ch.CheckNamedValue(nv)
	}
	return driver.ErrSkip
}

// Raw is the wrapped driver connection, for code that needs the driver's own
// type (sql.Conn.Raw hands the wrapper).
func (c *conn_) Raw() driver.Conn { return c.Conn }

type stmt_ struct {
	driver.Stmt
	pool, query string
}

func (s *stmt_) ExecContext(ctx context.Context, args []driver.NamedValue) (driver.Result, error) {
	start := time.Now()
	var r driver.Result
	var err error
	if e, ok := s.Stmt.(driver.StmtExecContext); ok {
		r, err = e.ExecContext(ctx, args)
	} else {
		var vs []driver.Value
		if vs, err = namedToValues(args); err == nil {
			r, err = s.Stmt.Exec(vs) //nolint:staticcheck
		}
	}
	observe(s.pool, s.query, start, err)
	return r, err
}

func (s *stmt_) QueryContext(ctx context.Context, args []driver.NamedValue) (driver.Rows, error) {
	start := time.Now()
	var r driver.Rows
	var err error
	if q, ok := s.Stmt.(driver.StmtQueryContext); ok {
		r, err = q.QueryContext(ctx, args)
	} else {
		var vs []driver.Value
		if vs, err = namedToValues(args); err == nil {
			r, err = s.Stmt.Query(vs) //nolint:staticcheck
		}
	}
	observe(s.pool, s.query, start, err)
	return r, err
}

func (s *stmt_) CheckNamedValue(nv *driver.NamedValue) error {
	if ch, ok := s.Stmt.(driver.NamedValueChecker); ok {
		return ch.CheckNamedValue(nv)
	}
	return driver.ErrSkip
}

func namedToValues(args []driver.NamedValue) ([]driver.Value, error) {
	out := make([]driver.Value, len(args))
	for i, a := range args {
		if a.Name != "" {
			return nil, errors.New("metrics: named parameters need a driver with StmtExecContext")
		}
		out[i] = a.Value
	}
	return out, nil
}

type tx_ struct {
	driver.Tx
	pool string
}

func (t *tx_) Commit() error {
	err := t.Tx.Commit()
	if err != nil {
		dbTx.WithLabelValues(t.pool, "commit_error").Inc()
	} else {
		dbTx.WithLabelValues(t.pool, "commit").Inc()
	}
	return err
}

func (t *tx_) Rollback() error {
	err := t.Tx.Rollback()
	dbTx.WithLabelValues(t.pool, "rollback").Inc()
	return err
}
