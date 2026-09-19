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
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/grounditem"
	"github.com/OpenSRO/srrevamp/server/internal/guild"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/rates"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/session"
	"github.com/OpenSRO/srrevamp/server/internal/shop"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/spawn"
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
	// RefObjID is the species' numeric characterdata id -- the key npcpos.txt
	// places monsters by (its rows carry ids, not code names). Read from the
	// retail table 2026-09-19 for the roster; a spec without one cannot take
	// real placements from -npcpos-csv and keeps its anchor.
	RefObjID int64
	Level    int // real level, from the client's characterdata (_RefObjChar col 57)
	Rarity   int // real rank, from characterdata (_RefObjChar col 15); 0 = normal
	MaxHP    int // real max HP, from characterdata (_RefObjChar col 59) -- see below
	Defense  int // real flat absorption, from characterdata col 71 -- see below
	// BCRadius is the species' collision radius, characterdata col 50, read
	// from the retail table 2026-09-19 (round 247): Mangyang/Bigeye/Water
	// Ghost 6, Gyo/Stone Ghost 10, Yeoha 11, Tomb Stone/Earth Ghost 4. It is
	// half the base of the attack-distance rule (combat.ApproachBand); a spec
	// without one gets the 4 every playable body row carries -- the table's
	// most common monster value too (5,644 of the rows).
	BCRadius int
	// AttackMin/AttackMax are the real damage range of the species' primary
	// attack SKILL (characterdata col 83 -> that skill's 'att' param).
	AttackMin, AttackMax int
	// GoldMin/GoldMax are the real per-level gold range (levelgold.txt).
	GoldMin, GoldMax int64
	// Critical is the species' real critical-hit chance, characterdata col 78.
	// The game reads 2 on 7,493 of its 7,495 monster rows, so it is effectively
	// a constant -- but it is carried per-species rather than hardcoded,
	// because the two rows that differ (0 and 20) prove it is a real column
	// and not a shared default.
	Critical int
	X, Z     float64 // own-design spawn anchor (see the roster comment)
	Count    int     // how many to keep alive around the anchor (default 1)
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

