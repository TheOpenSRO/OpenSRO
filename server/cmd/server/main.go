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
	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/duel"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/friend"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/guild"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/session"
	"github.com/OpenSRO/srrevamp/server/internal/shop"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/storage"
	"github.com/OpenSRO/srrevamp/server/internal/trade"
	"github.com/OpenSRO/srrevamp/server/internal/world"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// monsterSpec describes one species of monster to keep alive somewhere in
// the world. Our own placeholder PvE content -- no real map/monster data
// exists yet. See docs/protocol/refdata_schema.md for what's still missing
// (a real drop/monster table); combat.LootTables and quest.Catalog key off
// these Names, so a new entry here should usually come with matching
// entries there too.
type monsterSpec struct {
	Zone     string
	Name     string
	CodeName string // the species' characterdata key; what the client draws it by
	Level    int    // real level, from the client's characterdata (_RefObjChar col 57)
	Rarity   int    // real rank, from characterdata (_RefObjChar col 15); 0 = normal
	MaxHP    int    // real max HP, from characterdata (_RefObjChar col 59) -- see below
	Defense  int    // real flat absorption, from characterdata col 71 -- see below
	// AttackMin/AttackMax are the real damage range of the species' primary
	// attack SKILL (characterdata col 83 -> that skill's 'att' param).
	AttackMin, AttackMax int
	// GoldMin/GoldMax are the real per-level gold range (levelgold.txt).
	GoldMin, GoldMax int64
	X, Z             float64 // own-design spawn anchor (see the roster comment)
	Count            int     // how many to keep alive around the anchor (default 1)
	// Spawns are the species' REAL placements, straight out of the client's
	// own npcpos table, as the table states them: a region id and a position
	// local to that region. When a species has these, they replace the
	// own-design anchor entirely -- one monster per real row, where the game
	// itself puts it -- and X/Z/Count are unused. worldmap.ToZoneWorld does
	// the conversion; see that package for why it is measured, not derived.
	Spawns []realSpawn
}

// realSpawn is one npcpos row, kept in the table's own terms rather than
// pre-converted, so the source stores the grounded fact and the derived world
// coordinate cannot drift away from it.
type realSpawn struct {
	RegionID       int
	LocalX, LocalZ float64
}

