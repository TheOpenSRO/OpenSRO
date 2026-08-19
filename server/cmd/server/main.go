package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/session"
)

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// TODO: swap for a persistent Store once one exists; MemStore has no
	// accounts registered yet, so nobody can actually log in via a running
	// server until account creation (registration) is implemented.
	store := account.NewMemStore()
	loginHandle := session.LoginHandler(store)

	srv := &gateway.Server{
		Addr:   *addr,
		Logger: logger,
		Handle: func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			logger.Info("packet received", "addr", sess.RemoteAddr(), "opcode", p.Opcode, "size", len(p.Data))
			return loginHandle(ctx, sess, p)
		},
	}

	if err := srv.ListenAndServe(ctx); err != nil {
		logger.Error("gateway server exited", "error", err)
		os.Exit(1)
	}
}
