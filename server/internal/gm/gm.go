// Package gm is the server's game-master console: the gate that decides who
// may use it and the commands themselves. It exists so a tester can put the
// world into a known state -- a level, an item, a monster, a place -- and
// report facts instead of impressions.
//
// Everything here is this project's own tooling. None of it mirrors an
// original-client feature, and nothing in it is presented as one.
//
// The gate is a list of account usernames (the -gm-accounts flag, env
// SRREVAMP_GM_ACCOUNTS); with none named, nobody is a GM. Every command,
// allowed or refused, is logged with the account that sent it.
//
// The commands only call the stores' existing methods: a level-up here is
// the same SetLeveling/ResetHP/mana refill the combat path does, an item is
// the same AddItem the shop uses, a kill is the hub's own ApplyDamage. What
// they deliberately skip -- kill rewards, drops, quest credit -- is said in
// each command's reply.
package gm

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sort"
	"strconv"
	"strings"

	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/leveldata"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Gate is the set of account usernames allowed to run GM commands.
type Gate struct {
	names map[string]bool
}

// ParseAccounts builds a Gate from a comma-separated list of usernames, the
// form the -gm-accounts flag and SRREVAMP_GM_ACCOUNTS take. Names are
// trimmed of surrounding whitespace; empty entries are ignored; the case is
// the one the account store holds (accounts.username), compared exactly.
func ParseAccounts(list string) *Gate {
	g := &Gate{names: map[string]bool{}}
	for _, part := range strings.Split(list, ",") {
		name := strings.TrimSpace(part)
		if name != "" {
			g.names[name] = true
		}
	}
	return g
}

// Allows reports whether username may run GM commands. A nil Gate allows
// nobody, which is what a server started without the flag gets.
func (g *Gate) Allows(username string) bool {
	if g == nil || username == "" {
		return false
	}
	return g.names[username]
}

