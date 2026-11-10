package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"sort"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/grounditem"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/metrics"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Items on the ground. A kill no longer drops straight into the killer's
// bag: it leaves ground items near the corpse that anyone in the zone sees
// and the owner (or, after 30 s, anyone) walks up to and picks. Our own
// protocol, like the rest; the rules behind it are the engine's, see
// internal/grounditem. All additive -- an older client that knows none of
// these opcodes simply does not see drops (it never crashed on OpLootDropped
// either, which is no longer sent).
const (
	OpGroundItemList          uint16 = 0x006a // client -> server: what lies in my zone
	OpGroundItemListResult    uint16 = 0x006b // server -> client
	OpGroundItemSpawned       uint16 = 0x006c // server -> zone: one item appeared
	OpGroundItemRemoved       uint16 = 0x006d // server -> zone: one item is gone (picked or expired)
	OpGroundItemOwnerReleased uint16 = 0x006e // server -> zone: its 30 s window passed (the real 0x304D)
	OpPickUp                  uint16 = 0x006f // client -> server: pick this ground item up
	OpPickUpResult            uint16 = 0x0079 // server -> client: the outcome
)

// Reasons an item left the ground.
const (
	GroundItemRemovedPicked  int32 = 0
	GroundItemRemovedExpired int32 = 1
)

// GroundItemSnapshot is one ground item on the wire.
type GroundItemSnapshot struct {
	ID       int64
	ItemID   int64
	Quantity int32
	Gold     bool
	X, Y, Z  float32
	OwnerID  int64 // 0 = anyone may pick it
	// Creator (round 805) is the stack instance's name string: a trade
	// good's buyer's job alias (inventory.Instance.Creator, round 801).
	// READ: CInstanceItem::vslot_010 (s:0x42e230) writes it into the item
	// spawn for a 3/3/8 or 3/3/9 item, and CIItem::vslot_025 (c:0x9e1d00)
	// appends it to the ground label as "(*%s)" / "(%s)". It rides after the
	// fixed snapshot (OURS framing: GroundItemSpawned's tail, the list's
	// trailing strings) so a client that walks fixed snapshots still reads.
	Creator string
}

func snapshotOf(it grounditem.Item, now time.Time) GroundItemSnapshot {
	s := GroundItemSnapshot{ID: it.ID, ItemID: it.ItemID, Quantity: it.Quantity, Gold: it.Gold,
		X: it.X, Y: it.Y, Z: it.Z, OwnerID: it.OwnerAt(now)}
	if it.Instance != nil {
		s.Creator = it.Instance.Creator
	}
	return s
}

// EncodeSpawned is OpGroundItemSpawned's payload: the snapshot, then its
// Creator as one length-prefixed string (round 805).
func (s *GroundItemSnapshot) EncodeSpawned() []byte {
	return append(s.Encode(), encodeStrings(s.Creator)...)
}

// DecodeGroundItemSpawned reads OpGroundItemSpawned; a payload from before
// round 805 has no Creator.
func DecodeGroundItemSpawned(data []byte) (*GroundItemSnapshot, error) {
	s, rest, err := decodeGroundItemSnapshot(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GroundItemSpawned: %w", err)
	}
	if len(rest) > 0 {
		f, _, err := decodeStringsPrefix(rest, 1)
		if err != nil {
			return nil, fmt.Errorf("session: decoding GroundItemSpawned: creator: %w", err)
		}
		s.Creator = f[0]
	}
	return s, nil
}

func (s *GroundItemSnapshot) Encode() []byte {
	out := append(encodeInt64(s.ID), encodeInt64(s.ItemID)...)
	buf := make([]byte, 5)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(s.Quantity))
	if s.Gold {
		buf[4] = 1
	}
	out = append(out, buf...)
	out = append(out, encodeFloat32(s.X)...)
	out = append(out, encodeFloat32(s.Y)...)
	out = append(out, encodeFloat32(s.Z)...)
	return append(out, encodeInt64(s.OwnerID)...)
}

func decodeGroundItemSnapshot(data []byte) (*GroundItemSnapshot, []byte, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, nil, fmt.Errorf("id: %w", err)
	}
	itemID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, nil, fmt.Errorf("item id: %w", err)
	}
	if len(rest) < 5 {
		return nil, nil, errors.New("truncated quantity")
	}
	s := &GroundItemSnapshot{ID: id, ItemID: itemID, Quantity: int32(binary.LittleEndian.Uint32(rest[0:4])), Gold: rest[4] == 1}
	rest = rest[5:]
	if s.X, rest, err = decodeFloat32(rest); err != nil {
		return nil, nil, fmt.Errorf("x: %w", err)
	}
	if s.Y, rest, err = decodeFloat32(rest); err != nil {
		return nil, nil, fmt.Errorf("y: %w", err)
	}
	if s.Z, rest, err = decodeFloat32(rest); err != nil {
		return nil, nil, fmt.Errorf("z: %w", err)
	}
	if s.OwnerID, rest, err = decodeInt64(rest); err != nil {
		return nil, nil, fmt.Errorf("owner: %w", err)
	}
	return s, rest, nil
}