// monsterStatsForLevel is the FALLBACK half of a monster's combat profile:
// a flat counter-attack and a flat gold reward derived from the grounded
// level, used only for a species whose real numbers are missing. In the live
// table every species has them -- AttackMin/AttackMax from its primary
// attack skill (characterdata col 83 -> that skill's 'att' param) and
// GoldMin/GoldMax from levelgold.txt -- so this curve does not decide a fight
// on the public server; it exists so a species added without them still
// fights. (An older version of this comment said attack and gold "have no
// identified real table"; they do, see combat.Monster.) MaxHP left in
// 2026-09-14 (real, characterdata col 59) and DEFENCE left in 2026-09-15 --
// both halves of it are real now:
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
// The curve itself stays disclosed own design, as a fallback. Exp per kill is
// real (leveldata col 5); SP still comes from combat.SPFor.
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
// VERIFIED 2026-09-16 against the client's own tables, not just asserted:
// client/tools/verify_monster_specs.py re-derives every number below and
// reports 55 verified, 0 mismatched. That covers the four copied columns
// (Level 57, MaxHP 59, Defense 71, Critical 78) for all 11 species, and the one
// genuinely DERIVED value -- the attack range, which is two hops:
// characterdata column 83 names a SKILL and that skill's 'att' parameter
// carries the range. The skill names corroborate the chain on their own
// (MOB_CH_MANGNYANG's column 83 resolves to MSKILL_CH_MANGNYANG_ATTACK01).
//
// "Grounded" is a claim about provenance, and provenance rots -- a
// transcription slip or an upstream column shift leaves the comment saying
// "real" while the number drifts. Re-run the verifier on the RE box after
// touching this table.
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
	{Zone: "jangan", Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", RefObjID: 1933, Level: 1, BCRadius: 6, Critical: 2, MaxHP: 54, Defense: 7, AttackMin: 17, AttackMax: 19, GoldMin: 28, GoldMax: 59, Spawns: []realSpawn{
		{RegionID: 24744, LocalX: 1089.65, LocalZ: 600.09003},
		{RegionID: 24744, LocalX: 1842.3, LocalZ: 600.94},
		{RegionID: 24744, LocalX: 553.73999, LocalZ: 471.07001},
		{RegionID: 24744, LocalX: 1260.99, LocalZ: 22.690001},
	}},
	{Zone: "jangan", Name: "Small-eyed Ghost", CodeName: "MOB_CH_BIGEYEGHOST_CLON", RefObjID: 1934, Level: 2, BCRadius: 6, Critical: 2, MaxHP: 55, Defense: 9, AttackMin: 21, AttackMax: 23, GoldMin: 32, GoldMax: 66, X: -170, Z: -880, Count: 2},
	{Zone: "jangan", Name: "Big-eyed Ghost", CodeName: "MOB_CH_BIGEYEGHOST", RefObjID: 1935, Level: 3, BCRadius: 6, Critical: 2, MaxHP: 85, Defense: 9, AttackMin: 25, AttackMax: 29, GoldMin: 35, GoldMax: 74, X: 170, Z: -880, Count: 2},
	{Zone: "jangan", Name: "Old Weasel", CodeName: "MOB_CH_GYO_CLON", RefObjID: 1936, Level: 4, BCRadius: 10, Critical: 2, MaxHP: 83, Defense: 12, AttackMin: 30, AttackMax: 34, GoldMin: 39, GoldMax: 81, X: -170, Z: -760, Count: 2},
	// A higher ground east of the fields (the (340,-340) anchor):
	{Zone: "jangan", Name: "Weasel", CodeName: "MOB_CH_GYO", RefObjID: 1937, Level: 5, BCRadius: 10, Critical: 2, MaxHP: 119, Defense: 12, AttackMin: 35, AttackMax: 40, GoldMin: 42, GoldMax: 88, X: 340, Z: -340, Count: 3},
	{Zone: "jangan", Name: "Water Ghost slave", CodeName: "MOB_CH_WATERGHOST_CLON", RefObjID: 1938, Level: 6, BCRadius: 6, Critical: 2, MaxHP: 114, Defense: 15, AttackMin: 41, AttackMax: 47, GoldMin: 46, GoldMax: 96, X: 500, Z: -360, Count: 2},
	{Zone: "jangan", Name: "Water Ghost", CodeName: "MOB_CH_WATERGHOST", RefObjID: 1939, Level: 7, BCRadius: 6, Critical: 2, MaxHP: 156, Defense: 15, AttackMin: 47, AttackMax: 54, GoldMin: 49, GoldMax: 103, X: 340, Z: -500, Count: 2},
	{Zone: "jangan", Name: "Tomb Stone Ghost", CodeName: "MOB_CH_TOMBSTONE_CLON", RefObjID: 1950, Level: 8, BCRadius: 4, Critical: 2, MaxHP: 204, Defense: 15, AttackMin: 74, AttackMax: 83, GoldMin: 53, GoldMax: 110, X: 500, Z: -500, Count: 2},
	{Zone: "jangan", Name: "Stone Ghost", CodeName: "MOB_CH_STONEGHOST", RefObjID: 1941, Level: 9, BCRadius: 10, Critical: 2, MaxHP: 194, Defense: 22, AttackMin: 60, AttackMax: 70, GoldMin: 56, GoldMax: 118, X: 200, Z: -480, Count: 2},
	{Zone: "jangan", Name: "Yeoha", CodeName: "MOB_CH_YEOHA", RefObjID: 1943, Level: 10, BCRadius: 11, Critical: 2, MaxHP: 249, Defense: 22, AttackMin: 67, AttackMax: 79, GoldMin: 60, GoldMax: 125, X: 200, Z: -220, Count: 2},
	// The donghwang example kept from before (a far, higher-level zone).
	{Zone: "donwhang", Name: "Earth Ghost", CodeName: "MOB_WC_EARTHGHOST", RefObjID: 1963, Level: 27, BCRadius: 4, Critical: 2, MaxHP: 1451, Defense: 103, AttackMin: 219, AttackMax: 261, GoldMin: 119, GoldMax: 250, X: 70, Z: -50, Count: 1},
}

