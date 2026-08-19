package main

import (
	"context"
	"flag"
	"log/slog"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
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
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// spawnZone/monster stats are our own placeholder PvE content -- a single
// "training dummy" monster kept alive in the world's one spawn zone, since
// no real map/monster data exists yet. See docs/protocol/refdata_schema.md
// for what's still missing (a real drop/monster table).
const (
	monsterZone       = "jangan"
	monsterName       = "Stone Golem"
	monsterMaxHP      = 200
	monsterDefense    = 10
	monsterAttack     = 8
	monsterGoldReward = 50
	respawnDelay      = 10 * time.Second
)

// maintainMonster keeps exactly one monster alive in monsterZone, respawning
// it respawnDelay after each death, until ctx is canceled.
func maintainMonster(ctx context.Context, monsters *combat.Hub, logger *slog.Logger) {
	spawn := func() int64 {
		m := monsters.Spawn(monsterZone, monsterName, monsterMaxHP, monsterDefense, monsterAttack, monsterGoldReward)
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
	logger.Info("postgres storage ready")

	shopSvc := &shop.Service{Gold: chars, Inv: inv, Items: refItems}

	hub := world.NewHub()
	monsters := combat.NewHub()
	parties := party.NewHub()
	go maintainMonster(ctx, monsters, logger)

	handle := gateway.Chain(
		session.LoginHandler(accounts),
		session.RegisterHandler(accounts),
		session.CharacterHandler(chars),
		session.WorldHandler(chars, hub),
		session.InventoryHandler(chars, inv),
		session.EquipmentHandler(chars, eq),
		session.ShopHandler(chars, shopSvc),
		session.CombatHandler(chars, eq, refItems, hub, monsters, quests),
		session.LearnSkillHandler(chars, skills),
		session.UseSkillHandler(chars, eq, refItems, skills, hub, monsters, quests),
		session.PartyHandler(chars, parties),
		session.GuildHandler(chars, guilds),
		session.ChatHandler(hub),
		session.QuestHandler(chars, quests),
	)

	worldDisconnect := session.WorldDisconnectHandler(hub)
	partyDisconnect := session.PartyDisconnectHandler(parties)

	srv := &gateway.Server{
		Addr:   *addr,
		Logger: logger,
		Handle: func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			logger.Info("packet received", "addr", sess.RemoteAddr(), "opcode", p.Opcode, "size", len(p.Data))
			return handle(ctx, sess, p)
		},
		OnDisconnect: func(sess *gateway.Session) {
			worldDisconnect(sess)
			partyDisconnect(sess)
		},
	}

	if err := srv.ListenAndServe(ctx); err != nil {
		logger.Error("gateway server exited", "error", err)
		os.Exit(1)
	}
}
