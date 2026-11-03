package session

// The server side of character select and create (round 682, lane S),
// answering lobby.go's 0x7007 in the order and with the codes SR_ShardManager
// uses (READ, docs/protocol/charselect.md section 5) except where a comment
// says OURS.

import (
	"context"
	"errors"
	"log/slog"
	"math/rand"
	"sort"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/namefilter"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// LobbyStores is the character store the lobby needs: Store plus the lobby's
// own create, name lookup and soft delete. MemStore and SQLStore are both.
type LobbyStores interface {
	character.Store
	character.LobbyStore
}

// GuildRoles is the slice of the guild store the list record and the delete
// refusal read.
type GuildRoles interface {
	GetByCharacter(ctx context.Context, characterID int64) (*guild.Guild, error)
}

// CharDefaultSkills is the slice of the skill store a new character's
// default masteries and skills go into (skill.MemStore and skill.SQLStore).
type CharDefaultSkills interface {
	Learn(ctx context.Context, characterID, skillID int64) error
	SeedMasteries(ctx context.Context, characterID int64, masteryIDs []int64) error
}

// CharDefaultQuests is where a new character's default quests are recorded
// (quest.MemStore and quest.SQLStore; quest/defaults.go says why they are
// not quests yet).
type CharDefaultQuests interface {
	GrantDefaultQuests(ctx context.Context, characterID int64, codes []string) error
}

// LobbyDeps is what LobbyHandler works with. Chars and Catalogue are
// required for create; the rest may be nil (tests): no kit is given without
// Inv/Eq, every character is guildless without Guilds, MP is the maximum
// without Mana.
type LobbyDeps struct {
	Chars LobbyStores
	// Catalogue is the creatable set (refdata.CreatableSet, from
	// -chargen-csv). nil refuses every create with 0x403: without it the
	// server cannot tell a body or an item it may make from one it may not.
	Catalogue *refdata.CreatableSet
	Inv       equipment.InventoryAdder
	Eq        equipment.Store
	// Avatars is the avatar inventory the list's avatar block is read from
	// (round 789); nil lists none.
	Avatars inventory.Store
	Guilds  GuildRoles
	Mana    *mana.Tracker
	// Defaults is the shard's `_RefCharDefault_*` tables (round 692,
	// -chardefaults-dir); Skills and Quests are where create puts what they
	// give. Defaults nil: a new character gets none (the server warns at
	// boot); Skills or Quests nil: that part is skipped.
	Defaults *refdata.CharDefaults
	Skills   CharDefaultSkills
	Quests   CharDefaultQuests
	// Hub, when set, is how the lobby tells a session already in the world:
	// every lobby action is refused there (round 682's review).
	Hub *world.Hub
	// Now is the clock (time.Now when nil); Pick returns a number in [0, n)
	// for the start spawn (rand.Intn when nil).
	Now    func() time.Time
	Pick   func(n int) int
	Logger *slog.Logger
}

func (d *LobbyDeps) now() time.Time {
	if d.Now != nil {
		return d.Now()
	}
	return time.Now()
}

func (d *LobbyDeps) pick(n int) int {
	if d.Pick != nil {
		return d.Pick(n)
	}
	return rand.Intn(n)
}

func (d *LobbyDeps) logger() *slog.Logger {
	if d.Logger != nil {
		return d.Logger
	}
	return slog.Default()
}

// LobbyHandler answers 0x7007. Start (0x7001) is the world handler's
// (world.go), which owns the path into the world.
func LobbyHandler(d LobbyDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpLobby {
			return nil
		}
		req, err := DecodeLobbyRequest(p.Data)
		if err != nil {
			// A payload too short to read: the client is not retail's. The
			// action byte, when there is one, is echoed with the generic
			// refusal (OURS: the ShardManager's parser behaviour on a short
			// packet was not read).
			action := uint8(0)
			if len(p.Data) > 0 {
				action = p.Data[0]
			}
			return sendLobby(sess, &LobbyResult{Action: action, Code: LobbyErrRefused})
		}
		accountID, authed := AuthenticatedAccountID(sess)
		// A session in the world has left the lobby: retail's client never
		// sends 0x7007 from the world (its senders are the select and create
		// screens), and what the ShardManager would answer was not read. So
		// every action is refused with 0x40e, "an operation is pending" -- the
		// closest READ meaning, the choice OURS (round 682's review).
		if d.Hub != nil && req.Action >= LobbyCreate && req.Action <= LobbyRestore {
			if _, inWorld := d.Hub.EntityBySession(sess.ID()); inWorld {
				return sendLobby(sess, &LobbyResult{Action: req.Action, Code: LobbyErrBusy})
			}
		}
		switch req.Action {
		case LobbyList:
			if !authed {
				return sendLobby(sess, &LobbyResult{Action: req.Action, Code: LobbyErrNoUser})
			}
			return d.list(ctx, sess, accountID)
		case LobbyCreate:
			if !authed {
				return sendLobby(sess, &LobbyResult{Action: req.Action, Code: LobbyErrNoUser})
			}
			return sendLobby(sess, d.create(ctx, accountID, req))
		case LobbyNameCheck:
			if !authed {
				return sendLobby(sess, &LobbyResult{Action: req.Action, Code: LobbyErrNoUser})
			}
			return sendLobby(sess, d.nameCheck(ctx, req))
		case LobbyDelete:
			if !authed {
				return sendLobby(sess, &LobbyResult{Action: req.Action, Code: LobbyErrNoUser})
			}
			return sendLobby(sess, d.remove(ctx, accountID, req))
		case LobbyRestore:
			if !authed {
				return sendLobby(sess, &LobbyResult{Action: req.Action, Code: LobbyErrNoUser})
			}
			return sendLobby(sess, d.restore(ctx, accountID, req))
		default:
			// Any other action is ignored (READ, the jump table 0x40f0f8).
			return nil
		}
	}
}

