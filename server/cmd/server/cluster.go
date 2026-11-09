package main

// Several processes (round 869 lane W2, OURS, docs/protocol/game_worlds.md
// 12; deploy/README.md "Several processes (not enabled)"): -role front runs
// only the front's relay; -role world runs the game -- the open world
// (-world-layers open), instance layers (instances) or both -- with the
// PostgreSQL registry and bus, the relay listener the fronts open streams
// to, the heartbeat, the reaper and the drain. -role all (the default) is
// one process exactly as before: none of this runs.

import (
	"context"
	"database/sql"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/bus"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cluster"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/registry"
	"github.com/TheOpenSRO/OpenSRO/server/internal/relay"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

type clusterFlags struct {
	role          *string
	hostID        *string
	relayListen   *string
	relayAdvert   *string
	secret        *string
	layers        *string
	clusterDSN    *string
	drainDeadline *time.Duration
	lease         *time.Duration
}

func registerClusterFlags() clusterFlags {
	return clusterFlags{
		role: flag.String("role", envOr("OPENSRO_ROLE", "all"),
			"the process's part (round 869, OURS, docs/protocol/game_worlds.md 12): all (one process, the default), "+
				"front (client connections relayed to the world hosts), world (the game: -world-layers says which)"),
		hostID: flag.String("host-id", os.Getenv("OPENSRO_HOST_ID"),
			"-role world/front: this process's id in the registry (default: the host name and the relay port)"),
		relayListen: flag.String("relay-listen", envOr("OPENSRO_RELAY_LISTEN", "127.0.0.1:15790"),
			"-role world: the internal listener the fronts open streams to"),
		relayAdvert: flag.String("relay-advertise", os.Getenv("OPENSRO_RELAY_ADVERTISE"),
			"-role world: the address the fronts dial for -relay-listen (default -relay-listen)"),
		secret: flag.String("relay-secret", os.Getenv("OPENSRO_RELAY_SECRET"),
			"-role world/front: the shared secret every stream opens with (required)"),
		layers: flag.String("world-layers", envOr("OPENSRO_WORLD_LAYERS", "both"),
			"-role world: open (the open world, logins and the social services), instances (instance layers only) or both"),
		clusterDSN: flag.String("cluster-dsn", os.Getenv("OPENSRO_CLUSTER_DSN"),
			"-role world/front: the registry's and the bus's PostgreSQL (default -postgres-dsn); it must reach "+
				"PostgreSQL directly (LISTEN does not pass a transaction-pooling PgBouncer)"),
		drainDeadline: flag.Duration("drain-deadline", 2*time.Minute,
			"-role world: on SIGTERM the host drains -- no new instances, its layers run on for this long, then "+
				"their players go to their return points -- and exits"),
		lease: flag.Duration("host-lease", registry.DefaultLease,
			"-role world/front: how long a host may miss its heartbeat before the reaper declares it dead"),
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func (c clusterFlags) on() bool { return *c.role == "world" || *c.role == "front" }

func (c clusterFlags) check(inMemory bool) error {
	switch *c.role {
	case "all":
		return nil
	case "front", "world":
	default:
		return fmt.Errorf("-role %q: want all, front or world", *c.role)
	}
	if *c.secret == "" {
		return errors.New("-role front/world needs -relay-secret (OPENSRO_RELAY_SECRET)")
	}
	if *c.role == "world" {
		if inMemory {
			return errors.New("-role world needs the shared PostgreSQL: a character moves between processes through it (no -in-memory)")
		}
		switch *c.layers {
		case "open", "instances", "both":
		default:
			return fmt.Errorf("-world-layers %q: want open, instances or both", *c.layers)
		}
	}
	return nil
}

func (c clusterFlags) id(port string) string {
	if *c.hostID != "" {
		return *c.hostID
	}
	h, _ := os.Hostname()
	if h == "" {
		h = "host"
	}
	return h + "-" + port
}

// openCluster opens the registry, the bus and the node.
func openCluster(ctx context.Context, c clusterFlags, dsn string, self registry.Host, logger *slog.Logger,
	stats func() (int, int), onDead func(registry.Host), onPresence func(registry.Character, bool)) (*cluster.Node, *sql.DB, error) {
	if *c.clusterDSN != "" {
		dsn = *c.clusterDSN
	}
	pool, err := txn.OpenNamedPool(dsn, 6, "cluster")
	if err != nil {
		return nil, nil, fmt.Errorf("the cluster's pool: %w", err)
	}
	reg, err := registry.NewPostgres(ctx, pool, *c.lease)
	if err != nil {
		return nil, nil, err
	}
	b, err := bus.NewPostgres(ctx, pool, dsn, logger)
	if err != nil {
		return nil, nil, err
	}
	n := cluster.New(cluster.Config{Self: self, Registry: reg, Bus: b, Logger: logger, Lease: *c.lease, Stats: stats,
		OnHostDead: onDead, OnPresence: onPresence,
		OnFenced: func() {
			logger.Error("this host was declared dead by the reaper; exiting so its players stay where they were sent")
			os.Exit(3)
		}})
	return n, pool, nil
}

// runFront is -role front: the client listener relayed to the world hosts.
func runFront(c clusterFlags, addr, dsn string, logger *slog.Logger) {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	_, port, _ := net.SplitHostPort(addr)
	id := c.id("front" + port)
	f := &relay.Front{Addr: addr, Secret: *c.secret, ID: id, Logger: logger}
	n, _, err := openCluster(ctx, c, dsn, registry.Host{ID: id, Version: version}, logger,
		func() (int, int) { return f.Clients(), 0 }, func(h registry.Host) { f.HostDown(h.ID) }, nil)
	if err != nil {
		logger.Error("front: the cluster", "err", err)
		os.Exit(1)
	}
	f.Home = func(ctx context.Context) (string, string, error) {
		h, ok := n.Home()
		if !ok {
			n.RefreshHosts(ctx)
			h, ok = n.Home()
		}
		if !ok {
			return "", "", errors.New("no live host runs the open world")
		}
		return h.ID, h.Addr, nil
	}
	if err := n.Start(ctx); err != nil {
		logger.Error("front: the cluster", "err", err)
		os.Exit(1)
	}
	// A host declared dead: its streams are closed and their characters
	// recovered (a hung host's TCP stays open).
	go watchDeadHosts(ctx, n, f)
	logger.Info("front ready", "id", id, "addr", addr)
	if err := f.ListenAndServe(ctx); err != nil {
		logger.Error("front exited", "err", err)
		os.Exit(1)
	}
}

// watchDeadHosts closes a front's streams to hosts the registry has dead.
func watchDeadHosts(ctx context.Context, n *cluster.Node, f *relay.Front) {
	seen := map[string]bool{}
	t := time.NewTicker(time.Second)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		for _, h := range n.Hosts() {
			if h.State == registry.HostDead && !seen[h.ID] {
				seen[h.ID] = true
				f.HostDown(h.ID)
			}
		}
	}
}

// worldCluster is -role world's running parts.
type worldCluster struct {
	flags  clusterFlags
	node   *cluster.Node
	home   bool
	id     string
	relay  string
	logger *slog.Logger
}

// startWorldCluster joins this world process to the cluster: the node, the
// session layer's glue, the buff tokens' range, the party hub's sync.
func startWorldCluster(ctx context.Context, c clusterFlags, dsn string, logger *slog.Logger, hub *world.Hub,
	stats func() (int, int)) *worldCluster {
	advert := *c.relayAdvert
	if advert == "" {
		advert = *c.relayListen
	}
	_, port, _ := net.SplitHostPort(*c.relayListen)
	id := c.id(port)
	home := *c.layers == "open" || *c.layers == "both"
	self := registry.Host{ID: id, Addr: advert, Version: version, OpenWorld: home, Instances: *c.layers != "open"}
	n, _, err := openCluster(ctx, c, dsn, self, logger, stats, session.ClusterHostDead, session.ClusterPresenceChanged)
	if err != nil {
		logger.Error("the cluster", "err", err)
		os.Exit(1)
	}
	session.SetCluster(n, home)
	session.SetClusterOpenHub(hub)
	session.SeedBuffTokens(session.HostBase(id))
	return &worldCluster{flags: c, node: n, home: home, id: id, relay: *c.relayListen, logger: logger}
}

// managerConfig is the world manager's registry and host (lane W1's seam).
func (wc *worldCluster) managerConfig() (registry.Registry, string) {
	if wc == nil {
		return nil, ""
	}
	return wc.node.Registry(), wc.id
}

// start runs the node (after every handler is registered).
func (wc *worldCluster) start(ctx context.Context) {
	if err := wc.node.Start(ctx); err != nil {
		wc.logger.Error("the cluster", "err", err)
		os.Exit(1)
	}
	wc.logger.Info("cluster joined", "host", wc.id, "relay", wc.relay, "open_world", wc.home, "layers", *wc.flags.layers)
}

// relayServer is the listener the fronts open streams to.
func (wc *worldCluster) relayServer(handle gateway.Handler, onDisconnect func(*gateway.Session)) *gateway.Server {
	return &gateway.Server{Addr: wc.relay, Logger: wc.logger, Codec: relay.NewHostCodec(*wc.flags.secret),
		Handle: handle, OnDisconnect: onDisconnect}
}

// drainOnSignal is the graceful drain (game_worlds.md 12.4): the first
// SIGTERM marks the host draining (no new instances), tells its instances'
// players the layer closes at the deadline, lets them run until then (or
// until every one has closed on its own), closes the rest -- their players
// handed to their return points -- and then cancels the process.
func (wc *worldCluster) drainOnSignal(cancel context.CancelFunc) {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM)
	go func() {
		<-sig
		deadline := *wc.flags.drainDeadline
		wc.logger.Info("drain started", "host", wc.id, "deadline", deadline)
		ctx := context.Background()
		wc.node.Drain(ctx)
		mgr := session.GameWorlds()
		if mgr != nil {
			session.NoticeDrain(mgr, deadline)
			end := time.Now().Add(deadline)
			for time.Now().Before(end) && len(mgr.Local()) > 0 {
				time.Sleep(500 * time.Millisecond)
			}
			for _, w := range mgr.Local() {
				w.CloseAsync(gameworld.CloseManual)
			}
		}
		// The players hand off; wait for the last one (bounded).
		end := time.Now().Add(15 * time.Second)
		for time.Now().Before(end) && session.LocalPlayers() > 0 {
			time.Sleep(200 * time.Millisecond)
		}
		wc.logger.Info("drain done", "host", wc.id, "players_left", session.LocalPlayers())
		cancel()
	}()
}
