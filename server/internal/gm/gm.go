// Package gm is the server's game-master console: the gate that decides who
// may use it and the commands themselves. It exists so a tester can put the
// world into a known state -- a level, an item, a monster, a place -- and
// report facts instead of impressions.
//
// Everything here is this project's own tooling. None of it mirrors an
// original-client feature, and nothing in it is presented as one.
//
// The gate is a list of account usernames (the -gm-accounts flag, env
// OPENSRO_GM_ACCOUNTS); with none named, nobody is a GM. Every command,
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
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Gate is the set of account usernames allowed to run GM commands.
type Gate struct {
	names map[string]bool
}

// ParseAccounts builds a Gate from a comma-separated list of usernames, the
// form the -gm-accounts flag and OPENSRO_GM_ACCOUNTS take. Names are
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
	// Unplaced marks a species the server keeps nowhere -- one the monster
	// table (round 654, -monsters-csv) holds but the roster does not spawn:
	// /spawn puts it next to the GM, /goto has nowhere to go.
	Unplaced bool
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
	// KilledX/KilledZ are where it stood (round 656): the session layer
	// announces the kill to the players whose area of interest holds that
	// spot, not to the whole zone.
	KilledX, KilledZ float64
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
	// WornChanged are the equip slots whose worn item /item worn changed,
	// for the session layer to show the zone (retail 0x3038, round 735).
	WornChanged []int
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
	Avatars  inventory.Store // round 789: the avatar inventory /avatar lists; nil refuses the list
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
	// LookupSpecies resolves a species the roster (Species) does not hold,
	// by a lower-cased code name, display name or characterdata id: the
	// monster table's (round 654). Nil: only the roster. LookupCount is how
	// many species it knows, for the usage lines.
	LookupSpecies func(want string) (Species, bool)
	LookupCount   int
	// Zones are the named zones /goto accepts (worldmap.ZoneCentre's keys).
	Zones  []string
	Logger *slog.Logger
	// Speed is what /speed drives (round 636); nil refuses it. The session
	// layer fills it in (session.GMCommandHandler) when the server leaves it
	// nil.
	Speed SpeedControl
	// Jobs is what /jobexp and /jobweek drive (round 799, test tools); nil
	// refuses them. The session layer fills it in.
	Jobs JobControl
	// Afflict is what /afflict drives (round 786, a test tool); nil refuses
	// it. The session layer fills it in when the server leaves it nil.
	Afflict AfflictControl
	// Clock is what /hour drives (round 786); nil refuses it. The session
	// layer fills it in when the server leaves it nil.
	Clock ClockControl
	// Round 788, accounts.go: /ban needs Sessions; /block, /unblock and
	// /blockinfo need Punishments and AccountLookup (the account store),
	// and Chars to be a character.OwnerStore to name a character. Sessions
	// nil refuses /ban and leaves a /block's account connected. IsGMAccount
	// is the gate's test (/block refuses a GM's account); the session layer
	// fills it in. Now is their clock, nil time.Now.
	Sessions      Sessions
	Punishments   account.PunishmentStore
	AccountLookup account.AccountLookup
	IsGMAccount   func(username string) bool
	Now           func() time.Time
	// Guilds is what /guildlevel raises (round 814, a test tool); nil
	// refuses it.
	Guilds guild.Store
}

// ClockControl is /hour's hook into the game clock (round 786): retail's
// operator set-hour (SR_GameServer FUN_004154d0 case 10 -> FUN_00412be0,
// READ) -- the hour clamped to 23, the day and the minute kept, every
// character in the world told (0x3027).
type ClockControl interface {
	// SetHour re-bases the clock at hour and tells the world; it returns the
	// clock's new reading and how many characters were told.
	SetHour(hour int) (day, newHour, minute, told int)
}