func sendLobby(sess *gateway.Session, r *LobbyResult) error {
	return sess.Send(&proto.Packet{Opcode: OpLobbyResult, Data: r.Encode()})
}

// nameFilter is the process's name filter, SR_ShardManager's one CStringCheck
// object (READ: the ShardManager's +0x400d0, loaded once at boot). main sets
// it from -abuse-filter / -abuse-filter-locale (SetNameFilter); until then,
// and without a file, it is namefilter.Default().
var nameFilter atomic.Pointer[namefilter.Filter]

func init() { nameFilter.Store(namefilter.Default()) }

// SetNameFilter installs f as the filter every new character and guild name
// is tested with (nil restores namefilter.Default()).
func SetNameFilter(f *namefilter.Filter) {
	if f == nil {
		f = namefilter.Default()
	}
	nameFilter.Store(f)
}

// NameFilter is the filter in use.
func NameFilter() *namefilter.Filter { return nameFilter.Load() }

// LobbyNameCode is the name rule both create and the name check apply
// (READ ShardManager 0x40f300 / 0x40f200, round 788), 0 when name passes:
//
//   - 2..12 bytes (lstrlenA), else 0x40c;
//   - 0x40f200, else 0x40d: no space; no `'` or `"` and none of the
//     compiled-in SQL words in the lower-cased name (0x527390); and the
//     AbuseFilter group's test (0x6df4c0): its allowed characters -- without a
//     file, [0-9A-Za-z_] (OURS: see namefilter.Default) -- then its substring
//     and whole-word lists. namefilter has the whole rule with addresses.
//
// The name-taken test (0x410) is the caller's (READ: `_IsExistingCharName`
// on `_CharNameList.CharName16`, collation Latin1_General_CI_AS, so
// case-insensitive; both character stores compare names case-insensitively).
//
// Existing characters keep their names whatever these say (OURS, the user
// accepted it): the rule is applied to new names only.
func LobbyNameCode(name string) uint16 {
	if len(name) < 2 || len(name) > 12 {
		return LobbyErrNameLength
	}
	if !NameFilter().NameOK(name) {
		return LobbyErrNameInvalid
	}
	return 0
}

func (d *LobbyDeps) nameCheck(ctx context.Context, req *LobbyRequest) *LobbyResult {
	r := &LobbyResult{Action: LobbyNameCheck}
	if code := LobbyNameCode(req.Name); code != 0 {
		r.Code = code
		return r
	}
	taken, err := d.Chars.NameTaken(ctx, req.Name)
	if err != nil {
		d.logger().Warn("lobby: name check", "err", err)
		r.Code = LobbyErrRefused
		return r
	}
	if taken {
		r.Code = LobbyErrNameExists
		return r
	}
	r.OK = true
	return r
}