// GroundItemListResult is everything on the ground in the asker's zone.
type GroundItemListResult struct {
	Items []GroundItemSnapshot
}

func (r *GroundItemListResult) Encode() []byte {
	out := make([]byte, 2)
	binary.LittleEndian.PutUint16(out, uint16(len(r.Items)))
	for i := range r.Items {
		out = append(out, r.Items[i].Encode()...)
	}
	// Round 805: the snapshots' Creators, in order, after the last one.
	for i := range r.Items {
		out = append(out, encodeStrings(r.Items[i].Creator)...)
	}
	return out
}

func DecodeGroundItemListResult(data []byte) (*GroundItemListResult, error) {
	if len(data) < 2 {
		return nil, errors.New("session: decoding GroundItemListResult: truncated count")
	}
	count := int(binary.LittleEndian.Uint16(data))
	rest := data[2:]
	r := &GroundItemListResult{}
	for i := 0; i < count; i++ {
		var s *GroundItemSnapshot
		var err error
		s, rest, err = decodeGroundItemSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding GroundItemListResult: item %d: %w", i, err)
		}
		r.Items = append(r.Items, *s)
	}
	if len(rest) > 0 {
		names, _, err := decodeStringsPrefix(rest, count)
		if err != nil {
			return nil, fmt.Errorf("session: decoding GroundItemListResult: creators: %w", err)
		}
		for i := range names {
			r.Items[i].Creator = names[i]
		}
	}
	return r, nil
}

// GroundItemRemoved says an item left the ground, and why.
type GroundItemRemoved struct {
	ID       int64
	Reason   int32
	PickerID int64 // the character that picked it, 0 when it expired
}

func (r *GroundItemRemoved) Encode() []byte {
	out := append(encodeInt64(r.ID), encodeInt64(int64(r.Reason))...)
	return append(out, encodeInt64(r.PickerID)...)
}

func DecodeGroundItemRemoved(data []byte) (*GroundItemRemoved, error) {
	id, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GroundItemRemoved: id: %w", err)
	}
	reason, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GroundItemRemoved: reason: %w", err)
	}
	picker, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GroundItemRemoved: picker: %w", err)
	}
	return &GroundItemRemoved{ID: id, Reason: int32(reason), PickerID: picker}, nil
}

// GroundItemOwnerReleased mirrors the engine's 0x304D: the 30 s window on
// this item has passed and anyone may pick it now.
type GroundItemOwnerReleased struct {
	ID int64
}

func (r *GroundItemOwnerReleased) Encode() []byte { return encodeInt64(r.ID) }

func DecodeGroundItemOwnerReleased(data []byte) (*GroundItemOwnerReleased, error) {
	id, _, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GroundItemOwnerReleased: %w", err)
	}
	return &GroundItemOwnerReleased{ID: id}, nil
}

// PickUpRequest asks to pick one ground item up.
type PickUpRequest struct {
	CharacterName string
	GroundItemID  int64
}

func (r *PickUpRequest) Encode() []byte {
	return append(encodeStrings(r.CharacterName), encodeInt64(r.GroundItemID)...)
}

func DecodePickUpRequest(data []byte) (*PickUpRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PickUpRequest: %w", err)
	}
	id, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PickUpRequest: id: %w", err)
	}
	return &PickUpRequest{CharacterName: fields[0], GroundItemID: id}, nil
}

// PickUpResult is the outcome: Code 0 and what landed (an item stack, or
// gold), or one of the engine's refusal codes (grounditem.Err*) as
// grounditem.PickCheck returns them -- 3 for a drop that is no longer there,
// 0x1839 for one whose CanPick is clear. The handler's own failures that the
// engine has no code for (an undecodable request, an unknown character, a
// bag or purse that will not take the stack) also answer 0x1839.
type PickUpResult struct {
	Code         int32
	GroundItemID int64
	ItemID       int64
	Quantity     int32
	Gold         bool
}

func (r *PickUpResult) Encode() []byte {
	out := append(encodeInt64(int64(r.Code)), encodeInt64(r.GroundItemID)...)
	out = append(out, encodeInt64(r.ItemID)...)
	buf := make([]byte, 5)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Quantity))
	if r.Gold {
		buf[4] = 1
	}
	return append(out, buf...)
}