// AfflictControl is /afflict's hook into the character's abnormal states
// (round 786, OURS: a test tool with no retail counterpart).
type AfflictControl interface {
	// Afflict lands one status run -- a skilldata code and its values, as a
	// monster skill carries them -- on characterID, as if it had landed
	// (no roll), tells the character's view, and returns the new mask.
	Afflict(characterID int64, code string, values []int) (mask uint32, err error)
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

// JobControl is the job system's GM hooks (round 799, OURS: test tools with
// no retail counterpart).
type JobControl interface {
	// GainJobExp changes characterID's job exp by amount through the job
	// rules (GObjPC::FUN_004e2830) and says what the record became.
	GainJobExp(ctx context.Context, characterID int64, amount int64) string
	// RunWeekly runs the weekly job procedure now.
	RunWeekly(ctx context.Context) error
}

// MaxSpawn caps one /spawn. Own choice: enough to test a group, not enough
// to take a zone down by typo.
const MaxSpawn = 20

// Help is the one-line list of server-side commands, what the client shows
// a GM. Kept here so the list and the dispatcher cannot drift apart.
const Help = "GM: /tp <x> <z>, /goto <zone|monster>, /give <item id> [qty] [plus], /item <slot> plus|var|quality|opt|adv|clear ..., /avatar [spirit <bag slot> <seconds|0>], /gold <n>, /level <n>, /heal, /spawn <monster> [n], /spawnunique <id|name>, /kill, /damage <n> [id], /durability <slot> <n>, /sp <n>, /hwan <0-5>, /notice <text>, /invsize [1-96|default], /speed [x|off], /hurt <hp> [mp], /afflict <code> <values...>, /hour <0-23>, /ban <name>, /block <name|@account> <30m|12h|7d|forever> [reason], /unblock <name|@account>, /blockinfo <name|@account>, /jobexp <n>, /jobweek, /guildlevel <1-5>"

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
	case "item":
		res = d.item(ctx, actor, args)
	case "avatar":
		res = d.avatar(ctx, actor, args)
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
	case "hurt":
		res = d.hurt(ctx, actor, args)
	case "afflict":
		res = d.afflict(actor, args)
	case "hour":
		res = d.hour(args)
	case "ban":
		res = d.ban(args)
	case "block":
		res = d.block(ctx, actor, line, args)
	case "unblock":
		res = d.unblock(ctx, args)
	case "blockinfo":
		res = d.blockInfo(ctx, args)
	case "jobexp":
		res = d.jobExp(ctx, actor, args)
	case "jobweek":
		res = d.jobWeek(ctx)
	case "guildlevel":
		res = d.guildLevel(ctx, actor, args)
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
// tokens); since round 749 the server's own legs and its claim bound run at
// the same speed (session/destmove.go), so both ends agree.
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

// hour is /hour <0-23> (round 786): the game clock's hour, set as retail's
// operator tool sets it (ClockControl; READ). The value is a byte there; the
// console takes 0..23 and refuses anything else rather than clamping it.
func (d *Deps) hour(args []string) Result {
	if d.Clock == nil {
		return refuse("/hour is not available on this server")
	}
	if len(args) != 1 {
		return refuse("usage: /hour <0-23>")
	}
	h, err := strconv.Atoi(args[0])
	if err != nil || h < 0 || h > 23 {
		return refuse("usage: /hour <0-23>")
	}
	day, nh, m, told := d.Clock.SetHour(h)
	return Result{Text: fmt.Sprintf("game clock set to day %d %02d:%02d (%d character(s) told)", day, nh, m, told)}
}

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
		if sp.Unplaced {
			return refuse(fmt.Sprintf("%s (%s, id %d) is not placed anywhere by the server; /spawn puts one next to you", sp.Name, sp.CodeName, sp.RefObjID))
		}
		res := Result{Text: fmt.Sprintf("going to %s at %.0f, %.0f in %s", sp.Name, sp.X, sp.Z, sp.Zone), HasPos: true, X: sp.X, Z: sp.Z}
		if sp.Zone != actor.Zone {
			res.Zone = sp.Zone
		}
		return res
	}
	return refuse("no place called " + strings.Join(args, " ") + ". Zones: " + strings.Join(d.Zones, ", ") + ". Monsters: " + d.speciesNames())
}

