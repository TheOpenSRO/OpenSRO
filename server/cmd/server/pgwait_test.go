package main

import (
	"errors"
	"io"
	"log/slog"
	"strings"
	"testing"
	"time"
)

func TestWaitForDatabaseRetriesUntilPostgresAnswers(t *testing.T) {
	refused := errors.New("dial tcp 172.18.0.3:5432: connect: connection refused")
	calls := 0
	ping := func() error {
		calls++
		if calls < 4 {
			return refused
		}
		return nil
	}
	var slept time.Duration
	sleep := func(d time.Duration) { slept += d }
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	if err := waitForDatabase(ping, 60*time.Second, time.Second, sleep, logger); err != nil {
		t.Fatalf("postgres answering on the 4th try: got %v, want nil", err)
	}
	if calls != 4 || slept != 3*time.Second {
		t.Fatalf("got %d pings and %s slept, want 4 and 3s", calls, slept)
	}
}

func TestWaitForDatabaseGivesUpAfterTheWait(t *testing.T) {
	refused := errors.New("connection refused")
	calls := 0
	ping := func() error { calls++; return refused }
	sleep := func(time.Duration) {}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	err := waitForDatabase(ping, 5*time.Second, time.Second, sleep, logger)
	if err == nil || !errors.Is(err, refused) || !strings.Contains(err.Error(), "not reachable after 5s") {
		t.Fatalf("got %v, want the refusal wrapped after 5s", err)
	}
	if calls != 6 {
		t.Fatalf("got %d pings, want 6 (at 0s..5s)", calls)
	}
}

func TestWaitForDatabaseZeroWaitIsOneTry(t *testing.T) {
	calls := 0
	ping := func() error { calls++; return errors.New("down") }
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	if err := waitForDatabase(ping, 0, time.Second, func(time.Duration) {}, logger); err == nil {
		t.Fatal("a zero wait with postgres down: got nil, want an error")
	}
	if calls != 1 {
		t.Fatalf("a zero wait: got %d pings, want 1 (the old behaviour)", calls)
	}
}