// monsterStatsForLevel is what is still this project's OWN DESIGN in a
// monster's combat profile: counter-attack and gold, derived from the grounded
// level. MaxHP left in 2026-09-14 (real, characterdata col 59) and DEFENCE left
// in 2026-09-15 -- both halves of it are real now:
//
//   - the flat absorption is characterdata col 71 (monsterSpec.Defense), and
//   - the percentage reduction is col 73, which is the monster's own level
//     (combat.Monster.DefensePercent).
//
// Those are the two terms of the game's own mitigation,
// `damage / (1 + pct/100) - flat`, read straight out of
// Formula_MitigatePhysicalDamage: it fetches param 5 (the flat) and param 7
// (the percentage), and GObjMob_PublishStats publishes cols 71 and 73 into
// exactly those two params.
//
// Attack and gold have no identified real table and stay a disclosed curve.
// Exp per kill is real (leveldata col 5); SP still comes from combat.SPFor.
func monsterStatsForLevel(level, rarity int) (attack int, gold int64) {
	if level < 1 {
		level = 1
	}
	attack = 4 + level*2
	gold = int64(10 + level*5)
	// A rarer rank (champion/giant/...) pays more. rarity 0 is an ordinary
	// monster; the multiplier is disclosed own design. It no longer touches
	// HP -- the real per-species MaxHP already reflects what the species is.
	if rarity > 0 {
		gold *= int64(1 + rarity)
	}
	return
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
	// The real Jangan leveling ladder. Every species' identity AND its max HP
	// are GROUNDED in the client's own characterdata (_RefObjChar): the
	// CodeName is the row's key (what the client resolves the model by, the
	// same in every archive), the Name is textdata_object's resolution of the
	// row's SN_ name key, and Level, Rarity and MaxHP are columns 57, 15 and
	// 59.
	//
	// **Col 59 = MaxHP was recovered from the binary**, not guessed. The
	// pserver's own SR_GameServer.exe carries RefObjChar::ExtractData, which
	// deserialises a row field-by-field into CRefObjChar; the struct there
	// runs `uint8 Lvl; uint8 CharGender; uint32 MaxHP; uint32 MaxMP;` at
	// offsets 0x198, 0x199, 0x19c, 0x1a0 (the two bytes then padding then two
	// dwords), and 0x19c is the field the binary asserts `m_dwMaxHP > 0` on.
	// Aligning that against the data confirms it four ways: col 57 is the
	// independently-verified Level (a byte, 1..110), col 58 is CharGender (1
	// for player men, 2 for monsters), col 59 is MaxHP and col 60 is MaxMP --
	// 0 for every monster, which is right, monsters have no mana. An earlier
	// pass had suspected col 79; that is wrong (it is 23.5*level, the same
	// value leveldata col 5 holds) and was never shipped. See
	// docs/GROUNDING_AUDIT.md.
	//
	// The HP values below are therefore the game's own. They are not
	// monotonic in level, and that is real authored design rather than noise:
	// a "_CLON" is a weaker slave version, so the level-4 Old Weasel (83) sits
	// under the level-3 Big-eyed Ghost (85).
	//
	// Defence, counter-attack and gold are still the disclosed
	// monsterStatsForLevel curve (no real table for those has been found).
	//
	// POSITIONS. Mangyang's are real -- see its entry. Every other species is
	// still OWN DESIGN, clustered at two anchors measured flat, walkable and
	// object-clear, so they stand on verified terrain rather than a blind
	// guess: (0,-840) and (340,-340), which are region 97/168 local
	// (960,1800) and (1300,1300). (Those two were described here as region
	// 96/168 until 2026-09-15; the coordinates were right and the region
	// label was wrong. worldmap's measured transform places them in 97/168,
	// the town's own region, and no local position in 96/168 maps to either.)
	//
	// Mangyang stands where the GAME puts it. npcpos -- the client's own
	// placement table, 12,367 rows across 1,451 regions -- has exactly four
	// rows in region 96/168, the farmland region immediately south of the
	// town, and all four are id 1933, which characterdata gives as
	// MOB_CH_MANGNYANG at level 1 with 54 HP: the same species and the same
	// two numbers this row already carried, arrived at independently.
	//
	// All four were measured walkable on the render box before being wired,
	// which is the whole reason they sat unused for a tick. Each column
	// reports exactly ONE surface, its landing height equal to the terrain
	// height to within 0.05, no blocking edge within 40 units, and the
	// nearest navmesh cell of any placed object 174 units away or more. That
	// is open field -- no roof, no upper storey, nothing to spawn inside.
	//
	// Their authored heights (-29.4, 0.03, -28.4, -30.5) disagree with the
	// measured terrain (-45.0, -41.4, -39.6, -51.9) by 11 to 41 units, and
	// are deliberately not carried: the client resolves standing height from
	// the region's walkable graph and ignores the authored y, so a height
	// here would be a number nothing reads.
	{Zone: "jangan", Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", Level: 1, MaxHP: 54, Defense: 7, AttackMin: 17, AttackMax: 19, GoldMin: 28, GoldMax: 59, Spawns: []realSpawn{
		{RegionID: 24744, LocalX: 1089.65, LocalZ: 600.09003},
		{RegionID: 24744, LocalX: 1842.3, LocalZ: 600.94},
		{RegionID: 24744, LocalX: 553.73999, LocalZ: 471.07001},
		{RegionID: 24744, LocalX: 1260.99, LocalZ: 22.690001},
	}},
	{Zone: "jangan", Name: "Small-eyed Ghost", CodeName: "MOB_CH_BIGEYEGHOST_CLON", Level: 2, MaxHP: 55, Defense: 9, AttackMin: 21, AttackMax: 23, GoldMin: 32, GoldMax: 66, X: -170, Z: -880, Count: 2},
	{Zone: "jangan", Name: "Big-eyed Ghost", CodeName: "MOB_CH_BIGEYEGHOST", Level: 3, MaxHP: 85, Defense: 9, AttackMin: 25, AttackMax: 29, GoldMin: 35, GoldMax: 74, X: 170, Z: -880, Count: 2},
	{Zone: "jangan", Name: "Old Weasel", CodeName: "MOB_CH_GYO_CLON", Level: 4, MaxHP: 83, Defense: 12, AttackMin: 30, AttackMax: 34, GoldMin: 39, GoldMax: 81, X: -170, Z: -760, Count: 2},
	// A higher ground east of the fields (the (340,-340) anchor):
	{Zone: "jangan", Name: "Weasel", CodeName: "MOB_CH_GYO", Level: 5, MaxHP: 119, Defense: 12, AttackMin: 35, AttackMax: 40, GoldMin: 42, GoldMax: 88, X: 340, Z: -340, Count: 3},
	{Zone: "jangan", Name: "Water Ghost slave", CodeName: "MOB_CH_WATERGHOST_CLON", Level: 6, MaxHP: 114, Defense: 15, AttackMin: 41, AttackMax: 47, GoldMin: 46, GoldMax: 96, X: 500, Z: -360, Count: 2},
	{Zone: "jangan", Name: "Water Ghost", CodeName: "MOB_CH_WATERGHOST", Level: 7, MaxHP: 156, Defense: 15, AttackMin: 47, AttackMax: 54, GoldMin: 49, GoldMax: 103, X: 340, Z: -500, Count: 2},
	{Zone: "jangan", Name: "Tomb Stone Ghost", CodeName: "MOB_CH_TOMBSTONE_CLON", Level: 8, MaxHP: 204, Defense: 15, AttackMin: 74, AttackMax: 83, GoldMin: 53, GoldMax: 110, X: 500, Z: -500, Count: 2},
	{Zone: "jangan", Name: "Stone Ghost", CodeName: "MOB_CH_STONEGHOST", Level: 9, MaxHP: 194, Defense: 22, AttackMin: 60, AttackMax: 70, GoldMin: 56, GoldMax: 118, X: 200, Z: -480, Count: 2},
	{Zone: "jangan", Name: "Yeoha", CodeName: "MOB_CH_YEOHA", Level: 10, MaxHP: 249, Defense: 22, AttackMin: 67, AttackMax: 79, GoldMin: 60, GoldMax: 125, X: 200, Z: -220, Count: 2},
	// The donghwang example kept from before (a far, higher-level zone).
	{Zone: "donwhang", Name: "Earth Ghost", CodeName: "MOB_WC_EARTHGHOST", Level: 27, MaxHP: 1451, Defense: 103, AttackMin: 219, AttackMax: 261, GoldMin: 119, GoldMax: 250, X: 70, Z: -50, Count: 1},
}