// StartSpawn is one start position: a region and a point local to it.
type StartSpawn struct {
	RegionX, RegionY int
	X, Y, Z          float64
}

// StartSpawns are the three start positions per race, from which rand() % 3
// picks (READ, this package's SR_ShardManager FUN_0042bb20, table 0x781b88).
// Europe's second row appears twice in the table, and is kept twice.
var StartSpawns = map[int][3]StartSpawn{
	character.RaceChina: {
		{98, 168, 960, 20, 420},
		{98, 168, 958, 60, 1087},
		{97, 168, 951, 20, 170},
	},
	character.RaceEurope: {
		{107, 79, 1205, 80, 396},
		{105, 77, 1466, 79, 1488},
		{105, 77, 1466, 79, 1488},
	},
}

// startZones is the zone label a race's spawns are named in: the town whose
// frame they lie in, so the character shares the town's hub bucket with
// everyone already there (OURS: the label is OpenSRO's; the spawns are
// region-local in retail).
var startZones = map[int]string{
	character.RaceChina:  "jangan",
	character.RaceEurope: "constantinople",
}

// startFor picks race's start spawn (index i) and names it in its zone's
// frame (worldmap.ToZoneWorld): the zone label and the world point.
func startFor(race, i int) (zone string, x, y, z float64) {
	spawns := StartSpawns[race]
	sp := spawns[i%len(spawns)]
	zone = startZones[race]
	x, z, _ = worldmap.ToZoneWorld(zone, sp.RegionX, sp.RegionY, sp.X, sp.Z)
	return zone, x, sp.Y, z
}

// create runs the READ checks in the server's order (charselect.md section
// 5, "Create on the server"):
//
//  1. logged in (0x407, the caller);
//  2. fewer than 4 characters (0x405);
//  3. the body a player character and each non-zero item equipment, of the
//     body's Country or 3, of its sex or 2 (0x403, FUN_0048d8d0) -- here, on
//     top, every id in the creatable catalogue (OURS, the user's default) and
//     each item the piece its field names (OURS);
//  4. a weapon (0x404);
//  5. the name rules (0x40c, 0x40d, 0x410);
//
// then the worker's own: the three armour pieces of one class (READ
// 0x429dc2-0x429dd7; the worker fails, and 0x406 is INFERRED to be what the
// client then sees). OURS, the user's default: all three armour pieces are
// required -- China's Protector "none" (a per-server flag, OPEN) is not
// offered -- and are refused with 0x403 when missing. The scale's nibbles must
// be the sliders' 0..4 (OURS; 0x403).
func (d *LobbyDeps) create(ctx context.Context, accountID int64, req *LobbyRequest) *LobbyResult {
	r := &LobbyResult{Action: LobbyCreate}
	fail := func(code uint16) *LobbyResult { r.Code = code; return r }

	list, err := d.Chars.ListByAccount(ctx, accountID)
	if err != nil {
		d.logger().Warn("lobby: create: listing", "err", err)
		return fail(LobbyErrCreateFailed)
	}
	if len(list) >= character.MaxPerAccount {
		return fail(LobbyErrAccountFull)
	}

	if d.Catalogue == nil || d.Catalogue.Len() == 0 {
		d.logger().Warn("lobby: create refused: no creatable catalogue loaded (cmd/server -chargen-csv)")
		return fail(LobbyErrBadChargen)
	}
	model, ok := d.Catalogue.Get(int64(req.RefObjID))
	if !ok || model.Kind != refdata.CreatableModel || model.TypeID1 != 1 || model.TypeID2 != 1 {
		return fail(LobbyErrBadChargen)
	}
	if !character.ValidScale(int(req.Scale)) {
		return fail(LobbyErrBadChargen)
	}
	fields := []struct {
		id    uint32
		piece refdata.Piece
	}{{req.Chest, refdata.PieceChest}, {req.Legs, refdata.PieceLegs}, {req.Feet, refdata.PieceFeet}, {req.Weapon, refdata.PieceWeapon}}
	items := make([]refdata.Creatable, len(fields))
	for i, f := range fields {
		if f.id == 0 {
			continue
		}
		it, ok := d.Catalogue.Get(int64(f.id))
		if !ok || it.Kind != refdata.CreatableItem || it.TypeID1 != 3 || it.TypeID2 != 1 || it.Piece() != f.piece {
			return fail(LobbyErrBadChargen)
		}
		if it.Country != model.Country && it.Country != 3 {
			return fail(LobbyErrBadChargen)
		}
		if it.Sex != model.Sex && it.Sex != 2 {
			return fail(LobbyErrBadChargen)
		}
		items[i] = it
	}
	if req.Chest == 0 || req.Legs == 0 || req.Feet == 0 {
		return fail(LobbyErrBadChargen)
	}
	if req.Weapon == 0 {
		return fail(LobbyErrNoWeapon)
	}
	if code := LobbyNameCode(req.Name); code != 0 {
		return fail(code)
	}
	if taken, err := d.Chars.NameTaken(ctx, req.Name); err != nil {
		d.logger().Warn("lobby: create: name lookup", "err", err)
		return fail(LobbyErrCreateFailed)
	} else if taken {
		return fail(LobbyErrNameExists)
	}
	if items[0].ArmourClass() != items[1].ArmourClass() || items[0].ArmourClass() != items[2].ArmourClass() {
		return fail(LobbyErrCreateFailed)
	}

	zone, x, y, z := startFor(model.Country, d.pick(3))
	created, err := d.Chars.CreateCharacter(ctx, accountID, character.NewCharacter{
		Name: req.Name, RefObjID: model.ID, Scale: int(req.Scale),
		Gender:    character.GenderFor(model.Country, model.Sex),
		StartZone: zone, StartX: x, StartY: y, StartZ: z,
	})
	switch {
	case errors.Is(err, character.ErrNameTaken):
		return fail(LobbyErrNameExists)
	case errors.Is(err, character.ErrAccountFull):
		return fail(LobbyErrAccountFull)
	case err != nil:
		d.logger().Warn("lobby: create", "err", err)
		return fail(LobbyErrCreateFailed)
	}

	// The chosen items, worn, then what the server adds. A character that
	// could not be dressed is still a character (as before round 682): the
	// failure is logged, not sent.
	if err := equipment.GiveKit(ctx, d.Inv, d.Eq, created.ID, d.chosenKit(items, model.Country)); err != nil {
		d.logger().Warn("lobby: character created without all of its chosen items", "character", created.Name, "err", err)
	}
	d.giveDefaults(ctx, created, model.Country)
	r.OK = true
	metrics.CharacterOp("create")
	d.logger().Info("lobby: character created", "character", created.Name, "character_id", created.ID, "account_id", accountID)
	return r
}

