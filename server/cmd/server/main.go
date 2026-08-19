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
)

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	accountDB := flag.String("account-db", "accounts.db", "path to the SQLite database for accounts (use :memory: for an ephemeral one)")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	accounts, err := account.OpenSQLStore(*accountDB)
	if err != nil {
		logger.Error("opening account database", "path", *accountDB, "error", err)
		os.Exit(1)
	}
	defer accounts.Close()
	logger.Info("account database ready", "path", *accountDB)

	// TODO: character state still doesn't survive a restart — give it the
	// same SQLite treatment as accounts once its schema settles.
	chars := character.NewMemStore()
	handle := gateway.Chain(
		session.LoginHandler(accounts),
		session.RegisterHandler(accounts),
		session.CharacterHandler(chars),
	)

	srv := &gateway.Server{
		Addr:   *addr,
		Logger: logger,
		Handle: func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			logger.Info("packet received", "addr", sess.RemoteAddr(), "opcode", p.Opcode, "size", len(p.Data))
			return handle(ctx, sess, p)
		},
	}

	if err := srv.ListenAndServe(ctx); err != nil {
		logger.Error("gateway server exited", "error", err)
		os.Exit(1)
	}
}