func DecodePickUpResult(data []byte) (*PickUpResult, error) {
	code, rest, err := decodeInt64(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PickUpResult: code: %w", err)
	}
	gid, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PickUpResult: ground id: %w", err)
	}
	itemID, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding PickUpResult: item id: %w", err)
	}
	if len(rest) < 5 {
		return nil, errors.New("session: decoding PickUpResult: truncated quantity")
	}
	return &PickUpResult{Code: int32(code), GroundItemID: gid, ItemID: itemID,
		Quantity: int32(binary.LittleEndian.Uint32(rest[0:4])), Gold: rest[4] == 1}, nil
}

// dropKillLoot turns a kill's rewards into ground items near the corpse --
// the gold pile (ITEM_ETC_GOLD_03, the item FUN_009348f0 spawns) and whatever
// combat.LootTables rolled -- owned by the killer for the 30 s window, and
// tells everyone in the zone. Returns what was dropped.
//
// Each stack is placed the way the engine places it (round 785,
// grounditem.Scatter, READ FUN_0048fdf0): on a ring 8 to 20 units from the
// corpse at a random angle, every stack drawn on its own, with no test against
// the stacks already there. Until round 785 OpenSRO used its own 2-unit disc,
// which put a kill's stacks on top of one another (the user's log: 52 Gold and
// an HP herb 1.95 units apart). The y stays the corpse's: OpenSRO's server has
// no navmesh height (the engine's ResolveCellAndHeight), and the client grounds
// the stack under its x, z.
func dropKillLoot(ground *grounditem.Hub, hub *world.Hub, monster combat.Monster, killerID int64, gold int64, drops []LootDrop) []grounditem.Item {
	if ground == nil {
		return nil
	}
	var out []grounditem.Item
	place := func(itemID int64, qty int32, isGold bool) {
		x, z := grounditem.Scatter(monster.X, monster.Z, grounditem.ScatterDraw(rand.Intn), grounditem.ScatterDraw(rand.Intn))
		y := monster.Y
		// Round 879 (READ FUN_0048fdf0, s:0x48fdf0): the stack enters the
		// world at the ring's point from the corpse's (vslot 0x2b0 with the
		// corpse's position as the source); when that fails it enters at the
		// corpse's own point (the second call, source and target the same).
		// For a monster that carries its height (an instance's deck): the
		// walk from the corpse on the navigation mesh -- a wall or the
		// deck's edge in between leaves the stack on the corpse, else it
		// lies on the surface the walk ends on. MEASURED before: 2 of 203
		// stacks of a Wrecked Ship run landed past the deck's edge and were
		// drawn on the sea floor ~950 under it.
		if monster.HasHeight {
			fy, blocked := HatchFooting(monster.Zone, monster.X, monster.Y, monster.Z, x, z)
			if blocked {
				x, z = monster.X, monster.Z
			} else {
				y = fy
			}
		}
		it := ground.Drop(monster.Zone, itemID, qty, isGold, float32(x), float32(y), float32(z), killerID)
		// The corpse and the stack, so a QA run's server.log measures the ring.
		slog.Info("ground drop", "ground_item", it.ID, "monster", monster.ID, "corpse_x", monster.X, "corpse_z", monster.Z,
			"x", it.X, "z", it.Z, "from_corpse", math.Hypot(x-monster.X, z-monster.Z))
		out = append(out, it)
	}
	if gold > 0 {
		place(grounditem.GoldItemID, int32(gold), true)
	}
	for _, d := range drops {
		place(d.ItemID, d.Quantity, false)
	}
	if hub != nil {
		now := time.Now()
		for _, it := range out {
			snap := snapshotOf(it, now)
			pkt := &proto.Packet{Opcode: OpGroundItemSpawned, Data: snap.EncodeSpawned()}
			for _, e := range hub.EntitiesInZone(monster.Zone) {
				e.Session.Send(pkt)
			}
		}
	}
	return out
}

// DropSource is the real, server-side drop data: the two tables a kill needs
// to roll loot the way the engine does. Both the SQL and in-memory refdata
// stores already satisfy it; it is an interface here so the combat handler
// does not depend on a concrete store.
type DropSource interface {
	GetMonsterDrops(ctx context.Context, monsterID int64) ([]*refdata.MonsterDrop, error)
	GetDropGroupEntries(ctx context.Context, groupID int64) ([]*refdata.DropGroupEntry, error)
}