// giveDefaults is what `_AddNewChar` gives every new character beside its
// items (READ, this package's procedure; EXTERNAL data, round 692): the
// `_RefCharDefault_*` rows of the character's Country or of Race 3 -- each
// mastery at level 0, each skill learned, and each quest with RequiredLevel 1
// and Service 1 started (refdata.CharDefaults says which rows). Country is the
// body's (catalogue column 14), the value the procedure's `_GetObjCountry`
// reads (INFERRED: its body was not exported).
//
// The procedure does this inside the create's transaction and fails the whole
// create when an insert fails (-15, -16, -17). Here, as for the items since
// round 682 (OURS), a character that could not be given everything is still
// a character: the failure is logged, not sent.
//
// The quests cannot be held as quests yet (quest/defaults.go): their code
// names are recorded against the character instead.
func (d *LobbyDeps) giveDefaults(ctx context.Context, c *character.Character, country int) {
	if d.Defaults == nil {
		return
	}
	if d.Skills != nil {
		if err := d.Skills.SeedMasteries(ctx, c.ID, d.Defaults.Masteries(country)); err != nil {
			d.logger().Warn("lobby: character created without its default masteries", "character", c.Name, "err", err)
		}
		for _, id := range d.Defaults.Skills(country) {
			if err := d.Skills.Learn(ctx, c.ID, id); err != nil && !errors.Is(err, skill.ErrAlreadyKnown) {
				d.logger().Warn("lobby: character created without a default skill", "character", c.Name, "skill", id, "err", err)
			}
		}
	}
	if d.Quests != nil {
		var codes []string
		for _, q := range d.Defaults.Quests(country) {
			codes = append(codes, q.CodeName)
		}
		if len(codes) > 0 {
			if err := d.Quests.GrantDefaultQuests(ctx, c.ID, codes); err != nil {
				d.logger().Warn("lobby: character created without its default quests", "character", c.Name, "err", err)
			}
		}
	}
}

