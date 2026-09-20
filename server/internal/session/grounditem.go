package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"math/rand"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/grounditem"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/world"
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
}

func snapshotOf(it grounditem.Item, now time.Time) GroundItemSnapshot {
	return GroundItemSnapshot{ID: it.ID, ItemID: it.ItemID, Quantity: it.Quantity, Gold: it.Gold,
		X: it.X, Y: it.Y, Z: it.Z, OwnerID: it.OwnerAt(now)}
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
// gold), or one of the engine's refusal codes (grounditem.Err*).
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

// DropScatter is how far from the corpse a dropped stack lands, in world
// units, on a uniform disc. Own design, disclosed: the engine's spread was
// not read (the drop position is set in the spawn path, not in CGItem).
// Two units keeps a kill's several stacks apart without hiding one under
// the corpse.
const DropScatter = 2.0

// dropKillLoot turns a kill's rewards into ground items near the corpse --
// the gold pile (ITEM_ETC_GOLD_03, the item FUN_009348f0 spawns) and whatever
// combat.LootTables rolled -- owned by the killer for the 30 s window, and
// tells everyone in the zone. Returns what was dropped.
func dropKillLoot(ground *grounditem.Hub, hub *world.Hub, monster combat.Monster, killerID int64, gold int64, drops []LootDrop) []grounditem.Item {
	if ground == nil {
		return nil
	}
	var out []grounditem.Item
	place := func(itemID int64, qty int32, isGold bool) {
		angle := rand.Float64() * 2 * math.Pi
		dist := math.Sqrt(rand.Float64()) * DropScatter
		it := ground.Drop(monster.Zone, itemID, qty, isGold,
			float32(monster.X+math.Cos(angle)*dist), float32(monster.Y), float32(monster.Z+math.Sin(angle)*dist), killerID)
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
			pkt := &proto.Packet{Opcode: OpGroundItemSpawned, Data: snap.Encode()}
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
	if d, ok := realDrops(ctx, src, monster); ok {
		return d
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
// shares items (its flag bit with value 2, `FUN_004ea200() & 2`). srrevamp's
// parties share unconditionally, the same choice already made for
// experience (internal/party), so being in the same party is enough here.
func samePartyFunc(parties *party.Hub) func(a, b int64) bool {
	if parties == nil {
		return nil
	}
	return func(a, b int64) bool {
		pa, inA := parties.Get(a)
		pb, inB := parties.Get(b)
		return inA && inB && pa != nil && pb != nil && pa.ID == pb.ID
	}
}

// GroundItemHandler returns a gateway.Handler implementing OpGroundItemList
// and OpPickUp.
func GroundItemHandler(chars character.Store, hub *world.Hub, ground *grounditem.Hub, inv inventory.Store, parties *party.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
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
			entity, ok := hub.EntityBySession(sess.ID())
			if !ok || ground == nil || inv == nil {
				return reply(&PickUpResult{Code: grounditem.ErrCannotPick, GroundItemID: req.GroundItemID})
			}
			// The engine measures the 10 units in 3-D. Here the vertical term is
			// dropped ON PURPOSE: srrevamp's monsters (and so their drops) sit
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
			// The item is ours to take now (busy for everyone else). Move it.
			if it.Gold {
				if err := chars.AddGold(ctx, characterID, int64(it.Quantity)); err != nil {
					ground.Release(it.ID)
					return reply(&PickUpResult{Code: grounditem.ErrCannotPick, GroundItemID: it.ID})
				}
			} else {
				// A stack that already had an instance keeps it; a fresh drop
				// gets one the way any new item does (rolled by the bag).
				var addErr error
				if it.Instance != nil {
					addErr = inv.AddItemInstance(ctx, characterID, it.ItemID, int(it.Quantity), *it.Instance)
				} else {
					addErr = inv.AddItem(ctx, characterID, it.ItemID, int(it.Quantity))
				}
				if addErr != nil {
					ground.Release(it.ID)
					return reply(&PickUpResult{Code: grounditem.ErrCannotPick, GroundItemID: it.ID})
				}
			}
			ground.Remove(it.ID)
			// The picker hears the result before the zone hears the removal,
			// so its own reply is never preceded by the broadcast.
			if err := reply(&PickUpResult{GroundItemID: it.ID, ItemID: it.ItemID, Quantity: it.Quantity, Gold: it.Gold}); err != nil {
				return err
			}
			removed := &GroundItemRemoved{ID: it.ID, Reason: GroundItemRemovedPicked, PickerID: characterID}
			pkt := &proto.Packet{Opcode: OpGroundItemRemoved, Data: removed.Encode()}
			for _, e := range hub.EntitiesInZone(it.Zone) {
				e.Session.Send(pkt)
			}
			return nil
		}
		return nil
	}
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
		}
	}
}
