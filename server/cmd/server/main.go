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
	X, Z       float64 // own design placeholder spawn anchor -- see combat.Hub.Spawn
	MaxHP      int
	Defense    int
	Attack     int
	GoldReward int64
}

// These anchors were originally picked back when a character was still the
// old, uncalibrated 1.8-unit placeholder capsule (see client's
// PLAYER_SCALE_RATIO doc comment) -- close enough together that they never
// visibly overlapped. Now that a real assembled/placeholder character is its
// real ~138.7-unit native height (a monster capsule is ~77 units across),
// the old (15,10)/(-20,25) anchors sat almost on top of each other and on
// top of the player's own (0,0,0) spawn (see session/world.go's spawnPos),
// producing two giant overlapping red capsules filling the screen even at
// max camera zoom. Respaced to a few hundred units apart -- consistent with
// real measured building/wall scale (~44-300 units, see docs/WORLD_ISSUES.md)
// rather than a blind PLAYER_SCALE_RATIO multiply, which would have pushed
// these off the real terrain these zones actually have at those coordinates.
var monsterSpecs = []monsterSpec{
	// Species names are the ones the game's own tables use, so the client
	// can resolve each to its model: characterdata carries every row's SN_
	// name key and its .bsr, textdata_object resolves that key to a display
	// name, and joining the two covers 642 species. The three invented
	// names these replaced ("Stone Golem", "Wild Boar", "Sand Scorpion")
	// appear nowhere in the real data, so they could only ever draw the
	// placeholder capsule.
	// Positions are within sight of the spawn point, which is at the
	// origin. They used to be 250-350 units out, which measured as 292 and
	// 461 units from a new character -- both were really there, with real
	// resolved models, and neither was ever going to be seen. Placeholder
	// content either way, but placeholder content a player meets.
	{Zone: "jangan", Name: "Mangyang", X: 62, Z: 44, MaxHP: 200, Defense: 10, Attack: 8, GoldReward: 50},
	{Zone: "jangan", Name: "Weasel", X: -55, Z: 58, MaxHP: 80, Defense: 3, Attack: 4, GoldReward: 15},
	{Zone: "donwhang", Name: "Earth Ghost", X: 70, Z: -50, MaxHP: 350, Defense: 18, Attack: 14, GoldReward: 120},
}

const respawnDelay = 10 * time.Second