// Names returns the gated usernames, sorted -- for the startup log line.
func (g *Gate) Names() []string {
	if g == nil {
		return nil
	}
	out := make([]string, 0, len(g.names))
	for n := range g.names {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// Actor is who is running a command and where they stand.
type Actor struct {
	Account     string
	CharacterID int64
	Name        string
	// Zone and the position come from world.Hub; Zone is "" when the
	// character has not entered the world, which the world-bound commands
	// refuse. Zone is the hub's bucket (world.Entity.Zone): the zone label,
	// or worldmap.WorldBucket under cmd/server's -single-frame (round 571),
	// which no zone label equals -- so there /goto <zone> is never "already
	// in" and /goto <monster> always carries the species' zone, and the
	// client re-centres its grid on that town before it moves the GM.
	Zone    string
	X, Y, Z float64
	// TargetMonsterID is the monster the client has selected, or 0.
	TargetMonsterID int64
	// Dead is the character's life state as world.Hub holds it (round 549,
	// session/deadstate.go): /tp and /goto refuse a dead actor.
	Dead bool
}

// Species is one kind of monster /spawn and /goto know, with the stats a
// spawn of it gets -- the same figures cmd/server's roster hands
// maintainMonster -- and the spot the roster keeps it at.
type Species struct {
	combat.Species
	// Zone is the species' zone LABEL (cmd/server's roster zone), what
	// /goto hands the client to re-centre on -- not the hub bucket its
	// monsters are spawned in, which under -single-frame is the one world's
	// (round 571). X/Z are in the frame the server keeps the monster in.
	Zone    string
	MaxHP   int
	Defense int
	Attack  int
	Gold    int64
	X, Z    float64
}

// deadRefusal is what /tp and /goto answer a dead actor (round 549). OWN
// DESIGN, disclosed: a GM's teleport has no retail counterpart to read a
// life-state test from; refusing keeps the server's position and the
// client's held die pose together until the GM revives. The other commands
// run as before -- /heal on a dead character fills its pools without reviving
// it, which the Revive button then sets to the respawn fraction.
const deadRefusal = "you are dead: revive first"

// Result is a command's outcome, for the session layer to send back.
type Result struct {
	// Text is the reply line the client prints in chat.
	Text string
	// Refused is set for a command that did nothing: unknown, malformed,
	// or not possible in the current state.
	Refused bool

	// HasPos asks the client to move the character to X/Z (Y is resolved
	// client-side, off the walkable graph). Zone, when set, is a different
	// zone to enter first.
	HasPos  bool
	Zone    string
	X, Y, Z float64

	// Which client views the command made stale.
	RefreshStats     bool
	RefreshMonsters  bool
	RefreshInventory bool
	RefreshEquipment bool

	// KilledMonsterID is the monster /kill or /damage removed, for the
	// session layer to announce to the zone the way a combat kill is
	// announced.
	KilledMonsterID int64
	// Killed is that monster as it died, and KillHits its damage list (the
	// hub's, combat.Hub.ApplyDamageFrom), for the unique kill notice (round
	// 657, session.AnnounceUniqueKill). A /kill credits nobody, so its list
	// holds only the blows players struck before it.
	Killed   *combat.Monster
	KillHits []combat.Hit
	// SpawnedMonsterIDs are the monsters /spawn made, in order, for the
	// session layer to push to the zone (session.BroadcastMonsterSpawned,
	// round 542, behind -monster-spawn-push); empty for every other command.
	SpawnedMonsterIDs []int64
	// LevelUp is set when /level raised the character, carrying what the
	// combat path's OpLevelUp carries.
	LevelUp *LevelUp
	// Notice is /notice's text, for the session layer to broadcast to every
	// character as a chat type-7 line (round 634, session.BroadcastNotice).
	Notice string
}

// LevelUp mirrors the combat path's level-up announcement.
type LevelUp struct {
	NewLevel   int
	StatPoints int
}

// Deps are the stores and hubs the commands act on. Any of them may be nil;
// a command whose dependency is missing refuses with a reply saying so
// rather than panicking.
type Deps struct {
	Chars    character.Store
	Inv      inventory.Store
	Equip    equipment.Store
	Items    combat.ItemLookup
	Skills   skill.Store
	Monsters *combat.Hub
	// World is the world hub whose cached level /level moves with the row
	// (world.Entity.Level, round 555); nil leaves the cache alone.
	World *world.Hub
	Mana  *mana.Tracker
	// Berserk is the orb tracker /hwan sets; nil refuses it.
	Berserk *berserk.Tracker
	Levels  *leveldata.Table
	Species []Species
	// Parties is the party hub the unique kill notice groups attackers by
	// (round 657, session.AnnounceUniqueKill); nil groups nobody.
	Parties *party.Hub
	// Uniques are the unique monsters /spawnunique knows (round 657): none
	// is placed in the world yet, so the console is how one is met.
	Uniques []Species
	// Zones are the named zones /goto accepts (worldmap.ZoneCentre's keys).
	Zones  []string
	Logger *slog.Logger
	// Speed is what /speed drives (round 636); nil refuses it. The session
	// layer fills it in (session.GMCommandHandler) when the server leaves it
	// nil.
	Speed SpeedControl
}

// SpeedControl is /speed's hook into the run speed the server tells a
// client (round 636; the buff book's speed path, session.gmSpeed).
type SpeedControl interface {
	// SetGMSpeed sets characterID's /speed multiplier (1 clears it), tells
	// the character's client its new run speed, and returns that speed.
	SetGMSpeed(characterID int64, factor float64) (runSpeed uint32)
	// GMSpeed is characterID's multiplier (1 when none) and run speed.
	GMSpeed(characterID int64) (factor float64, runSpeed uint32)
}

// MaxSpawn caps one /spawn. Own choice: enough to test a group, not enough
// to take a zone down by typo.
const MaxSpawn = 20

// Help is the one-line list of server-side commands, what the client shows
// a GM. Kept here so the list and the dispatcher cannot drift apart.
const Help = "GM: /tp <x> <z>, /goto <zone|monster>, /give <item id> [qty], /gold <n>, /level <n>, /heal, /spawn <monster> [n], /spawnunique <id|name>, /kill, /damage <n> [id], /durability <slot> <n>, /sp <n>, /hwan <0-5>, /notice <text>, /invsize [1-96|default], /speed [x|off]"

// Run executes one command line for actor. The leading slash is optional;
// the first word is the command. The caller has already checked the gate.
func (d *Deps) Run(ctx context.Context, actor Actor, line string) Result {
	line = strings.TrimSpace(line)
	// Trimmed again after the slash, so "/ notice hi" keeps its text whole:
	// /notice slices the line after its first word (round 634's review).
	line = strings.TrimSpace(strings.TrimPrefix(line, "/"))
	fields := strings.Fields(line)
	if len(fields) == 0 {
		return refuse("empty command. " + Help)
	}
	cmd := strings.ToLower(fields[0])
	args := fields[1:]
	var res Result
	switch cmd {
	case "tp":
		res = d.tp(actor, args)
	case "goto":
		res = d.gotoSpot(actor, args)
	case "give":
		res = d.give(ctx, actor, args)
	case "gold":
		res = d.gold(ctx, actor, args)
	case "level":
		res = d.level(ctx, actor, args)
	case "heal":
		res = d.heal(ctx, actor)
	case "spawn":
		res = d.spawn(actor, args)
	case "kill":
		res = d.kill(actor)
	case "spawnunique":
		res = d.spawnUnique(actor, args)
	case "damage":
		res = d.damage(actor, args)
	case "durability":
		res = d.durability(ctx, actor, args)
	case "sp":
		res = d.sp(ctx, actor, args)
	case "hwan":
		res = d.hwan(ctx, actor, args)
	case "notice":
		res = notice(line[len(fields[0]):])
	case "invsize":
		res = d.invsize(ctx, actor, args)
	case "speed":
		res = d.speed(actor, args)
	default:
		res = refuse("unknown GM command /" + cmd + ". " + Help)
	}
	if d.Logger != nil {
		d.Logger.Info("gm command", "account", actor.Account, "character", actor.Name,
			"line", line, "refused", res.Refused, "reply", res.Text)
	}
	return res
}

// speed multiplies the GM's own run speed (OURS, a test tool with no
// retail counterpart; round 636, at the user's request): /speed <x> sets a
// multiplier on top of the buffs (0.1 <= x <= 10, buff.MaxGMSpeedFactor),
// /speed off (or 1) clears it, /speed alone shows it. The new speed reaches
// the client through the buff path's runSpeed (an OpBuffEnd with no
// tokens); the server does not police movement speed, so nothing else has
// to accept it.
func (d *Deps) speed(actor Actor, args []string) Result {
	const usage = "usage: /speed [x|off] (x from 0.1 to 10: a multiplier on your run speed)"
	if d.Speed == nil {
		return refuse("no speed control")
	}
	if actor.Zone == "" {
		return refuse("not in the world")
	}
	switch len(args) {
	case 0:
		f, v := d.Speed.GMSpeed(actor.CharacterID)
		return Result{Text: fmt.Sprintf("run speed %d (x%.2g)", v, f)}
	case 1:
	default:
		return refuse(usage)
	}
	f := 1.0
	if a := strings.ToLower(args[0]); a != "off" && a != "default" {
		v, err := strconv.ParseFloat(strings.TrimPrefix(a, "x"), 64)
		if err != nil || math.IsNaN(v) || v < 0.1 || v > 10 {
			return refuse(usage)
		}
		f = v
	}
	v := d.Speed.SetGMSpeed(actor.CharacterID, f)
	if f == 1 {
		return Result{Text: fmt.Sprintf("speed multiplier off: run speed %d", v)}
	}
	return Result{Text: fmt.Sprintf("run speed %d (x%.2g)", v, f)}
}

// hwan sets the berserk orbs held (OURS, a test tool; round 629's review): the
// live tracker and the persisted _CHAR.RemainHwanCount together, so the stats
// packet the client then asks for carries the new count.
func (d *Deps) hwan(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /hwan <0-5>")
	}
	n, err := strconv.Atoi(args[0])
	if err != nil || n < 0 || n > berserk.Orbs {
		return refuse("usage: /hwan <0-5>")
	}
	if d.Berserk == nil || d.Chars == nil {
		return refuse("no berserk tracker")
	}
	// The character's berserk turn (berserk.Tracker.Turn), as every other
	// changer of the orbs holds it: the count and its persisted copy move as
	// one against a potion, a fill or an activation of the same character.
	release := d.Berserk.Turn(actor.CharacterID)
	defer release()
	if c, err := d.Chars.GetByID(ctx, actor.CharacterID); err == nil {
		d.Berserk.EnsureSeeded(actor.CharacterID, c.HwanCount)
	}
	n = d.Berserk.SetCharges(actor.CharacterID, n)
	if err := d.Chars.SetHwanCount(ctx, actor.CharacterID, n); err != nil {
		return refuse("could not store the orb count: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("berserk orbs now %d", n), RefreshStats: true}
}

// invsize shows or sets the GM's own bag size in slots (OURS, a test tool;
// round 633): the client pages it 32 to a page, at most three (IFInventory
// 0x6b6620), and locks the slots past it. "default" clears the character's own
// size, so the server's -inventory-size applies again. A size below an
// occupied slot is refused: the store would hold the item where no operation
// may reach it (every one is bounded by the size).
func (d *Deps) invsize(ctx context.Context, actor Actor, args []string) Result {
	const usage = "usage: /invsize [1-96|default]"
	sizes, ok := d.Chars.(character.InventorySizeStore)
	if !ok || d.Inv == nil {
		return refuse("no inventory size store")
	}
	if len(args) == 0 {
		return Result{Text: "inventory size " + sizeText(ctx, d.Inv, actor.CharacterID)}
	}
	if len(args) != 1 {
		return refuse(usage)
	}
	want := 0
	if strings.ToLower(args[0]) != "default" {
		n, err := strconv.Atoi(args[0])
		if err != nil || n < 1 || n > inventory.MaxBagSlots {
			return refuse(usage)
		}
		want = n
	}
	slots, err := d.Inv.List(ctx, actor.CharacterID)
	if err != nil {
		return refuse("could not read the bag: " + err.Error())
	}
	// The check is against the size asked for, not the store's answer after
	// the change: the server keeps the slots held past a size reachable
	// (inventory.SetKeepHeld), which would hide the shrink here.
	if want > 0 {
		for _, sl := range slots {
			if sl.Index >= want {
				return refuse(fmt.Sprintf("bag slot %d holds an item; empty it before making the bag smaller than %d", sl.Index, sl.Index+1))
			}
		}
	}
	if err := sizes.SetInventorySize(ctx, actor.CharacterID, want); err != nil {
		return refuse("could not store the size: " + err.Error())
	}
	return Result{Text: "inventory size now " + sizeText(ctx, d.Inv, actor.CharacterID), RefreshInventory: true}
}

// sizeText is the bag's size for /invsize: the configured or stored size new
// items are held to, and, when items are held past it (only after "default"
// under a lowered -inventory-size), how far they stay reachable.
func sizeText(ctx context.Context, inv inventory.Store, owner int64) string {
	size := inventory.PlacementCapacityOf(ctx, inv, owner)
	text := fmt.Sprintf("%d slots (%d pages)", size, pagesOf(size))
	if reach := inventory.CapacityOf(ctx, inv, owner); reach > size {
		text += fmt.Sprintf("; items held up to slot %d stay reachable until moved or used", reach-1)
	}
	return text
}

func pagesOf(slots int) int {
	if slots <= 1 {
		return 1
	}
	return (slots-1)/inventory.BagPageSlots + 1
}

func refuse(text string) Result { return Result{Text: text, Refused: true} }

// notice is /notice <text> (round 634, OURS as a command: retail's GM tool
// that raises a notice was not read). The text goes out exactly as typed
// after the command word, inner spaces kept; the session layer sends it to
// every character as chat type 7, which the client shows as a
// "(Notice):" line and in GDR_NOTICE (docs/protocol/chat.md).
func notice(rest string) Result {
	text := strings.TrimSpace(rest)
	if text == "" {
		return refuse("usage: /notice <text>")
	}
	return Result{Text: "notice sent: " + text, Notice: text}
}

func (d *Deps) tp(actor Actor, args []string) Result {
	if len(args) != 2 {
		return refuse("usage: /tp <x> <z> (world coordinates in the current zone)")
	}
	x, errX := strconv.ParseFloat(args[0], 64)
	z, errZ := strconv.ParseFloat(args[1], 64)
	if errX != nil || errZ != nil || math.IsNaN(x) || math.IsNaN(z) || math.IsInf(x, 0) || math.IsInf(z, 0) {
		return refuse("usage: /tp <x> <z> -- both must be numbers")
	}
	if actor.Zone == "" {
		return refuse("not in the world")
	}
	if actor.Dead {
		return refuse(deadRefusal)
	}
	return Result{Text: fmt.Sprintf("teleporting to %.1f, %.1f", x, z), HasPos: true, X: x, Z: z}
}

// gotoSpot resolves a named place: a zone (its entry point) or a monster
// species (where the roster keeps it).
func (d *Deps) gotoSpot(actor Actor, args []string) Result {
	if len(args) == 0 {
		return refuse("usage: /goto <zone|monster>. Zones: " + strings.Join(d.Zones, ", ") + ". Monsters: " + d.speciesNames())
	}
	if actor.Dead {
		return refuse(deadRefusal)
	}
	want := strings.ToLower(strings.Join(args, " "))
	for _, z := range d.Zones {
		if strings.ToLower(z) == want {
			if z == actor.Zone {
				return refuse("already in " + z)
			}
			return Result{Text: "travelling to " + z, HasPos: false, Zone: z}
		}
	}
	if sp, ok := d.findSpecies(want); ok {
		res := Result{Text: fmt.Sprintf("going to %s at %.0f, %.0f in %s", sp.Name, sp.X, sp.Z, sp.Zone), HasPos: true, X: sp.X, Z: sp.Z}
		if sp.Zone != actor.Zone {
			res.Zone = sp.Zone
		}
		return res
	}
	return refuse("no place called " + strings.Join(args, " ") + ". Zones: " + strings.Join(d.Zones, ", ") + ". Monsters: " + d.speciesNames())
}

func (d *Deps) give(ctx context.Context, actor Actor, args []string) Result {
	if len(args) < 1 || len(args) > 2 {
		return refuse("usage: /give <item id> [qty]")
	}
	itemID, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || itemID <= 0 {
		return refuse("usage: /give <item id> [qty] -- the id is the item table's numeric id (the client resolves a code name to one)")
	}
	qty := 1
	if len(args) == 2 {
		qty, err = strconv.Atoi(args[1])
		if err != nil || qty < 1 {
			return refuse("usage: /give <item id> [qty] -- qty must be a positive number")
		}
	}
	if d.Items == nil {
		return refuse("no item table loaded on this server (-items-csv), so item ids cannot be checked")
	}
	if _, err := d.Items.GetItem(ctx, itemID); err != nil {
		return refuse(fmt.Sprintf("unknown item id %d", itemID))
	}
	if d.Inv == nil {
		return refuse("no inventory store")
	}
	if err := d.Inv.AddItem(ctx, actor.CharacterID, itemID, qty); err != nil {
		if errors.Is(err, inventory.ErrNoRoom) {
			return refuse("no room in the bag")
		}
		return refuse("giving the item failed: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("gave %d x item %d", qty, itemID), RefreshInventory: true}
}

func (d *Deps) gold(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /gold <n> (negative takes gold away)")
	}
	n, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || n == 0 {
		return refuse("usage: /gold <n> -- a non-zero whole number")
	}
	if d.Chars == nil {
		return refuse("no character store")
	}
	if n > 0 {
		err = d.Chars.AddGold(ctx, actor.CharacterID, n)
	} else {
		err = d.Chars.DeductGold(ctx, actor.CharacterID, -n)
	}
	if err != nil {
		if errors.Is(err, character.ErrInsufficientGold) {
			return refuse("not that much gold to take")
		}
		return refuse("changing gold failed: " + err.Error())
	}
	c, err := d.Chars.GetByID(ctx, actor.CharacterID)
	if err != nil {
		return Result{Text: "gold changed", RefreshStats: true}
	}
	return Result{Text: fmt.Sprintf("gold now %d", c.Gold), RefreshStats: true, RefreshInventory: true}
}

// level raises the character to a level through the arithmetic the combat
// path applies on a level-up (session/combat.go): +StatPointsPerLevel
// spendable points and +StatGrowthPerLevel Str and Int per level gained,
// HP refilled to the new maximum, mana with it. EXP is set to zero at the
// new level, the bar of a character who has just arrived there.
func (d *Deps) level(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /level <n>")
	}
	want, err := strconv.Atoi(args[0])
	if err != nil || want < 1 {
		return refuse("usage: /level <n> -- a level number")
	}
	if d.Chars == nil {
		return refuse("no character store")
	}
	if d.Levels == nil || !d.Levels.Loaded() {
		return refuse("no level table loaded on this server (-leveldata-csv), so levels cannot be set")
	}
	if want > d.Levels.MaxLevel() {
		return refuse(fmt.Sprintf("the level table ends at %d", d.Levels.MaxLevel()))
	}
	c, err := d.Chars.GetByID(ctx, actor.CharacterID)
	if err != nil {
		return refuse("reading the character failed: " + err.Error())
	}
	if want <= c.Level {
		return refuse(fmt.Sprintf("already level %d; /level only goes up (levelling down would have to unwind stats)", c.Level))
	}
	gained := want - c.Level
	newStatPoints := c.StatPoints + gained*leveldata.StatPointsPerLevel
	newStr := c.Str + gained*character.StatGrowthPerLevel
	newInt := c.Int + gained*character.StatGrowthPerLevel
	if err := d.Chars.SetLeveling(ctx, actor.CharacterID, want, 0, newStatPoints, newStr, newInt); err != nil {
		return refuse("setting the level failed: " + err.Error())
	}
	if d.World != nil {
		// The entity's cached level follows the row, as performAttack's
		// level-up does (round 555): the monster AI reads it there.
		d.World.SetLevel(actor.CharacterID, want)
	}
	if err := d.Chars.ResetHP(ctx, actor.CharacterID); err != nil {
		return refuse("refilling hp failed: " + err.Error())
	}
	if d.Mana != nil {
		d.Mana.Refill(actor.CharacterID, character.MaxMPFor(newInt, want))
	}
	return Result{
		Text: fmt.Sprintf("level %d -> %d: +%d stat points (%d unspent), Str %d, Int %d, HP %d, MP %d",
			c.Level, want, gained*leveldata.StatPointsPerLevel, newStatPoints, newStr, newInt,
			character.MaxHPFor(newStr, want), character.MaxMPFor(newInt, want)),
		RefreshStats: true,
		LevelUp:      &LevelUp{NewLevel: want, StatPoints: newStatPoints},
	}
}

func (d *Deps) heal(ctx context.Context, actor Actor) Result {
	if d.Chars == nil {
		return refuse("no character store")
	}
	if err := d.Chars.ResetHP(ctx, actor.CharacterID); err != nil {
		return refuse("refilling hp failed: " + err.Error())
	}
	c, err := d.Chars.GetByID(ctx, actor.CharacterID)
	if err != nil {
		return refuse("reading the character failed: " + err.Error())
	}
	mp := 0
	if d.Mana != nil {
		d.Mana.Refill(actor.CharacterID, c.MaxMP())
		mp = d.Mana.Current(actor.CharacterID, c.MaxMP())
	}
	return Result{Text: fmt.Sprintf("healed: HP %d/%d, MP %d/%d", c.HP, c.MaxHP(), mp, c.MaxMP()), RefreshStats: true}
}

// spawn puts n of a species next to the actor. Own choices: the copies stand
// 4 units apart in a row, they get the roster's stats for the species, and
// nothing respawns them -- a GM spawn is a one-off.
func (d *Deps) spawn(actor Actor, args []string) Result {
	if len(args) < 1 {
		return refuse("usage: /spawn <monster> [n]. Monsters: " + d.speciesNames())
	}
	n := 1
	name := args
	if len(args) >= 2 {
		if v, err := strconv.Atoi(args[len(args)-1]); err == nil {
			n = v
			name = args[:len(args)-1]
		}
	}
	if n < 1 || n > MaxSpawn {
		return refuse(fmt.Sprintf("n must be 1..%d", MaxSpawn))
	}
	if actor.Zone == "" {
		return refuse("not in the world")
	}
	if d.Monsters == nil {
		return refuse("no monster hub")
	}
	sp, ok := d.findSpecies(strings.ToLower(strings.Join(name, " ")))
	if !ok {
		return refuse("no monster called " + strings.Join(name, " ") + ". Monsters: " + d.speciesNames())
	}
	ids := make([]string, 0, n)
	spawned := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		x := actor.X + 6 + float64(i)*4
		m := d.Monsters.SpawnSpecies(actor.Zone, sp.Species, x, actor.Y, actor.Z, sp.MaxHP, sp.Defense, sp.Attack, sp.Gold)
		ids = append(ids, strconv.FormatInt(m.ID, 10))
		spawned = append(spawned, m.ID)
	}
	return Result{
		Text:              fmt.Sprintf("spawned %d x %s (level %d, HP %d) at %.0f, %.0f -- ids %s; no respawn", n, sp.Name, sp.Level, sp.MaxHP, actor.X+6, actor.Z, strings.Join(ids, ",")),
		RefreshMonsters:   true,
		SpawnedMonsterIDs: spawned,
	}
}

// kill removes the selected monster through the hub's own damage path (HP
// to zero, gone from the zone). No rewards, no drops, no quest credit --
// those belong to the combat handler and a GM kill is not a kill.
func (d *Deps) kill(actor Actor) Result {
	if actor.TargetMonsterID == 0 {
		return refuse("no target selected -- click a monster first")
	}
	if d.Monsters == nil {
		return refuse("no monster hub")
	}
	m, ok := d.Monsters.Get(actor.TargetMonsterID)
	if !ok {
		return refuse(fmt.Sprintf("monster %d is not alive", actor.TargetMonsterID))
	}
	dead, died, ok, hits := d.Monsters.ApplyDamageFrom(m.ID, 0, m.HP)
	if !ok || !died {
		return refuse(fmt.Sprintf("monster %d could not be killed", m.ID))
	}
	return Result{
		Text:            fmt.Sprintf("killed %s (#%d); no exp, gold, drops or quest credit from a GM kill", m.Name, m.ID),
		RefreshMonsters: true,
		KilledMonsterID: m.ID,
		Zone:            m.Zone,
		Killed:          &dead,
		KillHits:        hits,
	}
}

// spawnUnique puts one unique monster 6 units east of the GM (OURS, a test
// tool: round 657; uniques are not placed in the world until their rotation
// is built). The argument is the unique's characterdata id or its name or
// code name. Nothing respawns it. Its hatch is announced to the world as a
// roster unique's would be (the session layer, AnnounceUniqueSpawn).
func (d *Deps) spawnUnique(actor Actor, args []string) Result {
	if len(args) < 1 {
		return refuse("usage: /spawnunique <id|name>. Uniques: " + uniqueNames(d.Uniques))
	}
	if actor.Zone == "" {
		return refuse("not in the world")
	}
	if d.Monsters == nil {
		return refuse("no monster hub")
	}
	want := strings.ToLower(strings.Join(args, " "))
	var sp *Species
	for i := range d.Uniques {
		u := &d.Uniques[i]
		if want == strconv.FormatInt(u.RefObjID, 10) || want == strings.ToLower(u.Name) || want == strings.ToLower(u.CodeName) {
			sp = u
			break
		}
	}
	if sp == nil {
		return refuse("no unique called " + strings.Join(args, " ") + ". Uniques: " + uniqueNames(d.Uniques))
	}
	x := actor.X + 6
	m := d.Monsters.SpawnSpecies(actor.Zone, sp.Species, x, actor.Y, actor.Z, sp.MaxHP, sp.Defense, sp.Attack, sp.Gold)
	return Result{
		Text:              fmt.Sprintf("spawned unique %s (id %d, level %d, HP %d) at %.0f, %.0f -- monster #%d; no respawn", sp.Name, sp.RefObjID, sp.Level, m.MaxHP, x, actor.Z, m.ID),
		RefreshMonsters:   true,
		SpawnedMonsterIDs: []int64{m.ID},
	}
}

func uniqueNames(us []Species) string {
	if len(us) == 0 {
		return "(none)"
	}
	names := make([]string, 0, len(us))
	for _, u := range us {
		names = append(names, fmt.Sprintf("%s (%d)", u.Name, u.RefObjID))
	}
	return strings.Join(names, ", ")
}

// damage deals n damage to the selected monster -- or to the monster whose
// id follows n, as /spawnunique's reply prints it -- booked to the GM on the
// monster's damage list as a blow of the GM's (OURS, a test tool: round 657).
// A blow that kills is announced like /kill's, and names the GM when the GM
// tops the list; as with /kill, no exp, gold, drops or quest credit.
func (d *Deps) damage(actor Actor, args []string) Result {
	if len(args) < 1 || len(args) > 2 {
		return refuse("usage: /damage <n> [monster id] -- damage the selected monster, or that one")
	}
	n, err := strconv.Atoi(args[0])
	if err != nil || n < 1 {
		return refuse("n must be a positive whole number")
	}
	target := actor.TargetMonsterID
	if len(args) == 2 {
		id, err := strconv.ParseInt(strings.TrimPrefix(args[1], "#"), 10, 64)
		if err != nil || id < 1 {
			return refuse("the monster id must be a positive whole number")
		}
		target = id
	}
	if target == 0 {
		return refuse("no target selected -- click a monster first, or give its id")
	}
	if d.Monsters == nil {
		return refuse("no monster hub")
	}
	after, died, ok, hits := d.Monsters.ApplyDamageFrom(target, actor.CharacterID, n)
	if !ok {
		return refuse(fmt.Sprintf("monster %d is not alive", target))
	}
	if !died {
		return Result{
			Text:            fmt.Sprintf("%s (#%d) took %d: HP %d/%d", after.Name, after.ID, n, after.HP, after.MaxHP),
			RefreshMonsters: true,
		}
	}
	return Result{
		Text:            fmt.Sprintf("%s (#%d) took %d and died; no exp, gold, drops or quest credit from a GM kill", after.Name, after.ID, n),
		RefreshMonsters: true,
		KilledMonsterID: after.ID,
		Zone:            after.Zone,
		Killed:          &after,
		KillHits:        hits,
	}
}

func (d *Deps) durability(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 2 {
		return refuse("usage: /durability <slot 0-8> <n> (0 helm, 1 mail, 2 shoulder, 3 gauntlet, 4 pants, 5 boots, 6 weapon, 7 shield, 8 job suit)")
	}
	slot, errS := strconv.Atoi(args[0])
	n, errN := strconv.Atoi(args[1])
	if errS != nil || errN != nil || slot < int(equipment.SlotHelm) || slot > int(equipment.SlotJobSuit) || n < 0 {
		return refuse("usage: /durability <slot 0-8> <n>")
	}
	if d.Equip == nil {
		return refuse("no equipment store")
	}
	if err := d.Equip.SetDurability(ctx, actor.CharacterID, equipment.Slot(slot), n); err != nil {
		if errors.Is(err, equipment.ErrSlotEmpty) {
			return refuse(fmt.Sprintf("nothing worn in slot %d", slot))
		}
		return refuse("setting durability failed: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("slot %d durability set to %d", slot, n), RefreshEquipment: true}
}

func (d *Deps) sp(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 1 {
		return refuse("usage: /sp <n> (negative takes points away)")
	}
	n, err := strconv.Atoi(args[0])
	if err != nil || n == 0 {
		return refuse("usage: /sp <n> -- a non-zero whole number")
	}
	if d.Skills == nil {
		return refuse("no skill store")
	}
	total, err := d.Skills.AddSkillPoints(ctx, actor.CharacterID, n)
	if err != nil {
		return refuse("changing skill points failed: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("skill points now %d", total), RefreshStats: true}
}

// findSpecies matches a lower-cased code name or display name.
func (d *Deps) findSpecies(want string) (Species, bool) {
	for _, sp := range d.Species {
		if strings.ToLower(sp.CodeName) == want || strings.ToLower(sp.Name) == want {
			return sp, true
		}
	}
	return Species{}, false
}

func (d *Deps) speciesNames() string {
	names := make([]string, 0, len(d.Species))
	seen := map[string]bool{}
	for _, sp := range d.Species {
		if seen[sp.CodeName] {
			continue
		}
		seen[sp.CodeName] = true
		names = append(names, sp.CodeName)
	}
	sort.Strings(names)
	return strings.Join(names, ", ")
}