// AmmoStartQuantity is how many arrows or bolts a new character is given:
// 250. READ (this package's `_AddNewChar`, EXTERNAL, round 692): it equips the
// ammunition into slot 7 with `_FN_ADD_INITIAL_EQUIP @NewCharID, 7,
// @DefaultArrow, 250`, where every other item's fourth argument is its
// durability; that the 250 is the stack's count for ammunition is INFERRED
// (`_FN_ADD_INITIAL_EQUIP`'s body was not exported). Until round 692 the bag
// got one full stack (its MaxStack, 2,500 on a retail archive), OURS. Capped
// at the row's MaxStack so it stays one stack.
const AmmoStartQuantity = 250

func ammoQuantity(maxStack int) int {
	if maxStack > 0 && maxStack < AmmoStartQuantity {
		return maxStack
	}
	return AmmoStartQuantity
}

// chosenKit is what a new character is given (READ, ShardManager
// FUN_00429c80): the chest, legs, feet and weapon it chose, worn; a bow's
// arrows (ITEM_ETC_AMMO_ARROW_01_DEF) or a crossbow's bolts
// (ITEM_ETC_AMMO_BOLT_01_DEF); otherwise, beside a one-handed weapon
// (TwoHanded 0, itemdata column 93 -- INFERRED to be what the server reads),
// the race's shield, worn.
//
// The ammunition is AmmoStartQuantity (round 692; see there), and goes into
// the bag, not worn (OURS): OpenSRO's equipment slot carries no quantity and
// ammunition is not modelled (session/skill.go). The durability byte the
// server writes for each item is the inventory's own fresh roll here (the
// procedure writes each item's `_RefObjItem.Dur_L`).
func (d *LobbyDeps) chosenKit(items []refdata.Creatable, race int) []equipment.KitPiece {
	slots := []equipment.Slot{equipment.SlotMail, equipment.SlotPants, equipment.SlotBoots, equipment.SlotWeapon}
	var kit []equipment.KitPiece
	for i, it := range items {
		if it.ID == 0 {
			continue
		}
		kit = append(kit, equipment.KitPiece{Slot: slots[i], ItemID: it.ID, Quantity: 1, Worn: true})
	}
	weapon := items[3]
	switch {
	case weapon.IsBow():
		if a, ok := d.Catalogue.Ammo(refdata.AmmoArrowCode); ok {
			kit = append(kit, equipment.KitPiece{Slot: equipment.SlotShield, ItemID: a.ID, Quantity: ammoQuantity(a.MaxStack)})
		}
	case weapon.IsCrossbow():
		if a, ok := d.Catalogue.Ammo(refdata.AmmoBoltCode); ok {
			kit = append(kit, equipment.KitPiece{Slot: equipment.SlotShield, ItemID: a.ID, Quantity: ammoQuantity(a.MaxStack)})
		}
	case !weapon.TwoHanded:
		if s, ok := d.Catalogue.Shield(race); ok {
			kit = append(kit, equipment.KitPiece{Slot: equipment.SlotShield, ItemID: s.ID, Quantity: 1, Worn: true})
		}
	}
	return kit
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

// findOwned returns the account's character named name, or nil.
func findOwned(list []*character.Character, name string) *character.Character {
	for _, c := range list {
		if c.Name == name {
			return c
		}
	}
	return nil
}

// remove is action 3: the 7-day soft delete (READ, `_DeleteCharTemporal`,
// replied at once). Refused (READ ShardManager, charselect.md section 5): an
// empty name 0x408 (retail also refuses a quote there: not applied, see
// below); a name not on the account 0x40b; a guild member or master 0x402
// (the client refuses those before sending, 0x858b40) -- and, failing closed,
// a guild lookup that errs (OURS). Academy members cannot occur: OpenSRO has no academy. A
// character already pending is refused with 0x402 (OURS).
func (d *LobbyDeps) remove(ctx context.Context, accountID int64, req *LobbyRequest) *LobbyResult {
	r := &LobbyResult{Action: LobbyDelete}
	// An empty name is refused with 0x408 (READ). The server's quote
	// refusal is not applied (round 682's review, OURS): a grandfathered
	// name may hold one, and the name is only matched against the account's
	// own list.
	if req.Name == "" {
		r.Code = LobbyErrDeleteName
		return r
	}
	list, err := d.Chars.ListByAccount(ctx, accountID)
	if err != nil {
		r.Code = LobbyErrRefused
		return r
	}
	c := findOwned(list, req.Name)
	if c == nil {
		r.Code = LobbyErrNotOnAccount
		return r
	}
	if class, err := d.guildClass(ctx, c.ID); err != nil || class != 0 {
		if err != nil {
			d.logger().Warn("lobby: delete refused: the guild lookup failed", "character", c.Name, "err", err)
		}
		r.Code = LobbyErrRefused
		return r
	}
	switch err := d.Chars.MarkDeleted(ctx, accountID, c.ID, d.now()); {
	case errors.Is(err, character.ErrNotFound):
		r.Code = LobbyErrNotOnAccount
	case err != nil:
		d.logger().Warn("lobby: delete", "character", c.Name, "err", err)
		r.Code = LobbyErrRefused
	default:
		r.OK = true
		metrics.CharacterOp("delete")
		d.logger().Info("lobby: character marked for deletion", "character", c.Name, "character_id", c.ID, "account_id", accountID)
	}
	return r
}

// restore is action 5 (READ, `_ReviveChar`): not on the account 0x40b, not
// pending deletion 0x419.
func (d *LobbyDeps) restore(ctx context.Context, accountID int64, req *LobbyRequest) *LobbyResult {
	r := &LobbyResult{Action: LobbyRestore}
	list, err := d.Chars.ListByAccount(ctx, accountID)
	if err != nil {
		r.Code = LobbyErrRefused
		return r
	}
	c := findOwned(list, req.Name)
	if c == nil {
		r.Code = LobbyErrNotOnAccount
		return r
	}
	switch err := d.Chars.Restore(ctx, accountID, c.ID); {
	case errors.Is(err, character.ErrNotDeleting):
		r.Code = LobbyErrNothingRestore
	case errors.Is(err, character.ErrNotFound):
		r.Code = LobbyErrNotOnAccount
	case err != nil:
		d.logger().Warn("lobby: restore", "character", c.Name, "err", err)
		r.Code = LobbyErrRefused
	default:
		r.OK = true
		metrics.CharacterOp("restore")
		d.logger().Info("lobby: character restored", "character", c.Name, "character_id", c.ID, "account_id", accountID)
	}
	return r
}

// guildClass is the list record's guild byte: 0 none, 1 member, 2 master
// (READ, the client's delete refusal reads 1 as _MEMBER and 2 as _MASTER).
// A lookup that fails for any reason but "not in a guild" is returned as an
// error (round 682's review: the delete refusal fails closed on it).
func (d *LobbyDeps) guildClass(ctx context.Context, characterID int64) (uint8, error) {
	if d.Guilds == nil {
		return 0, nil
	}
	g, err := d.Guilds.GetByCharacter(ctx, characterID)
	if errors.Is(err, guild.ErrNotInGuild) {
		return 0, nil
	}
	if err != nil {
		return 0, err
	}
	if g == nil {
		return 0, nil
	}
	if g.LeaderID == characterID {
		return 2, nil
	}
	return 1, nil
}

// list is action 2: every character on the account, in creation order (the
// client sorts by level, then EXP, itself -- READ 0x85e900).
func (d *LobbyDeps) list(ctx context.Context, sess *gateway.Session, accountID int64) error {
	chars, err := d.Chars.ListByAccount(ctx, accountID)
	if err != nil {
		d.logger().Warn("lobby: list", "err", err)
		return sendLobby(sess, &LobbyResult{Action: LobbyList, Code: LobbyErrRefused})
	}
	now := d.now()
	r := &LobbyResult{Action: LobbyList, OK: true}
	for _, c := range chars {
		r.Characters = append(r.Characters, d.record(ctx, c, now))
	}
	return sendLobby(sess, r)
}

// record is one character's list record.
//
//   - Level is a u8 and Exp the current-level progress (ExpOffset) the row
//     keeps; Str, Int and the unspent stat points are the row's.
//   - MP: OpenSRO does not persist current MP (character/schema.go's
//     EngineOnlyColumns "MP"), so a character not in the world reports the
//     mana tracker's value, which is its maximum when it has none (OURS).
//   - Items: the worn items in slots 0..8, the nine the record holds (INFERRED:
//     the nine non-accessory slots, which is OpenSRO's WearableSlots), each
//     named by the row it is drawn as (round 847: a model switcher's row,
//     displayRef, as the spawn record and 0x3038 name it; its own id in the
//     list's trailer, LobbyItem.Own), each
//     with its effective plus, OptLevel + the advanced elixir in a byte
//     (round 735; equipment.Equipped.EffectivePlus). The byte's place, after
//     each u32 RefItemID, is READ (the client's SCharacterInfo reader
//     0x85e620; FUN_0085a580 installs each item with it, so the select
//     screen can draw the glow). The value is the one 0x3038 and 0x3015
//     carry (READ); whether retail's list builder adds the elixir too was
//     not read.
//   - Avatars (round 789): the avatar inventory in storage order, at most
//     5, each u32 RefItemID and the u8 the client discards; OpenSRO writes
//     the OptLevel there (INFERRED: what the ShardManager writes into it is
//     not read, AVATAR_RESEARCH.md 4.2).
//   - Academy 0: OpenSRO has no academy.
func (d *LobbyDeps) record(ctx context.Context, c *character.Character, now time.Time) LobbyCharacter {
	maxMP := c.MaxMP()
	mp := maxMP
	if d.Mana != nil {
		mp = d.Mana.Current(c.ID, maxMP)
	}
	rec := LobbyCharacter{
		RefObjID: uint32(c.RefObjID), Name: c.Name, Scale: uint8(c.Scale), Level: clampU8(c.Level),
		Exp: uint64(maxI64(c.Exp, 0)), Str: clampU16(c.TotalStr()), Int: clampU16(c.TotalInt()), StatPoints: clampU16(c.StatPoints),
		HP: uint32(maxInt(c.HP, 0)), MP: uint32(maxInt(mp, 0)),
		Deleting: c.Deleting(), MinutesLeft: c.MinutesLeft(now),
	}
	if class, err := d.guildClass(ctx, c.ID); err == nil {
		rec.GuildClass = class
	} else {
		d.logger().Warn("lobby: list: the guild lookup failed; listed as guildless", "character", c.Name, "err", err)
	}
	if d.Eq != nil {
		if worn, err := d.Eq.Get(ctx, c.ID); err == nil {
			for slot := equipment.Slot(0); slot < equipment.Slot(LobbyMaxItems); slot++ {
				for _, w := range worn {
					if w.Slot == slot {
						// Round 847: the model a switcher gave the item is
						// drawn here as in the world (displayRef), and the
						// item's own id rides the list's trailer (Own).
						rec.Items = append(rec.Items, LobbyItem{RefItemID: uint32(displayRef(w.ItemID, w.Model)), Plus: w.EffectivePlus(),
							Own: switchedOwn(w.ItemID, w.Model)})
					}
				}
			}
		}
	}
	if d.Avatars != nil {
		if held, err := d.Avatars.List(ctx, c.ID); err == nil {
			sort.Slice(held, func(i, j int) bool { return held[i].Index < held[j].Index })
			for _, a := range held {
				if len(rec.Avatars) == LobbyMaxAvatars {
					break
				}
				rec.Avatars = append(rec.Avatars, LobbyItem{RefItemID: uint32(a.ItemID), Plus: a.OptLevel})
			}
		}
	}
	return rec
}

func clampU8(v int) uint8 {
	if v < 0 {
		return 0
	}
	if v > 0xff {
		return 0xff
	}
	return uint8(v)
}

func maxI64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// RunLobbyPurge removes characters whose deletion is DeleteDelay old, once
// every interval until ctx ends (OURS: the cadence; retail's
// `_DeleteCharPermanently` runs on a schedule not read). The removed rows'
// other tables (bag, worn items, skills) are left as Store.Delete always left
// them: OPEN, recorded in docs/TODO.md.
func RunLobbyPurge(ctx context.Context, store character.LobbyStore, interval time.Duration, now func() time.Time, logger *slog.Logger) {
	if now == nil {
		now = time.Now
	}
	if logger == nil {
		logger = slog.Default()
	}
	purge := func() {
		ids, err := store.PurgeDeleted(ctx, now().Add(-character.DeleteDelay))
		if err != nil {
			logger.Warn("lobby: purging deleted characters", "err", err)
			return
		}
		if len(ids) > 0 {
			logger.Info("lobby: purged characters whose 7-day deletion ended", "ids", ids)
		}
	}
	purge()
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			purge()
		}
	}
}