// realDrops rolls a kill against the REAL drop tables, returning ok=false when
// there is no real data for this monster so the caller can fall back.
//
// This closes the gap combat/loot.go documented: the algorithm
// (refdata.MonsterDrop.RollAssignedDrop / refdata.SelectFromGroup, recovered
// from CRefDropData__AddAssignedItemDrop) and the loaders have existed since
// 2026-09-15, and the only thing missing was the numeric key -- which
// cmd/server has carried as monsterSpec.RefObjID since 2026-09-19 and never
// passed to combat.Monster. Nothing here re-derives the engine's arithmetic;
// it calls the functions that already implement it.
//
// A row produces a COUNT of independent instances, not a stack: RollAssignedDrop
// picks an attempt count in [DropAmountMin, DropAmountMax] and rolls DropRatio
// afresh for each, and every success picks its own entry from the group. So the
// group is re-selected per instance rather than once per row.
//
// ok=true WITH AN EMPTY RESULT IS A REAL OUTCOME and must not fall through: a
// monster with real drop data that rolls nothing has dropped nothing. Falling
// back there would pay out the own-design table on top of the real one, which
// is how a kill would end up luckier than the engine ever makes it.
func realDrops(ctx context.Context, src DropSource, monster combat.Monster) ([]LootDrop, bool) {
	if src == nil || monster.RefObjID == 0 {
		return nil, false
	}
	rows, err := src.GetMonsterDrops(ctx, monster.RefObjID)
	if err != nil || len(rows) == 0 {
		return nil, false
	}
	var out []LootDrop
	for _, row := range rows {
		if row == nil {
			continue
		}
		n := row.RollAssignedDrop(nil)
		for i := 0; i < n; i++ {
			entries, err := src.GetDropGroupEntries(ctx, row.ItemGroupID)
			if err != nil || len(entries) == 0 {
				continue
			}
			// A group need not be exhaustive -- SelectFromGroup returns nil
			// when the roll falls past the last entry, which is the engine's
			// own behaviour, not an error.
			e := refdata.SelectFromGroup(entries, nil)
			if e == nil {
				continue
			}
			out = append(out, LootDrop{ItemID: e.ItemID, Quantity: 1})
		}
	}
	return out, true
}

// dropsForKill is everything a kill produced, before anything is done with it:
// the real tables when the operator has supplied them for this monster, and the
// own-design combat.LootTables otherwise.
//
// BOTH loot paths go through here on purpose. The ground path and the
// straight-to-inventory path used to roll separately, so wiring one would have
// left the other on own-design data -- and the ground path is the one cmd/server
// actually runs.
func dropsForKill(ctx context.Context, src DropSource, monster combat.Monster) []LootDrop {
	// Round 869 lane W3 (fgw_pillar.go): a Forgotten World monster's assigned
	// drops (the ENVY_DROP pillars' holes) come on top of its group drops.
	fgw := fgwKillLoot(ctx, monster)
	if d, ok := realDrops(ctx, src, monster); ok {
		return append(d, fgw...)
	}
	if len(fgw) > 0 {
		return append(rollDrops(monster.Name), fgw...)
	}
	return rollDrops(monster.Name)
}

// rollDrops rolls combat.LootTables[monsterName] without touching any
// inventory: what a kill leaves on the ground. The item ids are real, the
// per-monster assignment is own design (see combat/loot.go).
func rollDrops(monsterName string) []LootDrop {
	entries, ok := combat.LootTables[monsterName]
	if !ok {
		return nil
	}
	var drops []LootDrop
	for _, e := range entries {
		if rand.Float64() > e.Chance {
			continue
		}
		qty := e.MinQuantity
		if e.MaxQuantity > e.MinQuantity {
			qty += rand.Intn(e.MaxQuantity - e.MinQuantity + 1)
		}
		drops = append(drops, LootDrop{ItemID: e.ItemID, Quantity: int32(qty)})
	}
	return drops
}

// samePartyFunc is the party rule CheckCanPickUp applies to someone else's
// drop: allowed when picker and owner are in the same party and the party
// shares items (its flag bit with value 2, `FUN_004ea200() & 2`) -- round
// 712: the party's own Item Auto Share flag since round 710 gave parties
// their types.
// The engine never reaches this rule for an owned TypeID 3/3/9 item whose
// codename does not begin ITEM_QNO_RM_ARCHEMY (CheckCanPickUp refuses it
// 0x1812 at 0x4a934d first), and neither does grounditem.PickCheck, which
// refuses such an item before asking (grounditem.OwnerOnlyPick, round 497;
// docs/protocol/ground_items.md, "Picking up", step 3).
func samePartyFunc(parties *party.Hub) func(a, b int64) bool {
	if parties == nil {
		return nil
	}
	return func(a, b int64) bool {
		pa, inA := parties.Get(a)
		pb, inB := parties.Get(b)
		return inA && inB && pa != nil && pb != nil && pa.ID == pb.ID && pa.Flags.ItemShare()
	}
}

