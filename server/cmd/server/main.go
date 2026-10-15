package main

import (
	"context"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log/slog"
	"math/rand"
	"os"
	"os/signal"
	"path/filepath"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/ai"
	"github.com/OpenSRO/OpenSRO/server/internal/berserk"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/duel"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/friend"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/gm"
	"github.com/OpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/OpenSRO/OpenSRO/server/internal/guild"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/OpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/nest"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/rates"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/safezone"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/shop"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/spawn"
	"github.com/OpenSRO/OpenSRO/server/internal/species"
	"github.com/OpenSRO/OpenSRO/server/internal/storage"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/txn"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldclock"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
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
	// WalkSpeed/RunSpeed are the species' Speed1/Speed2, characterdata cols 46
	// and 47, in world units per second: the engine publishes them as
	// ParamKeeper params 23/24 (docs/protocol/param_registry.md), and its mover
	// multiplies the object's speed (+0x174) by seconds
	// (CGObjMoverByDest::FUN_0048bff0). Read by RefObjID from the retail
	// characterdata_5000.txt, with the Level (57), MaxHP (59) and BCRadius (50)
	// columns of the same rows matching this roster as the control: round 362's
	// table in docs/protocol/monster_ai.md ("The roster's real walk and run
	// speeds"), re-read on the RE box 2026-09-23 and re-checked by
	// client/tools/verify_monster_specs.py in round 536. The monster AI tick
	// walks and runs them (-monster-ai, off by default; round 537).
	WalkSpeed, RunSpeed float64
	// A NEW SPECIES NEEDS ITS ATTACK AND PARRY RATES CHECKED. combat.MonsterRate
	// computes both as 2*level + 25, which every one of the eleven species below
	// matches exactly -- but that is a regularity of the low-level China
	// monsters here, not a law of the table: it holds for only ~37 % of the
	// retail characterdata's monster rows (round 380). Read cols 75 and 77 for
	// the new row. Col 76 ('bri', blocking) is 0 for all eleven and non-zero on
	// 939 rows table-wide, so a blocking species also needs a mechanic OpenSRO
	// does not have yet.
	// AttackReuseMs / AttackRange are the primary attack skill's ReuseDelay
	// and Range (characterdata col 83 -> skilldata columns 14 and 21), read
	// from the retail tables 2026-09-19 (round 254): the monster cannot strike
	// more often than that. See combat.Species.
	AttackReuseMs int
	AttackRange   int
	// AttackMin/AttackMax are the real damage range of the species' primary
	// attack SKILL (characterdata col 83 -> that skill's 'att' param).
	AttackMin, AttackMax int
	// Skills is every attack skill the species carries, characterdata cols
	// 83..92 in column order (AI::CTactics::BindSkillsAndRanges 0x53f951..
	// 0x53f98a registers the ten dwords at RefObjChar+0x260), each with its
	// skilldata row's ReuseDelay (col 14), Range (col 21), 'att' min/max and
	// AI_AttackChance (col 66) -- read from the retail tables on the RE box
	// 2026-09-25 (round 554) and re-derived by verify_monster_specs.py. The
	// first is the col-83 skill, whose numbers AttackReuseMs, AttackRange,
	// AttackMin and AttackMax also carry (TestRosterSkillsLeadWithThePrimary
	// holds the two equal). Four species carry a second: Mangyang 161,
	// Water Ghost slave 167, Water Ghost 169, Yeoha 177; the other seven
	// have col 84 = 0. With -monster-battle on, BATTLE draws each swing
	// between them by AI_AttackChance and reach (ai.PickSkill).
	Skills []combat.MonsterSkill
	// GoldMin/GoldMax are the real per-level gold range (levelgold.txt).
	GoldMin, GoldMax int64
	// ExpToGive is characterdata col 79, the kill's base EXP (round 712,
	// species.ColExpToGive); HasExpToGive is false without the column.
	ExpToGive    int64
	HasExpToGive bool
	// Knockdown / KORecoverMs are characterdata cols 81/82 (round 785,
	// species.ColKnockdown); HasKnockdown is false without them.
	Knockdown    int
	KORecoverMs  int
	HasKnockdown bool
	// Critical is the species' real critical-hit chance, characterdata col 78.
	// The game reads 2 on 7,493 of its 7,495 monster rows, so it is effectively
	// a constant -- but it is carried per-species rather than hardcoded,
	// because the two rows that differ (0 and 20) prove it is a real column
	// and not a shared default.
	Critical int
	// Block is the species' block chance, characterdata col 76 ('bri',
	// param 10): 0 for all eleven roster species (READ, so it is not typed
	// below), 20 on 938 other monster rows. The species table (round 654)
	// carries it for every species, but combatSpeciesOf does NOT hand it to
	// combat yet: docs/TODO.md's "A blocked hit with a skill percentage deals
	// 1, not 0" is to be fixed before any spawned monster blocks.
	Block int
	X, Z  float64 // own-design spawn anchor (see the roster comment)
	Count int     // how many to keep alive around the anchor (default 1)
	// Spawns are the species' REAL placements, straight out of the client's
	// own npcpos table, as the table states them: a region id and a position
	// local to that region. When a species has these, they replace the
	// own-design anchor entirely -- one monster per real row, where the game
	// itself puts it -- and X/Z/Count are unused. worldmap.ToZoneWorld does
	// the conversion; see that package for why it is measured, not derived.
	Spawns []realSpawn
}

// teleportObjectPlaces records, on the teleport network, where each teleport
// NPC stands -- its npcpos rows -- for the interaction range (round 642's
// review; teleport.Table.ObjectPlaces, session's reach). Gate structures carry
// their own place in teleportbuilding. Returns how many NPCs were placed; none
// without an npcpos table.
func teleportObjectPlaces(network *teleport.Table, npcs spawn.Table) int {
	if network == nil || npcs == nil {
		return 0
	}
	placed := 0
	for _, p := range network.Points {
		if _, isBuilding := network.BuildingByID(p.ObjectID); p.ObjectID == 0 || isBuilding {
			continue
		}
		rows := npcs.Rows(int64(p.ObjectID))
		if len(rows) == 0 {
			continue
		}
		places := make([]teleport.Place, 0, len(rows))
		for _, r := range rows {
			places = append(places, teleport.Place{Region: r.RegionID, X: r.LocalX, Y: r.LocalY, Z: r.LocalZ})
		}
		network.SetObjectPlaces(p.ObjectID, places)
		placed++
	}
	return placed
}

// realSpawn is one npcpos row, kept in the table's own terms rather than
// pre-converted, so the source stores the grounded fact and the derived world
// coordinate cannot drift away from it.
type realSpawn struct {
	RegionID       int
	LocalX, LocalZ float64
}

