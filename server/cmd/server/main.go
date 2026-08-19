package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	srv := &gateway.Server{
		Addr:   *addr,
		Logger: logger,
		Handle: func(_ context.Context, sess *gateway.Session, p *proto.Packet) error {
			// No opcode table yet (see docs/protocol/PACKET_FORMAT.md) — just
			// log what we see so we can start building the opcode list from
			// real traffic once a test client exists.
			logger.Info("packet received", "addr", sess.RemoteAddr(), "opcode", p.Opcode, "size", len(p.Data))
			return nil
		},
	}

	if err := srv.ListenAndServe(ctx); err != nil {
		logger.Error("gateway server exited", "error", err)
		os.Exit(1)
	}
}