const respawnDelay = 10 * time.Second

// maintainMonster keeps exactly one instance of spec's species alive in its
// zone, respawning it respawnDelay after each death, until ctx is
// canceled. main() runs one of these per monsterSpecs entry.
func maintainMonster(ctx context.Context, monsters *combat.Hub, logger *slog.Logger, spec monsterSpec) {
	attack, gold := monsterStatsForLevel(spec.Level, spec.Rarity)
	// Real flat absorption from characterdata col 71. A spec that forgot it
	// falls back to the old disclosed curve rather than spawning a monster
	// with no defence at all.
	defense := spec.Defense
	if defense < 1 {
		defense = 1 + spec.Level/3
	}
	// Real HP from characterdata col 59 (see monsterSpecs). A spec that
	// forgot it would otherwise spawn a 0-HP monster that dies on sight.
	maxHP := spec.MaxHP
	if maxHP < 1 {
		maxHP = 1
	}
	spawn := func() int64 {
		m := monsters.SpawnSpecies(spec.Zone, combat.Species{Name: spec.Name, CodeName: spec.CodeName, Level: spec.Level, Rarity: spec.Rarity,
			AttackMin: spec.AttackMin, AttackMax: spec.AttackMax,
			GoldMin: spec.GoldMin, GoldMax: spec.GoldMax}, spec.X, 0, spec.Z, maxHP, defense, attack, gold)
		logger.Info("monster spawned", "id", m.ID, "name", m.Name, "zone", m.Zone, "level", m.Level)
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
	GetSkill(ctx context.Context, id int64) (*refdata.Skill, error)
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
	leveldataCSV := flag.String("leveldata-csv", os.Getenv("SRREVAMP_LEVELDATA_CSV"),
		"path to a level,exp CSV (generated by cmd/export-leveldata from a client's own "+
			"leveldata.txt); enables EXP/leveling. Without it, characters never level.")
	skillsCSV := flag.String("skills-csv", os.Getenv("SRREVAMP_SKILLS_CSV"),
		"path to a skill-refdata CSV (from cmd/export-refdata -mode skills); with -in-memory it "+
			"lets the server gate learning on real skills. With PostgreSQL, import it via "+
			"cmd/import-refdata instead. Without either, learning real skills is unavailable.")
	itemsCSV := flag.String("items-csv", os.Getenv("SRREVAMP_ITEMS_CSV"),
		"path to an item-refdata CSV (from cmd/export-refdata -mode items); with -in-memory it "+
			"feeds the shop catalogue and prices, item stat lookups and inventory stack limits. "+
			"With PostgreSQL, import it via cmd/import-refdata instead. Without either, the shop "+
			"has no items to sell.")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	// Install the EXP curve if the operator provided one. Game data, so never
	// committed -- see docs/LEVELING.md.
	if *leveldataCSV != "" {
		f, err := os.Open(*leveldataCSV)
		if err != nil {
			logger.Error("opening leveldata CSV", "path", *leveldataCSV, "error", err)
			os.Exit(1)
		}
		table, err := leveldata.ParseCSV(f)
		f.Close()
		if err != nil {
			logger.Error("parsing leveldata CSV", "path", *leveldataCSV, "error", err)
			os.Exit(1)
		}
		session.SetLevelTable(table)
		logger.Info("loaded EXP curve", "path", *leveldataCSV, "maxLevel", table.MaxLevel())
	} else {
		logger.Info("no leveldata CSV set (SRREVAMP_LEVELDATA_CSV) -- characters will not level")
	}

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
		warehouse  inventory.Store // the storage NPC's container (a 2nd inventory)
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
		if *skillsCSV != "" {
			f, err := os.Open(*skillsCSV)
			if err != nil {
				logger.Error("opening skills CSV", "error", err)
				os.Exit(1)
			}
			sk, err := refdata.LoadSkillsCSV(f)
			f.Close()
			if err != nil {
				logger.Error("parsing skills CSV", "error", err)
				os.Exit(1)
			}
			if err := memRef.ImportSkills(context.Background(), sk); err != nil {
				logger.Error("importing skills", "error", err)
				os.Exit(1)
			}
			logger.Info("loaded skill refdata for learning", "skills", len(sk))
		}
		if *itemsCSV != "" {
			f, err := os.Open(*itemsCSV)
			if err != nil {
				logger.Error("opening items CSV", "error", err)
				os.Exit(1)
			}
			it, err := refdata.LoadItemsCSV(f)
			f.Close()
			if err != nil {
				logger.Error("parsing items CSV", "error", err)
				os.Exit(1)
			}
			if err := memRef.ImportItems(context.Background(), it); err != nil {
				logger.Error("importing items", "error", err)
				os.Exit(1)
			}
			logger.Info("loaded item refdata for the shop", "items", len(it))
		}
		memInv := inventory.NewMemStore(memRef)
		memAccounts := account.NewMemStore()
		accounts, registerer = memAccounts, memAccounts
		chars = character.NewMemStore()
		refItems = memRef
		inv = memInv
		warehouse = inventory.NewMemStore(memRef) // a second, independent container
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

		// The warehouse is a second inventory container on its own table.
		sqlWarehouse, err := inventory.OpenSQLStoreNamed(*postgresDSN, sqlRef, "storage_slots")
		if err != nil {
			logger.Error("opening warehouse store", "error", err)
			os.Exit(1)
		}
		defer sqlWarehouse.Close()

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
		warehouse = sqlWarehouse
		inv, eq, skills = sqlInv, sqlEq, sqlSkills
		guilds, quests, friends = sqlGuilds, sqlQuests, sqlFriends
		logger.Info("postgres storage ready")
	}

	shopSvc := &shop.Service{Gold: chars, Inv: inv, Items: refItems}
	storageSvc := &storage.Service{Bag: inv, Warehouse: warehouse, Gold: chars}
	zerkTracker := berserk.NewTracker()
	manaTracker := mana.NewTracker()

	hub := world.NewHub()
	monsters := combat.NewHub()
	parties := party.NewHub()
	duels := duel.NewHub()
	trades := trade.NewHub()
	for _, spec := range monsterSpecs {
		// A species with real npcpos placements gets one monster per real
		// row, where the game itself puts it. No spread: these are already
		// the authored positions, and nudging them would throw away the only
		// part of this that is grounded.
		if len(spec.Spawns) > 0 {
			placed := 0
			for _, s := range spec.Spawns {
				rx, ry := worldmap.RegionXY(s.RegionID)
				x, z, ok := worldmap.ToZoneWorld(spec.Zone, rx, ry, s.LocalX, s.LocalZ)
				if !ok {
					// The zone's own centre region is what world coordinates
					// are relative to; without it there is no frame to convert
					// into, and placing the monster at the local position
					// would silently put it somewhere arbitrary.
					logger.Warn("real spawn skipped: zone has no known centre region",
						"zone", spec.Zone, "name", spec.Name, "region", s.RegionID)
					continue
				}
				inst := spec
				inst.X, inst.Z = x, z
				go maintainMonster(ctx, monsters, logger, inst)
				placed++
			}
			if placed > 0 {
				continue
			}
			// Nothing converted. Fall through to the own-design anchor rather
			// than leaving the species out of the world entirely.
			logger.Warn("no real spawn converted, falling back to the anchor", "name", spec.Name)
		}
		count := spec.Count
		if count < 1 {
			count = 1
		}
		// Spread a species' instances around its anchor on a small deterministic
		// grid (so respawns land back in place) -- a cluster, not a stack. ~130
		// units apart, well over a monster's ~77-unit capsule.
		for i := 0; i < count; i++ {
			inst := spec
			inst.X += float64((i%3)-1) * 130.0
			inst.Z += float64(i/3) * 130.0
			go maintainMonster(ctx, monsters, logger, inst)
		}
	}

	handle := gateway.Chain(
		session.LoginHandler(accounts),
		session.RegisterHandler(registerer),
		// New characters are dressed server-side rather than the client
		// drawing a default set: that keeps the rendered character, the
		// equipment window, the inventory and the server all agreeing about
		// what is actually equipped.
		session.CharacterHandlerWithHook(chars, func(ctx context.Context, characterID int64) error {
			gender := character.DefaultGender
			if c, err := chars.GetByID(ctx, characterID); err == nil {
				gender = c.Gender
			}
			return equipment.GiveStartingKit(ctx, inv, eq, characterID, gender)
		}),
		// A character made before the starting kit existed enters the world
		// with nothing on and nothing in the bag; it is dressed on the way
		// in. Only that case: a character who has taken everything off and
		// emptied the bag looks the same, and gets a kit too, which is the
		// cheaper mistake on a test server.
		session.WorldHandlerWithHook(chars, eq, hub, func(ctx context.Context, c *character.Character) error {
			worn, err := eq.Get(ctx, c.ID)
			if err != nil || len(worn) > 0 {
				return err
			}
			bag, err := inv.List(ctx, c.ID)
			if err != nil || len(bag) > 0 {
				return err
			}
			logger.Info("dressing a character that had nothing", "character", c.Name)
			return equipment.GiveStartingKit(ctx, inv, eq, c.ID, c.Gender)
		}),
		session.InventoryHandler(chars, inv),
		session.EquipmentHandlerWithRules(chars, eq, inv, refItems),
		session.CharacterStatsHandler(chars, eq, refItems, skills, manaTracker),
		session.ShopHandler(chars, shopSvc),
		session.StorageHandler(chars, storageSvc),
		session.UseItemHandler(chars, inv, refItems, manaTracker),
		session.CombatHandler(chars, eq, refItems, hub, monsters, quests, inv, skills, zerkTracker, manaTracker),
		session.LearnSkillHandler(chars, skills, refItems),
		session.UseSkillHandler(chars, eq, refItems, skills, hub, monsters, quests, inv, refItems, zerkTracker, manaTracker),
		session.SkillListHandler(chars, skills),
		session.SkillStateHandler(chars, skills),
		session.RaiseMasteryHandler(chars, skills),
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