// GroundItemHandler returns a gateway.Handler implementing OpGroundItemList
// and OpPickUp.
func GroundItemHandler(chars character.Store, hub *world.Hub, ground *grounditem.Hub, inv inventory.Store, parties *party.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		// Round 869: the session's own world (gameworlds.go).
		hub := hub.For(sess)
		ground := groundFor(sess, ground)
		switch p.Opcode {
		case OpGroundItemList:
			entity, ok := hub.EntityBySession(sess.ID())
			if !ok || ground == nil {
				return sess.Send(&proto.Packet{Opcode: OpGroundItemListResult, Data: (&GroundItemListResult{}).Encode()})
			}
			now := time.Now()
			res := &GroundItemListResult{}
			for _, it := range ground.InZone(entity.Zone) {
				res.Items = append(res.Items, snapshotOf(it, now))
			}
			return sess.Send(&proto.Packet{Opcode: OpGroundItemListResult, Data: res.Encode()})

		case OpPickUp:
			req, err := DecodePickUpRequest(p.Data)
			if err != nil {
				return sess.Send(&proto.Packet{Opcode: OpPickUpResult, Data: (&PickUpResult{Code: grounditem.ErrCannotPick}).Encode()})
			}
			reply := func(r *PickUpResult) error {
				return sess.Send(&proto.Packet{Opcode: OpPickUpResult, Data: r.Encode()})
			}
			characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
			if errStr != "" {
				return reply(&PickUpResult{Code: grounditem.ErrCannotPick, GroundItemID: req.GroundItemID})
			}
			// Round 832: retail's pick-up is a 0x7074 kind-2 action, and Push
			// drops a running trace for it, silently (trace.go).
			dropTraceFor(characterID)
			entity, ok := hub.EntityBySession(sess.ID())
			if !ok || ground == nil || inv == nil {
				return reply(&PickUpResult{Code: grounditem.ErrCannotPick, GroundItemID: req.GroundItemID})
			}
			// A dead character picks nothing up (round 549, deadstate.go).
			// OWN DESIGN, disclosed: the retail pick-up handler (dispatch
			// 0x034, a vtable thunk through slot 0x608) was not read for a
			// life-state test; the code is the generic refusal.
			if entity.Life == world.LifeDead {
				return reply(&PickUpResult{Code: grounditem.ErrCannotPick, GroundItemID: req.GroundItemID})
			}
			// The engine measures the 10 units in 3-D. Here the vertical term is
			// dropped ON PURPOSE: OpenSRO's monsters (and so their drops) sit
			// at a placeholder y of 0 (combat.Monster: "own design placeholder
			// position") while clients report their real terrain height, so
			// a faithful 3-D distance in Jangan is ~50 units of pure height
			// mismatch. The rule in internal/grounditem stays the engine's;
			// this call site feeds it the item's own y until the server has
			// terrain heights of its own.
			var probe grounditem.Item
			if cur, ok := ground.Get(req.GroundItemID); ok {
				probe = cur
			}
			it, code := ground.PickCheck(req.GroundItemID, characterID,
				float32(entity.Pos.X), probe.Y, float32(entity.Pos.Z), samePartyFunc(parties))
			if code != 0 {
				// The refusal and its measurement, so a QA run's server.log says
				// which rule fired and with what numbers.
				slog.Info("pick-up refused", "character_id", characterID, "ground_item", req.GroundItemID,
					"code", fmt.Sprintf("%#x", code), "player_x", entity.Pos.X, "player_z", entity.Pos.Z,
					"item_x", probe.X, "item_z", probe.Z, "owner", probe.OwnerAt(time.Now()))
				return reply(&PickUpResult{Code: int32(code), GroundItemID: req.GroundItemID})
			}
			// A specialty good goes into the picker's transport by the job's
			// rules, never into the bag (round 801, pickGood).
			if !it.Gold {
				if items := cosWorld.depsNow().items; items != nil {
					if ref, err := items.GetItem(ctx, it.ItemID); err == nil && isSpecialtyItem(ref) {
						return pickGood(ctx, sess, entity, it, ground, hub, reply)
					}
				}
			}
			// The item is ours to take now (busy for everyone else). Move it.
			// An Item Auto Share party hands it on (round 712, itemshare.go):
			// gold is split among the members near the picker
			// (GObjPC::FUN_005bc7f0), an item goes to the next member of the
			// party's rotation (FUN_00525dc0) unless it is owner-only.
			sharing := itemSharePartyOf(parties, characterID)
			recipient := characterID
			pickedQty := it.Quantity
			var shares []goldShare
			if it.Gold {
				shares = []goldShare{{characterID, int64(it.Quantity)}}
				if sharing != nil {
					shares = splitGold(hub, sharing, entity, int64(it.Quantity))
				}
			} else if sharing != nil && !it.OwnerOnly() {
				recipient = roundRobinRecipient(hub, parties, sharing, entity)
			}
			// The grant is ONE transaction with the item's ledger claim (round
			// 743): every share of a gold split or none of them, and an item
			// granted at most once however many picks reach it -- a pick whose
			// commit succeeded but whose answer was lost, a retry, a second
			// process. See applyPickup.
			runner := txn.For(chars, inv)
			key := pickupLedgerKey(it)
			// Round 770: a fresh equipment drop gets its blue options
			// (dropstats.go), rolled once, before the transaction (which may
			// run again on a retry).
			if !it.Gold && it.Instance == nil {
				if inst, ok := freshDropInstance(ctx, it.ItemID); ok {
					it.Instance = &inst
				}
			}
			addErr := applyPickup(ctx, runner, chars, inv, it, key, recipient, shares)
			if addErr != nil && !errors.Is(addErr, txn.ErrAlreadyApplied) && !pickupRefusal(addErr) {
				// An error that does not say whether the commit happened:
				// the ledger does.
				if done, err := runner.Applied(ctx, key); err == nil && done {
					addErr = nil
				}
			}
			switch {
			case addErr == nil:
			case errors.Is(addErr, txn.ErrAlreadyApplied):
				// Granted already: it is not on the ground any more.
				if gone, ok := ground.Remove(it.ID); ok {
					broadcastGroundRemoval(hub, gone, 0)
				}
				return reply(&PickUpResult{Code: grounditem.ErrNotThere, GroundItemID: it.ID})
			default:
				ground.Release(it.ID)
				if !it.Gold && recipient != characterID && errors.Is(addErr, inventory.ErrNoRoom) {
					// The chosen member's bag is full: the picker is
					// refused 0x18da UIIT_MSG_STRGERR_PARTY_INVENTORY_FULL
					// and the item stays on the ground (READ, GS
					// FUN_00526090 0x52633d-0x5263a8). The member is told
					// 0x1807 in retail (op result 0xb034), which OpenSRO
					// has no message for (GAP).
					return reply(&PickUpResult{Code: ErrPartyInventoryFull, GroundItemID: it.ID})
				}
				return reply(&PickUpResult{Code: grounditem.ErrCannotPick, GroundItemID: it.ID})
			}
			if it.Gold {
				// The picker's own line reports the picker's part (its
				// client reads the balance back from the server). Every
				// credit also sends 0x304E kind 1, the new total (round 716):
				// the gold pick-up's credit GObjPC::FUN_004eaca0 calls
				// CGObjPC::OffsetGold (0x4e4b60) with (amount, 0, 0x19, 1, 0)
				// for a solo pick-up -- unshown, the purse only -- and, in an
				// Item Auto Share party, the split (0x5bc7f0) calls it with
				// (amount, 0, 0x17, 1, 1) for EVERY share, the picker's
				// included -- shown, so each client prints
				// UIIT_MSG_STATE_GAIN_GOLD with its rise (c:0x8a70d0).
				show := sharing != nil
				for _, g := range shares {
					tellGold(ctx, chars, hub, g.characterID, show)
				}
				pickedQty = int32(shares[0].amount)
			}
			ground.Remove(it.ID)
			metrics.ItemPicked("player", it.Gold)
			// The picker hears the result before the zone hears the removal,
			// so its own reply is never preceded by the broadcast.
			if err := reply(&PickUpResult{GroundItemID: it.ID, ItemID: it.ItemID, Quantity: pickedQty, Gold: it.Gold}); err != nil {
				return err
			}
			// The distribution notice (0x3068, READ GS FUN_005bdc80 from
			// 0x5263dd): for every item an Item Auto Share party's member
			// picks up -- an owner-only item too, which the round robin left
			// with the picker (FUN_00526090 calls it on any successful add
			// when the item is not gold, slot 31 CGObj::IsGold at
			// 0x5262a1-0x5262aa, 0x5263c8-0x5263dd). The gold split sends
			// none (FUN_005bc7f0 never calls 0x5bdc80, round 712's review).
			if sharing != nil && !it.Gold {
				class, amount := party.ItemNoticeOther, uint64(1)
				if it.Expendable {
					class, amount = party.ItemNoticeExpendable, uint64(it.Quantity)
				}
				sendItemNotice(hub, sharing, recipient, party.ItemNotice{RecipientJID: party.JIDOf(recipient),
					RefItemID: uint32(it.ItemID), Class: class, Amount: amount})
			}
			// The pick-up clip, for everyone in the zone (0x3036, round 785).
			broadcastPickUpMotion(hub, entity.Zone, characterID, entity.Pos.X, entity.Pos.Z, it)
			broadcastGroundRemoval(hub, it, characterID)
			return nil
		}
		return nil
	}
}

