package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/session"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	postgresDSN := flag.String("postgres-dsn", "postgres://postgres:postgres@localhost:5432/srrevamp?sslmode=disable",
		"PostgreSQL connection string for account/character storage")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	accounts, err := account.OpenSQLStore(*postgresDSN)
	if err != nil {
		logger.Error("opening account store", "error", err)
		os.Exit(1)
	}
	defer accounts.Close()

	chars, err := character.OpenSQLStore(*postgresDSN)
	if err != nil {
		logger.Error("opening character store", "error", err)
		os.Exit(1)
	}
	defer chars.Close()
	logger.Info("postgres storage ready")

	hub := world.NewHub()
	handle := gateway.Chain(
		session.LoginHandler(accounts),
		session.RegisterHandler(accounts),
		session.CharacterHandler(chars),
		session.WorldHandler(chars, hub),
	)

	srv := &gateway.Server{
		Addr:   *addr,
		Logger: logger,
		Handle: func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			logger.Info("packet received", "addr", sess.RemoteAddr(), "opcode", p.Opcode, "size", len(p.Data))
			return handle(ctx, sess, p)
		},
		OnDisconnect: session.WorldDisconnectHandler(hub),
	}

	if err := srv.ListenAndServe(ctx); err != nil {
		logger.Error("gateway server exited", "error", err)
		os.Exit(1)
	}
}
