package main

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"strings"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/clientpacks"
)

// startClientPacks turns the -client-packs flags into the manifest the
// server names to every client (round 789, lane U, OURS; docs/protocol/
// asset_packs.md "Server packs", deploy/README.md "Server packs"): with no
// folder, the manifest that names none. With one, every pack is checked and
// hashed (clientpacks.Build), the listener -- when on -- is bound before the
// gateway opens, and the list is logged. Any problem is returned: a server
// whose clients cannot get its content should not start.
func startClientPacks(ctx context.Context, dir, baseURL, listen string, extras bool, logger *slog.Logger) (clientpacks.Manifest, error) {
	dir = strings.TrimSpace(dir)
	if dir == "" {
		if baseURL != "" || (listen != "" && listen != "off") || extras {
			logger.Warn("-client-packs-url, -client-packs-listen and -client-packs-local-extras do nothing without -client-packs")
		}
		logger.Info("client packs: none named (no -client-packs); clients keep their own packs")
		return clientpacks.Manifest{}, nil
	}
	addr := strings.TrimSpace(listen)
	switch {
	case addr == "" && strings.TrimSpace(baseURL) == "":
		addr = clientpacks.DefaultListen
	case addr == "" || strings.EqualFold(addr, "off"):
		addr = ""
	}
	// The port goes into the manifest, so the listener is bound first (on
	// :0 a test gets a free one) -- and only once the packs are known good:
	// it is given the built set through a handler that waits for nothing.
	var holder packsHolder
	var port uint16
	if addr != "" {
		bound, err := clientpacks.Listen(ctx, addr, &holder, logger)
		if err != nil {
			return clientpacks.Manifest{}, err
		}
		port = clientpacks.ListenPort(bound)
		if port == 0 {
			return clientpacks.Manifest{}, fmt.Errorf("client packs: the listener %s has no port", bound)
		}
	}
	b, err := clientpacks.Build(clientpacks.Options{Dir: dir, BaseURL: baseURL, HTTPPort: port, LocalExtras: extras,
		Logf: func(format string, args ...any) { logger.Info(fmt.Sprintf(format, args...)) }})
	if err != nil {
		return clientpacks.Manifest{}, err
	}
	holder.h.Store(clientpacks.NewHandler(b, clientpacks.DefaultServeLimits, logger))
	var names []string
	for _, f := range b.Files {
		names = append(names, f.Name)
	}
	source := "the operator's URL " + strings.TrimRight(baseURL, "/") + "/<name>"
	if baseURL == "" {
		source = fmt.Sprintf("this server's listener, port %d, %s<name>", port, clientpacks.PathPrefix)
	} else if port != 0 {
		source += fmt.Sprintf(", then this server's listener (port %d)", port)
	}
	logger.Info("client packs: named to every client before login", "dir", dir, "packs", len(b.Files),
		"order", strings.Join(names, ", "), "from", source, "local_extras", extras)
	return b.Manifest, nil
}

// packsHolder serves 503 until the packs are built (the listener is bound
// before Build so the manifest can carry its port; the gateway, and so the
// manifest, is not up until then either).
type packsHolder struct {
	h atomic.Pointer[clientpacks.Handler]
}

func (p *packsHolder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	h := p.h.Load()
	if h == nil {
		w.Header().Set("Retry-After", "5")
		http.Error(w, "starting", http.StatusServiceUnavailable)
		return
	}
	h.ServeHTTP(w, r)
}