// OpPickUpMotion is retail's 0x3036 (round 785): a character has just picked
// something up -- turn it toward the item and play its pick-up clip. READ in
// SR_GameServer.exe: the player's pick (FUN_00526090, whose CGStorage add at
// 0x526335 succeeds, 0x526341 -> 0x5263b5) builds it at 0x52643c and
// broadcasts it to the picker's region (GObjPC::FUN_00484d90, 0x5264aa) --
// for an item and for gold alike (the IsGold answer at 0x5262a1 only skips
// the party notice, 0x5263c8); the pet's pick (GObjPC::FUN_004d4f60,
// 0x4d51de) sends the same with the pet's id. Nothing is sent for a refused
// pick. The payload, u32 the picker's unique id (+0x8, 0x52648c) and u8 the
// angle, is the client handler's (sro_client.exe FUN_008a78b0, registered for
// 0x3036 at 0x87065b): it reads the two, turns the object to face byte / 255
// * 360 degrees (plus the quarter turn every wire angle gets, FUN_009c40b0),
// and enters character state 10, whose enter (0xa59a00, the state table at
// 0xec5fb8 + 10 * 0x28) plays action type 38 -- the body's `_pickup` clip --
// once, and whose event handler (0xa59a60) leaves it when the clip ends.
//
// OURS: the order. The engine sends it after the add; OpenSRO sends the
// picker's PickUpResult, then this, then the zone's OpGroundItemRemoved (the
// engine's despawn of the picked item was not traced).
const OpPickUpMotion uint16 = 0x3036

