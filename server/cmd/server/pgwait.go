package main

import (
	"context"
	"database/sql"
	"fmt"
	"log/slog"
	"time"
)

// waitForDatabase calls ping until it succeeds or wait runs out, sleeping
// interval between tries, and logs each failed try.
//
// It exists for the boot of a host running the compose stack. Docker restarts
// the server and postgres containers together under their restart policy and
// ignores compose's `depends_on: condition: service_healthy`, which applies
// only to `docker compose up`. So the server's first connection could reach
// postgres before it accepted connections. The single ping in OpenSQLStore
// then failed ("connect: connection refused") and the server exited, to be
// restarted by Docker a second later: opensro-01, 2026-09-30, on both
// reboots (00:26:59 and 00:28:02). Waiting here makes the start clean
// whatever the order.
func waitForDatabase(ping func() error, wait, interval time.Duration, sleep func(time.Duration), logger *slog.Logger) error {
	deadline := wait
	var waited time.Duration
	for try := 1; ; try++ {
		err := ping()
		if err == nil {
			if try > 1 {
				logger.Info("postgres reachable", "tries", try, "waited", waited)
			}
			return nil
		}
		if waited >= deadline {
			return fmt.Errorf("postgres not reachable after %s (%d tries): %w", waited, try, err)
		}
		logger.Warn("waiting for postgres", "try", try, "err", err)
		sleep(interval)
		waited += interval
	}
}

// pingPostgres opens dsn once and pings it with a short timeout, for
// waitForDatabase. The pgx driver is registered by internal/account.
func pingPostgres(dsn string) func() error {
	return func() error {
		db, err := sql.Open("pgx", dsn)
		if err != nil {
			return err
		}
		defer db.Close()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		return db.PingContext(ctx)
	}
}