// give adds an item to the bag; the optional third argument is the plus
// (OptLevel) each fresh copy gets -- a GM test hook (OURS, round 732).
func (d *Deps) give(ctx context.Context, actor Actor, args []string) Result {
	const usage = "usage: /give <item id> [qty] [plus]"
	if len(args) < 1 || len(args) > 3 {
		return refuse(usage)
	}
	itemID, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || itemID <= 0 {
		return refuse(usage + " -- the id is the item table's numeric id (the client resolves a code name to one)")
	}
	qty := 1
	if len(args) >= 2 {
		qty, err = strconv.Atoi(args[1])
		if err != nil || qty < 1 {
			return refuse(usage + " -- qty must be a positive number")
		}
	}
	plus := 0
	if len(args) == 3 {
		plus, err = strconv.Atoi(args[2])
		if err != nil || plus < 0 || plus > 255 {
			return refuse(usage + " -- plus must be 0 to 255")
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
	// The give and its plus are ONE transaction (round 743): a plus that
	// cannot be set takes the item back with it.
	var at []string
	err = txn.For(d.Inv).Run(ctx, func(ctx context.Context) error {
		at = nil
		var before map[int]bool
		if plus > 0 {
			slots, err := d.Inv.List(ctx, actor.CharacterID)
			if err != nil {
				return fmt.Errorf("reading the bag failed: %w", err)
			}
			before = make(map[int]bool, len(slots))
			for _, sl := range slots {
				before[sl.Index] = true
			}
		}
		if err := d.Inv.AddItem(ctx, actor.CharacterID, itemID, qty); err != nil {
			return err
		}
		if plus == 0 {
			return nil
		}
		// The plus goes on the slots the give filled fresh; a top-up of an
		// existing stack keeps that stack's own instance.
		slots, err := d.Inv.List(ctx, actor.CharacterID)
		if err != nil {
			return fmt.Errorf("reading the bag failed: %w", err)
		}
		for _, sl := range slots {
			if before[sl.Index] || sl.ItemID != itemID {
				continue
			}
			inst := sl.Instance()
			inst.OptLevel = uint8(plus)
			if err := d.Inv.SetInstance(ctx, actor.CharacterID, sl.Index, inst); err != nil {
				return fmt.Errorf("setting the plus failed: %w", err)
			}
			at = append(at, strconv.Itoa(sl.Index))
		}
		return nil
	})
	if err != nil {
		if errors.Is(err, inventory.ErrNoRoom) {
			return refuse("no room in the bag")
		}
		return refuse("giving the item failed: " + err.Error())
	}
	if plus == 0 {
		return Result{Text: fmt.Sprintf("gave %d x item %d", qty, itemID), RefreshInventory: true}
	}
	// The slots are named so /item can follow up on them.
	return Result{Text: fmt.Sprintf("gave %d x item %d +%d (bag slot %s)", qty, itemID, plus, strings.Join(at, ", ")), RefreshInventory: true}
}

// itemUsage is /item's: a GM test hook (OURS, round 732) for an item's own
// data -- the plus, the white-stat variance, the blue options and the
// advanced elixir -- until drops, alchemy and the elixirs set them.
const itemUsage = "usage: /item <bag slot> plus <n> | var <u64> | quality <0-31> | opt <option id> <value> | adv <n> | clear; /item worn <equip slot 0-12> plus <n> | adv <n>"

// itemWornUsage is /item worn's (round 735, OURS): a worn item's plus or
// advanced elixir, changed in place so the zone sees the new plus (retail's
// 0x3038 of the same item, session/equip_broadcast.go).
const itemWornUsage = "usage: /item worn <equip slot 0-12> plus <n> | adv <n>"

// itemWorn edits a worn item's plus or advanced elixir.
func (d *Deps) itemWorn(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 3 {
		return refuse(itemWornUsage)
	}
	slot, err := strconv.Atoi(args[0])
	if err != nil || slot < int(equipment.SlotHelm) || slot > int(equipment.SlotRingRight) {
		return refuse(itemWornUsage)
	}
	v, err := strconv.ParseUint(args[2], 0, 8)
	if err != nil {
		return refuse(itemWornUsage)
	}
	setter, ok := d.Equip.(equipment.InstanceSetter)
	if d.Equip == nil || !ok {
		return refuse("no equipment store that can change a worn item")
	}
	worn, err := d.Equip.Get(ctx, actor.CharacterID)
	if err != nil {
		return refuse("reading the worn items failed: " + err.Error())
	}
	var found *equipment.Equipped
	for i := range worn {
		if int(worn[i].Slot) == slot {
			found = &worn[i]
		}
	}
	if found == nil {
		return refuse(fmt.Sprintf("nothing worn in slot %d", slot))
	}
	inst := found.Instance()
	var what string
	switch strings.ToLower(args[1]) {
	case "plus":
		inst.OptLevel, what = uint8(v), fmt.Sprintf("plus %d", v)
	case "adv":
		inst.AdvElixir, what = uint8(v), fmt.Sprintf("advanced elixir +%d", v)
	default:
		return refuse(itemWornUsage)
	}
	if err := setter.SetInstance(ctx, actor.CharacterID, equipment.Slot(slot), inst); err != nil {
		return refuse("setting the worn item failed: " + err.Error())
	}
	d.wornChanged(ctx, actor.CharacterID)
	return Result{Text: fmt.Sprintf("worn slot %d: %s", slot, what), RefreshEquipment: true, WornChanged: []int{slot}}
}

// wornChanged is what a worn item's change does to the character (round
// 769): its options' bonus is computed again, and an HP above the new max is
// lowered to it (OURS, the review's F2).
func (d *Deps) wornChanged(ctx context.Context, characterID int64) {
	character.InvalidateBonus(characterID)
	if d.Chars == nil {
		return
	}
	if c, err := d.Chars.GetByID(ctx, characterID); err == nil && c != nil && c.HP > c.MaxHP() {
		_, _ = d.Chars.Heal(ctx, characterID, 0, c.MaxHP())
	}
}

// item edits one bag slot's instance.
func (d *Deps) item(ctx context.Context, actor Actor, args []string) Result {
	if len(args) > 0 && strings.EqualFold(args[0], "worn") {
		return d.itemWorn(ctx, actor, args[1:])
	}
	if len(args) < 2 {
		return refuse(itemUsage)
	}
	slot, err := strconv.Atoi(args[0])
	if err != nil || slot < 0 {
		return refuse(itemUsage)
	}
	if d.Inv == nil {
		return refuse("no inventory store")
	}
	slots, err := d.Inv.List(ctx, actor.CharacterID)
	if err != nil {
		return refuse("reading the bag failed: " + err.Error())
	}
	var found *inventory.Slot
	for i := range slots {
		if slots[i].Index == slot {
			found = &slots[i]
		}
	}
	if found == nil {
		return refuse(fmt.Sprintf("bag slot %d is empty", slot))
	}
	// Only equipment (TypeID 3/1) carries an instance the lists send; a
	// stack would drop it again when stacks merge (round 732 review F9).
	if d.Items == nil {
		return refuse("no item table loaded on this server (-items-csv), so the item cannot be checked")
	}
	if it, err := d.Items.GetItem(ctx, found.ItemID); err != nil || it.TypeID1 != 3 || it.TypeID2 != 1 {
		return refuse(fmt.Sprintf("bag slot %d holds item %d, not equipment: /item sets equipment only", slot, found.ItemID))
	}
	inst := found.Instance()
	num := func(i int, max uint64) (uint64, bool) {
		if i >= len(args) {
			return 0, false
		}
		v, err := strconv.ParseUint(args[i], 0, 64)
		return v, err == nil && v <= max
	}
	var what string
	switch op := strings.ToLower(args[1]); {
	case op == "plus" && len(args) == 3:
		v, ok := num(2, 255)
		if !ok {
			return refuse(itemUsage)
		}
		inst.OptLevel, what = uint8(v), fmt.Sprintf("plus %d", v)
	case op == "var" && len(args) == 3:
		v, ok := num(2, ^uint64(0))
		if !ok {
			return refuse(itemUsage)
		}
		inst.Variance, what = v, fmt.Sprintf("variance %#x", v)
	case op == "quality" && len(args) == 3:
		// Every one of the twelve 5-bit groups at q: q/31 of the way up
		// each white stat's range (c:0x8bd980).
		q, ok := num(2, 31)
		if !ok {
			return refuse(itemUsage)
		}
		inst.Variance = 0
		for g := 0; g < 12; g++ {
			inst.Variance |= q << (5 * g)
		}
		what = fmt.Sprintf("every white stat at %d/31 (variance %#x)", q, inst.Variance)
	case op == "opt" && len(args) == 4:
		id, okID := num(2, 0xffff)
		v, okV := num(3, 0xffffffff)
		if !okID || !okV || id == 0 {
			return refuse(itemUsage)
		}
		p := inventory.MagParam(uint16(id), uint32(v))
		replaced := false
		for k, old := range inst.MagParams {
			if inventory.MagParamOption(old) == uint16(id) {
				inst.MagParams[k], replaced = p, true
			}
		}
		if !replaced {
			if len(inst.MagParams) >= inventory.MaxMagParams {
				return refuse(fmt.Sprintf("the item already carries %d options, the most it can", inventory.MaxMagParams))
			}
			inst.MagParams = append(inst.MagParams, p)
		}
		what = fmt.Sprintf("option %d = %d", id, v)
	case op == "adv" && len(args) == 3:
		v, ok := num(2, 255)
		if !ok {
			return refuse(itemUsage)
		}
		inst.AdvElixir, what = uint8(v), fmt.Sprintf("advanced elixir +%d", v)
	case op == "clear" && len(args) == 2:
		inst.OptLevel, inst.MagParams, inst.AdvElixir = 0, nil, 0
		what = "plus, options and advanced elixir cleared"
	default:
		return refuse(itemUsage)
	}
	if err := d.Inv.SetInstance(ctx, actor.CharacterID, slot, inst); err != nil {
		return refuse("setting the item failed: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("bag slot %d: %s", slot, what), RefreshInventory: true}
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
	// The row's read and write under the leveling lock (round 712: a party
	// member's kill can pay this character from another goroutine).
	unlock := character.LockLeveling(actor.CharacterID)
	c, err := d.Chars.GetByID(ctx, actor.CharacterID)
	if err != nil {
		unlock()
		return refuse("reading the character failed: " + err.Error())
	}
	if want <= c.Level {
		unlock()
		return refuse(fmt.Sprintf("already level %d; /level only goes up (levelling down would have to unwind stats)", c.Level))
	}
	gained := want - c.Level
	newStatPoints := c.StatPoints + gained*leveldata.StatPointsPerLevel
	newStr := c.Str + gained*character.StatGrowthPerLevel
	newInt := c.Int + gained*character.StatGrowthPerLevel
	err = d.Chars.SetLeveling(ctx, actor.CharacterID, want, 0, newStatPoints, newStr, newInt)
	unlock()
	if err != nil {
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
		// Round 769's review F4: with the worn items' bonus.
		d.Mana.Refill(actor.CharacterID, character.MaxMPWith(newInt, want, character.BonusOf(actor.CharacterID)))
	}
	bonus := character.BonusOf(actor.CharacterID)
	return Result{
		Text: fmt.Sprintf("level %d -> %d: +%d stat points (%d unspent), Str %d, Int %d, HP %d, MP %d",
			c.Level, want, gained*leveldata.StatPointsPerLevel, newStatPoints, newStr+bonus.Str, newInt+bonus.Int,
			character.MaxHPWith(newStr, want, bonus), character.MaxMPWith(newInt, want, bonus)),
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
		// The HP the monsters really have: SpawnSpecies scales the row's by the
		// rarity (combat.ScaleHPForRarity), and the code name and id say which
		// row a shared display name picked (round 654's review: 188 names are
		// shared by 7,087 rows).
		Text: fmt.Sprintf("spawned %d x %s (%s, id %d; level %d, rarity %d, HP %d) at %.0f, %.0f -- ids %s; no respawn",
			n, sp.Name, sp.CodeName, sp.RefObjID, sp.Level, sp.Rarity, combat.ScaleHPForRarity(sp.MaxHP, sp.Rarity),
			actor.X+6, actor.Z, strings.Join(ids, ",")),
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
		KilledX:         m.X,
		KilledZ:         m.Z,
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

// CommandTarget is the monster a console line acts on: /damage's explicit id
// when it names one, else the selected monster -- so the session layer can
// take the watchers of the right monster before the command runs (round 656's
// before/after union, round 657's /damage).
func CommandTarget(line string, selected int64) int64 {
	fields := strings.Fields(strings.TrimPrefix(strings.TrimSpace(line), "/"))
	if len(fields) == 3 && strings.ToLower(fields[0]) == "damage" {
		if id, err := strconv.ParseInt(strings.TrimPrefix(fields[2], "#"), 10, 64); err == nil && id > 0 {
			return id
		}
	}
	return selected
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
	before, alive := d.Monsters.Get(target)
	if !alive {
		return refuse(fmt.Sprintf("monster %d is not alive", target))
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
		KilledX:         before.X,
		KilledZ:         before.Z,
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
	d.wornChanged(ctx, actor.CharacterID)
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

// findSpecies matches a lower-cased code name, display name or characterdata
// id against the roster first, then the monster table (LookupSpecies).
func (d *Deps) findSpecies(want string) (Species, bool) {
	for _, sp := range d.Species {
		if strings.ToLower(sp.CodeName) == want || strings.ToLower(sp.Name) == want ||
			(sp.RefObjID != 0 && strconv.FormatInt(sp.RefObjID, 10) == want) {
			return sp, true
		}
	}
	if d.LookupSpecies != nil {
		return d.LookupSpecies(want)
	}
	return Species{}, false
}

// speciesNames is the roster's code names, and -- with the monster table --
// how to name any other species. The table's thousands are not listed: a
// usage line that long helps nobody.
func (d *Deps) speciesNames() string {
	names := d.rosterNames()
	if d.LookupSpecies != nil {
		names += fmt.Sprintf(" (or any of the monster table's %d species by code name or id)", d.LookupCount)
	}
	return names
}

func (d *Deps) rosterNames() string {
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

// hurt takes hp (and mp) off the GM's own character (round 786, OURS: a test
// tool with no retail counterpart, for the auto potion's QA). It never kills:
// at most HP-1 is taken. The client's bars follow the stats refresh.
func (d *Deps) hurt(ctx context.Context, actor Actor, args []string) Result {
	if len(args) < 1 || len(args) > 2 {
		return refuse("usage: /hurt <hp> [mp] -- take hp (and mp) off yourself, never below 1 HP")
	}
	hp, err := strconv.Atoi(args[0])
	if err != nil || hp < 0 {
		return refuse("hp must be a whole number, 0 or more")
	}
	mpLoss := 0
	if len(args) == 2 {
		if mpLoss, err = strconv.Atoi(args[1]); err != nil || mpLoss < 0 {
			return refuse("mp must be a whole number, 0 or more")
		}
	}
	if d.Chars == nil {
		return refuse("no character store")
	}
	c, err := d.Chars.GetByID(ctx, actor.CharacterID)
	if err != nil {
		return refuse("reading the character failed: " + err.Error())
	}
	if hp > c.HP-1 {
		hp = c.HP - 1
	}
	if hp > 0 {
		if _, _, err := d.Chars.ApplyDamage(ctx, actor.CharacterID, hp); err != nil {
			return refuse("hurting failed: " + err.Error())
		}
	}
	mp := 0
	if d.Mana != nil {
		cur := d.Mana.Current(actor.CharacterID, c.MaxMP())
		if mpLoss > cur {
			mpLoss = cur
		}
		if mpLoss > 0 {
			d.Mana.Spend(actor.CharacterID, c.MaxMP(), mpLoss)
		}
		mp = d.Mana.Current(actor.CharacterID, c.MaxMP())
	}
	after, err := d.Chars.GetByID(ctx, actor.CharacterID)
	if err != nil {
		return refuse("reading the character failed: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("hurt: HP %d/%d, MP %d/%d", after.HP, after.MaxHP(), mp, after.MaxMP()), RefreshStats: true}
}

// afflict lands a status run on the GM's own character (round 786, OURS: a
// test tool, for the cure pills' QA): /afflict ps 34 100 16 is a poison of
// strength 34 dealing 16 a tick, /afflict se 9000 100 3 a level-3 sleep of
// 9 s -- the skilldata codes and values (statuseffect.States).
func (d *Deps) afflict(actor Actor, args []string) Result {
	if len(args) < 2 {
		return refuse("usage: /afflict <code> <values...> -- e.g. /afflict ps 34 100 16, /afflict se 9000 100 3")
	}
	if d.Afflict == nil {
		return refuse("states are not available here")
	}
	var values []int
	for _, a := range args[1:] {
		v, err := strconv.Atoi(a)
		if err != nil {
			return refuse("values must be whole numbers")
		}
		values = append(values, v)
	}
	mask, err := d.Afflict.Afflict(actor.CharacterID, strings.ToLower(args[0]), values)
	if err != nil {
		return refuse("afflict: " + err.Error())
	}
	return Result{Text: fmt.Sprintf("afflicted: %s %v, mask %#x", args[0], values, mask)}
}

// jobExp is /jobexp <n> (round 799, OURS): a job exp change through the job
// rules -- a level-up, the robber's and hunter's contribution, 0x30E6.
func (d *Deps) jobExp(ctx context.Context, actor Actor, args []string) Result {
	if d.Jobs == nil {
		return refuse("no job system")
	}
	if len(args) != 1 {
		return refuse("usage: /jobexp <n> (negative takes exp away)")
	}
	n, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil || n == 0 {
		return refuse("usage: /jobexp <n> (negative takes exp away)")
	}
	return Result{Text: d.Jobs.GainJobExp(ctx, actor.CharacterID, n)}
}

// jobWeek is /jobweek (round 799, OURS): the weekly job procedure now.
func (d *Deps) jobWeek(ctx context.Context) Result {
	if d.Jobs == nil {
		return refuse("no job system")
	}
	if err := d.Jobs.RunWeekly(ctx); err != nil {
		return refuse("the weekly job procedure failed: " + err.Error())
	}
	return Result{Text: "the weekly job procedure ran: rewards shared, rankings rebuilt, contributions reset"}
}

// guildLevel raises the GM's own guild to level n (round 814, OURS, a test
// tool: a grant name needs a level-4 guild, guild.MinLevelForNickname). It
// is the store's own level-up, one level at a time, with the guild points
// each needs credited to the GM first and the gold not taken -- what it
// skips is said in the reply. It never lowers a level.
func (d *Deps) guildLevel(ctx context.Context, actor Actor, args []string) Result {
	if len(args) != 1 {
		return refuse(fmt.Sprintf("usage: /guildlevel <%d-%d>", guild.FoundingLevel, guild.MaxLevel))
	}
	n, err := strconv.Atoi(args[0])
	if err != nil || n < guild.FoundingLevel || n > guild.MaxLevel {
		return refuse(fmt.Sprintf("usage: /guildlevel <%d-%d>", guild.FoundingLevel, guild.MaxLevel))
	}
	if d.Guilds == nil {
		return refuse("no guild store")
	}
	g, err := d.Guilds.GetByCharacter(ctx, actor.CharacterID)
	if err != nil {
		return refuse("you are not in a guild")
	}
	for g.Level < n {
		_, gp, ok := guild.LevelUpCost(g.Level)
		if !ok {
			return refuse(fmt.Sprintf("level %d has no level-up cost", g.Level))
		}
		if err := d.Guilds.AddPoints(ctx, g.ID, actor.CharacterID, gp); err != nil {
			return refuse("crediting guild points failed: " + err.Error())
		}
		if g, err = d.Guilds.LevelUp(ctx, actor.CharacterID, true, math.MaxInt64, nil); err != nil {
			return refuse("the level-up failed: " + err.Error())
		}
	}
	return Result{Text: fmt.Sprintf("%s is level %d (the guild points were credited to you; no gold was taken)", g.Name, g.Level)}
}