// realSpawnWorld is where a real npcpos row stands in its zone's world: the
// row converted against the zone's centre region (worldmap.ZoneCentre), the
// frame the client builds that zone's grid in. The spawn loop in main and
// gmSpecies both place through it, so a moved centre (round 569: donwhang
// 98/157 -> 102/153) moves every row of the zone the same way. ok is false
// for a zone with no known centre.
//
// Under -single-frame (round 571, session.SingleFrame) every row of a zone
// with a frame (worldmap.FrameFor) is converted against worldmap.WorldOrigin
// instead: the one frame the server then names for every such zone, so
// Jangan's and Donwhang's monsters stand in one coordinate system and a player
// walking between them meets both. A zone with no frame is not ok under the
// flag either: session.ZoneBucket keeps it in its own bucket, keyed on the
// same FrameFor, where world-frame coordinates would name no place (round
// 571's review).
func realSpawnWorld(zone string, s realSpawn) (x, z float64, ok bool) {
	// A dungeon row has no region grid to convert through; the roster
	// places none (round 773: -full-map's nests place the served ones).
	if worldmap.IsDungeonRegion(s.RegionID) {
		return 0, 0, false
	}
	rx, ry := worldmap.RegionXY(s.RegionID)
	if session.SingleFrame() {
		if _, _, framed := worldmap.FrameFor(zone); !framed {
			return 0, 0, false
		}
		x, z = worldmap.ToWorld(rx, ry, s.LocalX, s.LocalZ, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
		return x, z, true
	}
	return worldmap.ToZoneWorld(zone, rx, ry, s.LocalX, s.LocalZ)
}

// anchorWorld is where a species' own-design anchor (monsterSpec.X/Z) stands.
// The anchor is relative to its zone's frame region (worldmap.FrameFor: the
// town's centre, or the region an "x/y" label names), so with -single-frame
// off it is used as it is; with it on (round 571) it is the same place named
// in worldmap.WorldOrigin's frame -- worldmap.Rebase from that region -- so a
// roster run without -npcpos-csv puts the Earth Ghost where it always stood,
// near the middle of Donwhang's region, and not near Jangan's. ok is false
// under the flag for a zone with no frame: its anchor names no place in the
// one frame. FrameFor, not ZoneCentre, so this, realSpawnWorld and
// session.ZoneBucket agree on which zones join the one world (round 571's
// review).
func anchorWorld(spec monsterSpec) (x, z float64, ok bool) {
	if !session.SingleFrame() {
		return spec.X, spec.Z, true
	}
	fx, fy, framed := worldmap.FrameFor(spec.Zone)
	if !framed {
		return 0, 0, false
	}
	x, z = worldmap.Rebase(spec.X, spec.Z, fx, fy, worldmap.WorldOrigin[0], worldmap.WorldOrigin[1])
	return x, z, true
}

// rosterInstances is every monster the roster keeps alive for spec: one per
// real npcpos row when the species has them (converted by realSpawnWorld,
// no spread -- these are the authored positions, and nudging them would throw
// away the only part of this that is grounded), else Count instances spread
// around the own-design anchor (anchorWorld) on a small deterministic grid, so
// respawns land back in place -- a cluster, not a stack, ~130 units apart,
// well over a monster's ~77-unit capsule. A species whose rows all fail to
// convert falls back to the anchor rather than leaving the world.
//
// Each instance's Zone is the hub bucket it is spawned in,
// session.ZoneBucket(spec.Zone): the species' zone, or worldmap.WorldBucket
// under -single-frame (round 571), where the players of every town are too.
// main runs maintainMonster on each.
func rosterInstances(spec monsterSpec, logger *slog.Logger) []monsterSpec {
	bucket := session.ZoneBucket(spec.Zone)
	var out []monsterSpec
	if len(spec.Spawns) > 0 {
		for _, s := range spec.Spawns {
			x, z, ok := realSpawnWorld(spec.Zone, s)
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
			inst.X, inst.Z, inst.Zone = x, z, bucket
			out = append(out, inst)
		}
		if len(out) > 0 {
			return out
		}
		// Nothing converted. Fall through to the own-design anchor rather
		// than leaving the species out of the world entirely.
		logger.Warn("no real spawn converted, falling back to the anchor", "name", spec.Name)
	}
	ax, az, ok := anchorWorld(spec)
	if !ok {
		logger.Warn("species skipped: its zone has no known centre region to place its anchor in the one world frame",
			"zone", spec.Zone, "name", spec.Name)
		return nil
	}
	count := spec.Count
	if count < 1 {
		count = 1
	}
	for i := 0; i < count; i++ {
		inst := spec
		inst.X = ax + float64((i%3)-1)*130.0
		inst.Z = az + float64(i/3)*130.0
		inst.Zone = bucket
		out = append(out, inst)
	}
	return out
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
// Round 536 added the walk and run speeds (cols 46/47) to the same run: 77
// verified, 0 mismatched -- 22 more fields than the 55 above.
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
	{Zone: "jangan", Name: "Mangyang", CodeName: "MOB_CH_MANGNYANG", RefObjID: 1933, WalkSpeed: 8, RunSpeed: 22, AttackReuseMs: 3000, AttackRange: 10, Level: 1, BCRadius: 6, Critical: 2, MaxHP: 54, Defense: 7, AttackMin: 17, AttackMax: 19, GoldMin: 28, GoldMax: 59,
		Skills: []combat.MonsterSkill{{ID: 160, ReuseMs: 3000, Range: 10, AttMin: 17, AttMax: 19, Chance: 100}, {ID: 161, ReuseMs: 3000, Range: 10, AttMin: 17, AttMax: 19, Chance: 100}},
		Spawns: []realSpawn{
			{RegionID: 24744, LocalX: 1089.65, LocalZ: 600.09003},
			{RegionID: 24744, LocalX: 1842.3, LocalZ: 600.94},
			{RegionID: 24744, LocalX: 553.73999, LocalZ: 471.07001},
			{RegionID: 24744, LocalX: 1260.99, LocalZ: 22.690001},
		}},
	{Zone: "jangan", Name: "Small-eyed Ghost", CodeName: "MOB_CH_BIGEYEGHOST_CLON", RefObjID: 1934, WalkSpeed: 14, RunSpeed: 55, AttackReuseMs: 2000, AttackRange: 4, Level: 2, BCRadius: 6, Critical: 2, MaxHP: 55, Defense: 9, AttackMin: 21, AttackMax: 23, GoldMin: 32, GoldMax: 66,
		Skills: []combat.MonsterSkill{{ID: 162, ReuseMs: 2000, Range: 4, AttMin: 21, AttMax: 23, Chance: 100}}, X: -170, Z: -880, Count: 2},
	{Zone: "jangan", Name: "Big-eyed Ghost", CodeName: "MOB_CH_BIGEYEGHOST", RefObjID: 1935, WalkSpeed: 14, RunSpeed: 55, AttackReuseMs: 1500, AttackRange: 4, Level: 3, BCRadius: 6, Critical: 2, MaxHP: 85, Defense: 9, AttackMin: 25, AttackMax: 29, GoldMin: 35, GoldMax: 74,
		Skills: []combat.MonsterSkill{{ID: 163, ReuseMs: 1500, Range: 4, AttMin: 25, AttMax: 29, Chance: 100}}, X: 170, Z: -880, Count: 2},
	{Zone: "jangan", Name: "Old Weasel", CodeName: "MOB_CH_GYO_CLON", RefObjID: 1936, WalkSpeed: 12, RunSpeed: 55, AttackReuseMs: 2000, AttackRange: 7, Level: 4, BCRadius: 10, Critical: 2, MaxHP: 83, Defense: 12, AttackMin: 30, AttackMax: 34, GoldMin: 39, GoldMax: 81,
		Skills: []combat.MonsterSkill{{ID: 164, ReuseMs: 2000, Range: 7, AttMin: 30, AttMax: 34, Chance: 100}}, X: -170, Z: -760, Count: 2},
	// A higher ground east of the fields (the (340,-340) anchor):
	{Zone: "jangan", Name: "Weasel", CodeName: "MOB_CH_GYO", RefObjID: 1937, WalkSpeed: 12, RunSpeed: 55, AttackReuseMs: 2000, AttackRange: 7, Level: 5, BCRadius: 10, Critical: 2, MaxHP: 119, Defense: 12, AttackMin: 35, AttackMax: 40, GoldMin: 42, GoldMax: 88,
		Skills: []combat.MonsterSkill{{ID: 165, ReuseMs: 2000, Range: 7, AttMin: 35, AttMax: 40, Chance: 100}}, X: 340, Z: -340, Count: 3},
	{Zone: "jangan", Name: "Water Ghost slave", CodeName: "MOB_CH_WATERGHOST_CLON", RefObjID: 1938, WalkSpeed: 15, RunSpeed: 55, AttackReuseMs: 2000, AttackRange: 16, Level: 6, BCRadius: 6, Critical: 2, MaxHP: 114, Defense: 15, AttackMin: 41, AttackMax: 47, GoldMin: 46, GoldMax: 96,
		Skills: []combat.MonsterSkill{{ID: 166, ReuseMs: 2000, Range: 16, AttMin: 41, AttMax: 47, Chance: 100}, {ID: 167, ReuseMs: 2500, Range: 16, AttMin: 41, AttMax: 47, Chance: 100}}, X: 500, Z: -360, Count: 2},
	// Water Ghost's second skill, MSKILL_CH_WATERGHOST_ATTACK02 169, carries a
	// zero-damage 'att' block (9,0,0,0,100) beside a `ps` param 28787
	// (34,100,16): a status skill, which OpenSRO has no system for, so a
	// swing of it lands nothing (session.monsterStrike). Its chance is 10
	// against ATTACK01's 100.
	{Zone: "jangan", Name: "Water Ghost", CodeName: "MOB_CH_WATERGHOST", RefObjID: 1939, WalkSpeed: 15, RunSpeed: 55, AttackReuseMs: 2000, AttackRange: 16, Level: 7, BCRadius: 6, Critical: 2, MaxHP: 156, Defense: 15, AttackMin: 47, AttackMax: 54, GoldMin: 49, GoldMax: 103,
		Skills: []combat.MonsterSkill{{ID: 168, ReuseMs: 2000, Range: 16, AttMin: 47, AttMax: 54, Chance: 100}, {ID: 169, ReuseMs: 4000, Range: 16, AttMin: 0, AttMax: 0, Chance: 10}}, X: 340, Z: -500, Count: 2},
	{Zone: "jangan", Name: "Tomb Stone Ghost", CodeName: "MOB_CH_TOMBSTONE_CLON", RefObjID: 1950, WalkSpeed: 15, RunSpeed: 55, AttackReuseMs: 2500, AttackRange: 100, Level: 8, BCRadius: 4, Critical: 2, MaxHP: 204, Defense: 15, AttackMin: 74, AttackMax: 83, GoldMin: 53, GoldMax: 110,
		Skills: []combat.MonsterSkill{{ID: 171, ReuseMs: 2500, Range: 100, AttMin: 74, AttMax: 83, Chance: 100}}, X: 500, Z: -500, Count: 2},
	{Zone: "jangan", Name: "Stone Ghost", CodeName: "MOB_CH_STONEGHOST", RefObjID: 1941, WalkSpeed: 14, RunSpeed: 55, AttackReuseMs: 2500, AttackRange: 10, Level: 9, BCRadius: 10, Critical: 2, MaxHP: 194, Defense: 22, AttackMin: 60, AttackMax: 70, GoldMin: 56, GoldMax: 118,
		Skills: []combat.MonsterSkill{{ID: 172, ReuseMs: 2500, Range: 10, AttMin: 60, AttMax: 70, Chance: 100}}, X: 200, Z: -480, Count: 2},
	// Yeoha's second skill, MSKILL_CH_YEOHA_ATTACK03 177, reaches 100 units
	// against ATTACK01's 7, with a harder blow (94-105 against 67-79).
	{Zone: "jangan", Name: "Yeoha", CodeName: "MOB_CH_YEOHA", RefObjID: 1943, WalkSpeed: 9, RunSpeed: 20, AttackReuseMs: 2500, AttackRange: 7, Level: 10, BCRadius: 11, Critical: 2, MaxHP: 249, Defense: 22, AttackMin: 67, AttackMax: 79, GoldMin: 60, GoldMax: 125,
		Skills: []combat.MonsterSkill{{ID: 176, ReuseMs: 2500, Range: 7, AttMin: 67, AttMax: 79, Chance: 100}, {ID: 177, ReuseMs: 2500, Range: 100, AttMin: 94, AttMax: 105, Chance: 100}}, X: 200, Z: -220, Count: 2},
	// The donghwang example kept from before (a far, higher-level zone).
	// Its X/Z anchor is own design and, like every coordinate in a zone, is
	// relative to the zone's centre region (worldmap.ZoneCentre). Round 569
	// moved donwhang's centre from 98/157 (textzonename: "Donwhang Ferry") to
	// the town, 102/153, so without -npcpos-csv this one monster now stands
	// at (-60, -50) -- the anchor plus the spread's -130 for a lone instance
	// -- from the middle of the town's region rather than the ferry's.
	// With -npcpos-csv it takes MOB_WC_EARTHGHOST's 65 real rows instead,
	// all in the regions around the town (96-105/148-156, none in 102/153 or
	// 103/153), each converted by realSpawnWorld against the new centre.
	{Zone: "donwhang", Name: "Earth Ghost", CodeName: "MOB_WC_EARTHGHOST", RefObjID: 1963, WalkSpeed: 11, RunSpeed: 75, AttackReuseMs: 2000, AttackRange: 7, Level: 27, BCRadius: 4, Critical: 2, MaxHP: 1451, Defense: 103, AttackMin: 219, AttackMax: 261, GoldMin: 119, GoldMax: 250,
		Skills: []combat.MonsterSkill{{ID: 210, ReuseMs: 2000, Range: 7, AttMin: 219, AttMax: 261, Chance: 100}}, X: 70, Z: -50, Count: 1},
}

// respawnDelay is DISCLOSED, own design: the stand-in nest's respawn window,
// both ends (a user decision, monster_decisions.md D3). The real game respawns
// per NEST (`_RefNest`, a server-only table): each nest keeps up to its alive
// cap of monsters, and when a full nest loses one, a timer armed at that death
// runs for a delay drawn uniformly between the nest row's two delay columns
// (in seconds, re-rolled every hatch) before one monster hatches per scheduler
// pass -- read off AIHive_HatchPass / NestSlot_RollHatchDelay, round 239,
// docs/protocol/monster_ai.md. Round 660 runs that rule (internal/nest) for
// every placement: a nest joined to the operator's DB rows (-nest-db-dir,
// EXTERNAL) takes its own window; every other one -- the roster's, and every
// npcpos row without a DB nest -- is a stand-in nest of one monster with this
// window.
const respawnDelay = 10 * time.Second

// qaSpreadInstances is -qa-spread-monsters' synthetic crowd (round 656, QA
// only, OURS): n placements of Jangan's roster species, taken in turn, each at
// a spot drawn from a fixed-seed generator over the (2 x radius + 1)^2
// regions centred on Jangan's region -- uniform over the square, whatever the
// terrain. Jangan's region is the origin of both the Jangan zone's frame and
// -single-frame's (worldmap.WorldOrigin), so the coordinates are the same
// either way; the bucket is session.ZoneBucket("jangan"). The placements have
// no npcpos rows: they exist to load the area of interest, the list's paging
// and the AI, not to stand anywhere a monster really does.
func qaSpreadInstances(n, radius int, specs []monsterSpec) []monsterSpec {
	if n <= 0 {
		return nil
	}
	if radius < 0 {
		radius = 0
	}
	var jangan []monsterSpec
	for _, spec := range specs {
		if spec.Zone == "jangan" {
			jangan = append(jangan, spec)
		}
	}
	if len(jangan) == 0 {
		return nil
	}
	rng := rand.New(rand.NewSource(656))
	span := worldmap.RegionSpan
	out := make([]monsterSpec, 0, n)
	for i := 0; i < n; i++ {
		inst := jangan[i%len(jangan)]
		kx := rng.Intn(2*radius+1) - radius
		kz := rng.Intn(2*radius+1) - radius
		inst.X = float64(kx)*span + (rng.Float64()-0.5)*span
		inst.Z = float64(kz)*span + (rng.Float64()-0.5)*span
		inst.Zone = session.ZoneBucket("jangan")
		inst.Spawns = nil
		inst.Count = 1
		out = append(out, inst)
	}
	return out
}

// gmSpecies converts the running monster roster into the species the GM
// console's /spawn and /goto know, with the same stats maintainMonster
// hands a live spawn (monsterStatsForLevel plus the roster's own real HP,
// defence and gold). Its go-to spot is the species' first real npcpos
// placement in world coordinates when it has one, else the own-design
// anchor -- so /goto lands where the server actually keeps the monster.
// Both go through the spawn loop's own conversions (realSpawnWorld,
// anchorWorld), so under -single-frame the spot is in the one world frame
// too. Its Zone stays the roster's zone LABEL, not the hub bucket: it is what
// /goto hands the client to re-centre its grid on (gm.Species). A species with
// no place at all -- under -single-frame, one whose zone has no frame -- is
// left out, as rosterInstances leaves it out of the world, rather than
// offered at (0, 0) (round 571's review); with the flag off every species has
// its anchor, so none is.
func gmSpecies() []gm.Species {
	out := make([]gm.Species, 0, len(monsterSpecs))
	for _, spec := range monsterSpecs {
		x, z, placed := anchorWorld(spec)
		if len(spec.Spawns) > 0 {
			if wx, wz, ok := realSpawnWorld(spec.Zone, spec.Spawns[0]); ok {
				x, z, placed = wx, wz, true
			}
		}
		if !placed {
			continue
		}
		sp := gmSpeciesOf(spec)
		sp.X, sp.Z = x, z
		out = append(out, sp)
	}
	return out
}

// uniqueSpecs are the unique monsters the GM console's /spawnunique can put
// down (round 657). None is placed in the world yet -- the uniques' rotation
// over their nests is a later round -- so this is how a tester meets one and
// sees the notices (session/uniquenotice.go).
//
// READ from the render box's retail characterdata (the row whose code name is
// the key; the columns as monsterSpec numbers them: RefObjID col 1, Rarity 15,
// walk/run 46/47, BCRadius 50, Level 57, MaxHP 59, Defense 71, Critical 78).
// The five named ones are the uniques the client's notice handler names by
// their SN_ key (0x874ea0: SN_MOB_CH_TIGERWOMAN, SN_MOB_KK_ISYUTARU,
// SN_MOB_OA_URUCHI, SN_MOB_TK_BONELORD, SN_MOB_RM_TAHOMET); Cerberus is a
// rarity-3 row it does not name, so it takes the generic lines. The Names are
// textdata_object's English for each SN_ key with the " [INT]" tag this
// archive appends to every one of them left off (the client's own lines come
// from its own tables, not from these). In this archive every base row is
// level 110; the _L2/_L3 rows carry the lower levels.
//
// DISCLOSED: a unique's attack is monsterStatsForLevel's curve and it carries
// no attack skill (AttackReuseMs, AttackRange and Skills are left unset, so
// it answers every blow); its real skills (cols 83..92) are not read here.
var uniqueSpecs = []monsterSpec{
	{Name: "Tiger Girl", CodeName: "MOB_CH_TIGERWOMAN", RefObjID: 1954, Rarity: 3, Level: 110, MaxHP: 299360, Defense: 42, BCRadius: 28, WalkSpeed: 20, RunSpeed: 90, Critical: 2},
	{Name: "Isyutaru", CodeName: "MOB_KK_ISYUTARU", RefObjID: 2002, Rarity: 3, Level: 110, MaxHP: 2162306, Defense: 274, BCRadius: 10, WalkSpeed: 35, RunSpeed: 70, Critical: 2},
	{Name: "Uruchi", CodeName: "MOB_OA_URUCHI", RefObjID: 1982, Rarity: 3, Level: 110, MaxHP: 889764, Defense: 124, BCRadius: 60, WalkSpeed: 28, RunSpeed: 80, Critical: 2},
	{Name: "Lord Yarkan", CodeName: "MOB_TK_BONELORD", RefObjID: 3810, Rarity: 3, Level: 110, MaxHP: 13382610, Defense: 559, BCRadius: 20, WalkSpeed: 30, RunSpeed: 75, Critical: 2},
	{Name: "Demon Shaitan", CodeName: "MOB_RM_TAHOMET", RefObjID: 3875, Rarity: 3, Level: 110, MaxHP: 31830150, Defense: 898, BCRadius: 13, WalkSpeed: 23, RunSpeed: 75, Critical: 2},
	{Name: "Cerberus", CodeName: "MOB_EU_KERBEROS", RefObjID: 5871, Rarity: 3, Level: 110, MaxHP: 346536, Defense: 52, BCRadius: 33, WalkSpeed: 30, RunSpeed: 96, Critical: 2},
}

// gmUniques is uniqueSpecs as the GM console's species, with the stats a
// roster spawn of the same row would get (gmSpecies' conversion, no place).
func gmUniques() []gm.Species {
	out := make([]gm.Species, 0, len(uniqueSpecs))
	for _, spec := range uniqueSpecs {
		attack, gold := monsterStatsForLevel(spec.Level, spec.Rarity)
		out = append(out, gm.Species{Species: combatSpeciesOf(spec), MaxHP: spec.MaxHP, Defense: spec.Defense, Attack: attack, Gold: gold})
	}
	return out
}

// combatSpeciesOf is the one place a roster spec becomes the combat.Species
// a spawn carries, so maintainMonster's roster spawns and the GM console's
// /spawn cannot drift apart again (until round 488 gmSpecies left out
// BCRadius, AttackReuseMs and AttackRange, so a GM-spawned Mangyang had a
// BCRadius of 0 and was reachable from 6 units less than a roster one).
// BCRadius is characterdata col 50 (round 247, see monsterSpec.BCRadius); a
// spec without one gets combat.PlayerBCRadius, the 4 every playable body row
// carries. AttackReuseMs/AttackRange are the primary attack skill's
// skilldata columns 14 and 21 (round 254). WalkSpeed/RunSpeed are
// characterdata cols 46/47 (round 536, see monsterSpec.WalkSpeed). Skills
// is the species' attack-skill list, cols 83..92 (round 554, see
// monsterSpec.Skills).
func combatSpeciesOf(spec monsterSpec) combat.Species {
	bc := spec.BCRadius
	if bc == 0 {
		bc = combat.PlayerBCRadius
	}
	return combat.Species{Name: spec.Name, CodeName: spec.CodeName, RefObjID: spec.RefObjID, Level: spec.Level, Rarity: spec.Rarity, BCRadius: bc, AttackReuseMs: spec.AttackReuseMs, AttackRange: spec.AttackRange,
		AttackMin: spec.AttackMin, AttackMax: spec.AttackMax, Skills: spec.Skills,
		GoldMin: spec.GoldMin, GoldMax: spec.GoldMax, Critical: spec.Critical,
		WalkSpeed: spec.WalkSpeed, RunSpeed: spec.RunSpeed,
		ExpToGive: spec.ExpToGive, HasExpToGive: spec.HasExpToGive,
		Knockdown: spec.Knockdown, KORecoverMs: spec.KORecoverMs, HasKnockdown: spec.HasKnockdown}
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

// groundDropRules adapts the reference item store to the ground-item hub's
// rules lookup: ONE GetItem per drop answers everything the drop needs
// (docs/protocol/ground_items.md) --
//   - DecayTimeMs: the row's DecayTime, itemdata column 13 (CGObj::Update
//     removes the item once its seconds pass it);
//   - Bound: CanTrade (column 16) clear -- GObjPC::FUN_004901c0 never
//     releases the owner ("The ownership window");
//   - NoPick: CanPick (column 21) clear -- GObjPC::CheckCanPickUp refuses
//     0x1839 ("Picking up", step 1);
//   - OwnerOnly: grounditem.OwnerOnlyPick on TypeID1..3 and CodeName (column
//     2) -- CheckCanPickUp refuses every non-owner of a 3/3/9 item not named
//     ITEM_QNO_RM_ARCHEMY* ("Picking up", step 3).
//
// A lookup error or a missing row answers the zero DropRules: the fallback
// lifetime, released after the 30 s window, pickable, and open to the party
// rule -- so only a row that really says otherwise changes a drop.
func groundDropRules(ctx context.Context, items interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
}) func(itemID int64) grounditem.DropRules {
	return func(itemID int64) grounditem.DropRules {
		it, err := items.GetItem(ctx, itemID)
		if err != nil || it == nil {
			return grounditem.DropRules{}
		}
		return grounditem.DropRules{
			DecayTimeMs: it.DecayTimeMs,
			Bound:       !it.CanTrade,
			NoPick:      !it.CanPick,
			OwnerOnly:   grounditem.OwnerOnlyPick(it.TypeID1, it.TypeID2, it.TypeID3, it.CodeName),
			Expendable:  it.TypeID1 == 3 && it.TypeID2 == 3,
		}
	}
}

// envBool reads a boolean switch from the environment with strconv.ParseBool
// ("1", "true", "0", "false", ...). Unset or empty is false. A value that does
// not parse is false as well, with the error returned so main can WARN once
// the logger exists: a typo must leave a kill switch off, never on.
func envBool(name string) (bool, error) {
	v := os.Getenv(name)
	if v == "" {
		return false, nil
	}
	b, err := strconv.ParseBool(v)
	if err != nil {
		return false, err
	}
	return b, nil
}

// envInt reads an integer setting from the environment. Unset or empty is
// def; a value that does not parse is def too, with the error returned so
// main can WARN once the logger exists.
// envBoolDefault is envBool with a default for an unset variable.
func envBoolDefault(name string, def bool) (bool, error) {
	if os.Getenv(name) == "" {
		return def, nil
	}
	b, err := envBool(name)
	if err != nil {
		return def, err
	}
	return b, nil
}

// envDuration reads a duration setting (time.ParseDuration: "10s", "2m")
// from the environment. Unset or empty is def; a value that does not parse is
// def too, with the error returned so main can WARN once the logger exists.
func envDuration(name string, def time.Duration) (time.Duration, error) {
	v := os.Getenv(name)
	if v == "" {
		return def, nil
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		return def, err
	}
	return d, nil
}

func envInt(name string, def int) (int, error) {
	v := os.Getenv(name)
	if v == "" {
		return def, nil
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def, err
	}
	return n, nil
}

// statusParamsWarning is the boot's check on the skills store (round 666):
// "" when some skill carries status params (Skill.StatusParams, the skills
// CSV's column 90, round 659), else the WARN to log, worded for the store it
// is about. A PostgreSQL skills table imported before round 659 has the
// column (the store adds it) and an empty string in every row, and nothing
// else says so: every status skill then lands no state, silently -- a
// player's poison, bleeding, stun or freeze, and with -monster-ai a
// monster's too. Status effects themselves have no switch (RunStatusEffects
// is started unconditionally), so the check runs on every boot; monsterAI
// only adds the monsters to the message. err is the count queries' error: a
// count that failed is reported as that, not read as 0 (round 666's review).
func statusParamsWarning(inMemory bool, skills, withStatus int, err error, monsterAI bool) string {
	if err != nil {
		return fmt.Sprintf("could not count the skills with status params (%v): whether any skill lands a status is unknown", err)
	}
	if withStatus > 0 {
		return ""
	}
	who := "no skill lands a status (poison, bleeding, burn, stun, freeze ...) on anyone"
	if monsterAI {
		who += ", the monsters' own status skills (-monster-ai) included"
	}
	switch {
	case inMemory && skills == 0:
		return "no skills loaded (-in-memory with no -skills-csv): no skill can be learned or cast, and " + who
	case inMemory:
		return fmt.Sprintf("the skills CSV (-skills-csv) carries NO status params (%d skills, 0 with StatusParams): %s. "+
			"It was exported before round 659: RE-EXPORT skills.csv with the new export-refdata (91 columns, column 90 "+
			"StatusParams)", skills, who)
	case skills == 0:
		return "skills table is EMPTY: no skill can be learned or cast, and " + who + ". Export skills.csv with " +
			"cmd/export-refdata and load it with cmd/import-refdata (deploy/README.md, \"Reference data\")"
	}
	return fmt.Sprintf("skills store has NO status params (%d skills, 0 with status_params): %s. "+
		"The skills were imported before round 659: RE-EXPORT skills.csv with the new export-refdata "+
		"(91 columns, column 90 StatusParams) and RE-IMPORT it with the new import-refdata, then restart "+
		"(deploy/README.md, \"Reference data\"). Check: SELECT count(*) FROM skills WHERE status_params <> ''; "+
		"must be above 0", skills, who)
}

// monsterSleepUsage is -monster-sleep's help text. The window is the one the
// area of interest serves (session.AOIRadius cells of combat.CellSpan units
// each way: 3x3 blocks of 320 since round 664), named from those constants so
// the help cannot drift from them again (round 666: it still said "5x5
// regions" two rounds after the window changed).
func monsterSleepUsage() string {
	side := 2*session.AOIRadius + 1
	return fmt.Sprintf("with -monster-ai, let the brains of monsters no player is near sleep (env OPENSRO_MONSTER_SLEEP): a "+
		"monster whose %g-unit block is outside every player's area of interest -- the %dx%d blocks of %g units "+
		"around the block a player stands in (retail's message blocks, 6x6 to a region) -- is neither moved nor run "+
		"until a player comes that near, and its brain is dropped until then, keeping only what it must "+
		"(round 656, round 666; OURS: retail's rule is unread). Default ON; off, every monster runs every tick as before.",
		combat.CellSpan, side, side, combat.CellSpan)
}

// monsterBattleAllowed decides whether -monster-battle takes effect: only
// with -monster-ai on (the chase and the swing run in the AI tick) and
// -monster-strike-push on (each swing reaches the zone only as an
// OpMonsterAttacked; without it a player would lose HP to blows nobody is
// told about). The second value says why not. Never an exit: a flag
// combination must not make the public server's update loop roll back.
func monsterBattleAllowed(battle, monsterAI, strikePush bool) (on bool, why string) {
	switch {
	case !battle:
		return false, ""
	case !monsterAI && !strikePush:
		return false, "needs -monster-ai (the chase runs in the AI tick) and -monster-strike-push (the swings reach the zone only as OpMonsterAttacked)"
	case !monsterAI:
		return false, "needs -monster-ai: the chase and the swing run in the AI tick"
	case !strikePush:
		return false, "needs -monster-strike-push: the swings reach the zone only as OpMonsterAttacked, and without it a player would lose HP to blows nobody is told about"
	}
	return true, ""
}

// monsterAggroAllowed decides whether -monster-aggro takes effect: only with
// -monster-battle in effect (battleOn is monsterBattleAllowed's answer, so the
// AI and the strike push are on too: a noticed player is engaged by the chase
// and the monster's own swings, and under the interim hold the monster would
// only stand where it noticed) and -player-dead-state on (a monster that seeks
// players out kills ones who never struck it, and a kill must leave them dead
// rather than respawned in place at 40 %). The second value says why not.
// Never an exit, for the same reason as monsterBattleAllowed.
func monsterAggroAllowed(aggro, battleOn, deadState bool) (on bool, why string) {
	switch {
	case !aggro:
		return false, ""
	case !battleOn && !deadState:
		return false, "needs -monster-battle in effect (a noticed player is engaged by the chase and the monster's own swings) and -player-dead-state (a monster that seeks players out kills ones who never struck it)"
	case !battleOn:
		return false, "needs -monster-battle in effect: a noticed player is engaged by the chase and the monster's own swings"
	case !deadState:
		return false, "needs -player-dead-state: a monster that seeks players out kills ones who never struck it, and a kill must leave them dead"
	}
	return true, ""
}

// frontEndThemeFromFlags validates the -login-* settings (raw, as given) into
// the theme the server serves before login, and tells the operator at startup what was
// refused, what the client will need to find, and what is being served.
// OURS (round 678).
func frontEndThemeFromFlags(raw session.FrontEndTheme, logger *slog.Logger) session.FrontEndTheme {
	theme, warnings, infos := session.NewFrontEndTheme(raw)
	for _, w := range warnings {
		logger.Warn(w)
	}
	for _, i := range infos {
		logger.Info(i)
	}
	if theme.IsDefault() {
		logger.Info("front-end theme: client defaults (no intro, bgm, logo, copyright or band art set)")
	} else {
		logger.Info("front-end theme", "intro", theme.Intro, "bgm", theme.BGM, "logo", theme.Logo, "copyright", theme.Copyright,
			"band_top", theme.BandTop, "band_bottom", theme.BandBottom)
	}
	return theme
}

// quietQuery is true for the before-login questions a client asks on a
// connection of its own -- the front-end theme and the server list's status
// -- whose connection, packet and disconnection lines are logged at Debug.
func quietQuery(opcode uint16) bool {
	return opcode == session.OpFrontEndThemeRequest || opcode == session.OpServerStatusRequest
}

// loginRulesFrom checks the login flags (round 788): a tolerance of 1-100
// (OURS bounds; retail reads any number), block minutes 0 (none) up to a
// year, a per-IP limit 0 (off) or more, a reason the gateway's field holds
// (511 bytes, session.maxBlockReasonBytes). A bad value stops the server:
// a mistyped security setting should not quietly fall back.
func loginRulesFrom(tolerance, blockMin, maxPerIP int, guide string) (session.LoginRules, error) {
	switch {
	case tolerance < 1 || tolerance > 100:
		return session.LoginRules{}, fmt.Errorf("-login-failure-tolerance %d: want 1-100", tolerance)
	case blockMin < 0 || blockMin > 525600:
		return session.LoginRules{}, fmt.Errorf("-login-failure-block-min %d: want 0-525600", blockMin)
	case maxPerIP < 0:
		return session.LoginRules{}, fmt.Errorf("-max-users-per-ip %d: want 0 or more", maxPerIP)
	case strings.TrimSpace(guide) == "" || len(guide) > 511:
		return session.LoginRules{}, fmt.Errorf("-login-punishment-guide: want 1-511 bytes of text, got %d", len(guide))
	}
	return session.LoginRules{FailureTolerance: tolerance, BlockMinutes: blockMin, MaxPerIP: maxPerIP, PunishmentGuide: guide}, nil
}

// defaultMaxPlayers is -max-players' default. OURS: retail's capacity is a
// row of its shard database, which neither executable carries.
const defaultMaxPlayers = 1000

// serverCapacity checks -max-players: 1..65535 (the status's field is a u16,
// as retail's is), else the default with a warning.
func serverCapacity(v int, logger *slog.Logger) int {
	if v < 1 || v > 0xffff {
		logger.Warn("-max-players must be 1-65535; using the default", "given", v, "default", defaultMaxPlayers)
		return defaultMaxPlayers
	}
	logger.Info("capacity", "max_players", v)
	return v
}

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	postgresDSN := flag.String("postgres-dsn", "postgres://postgres:postgres@localhost:5432/opensro?sslmode=disable",
		"PostgreSQL connection string for account/character storage")
	tlsCert := flag.String("tls-cert", "", "path to a TLS certificate (PEM); if set with -tls-key, the gateway serves TLS instead of plain TCP")
	tlsKey := flag.String("tls-key", "", "path to a TLS private key (PEM); see -tls-cert")
	postgresWait := flag.Duration("postgres-wait", 60*time.Second,
		"how long to wait at startup for PostgreSQL to accept connections, retrying every second "+
			"(0: one try, as before). At a host's boot Docker starts the server and postgres "+
			"together, ignoring compose's depends_on, so postgres may not be up yet")
	inMemory := flag.Bool("in-memory", false,
		"run with in-memory storage instead of PostgreSQL: nothing is persisted, and every "+
			"account, character, guild and friendship is gone when the process exits. For "+
			"development, for end-to-end client runs, and for anyone who wants to try the "+
			"server without setting up a database.")
	leveldataCSV := flag.String("leveldata-csv", os.Getenv("OPENSRO_LEVELDATA_CSV"),
		"path to a level,exp CSV (generated by cmd/export-leveldata from a client's own "+
			"leveldata.txt); enables EXP/leveling. Without it, characters never level.")
	skillsCSV := flag.String("skills-csv", os.Getenv("OPENSRO_SKILLS_CSV"),
		"path to a skill-refdata CSV (from cmd/export-refdata -mode skills); with -in-memory it "+
			"lets the server gate learning on real skills. With PostgreSQL, import it via "+
			"cmd/import-refdata instead. Without either, learning real skills is unavailable.")
	npcposCSV := flag.String("npcpos-csv", os.Getenv("OPENSRO_NPCPOS_CSV"),
		"path to the game's monster placements (from cmd/export-refdata -mode npcpos on a client's "+
			"own npcpos.txt). Every roster species with rows in it stands where the game puts it; "+
			"without the file the species keep their own-design anchors near the town.")
	monstersCSV := flag.String("monsters-csv", os.Getenv("OPENSRO_MONSTERS_CSV"),
		"path to the monster species table (from cmd/export-refdata -mode monsters on a client's own "+
			"characterdata parts, levelgold.txt and textdata_object.txt; round 654). Every roster species "+
			"takes its numbers from its row, and the GM console's /spawn knows every species in it by code "+
			"name, id or English name. Without -full-map, who spawns where does not change; with it, every "+
			"field nest spawns from this table (round 660). Without it the hand-typed roster is all the server knows. A configured path that does not load is fatal.")
	npcsCSV := flag.String("npcs-csv", os.Getenv("OPENSRO_NPCS_CSV"),
		"path to the NPC reference rows (from cmd/export-refdata -mode npcs on a client's own characterdata "+
			"parts and refshopgroup.txt; round 708): the code names the NPC spawn record's interaction list "+
			"is built from, and the talk menus with it (0xB045, round 727). REQUIRED with -npcpos-csv: the boot "+
			"fails without it. A configured path that does not load is fatal.")
	teleportDir := flag.String("teleport-dir", os.Getenv("OPENSRO_TELEPORT_DIR"),
		"directory holding the game's teleport network as teleportdata.csv, teleportlink.csv and "+
			"teleportbuilding.csv (from cmd/export-refdata -mode teleport on a client's own "+
			"teleportdata.txt, teleportlink.txt and teleportbuilding.txt). Loaded, checked and counted "+
			"at boot; the town teleporters' OpTeleportUse 0x00F3 charges and moves by it (round 576), "+
			"and without it every teleport is refused. A configured directory that does not load is fatal.")
	magicOptionsCSV := flag.String("magic-options-csv", os.Getenv("OPENSRO_MAGIC_OPTIONS_CSV"),
		"path to the game's magic option table as CSV (env OPENSRO_MAGIC_OPTIONS_CSV; from cmd/export-refdata "+
			"-mode magicoptions on a client's own server_dep\\silkroad\\textdata\\magicoption.txt, round 768). The "+
			"alchemy window's magic stones write their blue options from it, and a failed reinforce its durability "+
			"flaw. Without it every magic stone is refused and a flaw writes nothing; elixirs and attribute stones "+
			"still work. A configured path that does not load is fatal.")
	magicOptAssignCSV := flag.String("magic-option-assign-csv", os.Getenv("OPENSRO_MAGIC_OPTION_ASSIGN_CSV"),
		"path to the game's magic option assign table as CSV (env OPENSRO_MAGIC_OPTION_ASSIGN_CSV; from "+
			"cmd/export-refdata -mode magicoptassign on a client's own server_dep\\silkroad\\textdata\\"+
			"magicoptionassign.txt, round 770): which blue options each kind of item can drop with. With it and "+
			"-magic-options-csv a monster's equipment drop gets blue options as the original server gives them; "+
			"without either, drops carry none. A configured path that does not load is fatal.")
	regionsCSV := flag.String("regions-csv", os.Getenv("OPENSRO_REGIONS_CSV"),
		"path to the game's region table as CSV (env OPENSRO_REGIONS_CSV; from cmd/export-refdata -mode regions "+
			"on a client's own server_dep\\silkroad\\textdata\\refregion.txt, round 674). Its IsBattleField 0 regions "+
			"are the towns: with the monster AI on, a monster that walks into one -- chasing a player, say -- or is "+
			"placed in one is removed, as SR_GameServer.exe's CGObjMob::SetCurRegion does (no death, no reward; "+
			"docs/protocol/monster_ai.md). Without it no region is a town and monsters follow players in. "+
			"A configured path that does not load is fatal.")
	chargenCSV := flag.String("chargen-csv", os.Getenv("OPENSRO_CHARGEN_CSV"),
		"path to the creatable catalogue as CSV (env OPENSRO_CHARGEN_CSV; from cmd/export-refdata -mode chargen "+
			"on a client's own characterdata_*.txt and itemdata_*.txt, round 682): the 52 bodies and 52 starting items a "+
			"new character may be made from, and the two ammunition rows. Without it every character create is refused "+
			"(0x403) -- the server cannot tell what it may make. A configured path that does not load is fatal.")
	charDefaultsDir := flag.String("chardefaults-dir", os.Getenv("OPENSRO_CHARDEFAULTS_DIR"),
		"a directory holding the shard DB's _RefCharDefault_SkillMastery.csv, _RefCharDefault_Skill.csv and "+
			"_RefCharDefault_Quest.csv as exported (env OPENSRO_CHARDEFAULTS_DIR; EXTERNAL, round 692): a new "+
			"character gets its race's default masteries at level 0, its default skills, and its level-1 default "+
			"quests recorded, as the shard's _AddNewChar gives them. A _RefCharGen.csv beside them is compared with "+
			"the creatable catalogue at boot. Without it new characters get no defaults. A configured directory "+
			"that does not load is fatal. See deploy/README.md, \"Character defaults\".")
	questsDir := flag.String("quests-dir", os.Getenv("OPENSRO_QUESTS_DIR"),
		"a directory holding the quest catalogue cmd/export-refdata -mode quests wrote from the operator's own "+
			"questdata.txt, refqusetreward.txt, refquestrewarditems.txt and the game server's Script/VIETNAM/*.sct "+
			"(env OPENSRO_QUESTS_DIR; round 785): NPCs offer their quests, kills and drops count, rewards are paid. "+
			"Without it no quest is offered. A configured directory that does not load is fatal. See deploy/README.md, \"Quests\".")
	itemsCSV := flag.String("items-csv", os.Getenv("OPENSRO_ITEMS_CSV"),
		"path to an item-refdata CSV (from cmd/export-refdata -mode items); with -in-memory it "+
			"feeds the shop catalogue and prices, item stat lookups and inventory stack limits. "+
			"With PostgreSQL, import it via cmd/import-refdata instead. Without either, the shop "+
			"has no items to sell.")
	gmAccounts := flag.String("gm-accounts", os.Getenv("OPENSRO_GM_ACCOUNTS"),
		"comma-separated account usernames allowed to run GM commands (env OPENSRO_GM_ACCOUNTS). "+
			"Case is compared as stored in accounts.username. Default none: nobody is a GM. See "+
			"docs/DEBUG_TOOLS.md.")
	// The operator's front-end theme (round 678, OURS): served to any client
	// before login over OpFrontEndThemeRequest; see session/frontendtheme.go.
	loginIntro := flag.String("login-intro", os.Getenv("OPENSRO_LOGIN_INTRO"),
		"the title intro the login screen plays (env OPENSRO_LOGIN_INTRO): a retail intro's short name "+
			"(roc, egypt, china_whatf, china_wharf, constantinople, rm, rmzh, jupiter_login, ruby_baghdad -- "+
			"the files in Media.pk2 script\\intro\\), an operator's own name the client finds as "+
			"custom/intro/<name>.txt, or an archive path like script\\intro\\roc.txt. A name is letters, digits, _ and - "+
			"(an archive path's may also hold spaces); anything else is refused with a warning and none is served. Default empty: the client plays option.txt's IntroName.")
	loginBGM := flag.String("login-bgm", os.Getenv("OPENSRO_LOGIN_BGM"),
		"the title music's file name (env OPENSRO_LOGIN_BGM), e.g. maintheme_cut.ogg: letters, digits, "+
			"space, _ . -, ending .ogg (the only music the client looks up in Music.pk2). Default empty: the client plays option.txt's IntroBGM.")
	loginLogo := flag.String("login-logo", os.Getenv("OPENSRO_LOGIN_LOGO"),
		"a logo file name the client loads from its own custom/frontend/ folder (env OPENSRO_LOGIN_LOGO), "+
			"e.g. mylogo.png: letters, digits, _ and -, ending .png or .ddj. Default empty: the archive's own logo.")
	loginCopyright := flag.String("login-copyright", os.Getenv("OPENSRO_LOGIN_COPYRIGHT"),
		"one line of copyright or branding text for the login screen's bottom band (env "+
			"OPENSRO_LOGIN_COPYRIGHT), at most 200 characters; control characters are removed. Default empty: none.")
	loginBandTop := flag.String("login-band-top", os.Getenv("OPENSRO_LOGIN_BAND_TOP"),
		"the front-end's top band art, a file name the client loads from its own custom/frontend/ folder "+
			"(env OPENSRO_LOGIN_BAND_TOP): letters, digits, _ and -, ending .png or .ddj. Default empty: the archive's own band art.")
	loginBandBottom := flag.String("login-band-bottom", os.Getenv("OPENSRO_LOGIN_BAND_BOTTOM"),
		"the front-end's bottom band art, a file name the client loads from its own custom/frontend/ folder "+
			"(env OPENSRO_LOGIN_BAND_BOTTOM): letters, digits, _ and -, ending .png or .ddj. Default empty: the archive's own band art.")
	monsterAIEnv, monsterAIEnvErr := envBool("OPENSRO_MONSTER_AI")
	// The server list's status (round 679, OURS): the capacity the client's
	// population band divides by, and the inspection switch it shows as
	// "Check"; both also turn logins away (session.LoginGate).
	maxPlayersEnv, maxPlayersEnvErr := envInt("OPENSRO_MAX_PLAYERS", defaultMaxPlayers)
	inspectionEnv, inspectionEnvErr := envBool("OPENSRO_INSPECTION")
	maxPlayers := flag.Int("max-players", maxPlayersEnv,
		"the server's capacity: the client's server list shows current/max as Easy, Populated, Crowded or FULL, and a login is refused once this many characters are in the world (1-65535; OPENSRO_MAX_PLAYERS)")
	inspection := flag.Bool("inspection", inspectionEnv,
		"under inspection: the client's server list shows \"Check\" and every login is refused with retail's inspection message (OPENSRO_INSPECTION)")
	// The login rules (round 788, session.LoginService): retail's
	// GlobalManager settings, their code defaults (READ) except the per-IP
	// limit, off by default (OURS).
	loginTolEnv, loginTolEnvErr := envInt("OPENSRO_LOGIN_FAILURE_TOLERANCE", session.DefaultLoginFailureTolerance)
	loginBlockEnv, loginBlockEnvErr := envInt("OPENSRO_LOGIN_FAILURE_BLOCK_MIN", session.DefaultLoginFailureBlockMinutes)
	maxPerIPEnv, maxPerIPEnvErr := envInt("OPENSRO_MAX_USERS_PER_IP", 0)
	loginGuideEnv := os.Getenv("OPENSRO_LOGIN_PUNISHMENT_GUIDE")
	if loginGuideEnv == "" {
		loginGuideEnv = session.DefaultLoginPunishmentGuide
	}
	loginTolerance := flag.Int("login-failure-tolerance", loginTolEnv,
		"wrong passwords an account name may have; the one that reaches it closes the connection and raises the automatic block "+
			"(1-100; env OPENSRO_LOGIN_FAILURE_TOLERANCE; retail's LoginFailureTolerance, default 3)")
	loginBlockMin := flag.Int("login-failure-block-min", loginBlockEnv,
		"minutes the automatic block for too many wrong passwords lasts; 0 raises none "+
			"(env OPENSRO_LOGIN_FAILURE_BLOCK_MIN; retail's LoginFailureBlockTimeMin, default 10)")
	loginGuide := flag.String("login-punishment-guide", loginGuideEnv,
		"the reason the automatic block shows the player (env OPENSRO_LOGIN_PUNISHMENT_GUIDE; retail's LoginPunishmentGuide)")
	maxPerIP := flag.Int("max-users-per-ip", maxPerIPEnv,
		"accounts that may be logged in from one address at once; 0 is no limit "+
			"(env OPENSRO_MAX_USERS_PER_IP; retail's MaxUserForNonePCBangIP; default 0)")
	monsterAI := flag.Bool("monster-ai", monsterAIEnv,
		"run the monster AI (env OPENSRO_MONSTER_AI): monsters idle, wander, run home past their "+
			"roam radius, and stand where a blow found them while any player in the zone has an "+
			"auto-attack on them, each move pushed to the zone. Default OFF, and the kill switch: off, no monster moves "+
			"and the wire is what it was. Needs a client that draws OpMonsterMoved (v0.1.435 or "+
			"later). See deploy/README.md, \"Monster AI (off by default)\".")
	strikePushEnv, strikePushEnvErr := envBool("OPENSRO_MONSTER_STRIKE_PUSH")
	strikePush := flag.Bool("monster-strike-push", strikePushEnv,
		"push a monster's counterattack to its whole zone, the attacker included (env "+
			"OPENSRO_MONSTER_STRIKE_PUSH): OpMonsterAttacked 0x007D, sent after the attacker's "+
			"OpAttackResult, so everyone sees the blow. Default OFF: off, nothing is sent and the wire "+
			"is what it was. Needs a client release that carries round 540. See deploy/README.md, "+
			"\"Monster strike push (off by default)\".")
	spawnPushEnv, spawnPushEnvErr := envBool("OPENSRO_MONSTER_SPAWN_PUSH")
	spawnPush := flag.Bool("monster-spawn-push", spawnPushEnv,
		"push a monster that has just appeared -- a respawn or a GM /spawn -- to its whole zone at "+
			"once (env OPENSRO_MONSTER_SPAWN_PUSH): OpMonsterSpawned 0x007E, the list's record plus "+
			"the heading it hatched facing. Default OFF: off, nothing is sent and the wire is what it "+
			"was, so a respawn appears on each client's next monster list. Needs a client release that "+
			"carries round 540. See deploy/README.md, \"Monster spawn push (off by default)\".")
	uniqueOffEnv, uniqueOffEnvErr := envBool("OPENSRO_UNIQUE_NOTICE_OFF")
	uniqueNoticeOff := flag.Bool("unique-notice-off", uniqueOffEnv,
		"silence the unique monster notices (env OPENSRO_UNIQUE_NOTICE_OFF): retail's "+
			"CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG=ON. Default OFF: a unique's appearance and its "+
			"killer are announced to every character, as retail does with the key absent (round 657).")
	battleEnv, battleEnvErr := envBool("OPENSRO_MONSTER_BATTLE")
	battle := flag.Bool("monster-battle", battleEnv,
		"let a struck monster fight on its own (env OPENSRO_MONSTER_BATTLE): it chases its attacker "+
			"to its attack band at its run speed, swings on its attack skill's ReuseDelay with each blow "+
			"pushed to the zone (OpMonsterAttacked 0x007D), and gives up by distance; the counterattack "+
			"inside the attacker's OpAttackResult is then no longer made. Default OFF: off, the interim "+
			"hold and the counter are what they were. Forced off with a WARN unless -monster-ai and "+
			"-monster-strike-push are both on. Needs a client release that carries round 546. See "+
			"deploy/README.md, \"Monster battle (off by default)\".")
	deadStateEnv, deadStateEnvErr := envBool("OPENSRO_PLAYER_DEAD_STATE")
	deadState := flag.Bool("player-dead-state", deadStateEnv,
		"leave a player a monster kills dead (env OPENSRO_PLAYER_DEAD_STATE): life state 2 at HP 0, "+
			"its potion queue emptied, its moves, attacks, casts, items, pick-ups, duel blows, trade "+
			"requests, zone changes and GM teleports refused, and no monster's target, until it asks for "+
			"one of retail's resurrect choices with OpRevive 0x0028: option 1 returns it to its return point "+
			"(the world's entry point in town) at 40% HP, option 2 revives it where it lies, at level 10 or "+
			"under only. Nothing revives it unasked. Default OFF: off, a kill respawns the player at once at "+
			"the return point. Needs a client release that carries round 665 (the two buttons); an older "+
			"client's one Revive button gets option 2 at level 10 or under and option 1 above. See "+
			"deploy/README.md, \"Player dead state (off by default)\".")
	aggroEnv, aggroEnvErr := envBool("OPENSRO_MONSTER_AGGRO")
	aggro := flag.Bool("monster-aggro", aggroEnv,
		"let monsters notice players (env OPENSRO_MONSTER_AGGRO): a monster idle, wandering or, once "+
			"its blackout has passed, running home scans every 1001-1500 ms for the nearest living player "+
			"within its collision radius + 100 units (the detection distance, an own-design stand-in for "+
			"a server-database column: 104-111 units for the roster) and engages it as a blow would, "+
			"through -monster-battle's chase and swings. Default OFF: off, a monster fights only when "+
			"struck and the wire is what it was. Forced off with a WARN unless -monster-battle is in "+
			"effect and -player-dead-state is on. Needs the client releases those two need (rounds 546 "+
			"and 548). See deploy/README.md, \"Monster aggro (off by default)\".")
	trustPositions := flag.Bool("trust-client-positions", false,
		"take every position a client reports in OpMove (a placement, a stop, an older client's walk), "+
			"wherever it is, as before round 749. Default OFF: a stop is taken only on the server's own "+
			"leg of the character's move, a placement only there or at a point the server named (an "+
			"arrival, a GM /tp or /goto), and anything else is answered with the server's own position "+
			"(0xB023). For QA runs, which place their players anywhere (OPENSRO_QA_AT and its kin); "+
			"never on a public server.")
	arrivalGuard := flag.Bool("arrival-guard", true,
		"round 786: a character that arrives anywhere -- world entry, gate, walk-in portal, scroll, "+
			"return point, zone change, GM /tp and /goto, /unstuck -- is held out of the world (no "+
			"other player sees it, no monster targets it) until its client reports its loading done "+
			"(0x3012), then untouchable for 6.0 s (body mode 2), as retail's re-entry does "+
			"(docs/protocol/arrival_guard.md). A client that never reports is disconnected after 300 s. "+
			"Off: the arrival is immediate, as before round 786 (clients older than round 786 never send 0x3012).")
	worldClockOn := flag.Bool("world-clock", true,
		"round 786: tell each character the game clock at world entry (0x3020) and the whole world when a "+
			"GM sets the hour with /hour (0x3027), as retail does (docs/protocol/game_clock.md). The clock "+
			"runs one game second every 20 ms -- a day every 28 min 48 s -- in both binaries (READ). Off: "+
			"nothing is sent and a client draws the fixed midday it drew before round 786. A client older "+
			"than round 786 ignores both messages.")
	worldClockStart := flag.String("world-clock-start", os.Getenv("OPENSRO_WORLD_CLOCK_START"),
		"round 786: the game clock's reading when the server starts, HH:MM (env OPENSRO_WORLD_CLOCK_START; "+
			"OURS). Empty or 00:00 is retail's: day 0, 00:00 at the start (READ, SR_GameServer 0x427660).")
	singleFrameEnv, singleFrameEnvErr := envBool("OPENSRO_SINGLE_FRAME")
	singleFrame := flag.Bool("single-frame", singleFrameEnv,
		"put the whole world in ONE coordinate frame (env OPENSRO_SINGLE_FRAME): every zone with a "+
			"frame is named in Jangan's 97/168 (FrameRegion \"97/168\") and kept in one broadcast bucket, "+
			"every roster monster with it, and a zone change (so a GM /goto <town> too) lands at the "+
			"town's landing named in that frame -- so a player who walks from Jangan toward Donwhang meets Donwhang's "+
			"monsters and every other player. Default OFF, and the kill switch: off, every zone keeps "+
			"its own frame and bucket and the wire is what it was. Needs a client release that carries "+
			"rounds 569 to 571: 569 (the corrected town centres and the \"donwhang\" label), 570 (it "+
			"builds a zone's grid inside the server's FrameRegion) and 571 (it finds the grid's corner "+
			"when the centre region's terrain fails to load). See deploy/README.md, \"Single world "+
			"frame (off by default)\".")
	teleportFreeEnv, teleportFreeEnvErr := envBool("OPENSRO_TELEPORT_FREE")
	teleportFree := flag.Bool("teleport-free", teleportFreeEnv,
		"every gate teleport costs nothing (env OPENSRO_TELEPORT_FREE): the free-while-testing switch "+
			"(own design, round 576). Default OFF: off, a teleport charges its link's fee from the table, "+
			"waived below level 21 (the engine's rule) and for GM accounts (-gm-accounts, own design). "+
			"See deploy/README.md, \"Town teleporters\".")
	testItemsNPCEnv, testItemsNPCEnvErr := envBool("OPENSRO_TEST_ITEMS_NPC")
	testItemsNPC := flag.Bool("test-items-npc", testItemsNPCEnv,
		"spawn the Test Items NPC (env OPENSRO_TEST_ITEMS_NPC, round 783; OURS): an NPC of OpenSRO's own in "+
			"Jangan's square, between the Storage-Keeper and So-Ok, wearing Alexandria's Potion Merchant "+
			"Thiara's body, selling every 11th degree alchemy item and every Seal of Nova item at the items' "+
			"own prices. Its goods are rules (server/internal/testnpc/test_items.json) resolved at boot "+
			"against the loaded item reference data; needs -npcpos-csv and -npcs-csv (the NPC table names the "+
			"body). Default OFF. See docs/protocol/test_items_npc.md.")
	persistPositionEnv, persistPositionEnvErr := envBool("OPENSRO_PERSIST_POSITION")
	persistPosition := flag.Bool("persist-position", persistPositionEnv,
		"a character logs back in where it left off (env OPENSRO_PERSIST_POSITION): its zone label, "+
			"frame region and position are saved on its row -- on a disconnect, on each zone change, at "+
			"most every 30 s while it walks (own design) and for everyone still in the world when the "+
			"server stops -- and the next OpEnterWorldResult answers them, named in the zone's frame of "+
			"the day, with a trailing Restored byte. Default OFF: off, nothing is saved or read and every "+
			"entry lands at the zone spawn with the wire as it was. Needs a client release that carries "+
			"round 573: an older one moves a restored Jangan entry on to Jangan's landing spot. See "+
			"deploy/README.md, \"Saved position (off by default)\".")
	sleepEnv, sleepEnvErr := envBoolDefault("OPENSRO_MONSTER_SLEEP", true)
	monsterSleep := flag.Bool("monster-sleep", sleepEnv, monsterSleepUsage())
	qaSpreadEnv, qaSpreadEnvErr := envInt("OPENSRO_QA_SPREAD_MONSTERS", 0)
	qaSpread := flag.Int("qa-spread-monsters", qaSpreadEnv,
		"QA ONLY (env OPENSRO_QA_SPREAD_MONSTERS): spawn N more monsters of Jangan's roster species at "+
			"deterministic pseudo-random spots over the regions around Jangan (-qa-spread-radius), kept alive "+
			"by the respawn scheduler like the roster -- a synthetic crowd for load tests of the area of "+
			"interest (round 656). Not a claim about where any monster stands. Default 0: none.")
	qaSpreadRadiusEnv, qaSpreadRadiusEnvErr := envInt("OPENSRO_QA_SPREAD_RADIUS", 7)
	qaSpreadRadius := flag.Int("qa-spread-radius", qaSpreadRadiusEnv,
		"QA ONLY (env OPENSRO_QA_SPREAD_RADIUS): how many regions out from Jangan's region -qa-spread-monsters "+
			"spreads its monsters, on each axis (default 7: a 15x15-region square).")
	fullMapEnv, fullMapEnvErr := envBool("OPENSRO_FULL_MAP")
	fullMap := flag.Bool("full-map", fullMapEnv,
		"place every field monster of the game (env OPENSRO_FULL_MAP, round 660): each monster row of -npcpos-csv "+
			"outside the dungeons and the shard's custom species becomes a nest hatching its species from "+
			"-monsters-csv (a unique, rarity 3, rotates over its spots through its DB hive; a rarity-8 boss stands on its own field nest; the Pharaoh temple's rows are left to their instance worlds -- round 661) -- with -nest-db-dir, the DB nest's "+
			"window, radius, cap, champion chance and tactics (EXTERNAL); without it one monster per row, "+
			"respawning after 10 s, with the stand-in behaviour. Needs -npcpos-csv and -monsters-csv (forced off "+
			"with a WARN otherwise) and turns -single-frame on. Default OFF: off, the hand-typed roster stands "+
			"where it always has.")
	nestDBDir := flag.String("nest-db-dir", os.Getenv("OPENSRO_NEST_DB_DIR"),
		"directory holding the shard DB's AI tables as Tab_RefTactics.csv, tab_refnest.csv and tab_refhive.csv "+
			"(round 660; EXTERNAL: exported from the user's VSRO shard backup, never committed -- deploy/README.md), "+
			"and optionally Tab_RefAISkill.csv and _RefSkill.csv (round 661: the uniques' triggers and summons). "+
			"With -full-map every npcpos row joins the DB nest at its spot. A configured directory that does not load "+
			"is fatal.")
	swappedStandInEnv, swappedStandInEnvErr := envBool("OPENSRO_NEST_SWAPPED_STAND_IN")
	swappedStandIn := flag.Bool("nest-swapped-stand-in", swappedStandInEnv,
		"with -full-map and -nest-db-dir, place each of the 6,042 spots whose shard nest was repointed to "+
			"the shard's own monsters as a one-monster stand-in nest (10 s, radius 200, no champion roll; OURS) "+
			"instead of on that nest's own cap, window, radii and champion chance (EXTERNAL, the default; "+
			"round 660's review, the user's decision). Env OPENSRO_NEST_SWAPPED_STAND_IN.")
	nestRespawnEnv, nestRespawnEnvErr := envDuration("OPENSRO_NEST_RESPAWN", 0)
	nestRespawn := flag.Duration("nest-respawn", nestRespawnEnv,
		"every nest's respawn window but the uniques', both ends, in whole seconds (env OPENSRO_NEST_RESPAWN, round 660): an "+
			"override for testing. Default 0: each DB nest's own [min, max] window (1-3 s on most, EXTERNAL) and 10 s "+
			"for a stand-in nest.")
	uniqueRespawnEnv, uniqueRespawnEnvErr := envDuration("OPENSRO_UNIQUE_RESPAWN", 0)
	uniqueRespawn := flag.Duration("unique-respawn", uniqueRespawnEnv,
		"the uniques' respawn wait after a death, both ends, in whole seconds (env OPENSRO_UNIQUE_RESPAWN, round 661): "+
			"an OURS override for testing. Default 0: the hive's nests' own window (EXTERNAL: 1,200-1,400 s for Tiger Girl, "+
			"Uruchi, Isyutaru, Cerberus and Captain Ivy; 2,100-2,200 s for Lord Yarkan and Demon Shaitan).")
	inventorySizeEnv, inventorySizeEnvErr := envInt("OPENSRO_INVENTORY_SIZE", inventory.DefaultBagSlots)
	inventorySize := flag.Int("inventory-size", inventorySizeEnv,
		"the bag's size in slots for every character without one of its own (env OPENSRO_INVENTORY_SIZE): "+
			"the client shows it as pages of 32, at most three (IFInventory 0x6b6620), and locks the "+
			"slots of the last page past it. 1..96. Default 96, three full pages -- OURS, the test "+
			"server's choice (round 633); the shard DB's _AddNewChar gives a new character "+
			"InventorySize 109, the same 96 plus the 13 equipment slots (EXTERNAL, round 692). A GM's /invsize or the inventory expansion item gives a character its "+
			"own. See deploy/README.md, \"Inventory size\".")
	pprofAddr := flag.String("pprof-addr", os.Getenv("OPENSRO_PPROF_ADDR"),
		"serve net/http/pprof on this address, e.g. 127.0.0.1:6060 (env OPENSRO_PPROF_ADDR), and log a runtime stats line "+
			"every 30 s (GC, heap, goroutines, scheduler latency). OURS, debug only, off by default (empty). Never expose it: "+
			"it serves stacks and the command line. See deploy/README.md, \"Profiling a lagging server\".")
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, nil))
	if maxPlayersEnvErr != nil {
		logger.Warn("OPENSRO_MAX_PLAYERS is not a number; the capacity keeps its default unless -max-players is given",
			"err", maxPlayersEnvErr, "default", defaultMaxPlayers)
	}
	if inspectionEnvErr != nil {
		logger.Warn("OPENSRO_INSPECTION is not a boolean; the server is open unless -inspection is given", "err", inspectionEnvErr)
	}
	for _, e := range []struct {
		name string
		err  error
	}{{"OPENSRO_LOGIN_FAILURE_TOLERANCE", loginTolEnvErr}, {"OPENSRO_LOGIN_FAILURE_BLOCK_MIN", loginBlockEnvErr},
		{"OPENSRO_MAX_USERS_PER_IP", maxPerIPEnvErr}} {
		if e.err != nil {
			logger.Warn(e.name+" is not a number; its default applies unless the flag is given", "err", e.err)
		}
	}
	loginRules, err := loginRulesFrom(*loginTolerance, *loginBlockMin, *maxPerIP, *loginGuide)
	if err != nil {
		logger.Error("login rules", "err", err)
		os.Exit(2)
	}
	capacity := serverCapacity(*maxPlayers, logger)
	if *inspection {
		logger.Info("under inspection (-inspection): the server list shows Check and every login is refused")
	}
	if inventorySizeEnvErr != nil {
		logger.Warn("OPENSRO_INVENTORY_SIZE is not a number; the bag keeps its default unless -inventory-size is given",
			"err", inventorySizeEnvErr, "default", inventory.DefaultBagSlots)
	}
	for name, err := range map[string]error{"OPENSRO_MONSTER_SLEEP": sleepEnvErr, "OPENSRO_QA_SPREAD_MONSTERS": qaSpreadEnvErr,
		"OPENSRO_QA_SPREAD_RADIUS": qaSpreadRadiusEnvErr, "OPENSRO_FULL_MAP": fullMapEnvErr, "OPENSRO_NEST_SWAPPED_STAND_IN": swappedStandInEnvErr, "OPENSRO_NEST_RESPAWN": nestRespawnEnvErr,
		"OPENSRO_UNIQUE_RESPAWN": uniqueRespawnEnvErr} {
		if err != nil {
			logger.Warn(name+" does not parse; its flag keeps its default unless given", "err", err)
		}
	}
	if teleportFreeEnvErr != nil {
		logger.Warn("OPENSRO_TELEPORT_FREE is not a boolean; teleports stay charged unless -teleport-free is given",
			"err", teleportFreeEnvErr)
	}
	if testItemsNPCEnvErr != nil {
		logger.Warn("OPENSRO_TEST_ITEMS_NPC is not a boolean; the Test Items NPC stays off unless -test-items-npc is given",
			"err", testItemsNPCEnvErr)
	}
	if persistPositionEnvErr != nil {
		logger.Warn("OPENSRO_PERSIST_POSITION is not a boolean; the saved position stays off unless -persist-position is given",
			"err", persistPositionEnvErr)
	}
	if singleFrameEnvErr != nil {
		logger.Warn("OPENSRO_SINGLE_FRAME is not a boolean; the single frame stays off unless -single-frame is given",
			"err", singleFrameEnvErr)
	}
	frontEndTheme := frontEndThemeFromFlags(session.FrontEndTheme{Intro: *loginIntro, BGM: *loginBGM, Logo: *loginLogo,
		Copyright: *loginCopyright, BandTop: *loginBandTop, BandBottom: *loginBandBottom}, logger)
	if monsterAIEnvErr != nil {
		logger.Warn("OPENSRO_MONSTER_AI is not a boolean; the monster AI stays off unless -monster-ai is given",
			"err", monsterAIEnvErr)
	}
	if strikePushEnvErr != nil {
		logger.Warn("OPENSRO_MONSTER_STRIKE_PUSH is not a boolean; the strike push stays off unless -monster-strike-push is given",
			"err", strikePushEnvErr)
	}
	if spawnPushEnvErr != nil {
		logger.Warn("OPENSRO_MONSTER_SPAWN_PUSH is not a boolean; the spawn push stays off unless -monster-spawn-push is given",
			"err", spawnPushEnvErr)
	}
	if battleEnvErr != nil {
		logger.Warn("OPENSRO_MONSTER_BATTLE is not a boolean; the monster battle stays off unless -monster-battle is given",
			"err", battleEnvErr)
	}
	if deadStateEnvErr != nil {
		logger.Warn("OPENSRO_PLAYER_DEAD_STATE is not a boolean; the player dead state stays off unless -player-dead-state is given",
			"err", deadStateEnvErr)
	}
	if aggroEnvErr != nil {
		logger.Warn("OPENSRO_MONSTER_AGGRO is not a boolean; the monster aggro stays off unless -monster-aggro is given",
			"err", aggroEnvErr)
	}

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
		logger.Info("no leveldata CSV set (OPENSRO_LEVELDATA_CSV) -- characters will not level")
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := startDebug(ctx, *pprofAddr, logger); err != nil {
		logger.Error("pprof listener (-pprof-addr / OPENSRO_PPROF_ADDR)", "addr", *pprofAddr, "err", err)
		os.Exit(1)
	}

	// The stores are held as interfaces so the in-memory and PostgreSQL
	// wirings below are interchangeable. account is split in two because
	// login and registration take different halves of it.
	var (
		// serials numbers ground items (round 743): item_serial_seq on the
		// stores' pool, or an in-memory count.
		serials    = &txn.Serials{}
		accounts   account.Store
		registerer account.Registerer
		chars      character.Store
		refItems   refItemStore
		inv        inventory.Store
		warehouse  inventory.Store // the storage NPC's container (a 2nd inventory), owned by the ACCOUNT
		// The warehouse gold, kept per account as the game keeps it
		// (accounts.storage_gold; see internal/storage).
		storageGold account.StorageGoldStore
		chestSizes  account.ChestSizeStore
		eq          equipment.Store
		skills      skill.Store
		guilds      guild.Store
		quests      quest.Store
		friends     friend.Store
		// dropSrc is the real drop tables (_RefMonster_AssignedItemRndDrop and
		// _RefDropItemGroup). Both refdata stores already implement it; it is
		// bound separately from refItems because that interface is the item
		// lookup only. Nil, or a monster with no rows, falls back to the
		// own-design combat.LootTables.
		dropSrc session.DropSource
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
		chestSizes = memAccounts
		chars = character.NewMemStore()
		refItems = memRef
		dropSrc = memRef
		inv = memInv
		memWarehouse := inventory.NewMemStore(memRef) // a second, independent container, keyed by account id
		memWarehouse.SetDurabilityLookup(memRef)
		memWarehouse.SetCapacity(storage.DefaultCapacity)
		// Each account's own size, grown by the expansion item (round 498).
		memWarehouse.SetCapacityFunc(storage.CapacityOf(memAccounts))
		warehouse = memWarehouse
		eq = equipment.NewMemStore(memInv)
		skills = skill.NewMemStore()
		guilds = guild.NewMemStore()
		quests = quest.NewMemStore()
		friends = friend.NewMemStore()
		logger.Warn("in-memory storage ready -- nothing will be persisted")
		{
			n, err := memRef.CountSkills(context.Background())
			withStatus, err2 := memRef.CountSkillsWithStatusParams(context.Background())
			if err == nil {
				err = err2
			}
			if w := statusParamsWarning(true, n, withStatus, err, *monsterAI); w != "" {
				logger.Warn(w)
			}
		}
	} else {
		if err := waitForDatabase(pingPostgres(*postgresDSN), *postgresWait, time.Second, time.Sleep, logger); err != nil {
			logger.Error("opening account store", "error", err)
			os.Exit(1)
		}
		// ONE capped pool for the stores and a small one for the reference
		// data (round 743, txn.PoolSizes): every economy action is one
		// transaction on the stores' pool, and the reference lookups it makes
		// meanwhile never wait on that pool. Before, ten pools opened
		// uncapped.
		storeConns, refConns := txn.PoolSizes()
		storePool, err := txn.OpenPool(*postgresDSN, storeConns)
		if err != nil {
			logger.Error("opening the postgres pool", "error", err)
			os.Exit(1)
		}
		defer storePool.Close()
		refPool, err := txn.OpenPool(*postgresDSN, refConns)
		if err != nil {
			logger.Error("opening the reference-data pool", "error", err)
			os.Exit(1)
		}
		defer refPool.Close()
		logger.Info("postgres pools", "stores", storeConns, "refdata", refConns, "budgetVar", txn.MaxConnsEnv)
		serials = &txn.Serials{DB: storePool}

		sqlAccounts, err := account.NewSQLStore(storePool)
		if err != nil {
			logger.Error("opening account store", "error", err)
			os.Exit(1)
		}

		sqlChars, err := character.NewSQLStore(storePool)
		if err != nil {
			logger.Error("opening character store", "error", err)
			os.Exit(1)
		}
		// The economy ledger keeps a day (txn.PruneLedger): long past any
		// retry of the actions it guards.
		go func() {
			t := time.NewTicker(time.Hour)
			defer t.Stop()
			for {
				if n, err := txn.PruneLedger(ctx, storePool, 24*time.Hour); err != nil {
					logger.Warn("pruning the economy ledger", "error", err)
				} else if n > 0 {
					logger.Info("pruned the economy ledger", "rows", n)
				}
				select {
				case <-ctx.Done():
					return
				case <-t.C:
				}
			}
		}()

		sqlRef, err := refdata.NewSQLStore(refPool)
		if err != nil {
			logger.Error("opening refdata store", "error", err)
			os.Exit(1)
		}

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
			skills, skillsErr := sqlRef.CountSkills(ctx)
			drops, _ := sqlRef.CountMonsterDrops(ctx)
			groups, _ := sqlRef.CountDropGroupEntries(ctx)
			logger.Info("reference data in PostgreSQL", "items", items, "skills", skills,
				"monsterDrops", drops, "dropGroupEntries", groups)
			if items == 0 {
				logger.Warn("items table is EMPTY -- weapons have no stats and the shop sells nothing; " +
					"export the client's itemdata with cmd/export-refdata and load it with cmd/import-refdata " +
					"(see docs/HANDOFF_OPENSRO.md, 'Where the server actually is today')")
			}
			withStatus, err := sqlRef.CountSkillsWithStatusParams(ctx)
			if err == nil {
				err = skillsErr
			}
			if w := statusParamsWarning(false, skills, withStatus, err, *monsterAI); w != "" {
				logger.Warn(w)
			}
		}

		sqlInv, err := inventory.NewSQLStoreOwned(storePool, sqlRef, inventory.DefaultTable, inventory.DefaultOwnerColumn)
		if err != nil {
			logger.Error("opening inventory store", "error", err)
			os.Exit(1)
		}
		sqlInv.SetDurabilityLookup(sqlRef)

		// The warehouse is a second inventory container on its own table,
		// owned by the ACCOUNT (the game's `_CHEST WHERE UserJID=%d`; see
		// internal/storage). A database written by the older per-character
		// server is moved over once, losslessly, before anything opens it.
		sqlWarehouse, err := inventory.NewSQLStoreOwned(storePool, sqlRef, inventory.WarehouseTable, inventory.WarehouseOwnerColumn)
		if err != nil {
			logger.Error("opening warehouse store", "error", err)
			os.Exit(1)
		}
		sqlWarehouse.SetDurabilityLookup(sqlRef)
		sqlWarehouse.SetCapacity(storage.DefaultCapacity)
		// Each account's own size, grown by the expansion item (round 498).
		sqlWarehouse.SetCapacityFunc(storage.CapacityOf(sqlAccounts))
		storageGold = sqlAccounts
		chestSizes = sqlAccounts
		if moved, err := storage.MigrateToAccounts(ctx, sqlWarehouse.DB(), logger); err != nil {
			logger.Error("moving the warehouse to accounts", "error", err)
			os.Exit(1)
		} else if moved.Applied {
			logger.Info("warehouse moved from characters to accounts",
				"rows", moved.Rows, "reslotted", moved.Reslotted, "gold", moved.Gold,
				"characters", moved.Characters, "accounts", moved.Accounts, "orphanRowsLeft", moved.Orphans)
		}

		sqlEq, err := equipment.NewSQLStore(storePool, sqlInv)
		if err != nil {
			logger.Error("opening equipment store", "error", err)
			os.Exit(1)
		}
		// Worn rows written before durability existed get their instance on
		// first read, with the same roll a fresh bag item gets.
		sqlEq.SetFreshInstanceRoller(func(ctx context.Context, itemID int64) (inventory.Instance, error) {
			return inventory.FreshInstance(ctx, sqlRef, nil, itemID)
		})

		sqlSkills, err := skill.NewSQLStore(storePool)
		if err != nil {
			logger.Error("opening skill store", "error", err)
			os.Exit(1)
		}

		sqlGuilds, err := guild.NewSQLStore(storePool)
		if err != nil {
			logger.Error("opening guild store", "error", err)
			os.Exit(1)
		}

		sqlQuests, err := quest.NewSQLStore(storePool)
		if err != nil {
			logger.Error("opening quest store", "error", err)
			os.Exit(1)
		}

		sqlFriends, err := friend.NewSQLStore(storePool)
		if err != nil {
			logger.Error("opening friend store", "error", err)
			os.Exit(1)
		}

		accounts, registerer = sqlAccounts, sqlAccounts
		chars, refItems = sqlChars, sqlRef
		dropSrc = sqlRef
		warehouse = sqlWarehouse
		inv, eq, skills = sqlInv, sqlEq, sqlSkills
		guilds, quests, friends = sqlGuilds, sqlQuests, sqlFriends
		logger.Info("postgres storage ready")
	}

	// The bag's size per character (round 633): the character's own
	// (character.InventorySizeStore -- a GM's /invsize, an expansion item) or
	// -inventory-size, bounded to what the client can page. Every store
	// operation on the bag -- add, move, a slot's durability -- is held to it.
	bagDefault := inventory.ClampBagSlots(*inventorySize)
	bagSizes, _ := chars.(character.InventorySizeStore)
	if sized, ok := inv.(interface{ SetCapacityFunc(inventory.CapacityFunc) }); ok {
		sized.SetCapacityFunc(inventory.BagCapacity(bagSizes, bagDefault))
	}
	// A lower -inventory-size must not strand what a character carries: the
	// slots held past the size stay reachable (listed, removed, moved out),
	// while every new placement keeps to the size (inventory.heldReach, round
	// 633's review).
	if kh, ok := inv.(interface{ SetKeepHeld(*slog.Logger) }); ok {
		kh.SetKeepHeld(logger)
	}
	logger.Info("inventory size", "defaultSlots", bagDefault, "pages", (bagDefault+inventory.BagPageSlots-1)/inventory.BagPageSlots,
		"perCharacter", bagSizes != nil)

	shopSvc := &shop.Service{Gold: chars, Inv: inv, Items: refItems}
	storageSvc := &storage.Service{Bag: inv, Warehouse: warehouse, Gold: chars, Accounts: storageGold, ChestSizes: chestSizes, Items: refItems}
	zerkTracker := berserk.NewTracker()
	// The Energy of life scroll's grants (round 632 review, session/composite.go).
	compositeKeeper := session.NewCompositeKeeper()
	manaTracker := mana.NewTracker()

	hub := world.NewHub()

	// Passive recovery: CGObjPC::vslot_362 on each character's own 4 s timer,
	// a percentage of the MAXIMUM HP and MP -- 0.8% standing still, 8%
	// sitting, nothing while moving (round 607; internal/mana's note).
	go session.RunRegen(ctx, hub, chars, session.RegenDeps{
		Equipment: eq, Items: refItems, Skills: skills, Mana: manaTracker,
	}, logger)
	// Timed buffs end at their end time (round 616): the book's expiry
	// pass, broadcasting OpBuffEnd and the owner's new run speed.
	go session.RunBuffTicker(ctx, hub, logger)
	// A deleted character is removed 7 days after its deletion (round 682).
	// OURS: checked once a minute.
	lobbyChars, ok := chars.(session.LobbyStores)
	if !ok {
		logger.Error("the character store has no lobby (character.LobbyStore)")
		os.Exit(1)
	}
	go session.RunLobbyPurge(ctx, lobbyChars, time.Minute, nil, logger)
	// The toggles and the protection walls (round 640, session/walls.go):
	// each 'onff' toggle's MP drain and its end when the MP runs short, and
	// a wall's end once its HP is gone. The walls read the monster skills'
	// 'att' masks from the same skill table the casts use.
	session.SetMonsterSkillRefs(refItems)
	// The players' spawn records (round 737) ask the item table whether the
	// suit in equip slot 8 is a job suit: the record's job state, which
	// decides its guild block, as the client decides it.
	session.SetSpawnItemRefs(refItems)
	go session.RunToggleTicker(ctx, hub, chars, session.RegenDeps{
		Equipment: eq, Items: refItems, Skills: skills, Mana: manaTracker,
	}, logger)
	// The potion queue (round 509): an absolute HP/MP potion lands in five
	// steps of amount/5, the first at once and the rest one per second
	// (FUN_0049a5b0 / FUN_0049a510 from CGObjPC::PeriodicUpdate), each step
	// pushed to the client the way regen's are.
	potions := session.NewPotionQueue()
	go session.RunPotionQueue(ctx, hub, chars, potions, session.RegenDeps{
		Equipment: eq, Items: refItems, Skills: skills, Mana: manaTracker,
	}, logger)
	// The player's dead state (round 549), behind its own flag: a monster's
	// kill leaves the character dead until it asks for one of retail's two
	// resurrect choices (OpRevive; round 665). Nothing revives it unasked --
	// retail has no timed revive outside a fortress war, so round 549's 30 s
	// in-place fallback is gone. Set before the gateway serves, like the
	// monster flags below.
	session.SetPlayerDeadState(*deadState)
	if *deadState {
		logger.Info("player dead state on: a monster's kill leaves the player dead (life state 2, HP 0) until OpRevive 0x0028 -- option 1 to the return point, option 2 where it lies at level 10 or under")
	} else {
		logger.Info("player dead state off (-player-dead-state / OPENSRO_PLAYER_DEAD_STATE): a monster's kill respawns the player at once at the return point")
	}
	monsters := combat.NewHub()
	// Abnormal states (round 659, session/status.go): every monster's and
	// character's states expire and deal their damage ticks here, started
	// once the monster hub exists: a tick's caster is looked up in it.
	go session.RunStatusEffects(ctx, logger, session.RegenDeps{
		Equipment: eq, Items: refItems, Skills: skills, Mana: manaTracker,
	}, monsters)
	// Every monster hatches facing Nest_Hatch's heading, rand() / 32767.0 *
	// 2pi (0x5609ee..0x560a15, ai.SpawnHeading): the roster's species are all
	// the TypeID shape that takes it, and none is rarity 3, whose heading is
	// its nest row's own and server-database only (docs/protocol/monster_ai.md,
	// "The _RefNest row", row 8). Rolled at the spawn, before the first one, so
	// the spawn push and the monster AI's brain carry the same heading. The
	// roll runs under the hub's lock, which is what guards this rng.
	spawnHeadingRNG := rand.New(rand.NewSource(time.Now().UnixNano()))
	monsters.SetSpawnHeadingRoll(func() float64 { return ai.SpawnHeading(spawnHeadingRNG) })
	// Items on the ground: what a kill leaves near the corpse until it is
	// picked up (internal/grounditem). The sweep releases ownerships after the
	// 30 s window and removes stale items, telling each zone.
	ground := grounditem.NewHub()
	// One reference lookup per drop, taken before the hub locks: each drop
	// lies there for its own row's DecayTime (itemdata column 13; an item
	// without one gets grounditem.FallbackLifetime); an untradeable drop
	// (CanTrade, column 16, clear -- the quest items) is never released to
	// the zone (GObjPC::FUN_004901c0, grounditem.Item.Bound); a drop whose row
	// clears CanPick (column 21 -- the starter _DEF gear, fortress items) is
	// refused 0x1839 to everyone; and a TypeID 3/3/9 item not named
	// ITEM_QNO_RM_ARCHEMY* is its owner's alone, party or not
	// (GObjPC::CheckCanPickUp, grounditem.OwnerOnlyPick).
	ground.SetRulesLookup(groundDropRules(ctx, refItems))
	// Each drop gets its serial (round 743): the pick-up's key in the
	// economy ledger, so a drop is granted once.
	ground.SetSerialSource(func() int64 {
		v, err := serials.Next(ctx)
		if err != nil {
			logger.Warn("numbering a ground item", "error", err)
			return 0
		}
		return v
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
	// The monster species table (round 654), when the operator supplies it:
	// the roster's species numbers come from it, re-derived, and the GM
	// console knows every species in it. Loaded before the placements so
	// that what -npcpos-csv places is the overlaid roster. A configured path
	// that does not load is fatal, the npcpos rule. The attack lists resolve
	// through the same skill store the casts use (the -skills-csv memory
	// store, or PostgreSQL).
	var speciesTable *species.Table
	speciesSkills := species.RefdataLookup(func(id int64) (*refdata.Skill, error) { return refItems.GetSkill(ctx, id) })
	if *monstersCSV != "" {
		table, err := species.LoadCSV(*monstersCSV)
		if err != nil {
			logger.Error("loading the monster species table", "path", *monstersCSV, "err", err)
			os.Exit(1)
		}
		speciesTable = table
		ov := overlaySpeciesTable(monsterSpecs, table, speciesSkills)
		logger.Info("monster species table loaded", "path", *monstersCSV, "species", table.Len(),
			"roster_overlaid", ov.Overlaid, "roster_missing", len(ov.Missing), "roster_changed", len(ov.Changed))
		for _, m := range ov.Missing {
			logger.Warn("roster species not in the monster table: it keeps its hand-typed numbers", "name", m)
		}
		for _, c := range ov.Changed {
			logger.Warn("roster species numbers differ from the monster table: the table's are used", "change", c)
		}
		for _, k := range ov.Kept {
			logger.Warn("roster species kept hand-typed fields the table could not supply (re-export skills/levelgold/textdata_object, deploy/README.md)", "kept", k)
		}
	} else {
		logger.Info("no monster species table (-monsters-csv / OPENSRO_MONSTERS_CSV): the hand-typed roster is every species the server knows")
	}
	// The game's own placements, when the operator supplies them: every
	// species with rows takes them all, replacing both the embedded rows and
	// the own-design anchor. A configured path that does not load is fatal
	// rather than a silent fall-back to the anchors.
	var npcPlacements spawn.Table
	if *npcposCSV != "" {
		table, err := spawn.LoadCSV(*npcposCSV)
		npcPlacements = table
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
		inMonsterTable := 0
		for id := range table {
			if _, ok := speciesTable.ByID(id); ok {
				inMonsterTable++
			}
		}
		logger.Info("npcpos placements loaded", "species_in_table", len(table), "roster_species_placed", applied,
			"npcpos_species_in_monster_table", inMonsterTable)
	}
	// The towns (round 674): _RefRegion's IsBattleField, which the monster AI
	// removes a monster by when it enters a town region (session.SetSafeRegions).
	// Loaded and checked here so a bad export fails at boot.
	if *regionsCSV != "" {
		regions, err := safezone.Load(*regionsCSV)
		if err != nil {
			logger.Error("loading the region table", "path", *regionsCSV, "err", err)
			os.Exit(1)
		}
		session.SetSafeRegions(regions)
		// The removal is the monster AI's (round 674's review): the line says
		// so only when the AI runs.
		if *monsterAI {
			logger.Info("region table loaded: a monster entering a town region is removed (IsBattleField 0)",
				"path", *regionsCSV, "regions", regions.Len(), "towns", regions.SafeCount())
		} else {
			logger.Info("region table loaded (IsBattleField 0 are the towns), but the monster AI is off (-monster-ai): no monster moves, and none is removed",
				"path", *regionsCSV, "regions", regions.Len(), "towns", regions.SafeCount())
		}
	} else {
		logger.Info("no region table (-regions-csv / OPENSRO_REGIONS_CSV): no region is a town, and a monster follows a player into one")
	}
	// The magic option table (round 768): the alchemy stones' blue options.
	var magicOptions *magicopt.Table
	if *magicOptionsCSV != "" {
		t, err := magicopt.LoadCSVFile(*magicOptionsCSV)
		if err != nil {
			logger.Error("loading the magic option table", "path", *magicOptionsCSV, "err", err)
			os.Exit(1)
		}
		magicOptions = t
		// Round 769: the worn items' options count toward their stats.
		session.SetMagicOptions(t)
		logger.Info("magic option table loaded: the alchemy stones write blue options and worn options count", "path", *magicOptionsCSV, "rows", t.Len())
	} else {
		logger.Info("no magic option table (-magic-options-csv / OPENSRO_MAGIC_OPTIONS_CSV): every magic stone is refused")
	}
	// The magic option assign table (round 770): what equipment drops roll.
	if *magicOptAssignCSV != "" {
		a, err := magicopt.LoadAssignCSVFile(*magicOptAssignCSV)
		if err != nil {
			logger.Error("loading the magic option assign table", "path", *magicOptAssignCSV, "err", err)
			os.Exit(1)
		}
		session.SetDropOptions(refItems, a)
		if magicOptions == nil {
			logger.Warn("magic option assign table loaded, but no magic option table (-magic-options-csv): drops carry no blue options")
		} else {
			logger.Info("magic option assign table loaded: equipment drops roll blue options", "path", *magicOptAssignCSV, "rows", a.Len())
		}
	} else {
		logger.Info("no magic option assign table (-magic-option-assign-csv / OPENSRO_MAGIC_OPTION_ASSIGN_CSV): drops carry no blue options")
	}
	// The creatable catalogue (round 682): what the lobby's create checks
	// bodies and items against (session.LobbyDeps.Catalogue).
	var chargen *refdata.CreatableSet
	if *chargenCSV != "" {
		f, err := os.Open(*chargenCSV)
		if err == nil {
			chargen, err = refdata.LoadCreatableCSV(f)
			f.Close()
		}
		if err != nil {
			logger.Error("loading the creatable catalogue", "path", *chargenCSV, "err", err)
			os.Exit(1)
		}
		logger.Info("creatable catalogue loaded: characters can be created", "path", *chargenCSV, "ids", chargen.Len())
	} else {
		logger.Warn("no creatable catalogue (-chargen-csv / OPENSRO_CHARGEN_CSV): every character create is refused (0x403) -- see deploy/README.md \"Reference data\"")
	}
	// A new character's default masteries, skills and quests (round 692):
	// the shard DB's _RefCharDefault_* tables, as _AddNewChar applies them
	// (session.LobbyDeps.Defaults). EXTERNAL data, so it is the operator's to
	// supply; without it the create path gives none.
	var charDefaults *refdata.CharDefaults
	if *charDefaultsDir != "" {
		d, err := refdata.LoadCharDefaultsDir(*charDefaultsDir)
		if err != nil {
			logger.Error("loading the character defaults", "dir", *charDefaultsDir, "err", err)
			os.Exit(1)
		}
		charDefaults = d
		m, sk, q := d.Counts()
		logger.Info("character defaults loaded: new characters get their race's default masteries, skills and quests",
			"dir", *charDefaultsDir, "masteries", m, "skills", sk, "quests", q,
			"china", fmt.Sprintf("%d masteries, %d skills, %d quests", len(d.Masteries(0)), len(d.Skills(0)), len(d.Quests(0))),
			"europe", fmt.Sprintf("%d masteries, %d skills, %d quests", len(d.Masteries(1)), len(d.Skills(1)), len(d.Quests(1))))
		// Rows no character can match, and duplicates (given once, OURS).
		for _, w := range d.Warnings() {
			logger.Warn("character defaults: an odd row", "row", w)
		}
		// The shard's own list of creatable ids, when it is beside them: the
		// catalogue's rule should pick the same ids (MEASURED, round 692).
		refCharGenPath := filepath.Join(*charDefaultsDir, refdata.RefCharGenFile)
		if f, err := os.Open(refCharGenPath); err != nil {
			if !errors.Is(err, fs.ErrNotExist) {
				logger.Warn("the shard's _RefCharGen.csv is there but cannot be opened; the catalogue is not compared with it",
					"path", refCharGenPath, "err", err)
			}
		} else {
			ids, err := refdata.LoadRefCharGen(f)
			f.Close()
			switch {
			case err != nil:
				logger.Warn("the shard's _RefCharGen.csv does not load; the catalogue is not compared with it", "err", err)
			case chargen == nil:
				logger.Info("_RefCharGen.csv found but no creatable catalogue is loaded to compare it with", "ids", len(ids))
			default:
				if missing, extra := chargen.CompareRefCharGen(ids); len(missing) == 0 && len(extra) == 0 {
					logger.Info("the creatable catalogue agrees with the shard's _RefCharGen", "ids", len(ids))
				} else {
					logger.Warn("the creatable catalogue and the shard's _RefCharGen differ: creates follow the catalogue",
						"only_in_refchargen", missing, "only_in_catalogue", extra)
				}
			}
		}
	} else {
		logger.Warn("no character defaults (-chardefaults-dir / OPENSRO_CHARDEFAULTS_DIR): new characters get no default masteries, skills or quests -- see deploy/README.md \"Character defaults\"")
	}
	// The game's teleport network, when the operator supplies it (round 575).
	// Loaded and checked here so a bad export fails at boot, the npcpos rule;
	// session.TeleportHandler charges and moves by it (round 576), and refuses
	// every request without it.
	var teleportNetwork *teleport.Table
	if *teleportDir != "" {
		network, err := teleport.Load(*teleportDir)
		if err != nil {
			logger.Error("loading the teleport network", "dir", *teleportDir, "err", err)
			os.Exit(1)
		}
		teleportNetwork = network
		// The dungeons it serves (round 773): before the NPCs and the nests,
		// which place their dungeon rows only in these.
		session.InstallDungeonEntries(network)
		logger.Info("teleport network loaded", "dir", *teleportDir,
			"points", len(network.Points), "links", len(network.Links), "buildings", len(network.Buildings),
			"walk_ins", len(network.WalkIns), "dungeons_served", len(session.ServedDungeons()))
		if !network.HasWorldIDs() {
			logger.Warn("teleport network has no WorldID column (exported before round 642): links into " +
				"instanced areas (fortress, tomb, temple, arena, survival, Roc) are not refused up front -- " +
				"re-export it with cmd/export-refdata -mode teleport (deploy/README.md)")
		}
		placed := teleportObjectPlaces(network, npcPlacements)
		if npcPlacements == nil {
			logger.Warn("teleport NPCs' interaction range is not measured: no -npcpos-csv, so the server " +
				"does not know where the ferry, airship and tunnel sellers stand (gate structures are measured)")
		} else {
			logger.Info("teleport interaction range: NPC 300, structure 800 (IsWithinInteractionRange 0x4a8e10)",
				"npcs_placed", placed)
		}
		// The return point (round 686): a character's designated town gate,
		// else its race's (STORE_CH_GATE / STORE_EU_GATE), resolved on this
		// network. Without it a return goes to the zone arrival as before.
		session.SetRecallNetwork(network)
		_, chOK := network.PointByBuildingCode(session.RaceGateChina)
		_, euOK := network.PointByBuildingCode(session.RaceGateEurope)
		logger.Info("return points: designated at a town gate, else the race's gate",
			"china_gate", session.RaceGateChina, "china_found", chOK, "europe_gate", session.RaceGateEurope, "europe_found", euOK)
	} else {
		logger.Info("no teleport network: every return point is the zone arrival (jangan for China, constantinople for Europe)")
	}
	if *teleportFree {
		logger.Info("teleport free on: every gate teleport costs nothing (-teleport-free, own design, for testing)")
	} else {
		logger.Info("teleport free off (-teleport-free / OPENSRO_TELEPORT_FREE): a teleport charges its link's fee, waived below level 21 and for GM accounts")
	}
	// The full map (round 660): every field monster row, as nests. It needs the
	// placements and the species table, and the one world frame -- its rows
	// cover the whole map, not one zone's frame.
	if *fullMap && (npcPlacements == nil || speciesTable == nil) {
		logger.Warn("full map forced off: it needs -npcpos-csv (where every monster stands) and -monsters-csv (what each species is)")
		*fullMap = false
	}
	var nestDB *nest.DB
	if *nestDBDir != "" {
		db, err := nest.LoadDir(*nestDBDir)
		if err != nil {
			logger.Error("loading the nest DB", "dir", *nestDBDir, "err", err)
			os.Exit(1)
		}
		nestDB = db
		logger.Info("nest DB loaded (EXTERNAL: the user's shard backup, round 658)", "dir", *nestDBDir,
			"tactics", len(db.Tactics), "nests", len(db.Nests), "hives", len(db.Hives),
			"ai_skill_tactics", len(db.AISkills), "skills", len(db.Skills))
		if !*fullMap {
			logger.Warn("nest DB loaded but -full-map is off: the roster's stand-in nests do not use it")
		}
	}
	if *fullMap && !*singleFrame {
		logger.Info("full map: turning -single-frame on (its placements are named in the one world frame)")
		*singleFrame = true
	}
	// The one world frame (round 571), behind its own flag. Set before the
	// roster spawns and before gmSpecies: both read it for their monsters'
	// zone and coordinates (rosterInstances), and the world handlers for every
	// arrival (session.arrival).
	session.SetSingleFrame(*singleFrame)
	// Round 749: the move by destination's placement bound (destmove.go).
	session.SetTrustClientPositions(*trustPositions)
	// Round 786: the hold until the client's 0x3012 and the protection after
	// it (session/arrival.go).
	session.SetArrivalGuard(*arrivalGuard)
	session.SetArrivalLogger(logger)
	logger.Info("arrival guard", "on", *arrivalGuard)
	// Round 786: the game clock (session/celestial.go, worldclock).
	clockHour, clockMinute, clockErr := worldclock.ParseStart(*worldClockStart)
	if clockErr != nil {
		logger.Warn("-world-clock-start does not parse; the clock starts at 00:00", "err", clockErr)
		clockHour, clockMinute = 0, 0
	}
	session.SetGameClock(worldclock.New(time.Now(), 0, clockHour, clockMinute))
	session.SetClockAtEntry(*worldClockOn)
	logger.Info("game clock", "sent", *worldClockOn, "start", fmt.Sprintf("day 0 %02d:%02d", clockHour, clockMinute),
		"real_day", worldclock.RealDay.String())
	if *trustPositions {
		logger.Warn("trust-client-positions on: every position a client reports is taken (QA only)")
	}
	if *singleFrame {
		logger.Info(fmt.Sprintf("single frame on: origin %d/%d -- every zone with a frame is named in one frame and kept in one bucket (%q), every roster monster with it; a zone change lands at the town's landing in that frame",
			worldmap.WorldOrigin[0], worldmap.WorldOrigin[1], worldmap.WorldBucket))
	} else {
		logger.Info("single frame off (-single-frame / OPENSRO_SINGLE_FRAME)")
	}
	// The saved position (round 573), behind its own flag. Set before the
	// gateway serves, like the single frame above: every world handler reads
	// it.
	session.SetPersistPosition(*persistPosition)
	if *persistPosition {
		logger.Info("persist position on: a character re-enters where it last stood (saved on disconnect, zone change, every 30 s of walking and at stop)")
	} else {
		logger.Info("persist position off (-persist-position / OPENSRO_PERSIST_POSITION)")
	}
	// The spawn push (round 542), behind its own flag: a respawn or a GM /spawn
	// is sent to its zone as OpMonsterSpawned the moment it appears. Set
	// before the roster's first spawn, like the heading roll above.
	session.SetMonsterSpawnPush(*spawnPush)
	if *spawnPush {
		logger.Info("monster spawn push on: OpMonsterSpawned 0x007E to the zone for each respawn and GM /spawn")
	} else {
		logger.Info("monster spawn push off (-monster-spawn-push / OPENSRO_MONSTER_SPAWN_PUSH)")
	}
	// The NPCs (round 708): the server spawns them, as retail does, and the
	// client builds none of its own. Installed after SetSingleFrame (their
	// frame) and before the area of interest's first tick.
	var testItems *testItemsNPCSpec
	if *testItemsNPC {
		testItems = resolveTestItemsNPC(ctx, logger, refItems)
	}
	installNPCs(logger, npcPlacements, speciesTable, nestDB, teleportNetwork, *npcsCSV, testItems)
	// The monsters' area of interest (round 656): each player hears about the
	// monsters of the 3x3 message blocks around it (retail's, READ in round
	// 664: 320-unit blocks and their 8 neighbours), and is told as they come
	// into and go out of that window. Always on; installed before the first
	// spawn.
	session.RunMonsterAOI(ctx, hub, monsters, logger)
	logger.Info(fmt.Sprintf("monster area of interest: %d block(s) of %.0f units each way around a player (retail's message blocks, READ); list paged, enter/leave pushed",
		session.AOIRadius, combat.CellSpan))
	// The unique notices (round 657): on unless -unique-notice-off. A roster
	// unique's hatch is announced from the same spawn hook as the push.
	session.SetUniqueNoticeOff(*uniqueNoticeOff)
	if uniqueOffEnvErr != nil {
		logger.Warn("OPENSRO_UNIQUE_NOTICE_OFF is not a boolean; the unique notices stay on unless -unique-notice-off is given",
			"error", uniqueOffEnvErr)
	}
	if *uniqueNoticeOff {
		logger.Info("unique notices off (-unique-notice-off): no nest-hatch or kill notice is sent; a GM spawn is still announced")
	} else {
		logger.Info("unique notices on: a unique's appearance and death go to every character (OpUniqueNotice 0x0110)")
	}
	spawned := func(id int64) {
		session.BroadcastMonsterSpawned(hub, monsters, id)
		if m, ok := monsters.Get(id); ok {
			session.AnnounceUniqueSpawn(hub, m, true)
		}
	}
	// Every species' instances -- a monster per real npcpos row, or a cluster
	// around the own-design anchor -- in the zone and frame -single-frame
	// (set above) says: rosterInstances.
	//
	// One respawn scheduler for all of them (round 656), where there was a
	// goroutine per placement.
	if err := checkNestRespawn(*nestRespawn); err != nil {
		logger.Error("-nest-respawn / OPENSRO_NEST_RESPAWN refused", "err", err)
		os.Exit(1)
	}
	if err := checkUniqueRespawn(*uniqueRespawn); err != nil {
		logger.Error("-unique-respawn / OPENSRO_UNIQUE_RESPAWN refused", "err", err)
		os.Exit(1)
	}
	respawns := newRespawnScheduler(monsters, logger, spawned)
	respawns.delayOverride = *nestRespawn
	if *nestRespawn > 0 {
		logger.Info(fmt.Sprintf("nest respawn override: every nest's window but the uniques' is %v at both ends (-nest-respawn, for testing)", *nestRespawn))
	}
	respawns.uniqueOverride = *uniqueRespawn
	if *uniqueRespawn > 0 {
		logger.Info(fmt.Sprintf("unique respawn override: a unique reappears %v after its death (-unique-respawn, OURS, for testing)", *uniqueRespawn))
	}
	if *fullMap {
		// Round 660: every field monster row as a nest, replacing the roster's
		// placements (the roster's species are rows of npcpos too).
		nestSwappedStandIn = *swappedStandIn
		if *swappedStandIn {
			logger.Info("full map: -nest-swapped-stand-in: the swapped spots run one-monster stand-in nests (OURS)")
		}
		slots, rep := fullMapSlots(npcPlacements, speciesTable, speciesSkills, nestDB)
		for _, sl := range slots {
			respawns.addSlot(sl)
		}
		logFullMap(logger, rep, nestDB != nil)
		logUniques(logger, rep.uniques, *uniqueRespawn, nestDB != nil && nestDB.Skills != nil)
	} else {
		for _, spec := range monsterSpecs {
			for _, inst := range rosterInstances(spec, logger) {
				respawns.add(inst)
			}
		}
	}
	// The QA spread (round 656, -qa-spread-monsters): N more placements over
	// the regions around Jangan, for the area of interest's live check.
	for _, inst := range qaSpreadInstances(*qaSpread, *qaSpreadRadius, monsterSpecs) {
		respawns.add(inst)
	}
	respawns.quiet = respawns.nests > 200
	// The kill's party arming (round 660): a kill with more than one of the
	// killer's party members within 1000 units arms the nest for a party
	// monster (session/nestkill.go, internal/nest). Only with -full-map: the
	// roster's stand-in placements keep what they hatched before (round
	// 660's review), so a deploy without the flag is unchanged.
	if *fullMap {
		session.SetMonsterKillObserver(respawns.armParty)
	}
	go respawns.run(ctx)

	// The monster's own BATTLE (round 546), behind its own flag, which needs
	// the tick (the chase runs in it) and the strike push (a swing nobody is
	// told about is silent HP loss). Forced off with a WARN rather than an
	// exit, so the update loop never rolls back over a flag combination. Set
	// before the AI starts and before the gateway serves.
	battleOn, battleWhy := monsterBattleAllowed(*battle, *monsterAI, *strikePush)
	if *battle && !battleOn {
		logger.Warn("monster battle forced off", "why", battleWhy)
	}
	session.SetMonsterBattle(battleOn)
	if battleOn {
		logger.Info("monster battle on: a struck monster chases to its attack band at its run speed and swings on its skill's ReuseDelay, each blow pushed as OpMonsterAttacked 0x007D; a party member's first hit on a monster links as many of its ten nearest neighbours as the party has members within 1000 units")
	} else {
		logger.Info("monster battle off (-monster-battle / OPENSRO_MONSTER_BATTLE)")
	}

	// Target acquisition (round 552), behind its own flag, which needs the
	// battle in effect (a noticed player is engaged by the chase and the
	// swings) and the dead state (a monster that seeks players out kills ones
	// who never struck it). Forced off with a WARN, never an exit. Set before
	// the AI starts, like the battle above.
	aggroOn, aggroWhy := monsterAggroAllowed(*aggro, battleOn, *deadState)
	if *aggro && !aggroOn {
		logger.Warn("monster aggro forced off", "why", aggroWhy)
	}
	session.SetMonsterAggro(aggroOn)
	if aggroOn {
		logger.Info(fmt.Sprintf("monster aggro on: an aggressive monster notices the nearest living player within its collision radius + its tactics row's sight (EXTERNAL; %d units for a monster without one, own design) every 1001-1500 ms while idle, wandering or home from its blackout, and engages it; a passive one fights only when struck", ai.TacticsDetectionDistance))
	} else {
		logger.Info("monster aggro off (-monster-aggro / OPENSRO_MONSTER_AGGRO)")
	}

	// The monster AI (round 537), behind its kill switch. Installed here,
	// before the gateway serves, so no handler ever sees it half-started.
	if *monsterAI {
		session.RunMonsterAI(ctx, hub, monsters, logger, session.MonsterAIConfig{
			Trace: os.Getenv("OPENSRO_AI_TRACE") != "",
			// What a monster's own swing reads and writes (-monster-battle),
			// the potion queue its kill empties (-player-dead-state), and the
			// party hub the aggro link reads (round 553, with the battle on).
			Chars: chars, Equipment: eq, Items: refItems, Mana: manaTracker, Potions: potions,
			Parties: parties,
			// The sleep (round 656, -monster-sleep).
			Sleep: *monsterSleep,
			// The tick's cost, once a minute (round 660).
			TickStats: os.Getenv("OPENSRO_AI_TICK_STATS") != "",
		})
		logger.Info(fmt.Sprintf("monster AI on: tick %v (own design), roam radius %.0f (own design), sleep %v (own design)",
			session.MonsterAITick, session.MonsterRoamRadius, *monsterSleep))
	} else {
		logger.Info("monster AI off (-monster-ai / OPENSRO_MONSTER_AI)")
	}

	// The strike push (round 541), behind its own flag and independent of the
	// AI: a monster's counterattack is sent to its zone as OpMonsterAttacked.
	// Set here, before the gateway serves, like the AI above.
	session.SetMonsterStrikePush(*strikePush)
	if *strikePush {
		logger.Info("monster strike push on: OpMonsterAttacked 0x007D to the zone after each counterattack")
	} else {
		logger.Info("monster strike push off (-monster-strike-push / OPENSRO_MONSTER_STRIKE_PUSH)")
	}

	// The GM console (docs/DEBUG_TOOLS.md). The gate is the account-username
	// list; the deps are the same stores every other handler uses, so a GM
	// command is those stores' own methods and nothing more. The species and
	// zones a GM can name are built from the running roster and the world map.
	gmGate := gm.ParseAccounts(*gmAccounts)
	if names := gmGate.Names(); len(names) > 0 {
		logger.Info("GM accounts enabled", "accounts", names)
	} else {
		logger.Info("no GM accounts set (-gm-accounts / OPENSRO_GM_ACCOUNTS) -- the GM console is off")
	}
	gmDeps := &gm.Deps{
		Chars: chars, Inv: inv, Equip: eq, Items: refItems, Skills: skills,
		Monsters: monsters, World: hub, Mana: manaTracker, Berserk: zerkTracker, Levels: levelTable,
		Species: gmSpecies(), Zones: gmZones(), Logger: logger,
		Uniques: gmUniques(), Parties: parties,
	}
	if speciesTable != nil {
		gmDeps.LookupSpecies = gmSpeciesLookup(speciesTable, speciesSkills)
		gmDeps.LookupCount = speciesTable.Len()
	}

	// Guild points (round 525): the skill points a guild member converts out
	// of skill experience also go to the guild, batched at 10
	// (GObjPC_GainExpAndLevel 0x4e5250 -> CGuild::AddPoints 0x5c4110; see
	// session.NewGuildPointSkills). Only the kill paths get the wrapper: they
	// are the only callers of AddSkillExp, and everything else keeps the
	// plain store. Points still pending when a character leaves the world go
	// to the guild then, whatever their count (FUN_004def90's flush,
	// 0x4def96-0x4defc2): guildPointsDisconnect below, and FlushAllPending
	// once the listener stops.
	gpSkills := session.NewGuildPointSkills(skills, guilds, chars)

	// The server list's status (round 679): read when asked.
	serverStatus := func() session.ServerStatus {
		return session.ServerStatus{Current: hub.Count(), Max: capacity, Inspection: *inspection}
	}
	// The login rules (round 788): every front door's, the logged-in table
	// the GM console's /block reaches an account through.
	loginSvc := &session.LoginService{Accounts: accounts, Status: serverStatus, Staff: gmGate.Allows,
		Online: session.NewOnlineAccounts(), Rules: loginRules, Logger: logger}
	gmDeps.Sessions = session.GMSessions{Hub: hub, Online: loginSvc.Online}
	gmDeps.Punishments, _ = accounts.(account.PunishmentStore)
	gmDeps.AccountLookup, _ = accounts.(account.AccountLookup)
	// Where a new character's defaults go (round 692): both stores, memory
	// and SQL, take them.
	defaultSkills, _ := skills.(session.CharDefaultSkills)
	defaultQuests, _ := quests.(session.CharDefaultQuests)
	if charDefaults != nil && (defaultSkills == nil || defaultQuests == nil) {
		logger.Warn("character defaults loaded but a store cannot take them", "skills", defaultSkills != nil, "quests", defaultQuests != nil)
	}
	// The party on retail's opcodes (round 710): the handlers, the logout
	// removal and the 1 s member-update sampler (session/party.go).
	partyDeps := session.PartyDeps{Chars: chars, Hub: hub, Parties: parties, Trades: trades, Guilds: guilds, Skills: skills, Mana: manaTracker, Logger: logger}
	go session.RunPartyUpdates(ctx, partyDeps)
	// Party matching on retail's opcodes (round 713): the listings, their
	// pages and the join request with its 15 s backstop
	// (session/partymatch.go, party/match.go).
	partyMatchDeps := session.PartyMatchDeps{PartyDeps: partyDeps, Match: party.NewMatcher(parties)}
	go session.RunPartyMatchSweep(ctx, partyMatchDeps)
	// Round 769: a character's Str, Int and max HP/MP count its worn items'
	// blue options (character.BonusOf), read from the equipment store.
	session.SetEquipBonusSource(eq)
	// The quest catalogue (round 785, internal/quest): exported from the
	// operator's own archives and game server scripts; without it no quest is
	// offered and the NPCs keep their static talk stand-in.
	if *questsDir != "" {
		cat, err := quest.LoadDir(*questsDir)
		if err != nil {
			logger.Error("loading the quest catalogue", "dir", *questsDir, "err", err)
			os.Exit(1)
		}
		items, _ := refItems.(session.QuestItems)
		if items == nil {
			logger.Warn("the item store cannot look items up by code name: quest items and item rewards are not given")
		}
		session.InstallQuests(cat, session.QuestDeps{Store: quests, Chars: chars, Inv: inv, Items: items,
			Skills: skills, Hub: hub, MP: manaTracker, Logger: logger})
		cv := cat.Coverage()
		logger.Info("quest catalogue loaded: NPCs offer their quests", "dir", *questsDir, "quests", cv.Total,
			"playable", cv.Playable, "scripted", cv.Script, "compiled_not_extracted", cv.Compiled, "questdata_only", cv.None)
	} else {
		logger.Warn("no quest catalogue (-quests-dir / OPENSRO_QUESTS_DIR): no quest is offered -- see deploy/README.md \"Quests\"")
	}

	handle := gateway.Chain(
		// The front-end theme (round 678): answered on any connection, before
		// and without login; the client asks on a short connection of its own.
		session.FrontEndThemeHandler(frontEndTheme),
		// The status for the client's server list (round 679), the same way.
		session.ServerStatusHandler(serverStatus),
		// One LoginService decides every login, whatever wire it came in on
		// (round 788): the old 0x0001 with its reason string, and retail's
		// 0x6102 -> 0xA102 on our framing. Inspection and a full server turn
		// a login away there, the GM accounts passing both (round 679).
		session.LoginHandlerFor(loginSvc),
		session.GatewayLoginHandler(loginSvc),
		session.RegisterHandler(registerer),
		// The character lobby on retail's 0x7007/0x7001 (round 682): list,
		// create (dressed in what the player chose, plus the shield or
		// ammunition the server adds), the name check, the 7-day delete and
		// restore. Start is the world handler's.
		session.LobbyHandler(session.LobbyDeps{
			Chars: lobbyChars, Catalogue: chargen, Inv: inv, Eq: eq, Guilds: guilds, Mana: manaTracker, Hub: hub, Logger: logger,
			Defaults: charDefaults, Skills: defaultSkills, Quests: defaultQuests,
		}),
		// An older client's 0x0010/0x0012/0x0014 are told, in their own
		// reply format, to update (round 682's review).
		session.LegacyLobbyHandler(logger),
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
			// The legacy kit is China's; a European character is left as it is
			// (round 682's review, OURS; equipment.GiveStartingKit).
			if character.RaceOf(c.Gender) == character.RaceEurope {
				return nil
			}
			logger.Info("dressing a character that had nothing", "character", c.Name)
			return equipment.GiveStartingKit(ctx, inv, eq, c.ID, c.Gender)
		}, zerkTracker),
		session.InventoryHandler(chars, inv, refItems),
		session.InventoryMoveHandler(chars, inv, refItems),
		session.EquipmentHandlerWithBroadcast(chars, eq, inv, refItems, trades, hub),
		session.CharacterStatsHandler(chars, eq, refItems, skills, manaTracker),
		session.SpendStatPointsHandler(chars, eq, refItems, skills, manaTracker),
		session.GMCommandHandler(chars, gmGate, gmDeps, hub, logger),
		// The town teleporters (round 576): a gate's MOVE, charged and moved
		// by the teleport network; GM accounts travel free (the same gate as
		// the console), and everyone under -teleport-free.
		session.TeleportHandler(chars, eq, hub, teleportNetwork, gmGate, *teleportFree, logger, zerkTracker),
		session.ShopHandler(chars, shopSvc, trades),
		session.RepairHandler(chars, eq, refItems, trades),
		session.StorageHandler(chars, storageSvc, trades),
		// Round 728: split, sell, deposit and the buy back on the retail
		// 0x7034/0xB034 and 0x7168/0xB168 (session/itemop.go).
		session.ItemOpHandler(session.ItemOpDeps{Hub: hub, Inv: inv, Shop: shopSvc, Storage: storageSvc, Trades: trades}),
		// Round 778: the return scroll and the reverse return scroll
		// (session/scroll.go), the map option's points from -teleport-dir's
		// optionalteleport.csv (SetRecallNetwork's table).
		session.UseItemHandler(chars, inv, refItems, manaTracker, storageSvc, potions, hub, zerkTracker, gmGate, compositeKeeper,
			session.NewScrollCaster(chars, eq, hub, zerkTracker, logger)),
		session.CompositeHandler(chars, refItems, compositeKeeper, zerkTracker, gmGate, hub),
		// Round 768: the alchemy window's elixirs and stones (session/alchemy.go).
		session.AlchemyHandler(session.AlchemyDeps{Hub: hub, Inv: inv, Items: refItems, Options: magicOptions, Logger: logger}),
		session.CombatHandlerWithDrops(chars, eq, refItems, hub, monsters, quests, inv, gpSkills, zerkTracker, manaTracker, parties, ground, dropSrc, potions),
		session.GroundItemHandler(chars, hub, ground, inv, parties),
		session.LearnSkillHandler(chars, skills, refItems),
		session.UseSkillHandlerWithDrops(chars, eq, refItems, gpSkills, hub, monsters, quests, inv, refItems, zerkTracker, manaTracker, parties, ground, dropSrc, potions),
		// OpBuffCancel (round 616): the right-click cancel of a buff.
		session.BuffHandler(chars, hub),
		// OpRevive (round 549): answered whatever the flag says -- with it off
		// nobody is ever dead and the reply is "not dead", which no client
		// asks for since none is dead.
		session.ReviveHandler(chars, hub, session.RegenDeps{Equipment: eq, Items: refItems, Skills: skills, Mana: manaTracker, Berserk: zerkTracker}),
		session.SkillListHandler(chars, skills),
		session.SkillStateHandlerWithRefs(chars, skills, refItems),
		session.RaiseMasteryHandler(chars, skills),
		session.PartyHandler(partyDeps),
		session.PartyMatchHandler(partyMatchDeps),
		session.GuildHandler(chars, guilds, hub),
		// Chat (round 634): the five channels, whispers, the global
		// chatting item and the GM's type-3 line.
		session.ChatHandler(session.ChatDeps{Hub: hub, Parties: parties, Guilds: guilds, Inv: inv, Items: refItems, Gate: gmGate}),
		// The quests (round 785, session/quest.go): the talk pages' answers,
		// the reward, the give-up and the window's reward button.
		session.QuestHandler(),
		session.DuelHandler(chars, eq, refItems, hub, duels),
		session.TradeHandler(chars, inv, refItems, hub, trades),
		session.FriendHandler(chars, friends, hub),
		// N sits down and stands up (round 607): the retail 0x704f request
		// and its 0x30bf broadcast; the motion state sets the regen rate.
		session.MotionHandler(hub),
		// The action window's emotes (round 781): the retail 0x3091, the
		// byte echoed to the character's watchers.
		session.EmoteHandler(hub),
		// The retail NPC interaction (round 727): select 0x7045 -> 0xB045
		// with the NPC's interaction ids, open 0x7046 -> 0xB046, end 0x704B.
		session.NPCTalkHandler(hub, trades),
		// The Auto potion window's settings (round 786): retail's 0x7158 type
		// 2, stored per character and sent back after the world entry.
		session.AutoPotionHandler(autoPotionStoreOf(chars), hub, logger),
	)

	worldDisconnect := session.WorldDisconnectHandler(hub, chars)
	// Round 632's composite review: a leaving character's berserk turn,
	// charges and expired jobs are forgotten (before worldDisconnect, while
	// the hub still knows the session).
	berserkDisconnect := session.BerserkDisconnectHandler(hub, zerkTracker, compositeKeeper)
	partyDisconnect := session.PartyDisconnectHandler(partyDeps)
	partyMatchDisconnect := session.PartyMatchDisconnectHandler(partyMatchDeps)
	duelDisconnect := session.DuelDisconnectHandler(hub, duels)
	tradeDisconnect := session.TradeDisconnectHandler(hub, trades)
	guildPointsDisconnect := session.GuildPointsDisconnectHandler(hub, gpSkills)

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
			lvl := slog.LevelInfo
			if quietQuery(p.Opcode) {
				lvl = slog.LevelDebug
			}
			logger.Log(ctx, lvl, "packet received", "addr", sess.RemoteAddr(), "opcode", p.Opcode, "size", len(p.Data))
			return handle(ctx, sess, p)
		},
		// The unauthenticated one-question connections (round 679's review):
		// their lines go to Debug.
		Quiet: quietQuery,
		OnDisconnect: func(sess *gateway.Session) {
			// duelDisconnect/tradeDisconnect/guildPointsDisconnect must run
			// before worldDisconnect: all three look the disconnecting
			// session up in world.Hub, which worldDisconnect removes them
			// from.
			// Each hook runs under its own recover (round 737's verification,
			// P2): a panic in an early one must not skip the rest, above all
			// worldDisconnect, or the hub keeps a ghost body.
			step := func(name string, f func()) {
				defer func() {
					if r := recover(); r != nil {
						logger.Error("disconnect hook panicked", "hook", name, "panic", r, "stack", string(debug.Stack()))
					}
				}()
				f()
			}
			step("duel", func() { duelDisconnect(sess) })
			step("trade", func() { tradeDisconnect(sess) })
			step("npc", func() { session.ForgetNPCInteraction(sess.ID()) })
			step("quest", func() { session.ForgetQuestSession(sess.ID()) })
			step("guild points", func() { guildPointsDisconnect(sess) })
			step("berserk", func() { berserkDisconnect(sess) })
			// The party removal first, then the match entry, as the
			// ShardManager's logout does (SM 0x4296f0: 0x44f580 moves a
			// leader's entry to the next leader before 0x451590 deletes a
			// party-less owner's). Both before worldDisconnect: the match hook
			// reads the session's character from world.Hub, and a page built
			// while a leader is out of the world but still in its party would
			// otherwise skip its entry (round 713's review).
			step("party", func() { partyDisconnect(sess) })
			step("party match", func() { partyMatchDisconnect(sess) })
			step("world", func() { worldDisconnect(sess) })
			// Last (round 788): the account may log in again only once the
			// world has saved and let go of its character.
			step("login", func() { loginSvc.SessionEnded(sess) })
		},
	}

	if err := srv.ListenAndServe(ctx); err != nil {
		logger.Error("gateway server exited", "error", err)
		os.Exit(1)
	}

	// The gateway does not run OnDisconnect for sessions still open when it
	// stops, so the guild points they have pending are flushed here, before
	// the deferred store Closes (see GuildPointSkills.FlushAllPending: this
	// is OpenSRO's own handling). ctx is already cancelled at this point;
	// the 30 s bound is OpenSRO's own too, so a stalled database cannot hold
	// the stop open. It runs while connection goroutines and keep-up swings
	// may still be booking points, and main does not wait for them: points
	// booked after the flush passes a character are lost at exit (up to nine
	// pending per character on a clean stop, plus any batch of ten or more
	// whose credit is still running when main returns) -- disclosed, not
	// closed, in FlushAllPending's comment (round 527; the batch named here
	// in round 531).
	flushCtx, cancelFlush := context.WithTimeout(context.Background(), 30*time.Second)
	gpSkills.FlushAllPending(flushCtx)
	cancelFlush()
	// The same gap for the saved position (round 573): every character still
	// in the world is saved where it stands, before the deferred store Closes.
	// A no-op with -persist-position off.
	session.SaveAllPositions(hub, chars)
}

// gmZones is what /goto accepts: the named zones, then each dungeon the
// teleport network serves by its label (round 773, "dungeon/32769"), whose
// zone change lands at the dungeon's entry.
func gmZones() []string {
	out := worldmap.ZoneNames()
	for _, rid := range session.ServedDungeons() {
		out = append(out, worldmap.DungeonZone(rid))
	}
	return out
}

// autoPotionStoreOf is chars' AutoPotionStore, or nil when the store keeps
// none (round 786).
func autoPotionStoreOf(chars character.Store) character.AutoPotionStore {
	if s, ok := chars.(character.AutoPotionStore); ok {
		return s
	}
	return nil
}