// PickUpMotion is the 0x3036 payload.
type PickUpMotion struct {
	ObjectID uint32
	Angle    byte
}

func (m *PickUpMotion) Encode() []byte {
	out := make([]byte, 5)
	binary.LittleEndian.PutUint32(out[0:4], m.ObjectID)
	out[4] = m.Angle
	return out
}

func DecodePickUpMotion(data []byte) (*PickUpMotion, error) {
	if len(data) < 5 {
		return nil, errors.New("session: decoding PickUpMotion: truncated")
	}
	return &PickUpMotion{ObjectID: binary.LittleEndian.Uint32(data[0:4]), Angle: data[4]}, nil
}

// PickUpMotionAngle is 0x3036's angle byte for a picker at (px, pz) and an
// item at (ix, iz), in OpenSRO's frame. READ, the engine's (0x526422 ..
// 0x526473): atan2 of the vector between the two positions, in degrees
// (* 57.29578, .rdata 0xb45c38), / 360.0 (0xb45c30) * 255.0 (0xb460e8),
// truncated toward zero (the control word's 0xc00) and stored as its low byte,
// so a negative angle wraps. The engine's atan2 is taken in its region frame,
// x east and z north; OpenSRO's z runs the other way (the client's region
// group mirrors z, RemoteFacing's note), so the engine's angle is
// world.WireAngle of the heading OpenSRO computes toward the item -- the
// mapping every other wire angle this server sends uses -- taken into
// (-180, 180] degrees as atan2 answers. That the vector runs from the picker
// to the item (not back) is INFERRED: the item's position is copied at
// 0x52626a and the picker's at 0x5263e2, and the client turns its character to
// the angle as it bends.
func PickUpMotionAngle(px, pz, ix, iz float64) byte {
	a := world.WireAngle(world.HeadingToward(0, ix-px, iz-pz))
	if a > math.Pi {
		a -= 2 * math.Pi
	}
	deg := a * 57.295780181884766
	return byte(int32(deg / 360.0 * 255.0))
}