// maintainMonster keeps exactly one instance of spec's species alive in its
// zone, respawning it respawnDelay after each death, until ctx is
// canceled. main() runs one of these per monsterSpecs entry.
func maintainMonster(ctx context.Context, monsters *combat.Hub, logger *slog.Logger, spec monsterSpec) {
	spawn := func() int64 {
		m := monsters.Spawn(spec.Zone, spec.Name, spec.X, 0, spec.Z, spec.MaxHP, spec.Defense, spec.Attack, spec.GoldReward)
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

// refItemStore is the slice of reference data the running server needs:
// the shop's catalog listing plus the per-item lookup combat uses for
// attack and defence. Both the PostgreSQL and the in-memory store satisfy
// it, which is what lets -in-memory be a wiring choice rather than a fork.
type refItemStore interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
	ListAll(ctx context.Context) ([]*refdata.Item, error)
	GetMaxStack(ctx context.Context, itemID int64) (int, error)
}

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	postgresDSN := flag.String("postgres-dsn", "postgres://postgres:postgres@localhost:5432/srrevamp?sslmode=disable",
		"PostgreSQL connection string for account/character storage")
	tlsCert := flag.String("tls-cert", "", "path to a TLS certificate (PEM); if set with -tls-key, the gateway serves TLS instead of plain TCP")
	tlsKey := flag.String("tls-key", "", "path to a TLS private key (PEM); see -tls-cert")
	inMemory := flag.Bool("in-memory", false,
		"run with in-memory storage instead of PostgreSQL: nothing is persisted, and every "+
			"account, character, guild and friendship is gone when the process exits. For "+
			"development, for end-to-end client runs, and for anyone who wants to try the "+
			"server without setting up a database.")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	// The stores are held as interfaces so the in-memory and PostgreSQL
	// wirings below are interchangeable. account is split in two because
	// login and registration take different halves of it.
	var (
		accounts   account.Store
		registerer account.Registerer
		chars      character.Store
		refItems   refItemStore
		inv        inventory.Store
		eq         equipment.Store
		skills     skill.Store
		guilds     guild.Store
		quests     quest.Store
		friends    friend.Store
	)

	if *inMemory {
		// One shared refdata store feeds inventory's stack limits and the
		// combat/shop item lookups, exactly as the SQL wiring below does.
		memRef := refdata.NewMemStore()
		memInv := inventory.NewMemStore(memRef)
		memAccounts := account.NewMemStore()
		accounts, registerer = memAccounts, memAccounts
		chars = character.NewMemStore()
		refItems = memRef
		inv = memInv
		eq = equipment.NewMemStore(memInv)
		skills = skill.NewMemStore()
		guilds = guild.NewMemStore()
		quests = quest.NewMemStore()
		friends = friend.NewMemStore()
		logger.Warn("in-memory storage ready -- nothing will be persisted")
	} else {
		sqlAccounts, err := account.OpenSQLStore(*postgresDSN)
		if err != nil {
			logger.Error("opening account store", "error", err)
			os.Exit(1)
		}
		defer sqlAccounts.Close()

		sqlChars, err := character.OpenSQLStore(*postgresDSN)
		if err != nil {
			logger.Error("opening character store", "error", err)
			os.Exit(1)
		}
		defer sqlChars.Close()

		sqlRef, err := refdata.OpenSQLStore(*postgresDSN)
		if err != nil {
			logger.Error("opening refdata store", "error", err)
			os.Exit(1)
		}
		defer sqlRef.Close()

		sqlInv, err := inventory.OpenSQLStore(*postgresDSN, sqlRef)
		if err != nil {
			logger.Error("opening inventory store", "error", err)
			os.Exit(1)
		}
		defer sqlInv.Close()

		sqlEq, err := equipment.OpenSQLStore(*postgresDSN, sqlInv)
		if err != nil {
			logger.Error("opening equipment store", "error", err)
			os.Exit(1)
		}
		defer sqlEq.Close()

		sqlSkills, err := skill.OpenSQLStore(*postgresDSN)
		if err != nil {
			logger.Error("opening skill store", "error", err)
			os.Exit(1)
		}
		defer sqlSkills.Close()

		sqlGuilds, err := guild.OpenSQLStore(*postgresDSN)
		if err != nil {
			logger.Error("opening guild store", "error", err)
			os.Exit(1)
		}
		defer sqlGuilds.Close()

		sqlQuests, err := quest.OpenSQLStore(*postgresDSN)
		if err != nil {
			logger.Error("opening quest store", "error", err)
			os.Exit(1)
		}
		defer sqlQuests.Close()

		sqlFriends, err := friend.OpenSQLStore(*postgresDSN)
		if err != nil {
			logger.Error("opening friend store", "error", err)
			os.Exit(1)
		}
		defer sqlFriends.Close()

		accounts, registerer = sqlAccounts, sqlAccounts
		chars, refItems = sqlChars, sqlRef
		inv, eq, skills = sqlInv, sqlEq, sqlSkills
		guilds, quests, friends = sqlGuilds, sqlQuests, sqlFriends
		logger.Info("postgres storage ready")
	}

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
		session.RegisterHandler(registerer),
		// New characters are dressed server-side rather than the client
		// drawing a default set: that keeps the rendered character, the
		// equipment window, the inventory and the server all agreeing about
		// what is actually equipped.
		session.CharacterHandlerWithHook(chars, func(ctx context.Context, characterID int64) error {
			return equipment.GiveStartingKit(ctx, inv, eq, characterID)
		}),
		session.WorldHandler(chars, eq, hub),
		session.InventoryHandler(chars, inv),
		session.EquipmentHandler(chars, eq),
		session.ShopHandler(chars, shopSvc),
		session.CombatHandler(chars, eq, refItems, hub, monsters, quests, inv),
		session.LearnSkillHandler(chars, skills),
		session.UseSkillHandler(chars, eq, refItems, skills, hub, monsters, quests, inv),
		session.SkillListHandler(chars, skills),
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