// respawnDelay is DISCLOSED, own design. The real game respawns per NEST
// (`_RefNest`, a server-only table): each nest keeps up to its alive cap of
// monsters, and when a full nest loses one, a timer armed at that death runs
// for a delay drawn uniformly between the nest row's two delay columns (in
// seconds, re-rolled every hatch) before one monster hatches per scheduler
// pass -- read off AIHive_HatchPass / NestSlot_RollHatchDelay, round 239,
// docs/protocol/monster_ai.md. The client's npcpos.txt carries only the
// nests' ids and positions, so the window itself is data this project does
// not hold; 10 s stands in for it.
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
		bc := spec.BCRadius
		if bc == 0 {
			bc = combat.PlayerBCRadius
		}
		m := monsters.SpawnSpecies(spec.Zone, combat.Species{Name: spec.Name, CodeName: spec.CodeName, Level: spec.Level, Rarity: spec.Rarity, BCRadius: bc,
			AttackMin: spec.AttackMin, AttackMax: spec.AttackMax,
			GoldMin: spec.GoldMin, GoldMax: spec.GoldMax, Critical: spec.Critical}, spec.X, 0, spec.Z, maxHP, defense, attack, gold)
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

// gmSpecies converts the running monster roster into the species the GM
// console's /spawn and /goto know, with the same stats maintainMonster
// hands a live spawn (monsterStatsForLevel plus the roster's own real HP,
// defence and gold). Its go-to spot is the species' first real npcpos
// placement in world coordinates when it has one, else the own-design
// anchor -- so /goto lands where the server actually keeps the monster.
func gmSpecies() []gm.Species {
	out := make([]gm.Species, 0, len(monsterSpecs))
	for _, spec := range monsterSpecs {
		attack, gold := monsterStatsForLevel(spec.Level, spec.Rarity)
		defense := spec.Defense
		if defense < 1 {
			defense = 1 + spec.Level/3
		}
		maxHP := spec.MaxHP
		if maxHP < 1 {
			maxHP = 1
		}
		x, z := spec.X, spec.Z
		if len(spec.Spawns) > 0 {
			s := spec.Spawns[0]
			rx, ry := worldmap.RegionXY(s.RegionID)
			if wx, wz, ok := worldmap.ToZoneWorld(spec.Zone, rx, ry, s.LocalX, s.LocalZ); ok {
				x, z = wx, wz
			}
		}
		out = append(out, gm.Species{
			Species: combat.Species{
				Name: spec.Name, CodeName: spec.CodeName, Level: spec.Level, Rarity: spec.Rarity,
				AttackMin: spec.AttackMin, AttackMax: spec.AttackMax,
				GoldMin: spec.GoldMin, GoldMax: spec.GoldMax, Critical: spec.Critical,
			},
			Zone: spec.Zone, MaxHP: maxHP, Defense: defense, Attack: attack, Gold: gold, X: x, Z: z,
		})
	}
	return out
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
	npcposCSV := flag.String("npcpos-csv", os.Getenv("SRREVAMP_NPCPOS_CSV"),
		"path to the game's monster placements (from cmd/export-refdata -mode npcpos on a client's "+
			"own npcpos.txt). Every roster species with rows in it stands where the game puts it; "+
			"without the file the species keep their own-design anchors near the town.")
	itemsCSV := flag.String("items-csv", os.Getenv("SRREVAMP_ITEMS_CSV"),
		"path to an item-refdata CSV (from cmd/export-refdata -mode items); with -in-memory it "+
			"feeds the shop catalogue and prices, item stat lookups and inventory stack limits. "+
			"With PostgreSQL, import it via cmd/import-refdata instead. Without either, the shop "+
			"has no items to sell.")
	gmAccounts := flag.String("gm-accounts", os.Getenv("SRREVAMP_GM_ACCOUNTS"),
		"comma-separated account usernames allowed to run GM commands (env SRREVAMP_GM_ACCOUNTS). "+
			"Case is compared as stored in accounts.username. Default none: nobody is a GM. See "+
			"docs/DEBUG_TOOLS.md.")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))

	// Install the EXP curve if the operator provided one. Game data, so never
	// committed -- see docs/LEVELING.md. Kept in scope so the GM console's
	// /level can use the same table.
	var levelTable *leveldata.Table
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
		levelTable = table
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
		warehouse  inventory.Store // the storage NPC's container (a 2nd inventory), owned by the ACCOUNT
		// The warehouse gold, kept per account as the game keeps it
		// (accounts.storage_gold; see internal/storage).
		storageGold account.StorageGoldStore
		eq          equipment.Store
		skills      skill.Store
		guilds      guild.Store
		quests      quest.Store
		friends     friend.Store
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
		// The item table also says which items have a durability and its
		// range, so every fresh grant rolls its instance (durability.md).
		memInv.SetDurabilityLookup(memRef)
		memAccounts := account.NewMemStore()
		accounts, registerer = memAccounts, memAccounts
		storageGold = memAccounts
		chars = character.NewMemStore()
		refItems = memRef
		inv = memInv
		memWarehouse := inventory.NewMemStore(memRef) // a second, independent container, keyed by account id
		memWarehouse.SetDurabilityLookup(memRef)
		memWarehouse.SetCapacity(storage.DefaultCapacity)
		warehouse = memWarehouse
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

		// Say at boot what reference data the database actually holds. The
		// public test server ran for a week with every one of these at zero --
		// no weapon stats, so every hit did the placeholder 1; no skills to
		// learn; no drops -- and nothing in the log said so, because unlike
		// leveldata (a CSV flag that warns when unset) these come from tables
		// the operator fills with cmd/import-refdata. An empty items table is
		// worth a warning in the same breath as the missing EXP curve.
		{
			ctx := context.Background()
			items, _ := sqlRef.Count(ctx)
			skills, _ := sqlRef.CountSkills(ctx)
			drops, _ := sqlRef.CountMonsterDrops(ctx)
			groups, _ := sqlRef.CountDropGroupEntries(ctx)
			logger.Info("reference data in PostgreSQL", "items", items, "skills", skills,
				"monsterDrops", drops, "dropGroupEntries", groups)
			if items == 0 {
				logger.Warn("items table is EMPTY -- weapons have no stats and the shop sells nothing; " +
					"export the client's itemdata with cmd/export-refdata and load it with cmd/import-refdata " +
					"(see docs/HANDOFF_OPENSRO.md, 'Where the server actually is today')")
			}
		}

		sqlInv, err := inventory.OpenSQLStore(*postgresDSN, sqlRef)
		if err != nil {
			logger.Error("opening inventory store", "error", err)
			os.Exit(1)
		}
		defer sqlInv.Close()
		sqlInv.SetDurabilityLookup(sqlRef)

		// The warehouse is a second inventory container on its own table,
		// owned by the ACCOUNT (the game's `_CHEST WHERE UserJID=%d`; see
		// internal/storage). A database written by the older per-character
		// server is moved over once, losslessly, before anything opens it.
		sqlWarehouse, err := inventory.OpenSQLStoreOwned(*postgresDSN, sqlRef, inventory.WarehouseTable, inventory.WarehouseOwnerColumn)
		if err != nil {
			logger.Error("opening warehouse store", "error", err)
			os.Exit(1)
		}
		defer sqlWarehouse.Close()
		sqlWarehouse.SetDurabilityLookup(sqlRef)
		sqlWarehouse.SetCapacity(storage.DefaultCapacity)
		storageGold = sqlAccounts
		if moved, err := storage.MigrateToAccounts(ctx, sqlWarehouse.DB(), logger); err != nil {
			logger.Error("moving the warehouse to accounts", "error", err)
			os.Exit(1)
		} else if moved.Applied {
			logger.Info("warehouse moved from characters to accounts",
				"rows", moved.Rows, "reslotted", moved.Reslotted, "gold", moved.Gold,
				"characters", moved.Characters, "accounts", moved.Accounts, "orphanRowsLeft", moved.Orphans)
		}

		sqlEq, err := equipment.OpenSQLStore(*postgresDSN, sqlInv)
		if err != nil {
			logger.Error("opening equipment store", "error", err)
			os.Exit(1)
		}
		defer sqlEq.Close()
		// Worn rows written before durability existed get their instance on
		// first read, with the same roll a fresh bag item gets.
		sqlEq.SetFreshInstanceRoller(func(ctx context.Context, itemID int64) (inventory.Instance, error) {
			return inventory.FreshInstance(ctx, sqlRef, nil, itemID)
		})

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
	storageSvc := &storage.Service{Bag: inv, Warehouse: warehouse, Gold: chars, Accounts: storageGold}
	zerkTracker := berserk.NewTracker()
	manaTracker := mana.NewTracker()

	hub := world.NewHub()
	monsters := combat.NewHub()
	// Items on the ground: what a kill leaves near the corpse until it is
	// picked up (internal/grounditem). The sweep releases ownerships after the
	// 30 s window and removes stale items, telling each zone.
	ground := grounditem.NewHub()
	// Each drop lies there for its own row's DecayTime (itemdata column 13);
	// an item without one gets grounditem.FallbackLifetime.
	ground.SetDecayLookup(func(itemID int64) int {
		it, err := refItems.GetItem(ctx, itemID)
		if err != nil || it == nil {
			return 0
		}
		return it.DecayTimeMs
	})
	go session.RunGroundItemSweep(ctx, ground, hub)
	// The server's own gain multipliers, under the game's knob names. All
	// default to 1x, and the engine's floor means a server cannot be
	// configured slower than retail -- see internal/rates.
	rates.Set(rates.FromEnv())
	if r := rates.Current(); r != rates.Default() {
		logger.Info("rates configured",
			"exp", r.Exp, "party_exp", r.PartyExp, "gold", r.Gold,
			"drop_item", r.DropItem, "hwan_gain", r.HwanGain)
	}

	parties := party.NewHub()
	duels := duel.NewHub()
	trades := trade.NewHub()
	// The game's own placements, when the operator supplies them: every
	// species with rows takes them all, replacing both the embedded rows and
	// the own-design anchor. A configured path that does not load is fatal
	// rather than a silent fall-back to the anchors.
	if *npcposCSV != "" {
		table, err := spawn.LoadCSV(*npcposCSV)
		if err != nil {
			logger.Error("loading npcpos placements", "path", *npcposCSV, "err", err)
			os.Exit(1)
		}
		applied := 0
		for i := range monsterSpecs {
			rows := table.Rows(monsterSpecs[i].RefObjID)
			if len(rows) == 0 {
				continue
			}
			real := make([]realSpawn, 0, len(rows))
			for _, r := range rows {
				real = append(real, realSpawn{RegionID: r.RegionID, LocalX: r.LocalX, LocalZ: r.LocalZ})
			}
			monsterSpecs[i].Spawns = real
			applied++
		}
		logger.Info("npcpos placements loaded", "species_in_table", len(table), "roster_species_placed", applied)
	}
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

	// The GM console (docs/DEBUG_TOOLS.md). The gate is the account-username
	// list; the deps are the same stores every other handler uses, so a GM
	// command is those stores' own methods and nothing more. The species and
	// zones a GM can name are built from the running roster and the world map.
	gmGate := gm.ParseAccounts(*gmAccounts)
	if names := gmGate.Names(); len(names) > 0 {
		logger.Info("GM accounts enabled", "accounts", names)
	} else {
		logger.Info("no GM accounts set (-gm-accounts / SRREVAMP_GM_ACCOUNTS) -- the GM console is off")
	}
	gmDeps := &gm.Deps{
		Chars: chars, Inv: inv, Equip: eq, Items: refItems, Skills: skills,
		Monsters: monsters, Mana: manaTracker, Levels: levelTable,
		Species: gmSpecies(), Zones: worldmap.ZoneNames(), Logger: logger,
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
		session.InventoryHandler(chars, inv, refItems),
		session.InventoryMoveHandler(chars, inv, refItems),
		session.EquipmentHandlerWithRules(chars, eq, inv, refItems),
		session.CharacterStatsHandler(chars, eq, refItems, skills, manaTracker),
		session.SpendStatPointsHandler(chars, eq, refItems, skills, manaTracker),
		session.GMCommandHandler(chars, gmGate, gmDeps, hub, logger),
		session.ShopHandler(chars, shopSvc),
		session.RepairHandler(chars, eq, refItems),
		session.StorageHandler(chars, storageSvc),
		session.UseItemHandler(chars, inv, refItems, manaTracker),
		session.CombatHandlerWithGround(chars, eq, refItems, hub, monsters, quests, inv, skills, zerkTracker, manaTracker, parties, ground),
		session.GroundItemHandler(chars, hub, ground, inv, parties),
		session.LearnSkillHandler(chars, skills, refItems),
		session.UseSkillHandlerWithGround(chars, eq, refItems, skills, hub, monsters, quests, inv, refItems, zerkTracker, manaTracker, parties, ground),
		session.SkillListHandler(chars, skills),
		session.SkillStateHandler(chars, skills),
		session.RaiseMasteryHandler(chars, skills),
		session.PartyHandler(chars, parties),
		session.GuildHandler(chars, guilds),
		session.ChatHandler(hub),
		session.QuestHandler(chars, quests),
		session.DuelHandler(chars, eq, refItems, hub, duels),
		session.TradeHandler(chars, inv, refItems, hub, trades),
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