// broadcastPickUpMotion sends 0x3036 for the picker to its zone, the picker
// included (INFERRED: the engine's region broadcast, GObjPC::FUN_00484d90,
// was not traced to its receivers; the picker is in its own region).
func broadcastPickUpMotion(hub *world.Hub, zone string, pickerID int64, px, pz float64, it grounditem.Item) {
	m := &PickUpMotion{ObjectID: uint32(pickerID), Angle: PickUpMotionAngle(px, pz, float64(it.X), float64(it.Z))}
	pkt := &proto.Packet{Opcode: OpPickUpMotion, Data: m.Encode()}
	slog.Info("pick-up motion", "character_id", pickerID, "ground_item", it.ID, "angle", m.Angle)
	for _, e := range hub.EntitiesInZone(zone) {
		e.Session.Send(pkt)
	}
}

// broadcastGroundRemoval tells its zone the item was picked (by picker; 0
// when the picker is not known).
func broadcastGroundRemoval(hub *world.Hub, it grounditem.Item, picker int64) {
	removed := &GroundItemRemoved{ID: it.ID, Reason: GroundItemRemovedPicked, PickerID: picker}
	pkt := &proto.Packet{Opcode: OpGroundItemRemoved, Data: removed.Encode()}
	for _, e := range hub.EntitiesInZone(it.Zone) {
		e.Session.Send(pkt)
	}
}

// pickupLedgerKey is a ground item's key in the economy ledger: its serial
// (item_serial_seq, unique across processes and restarts) when it has one,
// else this process's boot id and its process-local number (a negative
// Serial, grounditem.Hub.Drop).
func pickupLedgerKey(it grounditem.Item) string {
	if it.Serial > 0 {
		return fmt.Sprintf("pickup:%d", it.Serial)
	}
	return fmt.Sprintf("pickup:%s:%d", txn.BootID, -it.Serial)
}

// pickupRefusal reports an orderly refusal of a pick-up's grant (the bag has
// no room), as opposed to an error that leaves its commit in doubt.
func pickupRefusal(err error) bool {
	return errors.Is(err, inventory.ErrNoRoom) || errors.Is(err, inventory.ErrInvalidQuantity)
}

// applyPickup grants a ground item as ONE transaction (round 743, the spec's
// M1): the item's ledger key is claimed first, then gold goes to every share
// or the item to its recipient. txn.ErrAlreadyApplied means the key was
// claimed before -- the item was granted already -- and nothing changed.
func applyPickup(ctx context.Context, runner txn.Runner, chars character.Store, inv inventory.Store, it grounditem.Item, key string, recipient int64, shares []goldShare) error {
	return runner.Run(ctx, func(ctx context.Context) error {
		if err := txn.Claim(ctx, key); err != nil {
			return err
		}
		if it.Gold {
			// In ascending character id (round 743's review, F1): every
			// action that locks several characters' rows locks them in one
			// order, so two members picking at once cannot deadlock. shares'
			// own order (the picker first) is left for the messages.
			for _, g := range sharesByCharacter(shares) {
				if err := chars.AddGold(ctx, g.characterID, g.amount); err != nil {
					return err
				}
			}
			return nil
		}
		// A stack that already had an instance keeps it; a fresh drop gets
		// one the way any new item does (rolled by the bag).
		if it.Instance != nil {
			return inv.AddItemInstance(ctx, recipient, it.ItemID, int(it.Quantity), *it.Instance)
		}
		return inv.AddItem(ctx, recipient, it.ItemID, int(it.Quantity))
	})
}

// RunGroundItemSweep releases expired ownerships and removes items past
// their lifetime once a second, telling each zone, until ctx is done. It is
// the tick CGItem::Update gets from the engine's object loop.
func RunGroundItemSweep(ctx context.Context, ground *grounditem.Hub, hub *world.Hub) {
	ticker := time.NewTicker(time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			start := time.Now()
			for _, it := range ground.ReleaseOwnerships() {
				pkt := &proto.Packet{Opcode: OpGroundItemOwnerReleased, Data: (&GroundItemOwnerReleased{ID: it.ID}).Encode()}
				for _, e := range hub.EntitiesInZone(it.Zone) {
					e.Session.Send(pkt)
				}
			}
			for _, it := range ground.Expire() {
				pkt := &proto.Packet{Opcode: OpGroundItemRemoved, Data: (&GroundItemRemoved{ID: it.ID, Reason: GroundItemRemovedExpired}).Encode()}
				for _, e := range hub.EntitiesInZone(it.Zone) {
					e.Session.Send(pkt)
				}
			}
			loopGroundItems.Tick(start)
		}
	}
}

// sharesByCharacter is a copy of shares in ascending character id, the order
// every multi-character action locks rows in.
func sharesByCharacter(shares []goldShare) []goldShare {
	out := append([]goldShare(nil), shares...)
	sort.Slice(out, func(i, j int) bool { return out[i].characterID < out[j].characterID })
	return out
}
