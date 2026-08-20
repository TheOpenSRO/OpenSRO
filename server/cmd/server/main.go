package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/duel"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/friend"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/guild"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/session"
	"github.com/OpenSRO/srrevamp/server/internal/shop"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/trade"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// monsterSpec describes one species of monster to keep alive somewhere in
// the world. Our own placeholder PvE content -- no real map/monster data
// exists yet. See docs/protocol/refdata_schema.md for what's still missing
// (a real drop/monster table); combat.LootTables and quest.Catalog key off
// these Names, so a new entry here should usually come with matching
// entries there too.
type monsterSpec struct {
	Zone       string
	Name       string
	MaxHP      int
	Defense    int
	Attack     int
	GoldReward int64
}

var monsterSpecs = []monsterSpec{
	{Zone: "jangan", Name: "Stone Golem", MaxHP: 200, Defense: 10, Attack: 8, GoldReward: 50},
	{Zone: "jangan", Name: "Wild Boar", MaxHP: 80, Defense: 3, Attack: 4, GoldReward: 15},
	{Zone: "donwhang", Name: "Sand Scorpion", MaxHP: 350, Defense: 18, Attack: 14, GoldReward: 120},
}

const respawnDelay = 10 * time.Second

// maintainMonster keeps exactly one instance of spec's species alive in its
// zone, respawning it respawnDelay after each death, until ctx is
// canceled. main() runs one of these per monsterSpecs entry.
func maintainMonster(ctx context.Context, monsters *combat.Hub, logger *slog.Logger, spec monsterSpec) {
	spawn := func() int64 {
		m := monsters.Spawn(spec.Zone, spec.Name, spec.MaxHP, spec.Defense, spec.Attack, spec.GoldReward)
		logger.Info("monster spawned", "id", m.ID, "name", m.Name, "zone", m.Zone)
		return m.ID
	}

	currentID := spawn()
	ticker := time.NewTicker(1 * time.Second)
	defer ticker.Stop()

	var deadSince time.Time
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if _, alive := monsters.Get(currentID); alive {
				deadSince = time.Time{}
				continue
			}
			if deadSince.IsZero() {
				deadSince = time.Now()
				continue
			}
			if time.Since(deadSince) >= respawnDelay {
				currentID = spawn()
			}
		}
	}
}

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	postgresDSN := flag.String("postgres-dsn", "postgres://postgres:postgres@localhost:5432/srrevamp?sslmode=disable",
		"PostgreSQL connection string for account/character storage")
	tlsCert := flag.String("tls-cert", "", "path to a TLS certificate (PEM); if set with -tls-key, the gateway serves TLS instead of plain TCP")
	tlsKey := flag.String("tls-key", "", "path to a TLS private key (PEM); see -tls-cert")
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

	refItems, err := refdata.OpenSQLStore(*postgresDSN)
	if err != nil {
		logger.Error("opening refdata store", "error", err)
		os.Exit(1)
	}
	defer refItems.Close()

	inv, err := inventory.OpenSQLStore(*postgresDSN, refItems)
	if err != nil {
		logger.Error("opening inventory store", "error", err)
		os.Exit(1)
	}
	defer inv.Close()

	eq, err := equipment.OpenSQLStore(*postgresDSN, inv)
	if err != nil {
		logger.Error("opening equipment store", "error", err)
		os.Exit(1)
	}
	defer eq.Close()

	skills, err := skill.OpenSQLStore(*postgresDSN)
	if err != nil {
		logger.Error("opening skill store", "error", err)
		os.Exit(1)
	}
	defer skills.Close()

	guilds, err := guild.OpenSQLStore(*postgresDSN)
	if err != nil {
		logger.Error("opening guild store", "error", err)
		os.Exit(1)
	}
	defer guilds.Close()

	quests, err := quest.OpenSQLStore(*postgresDSN)
	if err != nil {
		logger.Error("opening quest store", "error", err)
		os.Exit(1)
	}
	defer quests.Close()

	friends, err := friend.OpenSQLStore(*postgresDSN)
	if err != nil {
		logger.Error("opening friend store", "error", err)
		os.Exit(1)
	}
	defer friends.Close()
	logger.Info("postgres storage ready")

	shopSvc := &shop.Service{Gold: chars, Inv: inv, Items: refItems}

	hub := world.NewHub()
	monsters := combat.NewHub()
	parties := party.NewHub()
	duels := duel.NewHub()
	trades := trade.NewHub()
	for _, spec := range monsterSpecs {
		go maintainMonster(ctx, monsters, logger, spec)
	}

	handle := gateway.Chain(
		session.LoginHandler(accounts),
		session.RegisterHandler(accounts),
		session.CharacterHandler(chars),
		session.WorldHandler(chars, hub),
		session.InventoryHandler(chars, inv),
		session.EquipmentHandler(chars, eq),
		session.ShopHandler(chars, shopSvc),
		session.CombatHandler(chars, eq, refItems, hub, monsters, quests, inv),
		session.LearnSkillHandler(chars, skills),
		session.UseSkillHandler(chars, eq, refItems, skills, hub, monsters, quests, inv),
		session.PartyHandler(chars, parties),
		session.GuildHandler(chars, guilds),
		session.ChatHandler(hub),
		session.QuestHandler(chars, quests),
		session.DuelHandler(chars, eq, refItems, hub, duels),
		session.TradeHandler(chars, inv, hub, trades),
		session.FriendHandler(chars, friends, hub),
	)

	worldDisconnect := session.WorldDisconnectHandler(hub)
	partyDisconnect := session.PartyDisconnectHandler(parties)
	duelDisconnect := session.DuelDisconnectHandler(hub, duels)
	tradeDisconnect := session.TradeDisconnectHandler(hub, trades)

	var tlsConfig *tls.Config
	if *tlsCert != "" || *tlsKey != "" {
		if *tlsCert == "" || *tlsKey == "" {
			logger.Error("-tls-cert and -tls-key must both be set together")
			os.Exit(1)
		}
		cert, err := tls.LoadX509KeyPair(*tlsCert, *tlsKey)
		if err != nil {
			logger.Error("loading TLS certificate", "error", err)
			os.Exit(1)
		}
		tlsConfig = &tls.Config{Certificates: []tls.Certificate{cert}}
	}

	srv := &gateway.Server{
		Addr:      *addr,
		Logger:    logger,
		TLSConfig: tlsConfig,
		Handle: func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			logger.Info("packet received", "addr", sess.RemoteAddr(), "opcode", p.Opcode, "size", len(p.Data))
			return handle(ctx, sess, p)
		},
		OnDisconnect: func(sess *gateway.Session) {
			// duelDisconnect/tradeDisconnect must run before
			// worldDisconnect: both look the disconnecting session up in
			// world.Hub, which worldDisconnect removes them from.
			duelDisconnect(sess)
			tradeDisconnect(sess)
			worldDisconnect(sess)
			partyDisconnect(sess)
		},
	}

	if err := srv.ListenAndServe(ctx); err != nil {
		logger.Error("gateway server exited", "error", err)
		os.Exit(1)
	}
}
