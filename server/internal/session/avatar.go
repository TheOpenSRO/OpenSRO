package session

// The avatar inventory on the wire (round 789): the two moves on retail's
// 0x7034 / 0xB034, the list on OURS 0x0044 / 0x0045, the blacksmith's grant
// 0x34A9 / 0x34AA, the dead avatar enchant 0x34A7 / 0x34A8 and the world
// entry's integrity check. docs/protocol/avatars.md; the rules are
// internal/avatar's, READ unless labelled.

import (
	"context"
	"errors"
	"fmt"
	"log"
	"sort"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// AvatarDeps is what the avatar handlers need. Avatars nil (or Inv, Items)
// refuses every avatar operation.
type AvatarDeps struct {
	Chars   character.Store
	Inv     inventory.Store
	Avatars inventory.Store
	Items   ItemLookup
	Hub     *world.Hub
	Trades  *trade.Hub
}

// AvatarHandler answers OpAvatarList (0x0044), the grant (0x34A9) and the
// avatar enchant (0x34A7). The moves are ItemOpHandler's (0x7034).
func AvatarHandler(d AvatarDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpAvatarList:
			return handleAvatarList(ctx, sess, p.Data, d)
		case OpAvatarGrant:
			return handleAvatarGrant(ctx, sess, p.Data, d)
		case OpAvatarEnchant:
			return handleAvatarEnchant(ctx, sess, p.Data, d)
		}
		return nil
	}
}

// avatarCode is a refusal with its code, carried out of a transaction.
type avatarCode uint16

func (c avatarCode) Error() string { return fmt.Sprintf("avatar: refused 0x%x", uint16(c)) }

func avatarRefusal(err error) (uint16, bool) {
	var c avatarCode
	if errors.As(err, &c) {
		return uint16(c), true
	}
	return 0, false
}

// avatarStatsPush sends a character its stats after its avatars changed
// (retail's vslot 0x538 after the move, READ s:0x50f1f0); a test replaces it.
var avatarStatsPush = pushOwnerStats

// avatarRecordOf is an avatar item's record: the round-732 record, its word
// after the variance the durability for a 3/1/13 (0 on every retail avatar,
// MEASURED Dur 0) and the period word for a 3/1/14 (READ s:0x42e5c3).
func avatarRecordOf(it *refdata.Item, sl inventory.Slot, now time.Time) ItemInfo {
	word := uint32(0)
	switch {
	case it != nil && timeLimited(it):
		word = avatar.PeriodWord(sl.Durability, now)
	case sl.Durability > 0:
		word = uint32(sl.Durability)
	}
	return ItemInfo{Slot: sl.Index, RefItemID: uint32(sl.ItemID), OptLevel: sl.OptLevel, Variance: sl.Variance,
		Durability: word, MagParams: sl.MagParams, AdvElixir: sl.AdvElixir}
}

// AvatarListOf is the avatar section for held, in storage order.
func AvatarListOf(held []avatar.Held, now time.Time) *AvatarList {
	l := &AvatarList{Size: avatar.Slots, Items: []AvatarListItem{}}
	for _, h := range held {
		if h.Slot.Index < 0 || h.Slot.Index >= avatar.Slots {
			continue
		}
		l.Items = append(l.Items, AvatarListItem{Slot: byte(h.Slot.Index), Info: avatarRecordOf(h.Item, h.Slot, now)})
	}
	return l
}

// handleAvatarList answers 0x0044 with the section. The request is the bag
// list's (a character name, OpInventoryList's CharacterNameRequest) or empty,
// for the session's character in the world (OURS). Nothing is answered to a
// request that names no character of the session's (OURS: an empty section
// would read as "wears none", the ambiguity sendWornList's note describes).
func handleAvatarList(ctx context.Context, sess *gateway.Session, data []byte, d AvatarDeps) error {
	if d.Avatars == nil {
		return nil
	}
	cid := int64(-1)
	if len(data) > 0 && d.Chars != nil {
		req, err := DecodeCharacterNameRequest(data)
		if err != nil {
			return nil
		}
		id, errStr := resolveCharacterID(ctx, sess, d.Chars, req.Name)
		if errStr != "" {
			return nil
		}
		cid = id
	} else if d.Hub != nil {
		if e, ok := d.Hub.EntityBySession(sess.ID()); ok {
			cid = e.CharacterID
		}
	}
	if cid < 0 {
		return nil
	}
	held, err := avatar.List(ctx, d.Avatars, d.Items, cid)
	if err != nil {
		log.Printf("session: avatar list of %d: %v", cid, err)
		return nil
	}
	armWornSpirits(held, cid)
	return sess.Send(&proto.Packet{Opcode: OpAvatarListResult, Data: AvatarListOf(held, time.Now()).Encode()})
}

// handleAvatarMove is 0x7034 types 0x23 and 0x24: StorageOperation's framing
// (s:0x50f5c0) and then the type's handler (s:0x526ed0). Retail's order on
// the way out is kept: the move, the 0x3039 of a sub-op, the 0x3038 / 0x3039
// of the move, the stats, then the 0xB034 (READ s:0x50f1f0, s:0x4e9c40;
// retail answers after its DB commit, OpenSRO after its transaction).
func handleAvatarMove(ctx context.Context, sess *gateway.Session, data []byte, d AvatarDeps) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: EncodeItemFail(code)})
	}
	m, err := DecodeAvatarMove(data)
	if err != nil {
		return fail(avatar.CodeInvalidTarget) // OURS: a body that is not the parser's two bytes
	}
	if d.Hub == nil || d.Avatars == nil || d.Inv == nil || d.Items == nil {
		return fail(ItemErrDB)
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return fail(ItemErrDB)
	}
	cid := e.CharacterID
	// Dead: 2 (vslot 0xf8 == 2, the type is not 0x17/0x18).
	if e.Life == world.LifeDead {
		return fail(avatar.CodeDead)
	}
	// INTERACTMODE 2, 4 or 7: 0x1834. OpenSRO's established trade is mode 2
	// (CGObjPC::AttachEquipItem's note, equipment.go); it has no stall (4) and
	// no mode 7 (OURS: the mapping).
	if d.Trades.Established(cid) {
		return fail(avatar.CodeBlocked)
	}
	var c *character.Character
	if d.Chars != nil {
		c, _ = d.Chars.GetByID(ctx, cid)
	}
	var res *AvatarMoveResult
	var moved []movedAvatar
	err = txn.For(d.Inv, d.Avatars).Run(ctx, func(ctx context.Context) error {
		var err error
		if m.Type == ItemMoveBagToAvatar {
			res, moved, err = bagToAvatar(ctx, d, cid, c, m)
		} else {
			res, moved, err = avatarToBag(ctx, d, cid, m)
		}
		return err
	})
	if code, ok := avatarRefusal(err); ok {
		return fail(code)
	}
	if err != nil {
		log.Printf("session: avatar move of %d: %v", cid, err)
		return fail(ItemErrDB)
	}
	invalidateLook(cid)
	invalidateAvatarStats(cid)
	to := equipObservers(d.Hub, cid)
	for _, mv := range moved {
		msg := &EquipBroadcast{UID: uint32(cid), Slot: byte(mv.avatarSlot), RefItemID: uint32(mv.itemID)}
		op := OpUnequipBroadcast
		if mv.on {
			op = OpEquipBroadcast
			msg.Plus, msg.HasPlus = mv.plus, true
			if mv.spiritData > 0 {
				scheduleSpiritExpiry(cid, mv.avatarSlot, mv.spiritData)
			}
		}
		sendAboutOwner(to, cid, op, msg.Encode())
	}
	clampHP(ctx, d.Chars, cid)
	avatarStatsPush(cid)
	return sess.Send(&proto.Packet{Opcode: OpItemMoveResult, Data: res.Encode()})
}

// movedAvatar is one item a move put on (on) or took off, for its broadcast.
type movedAvatar struct {
	on         bool
	avatarSlot int
	itemID     int64
	plus       byte
	spiritData int // an awake devil's spirit's expiry, put on
}

func heldAt(held []avatar.Held, slot int) *avatar.Held {
	for i := range held {
		if held[i].Slot.Index == slot {
			return &held[i]
		}
	}
	return nil
}

// bagToAvatar is s:0x525950 (0x24), in its order.
func bagToAvatar(ctx context.Context, d AvatarDeps, cid int64, c *character.Character, m *AvatarMove) (*AvatarMoveResult, []movedAvatar, error) {
	// 1. The source is a bag slot (13..0x6f).
	if m.Src < ItemWireBagOffset || m.Src > 0x6f {
		return nil, nil, avatarCode(avatar.CodeInvalidTarget)
	}
	bagIdx := int(m.Src) - ItemWireBagOffset
	bag, err := d.Inv.List(ctx, cid)
	if err != nil {
		return nil, nil, err
	}
	var src *inventory.Slot
	for i := range bag {
		if bag[i].Index == bagIdx {
			src = &bag[i]
		}
	}
	// 2. Empty: 0x1809. (3. a serial of 0: every OpenSRO row has one.)
	if src == nil || src.Quantity <= 0 {
		return nil, nil, avatarCode(avatar.CodeEmpty)
	}
	it, err := d.Items.GetItem(ctx, src.ItemID)
	if err != nil {
		it = nil
	}
	// 4. CanBeEquipedAt(pc, dst).
	if code := avatar.CanBeEquipedAt(c, it, int(m.Dst)); code != 0 {
		return nil, nil, avatarCode(code)
	}
	// 5. Not 13 and not 14: 0x180e.
	if !avatar.IsAvatarItem(it) {
		return nil, nil, avatarCode(avatar.CodeEquipItem)
	}
	held, err := avatar.List(ctx, d.Avatars, d.Items, cid)
	if err != nil {
		return nil, nil, err
	}
	// 6. The same TypeID1..4 worn: 0x180e, no swap.
	for _, h := range held {
		if avatar.SameTID(h.Item, it) {
			return nil, nil, avatarCode(avatar.CodeEquipItem)
		}
	}
	// 7. An attachment needs a worn dress whose ChildItemCount is not 0.
	if avatar.IsAttachment(it) {
		ok := false
		for _, h := range held {
			if avatar.IsDress(h.Item) {
				ok = h.Item.ChildItemCount != 0
			}
		}
		if !ok {
			return nil, nil, avatarCode(avatar.CodeEquipItem)
		}
	}
	// 8. A devil's spirit that is not awake: 0x18f9.
	if avatar.IsDevilSpirit(it) && !avatar.Awake(src.Durability, time.Now()) {
		return nil, nil, avatarCode(avatar.CodeNotAwake)
	}
	// 9. FUN_00523f70: the source past the bag or the destination past the
	// avatar storage, 3; the destination kept when empty, else the first
	// empty avatar slot, none 0x1807.
	if bagIdx >= inventory.CapacityOf(ctx, d.Inv, cid) || int(m.Dst) >= avatar.Slots {
		return nil, nil, avatarCode(avatar.CodeInvalidTarget)
	}
	dst := int(m.Dst)
	if heldAt(held, dst) != nil {
		dst = -1
		for k := 0; k < avatar.Slots; k++ {
			if heldAt(held, k) == nil {
				dst = k
				break
			}
		}
		if dst < 0 {
			return nil, nil, avatarCode(avatar.CodeFull)
		}
	}
	placer, ok := d.Avatars.(inventory.Placer)
	if !ok {
		return nil, nil, errors.New("the avatar store cannot place")
	}
	inst, err := inventory.Take(ctx, d.Inv, cid, bagIdx, src.Quantity, src.ItemID, src.Instance())
	if err != nil {
		return nil, nil, err
	}
	if err := placer.PlaceItemInstance(ctx, cid, dst, src.ItemID, src.Quantity, inst); err != nil {
		return nil, nil, err
	}
	mv := movedAvatar{on: true, avatarSlot: dst, itemID: src.ItemID, plus: byte(int(inst.OptLevel) + int(inst.AdvElixir))}
	if avatar.IsDevilSpirit(it) {
		mv.spiritData = inst.Durability
	}
	return &AvatarMoveResult{OK: true, Type: m.Type, Src: m.Src, Dst: byte(dst), Subs: []AvatarSubOp{}}, []movedAvatar{mv}, nil
}

// avatarToBag is s:0x525ac0 (0x23): the client's bag slot is discarded for
// the first free one; a dress worn with an attachment takes it along as a
// sub-op into the next free slot (s:0x525c50), which needs two free slots.
func avatarToBag(ctx context.Context, d AvatarDeps, cid int64, m *AvatarMove) (*AvatarMoveResult, []movedAvatar, error) {
	held, err := avatar.List(ctx, d.Avatars, d.Items, cid)
	if err != nil {
		return nil, nil, err
	}
	src := heldAt(held, int(m.Src))
	if src == nil {
		return nil, nil, avatarCode(avatar.CodeEmpty)
	}
	if !avatar.IsAvatarItem(src.Item) {
		return nil, nil, avatarCode(avatar.CodeEquipItem)
	}
	bag, err := d.Inv.List(ctx, cid)
	if err != nil {
		return nil, nil, err
	}
	taken := make(map[int]bool, len(bag))
	for _, s := range bag {
		taken[s.Index] = true
	}
	var free []int
	for i := 0; i < inventory.PlacementCapacityOf(ctx, d.Inv, cid) && len(free) < 2; i++ {
		if !taken[i] {
			free = append(free, i)
		}
	}
	if len(free) == 0 {
		return nil, nil, avatarCode(avatar.CodeFull)
	}
	var att *avatar.Held
	if avatar.IsDress(src.Item) {
		for i := range held {
			if avatar.IsAttachment(held[i].Item) {
				att = &held[i]
			}
		}
	}
	if att != nil && len(free) < 2 {
		return nil, nil, avatarCode(avatar.CodeFull)
	}
	placer, ok := d.Inv.(inventory.Placer)
	if !ok {
		return nil, nil, errors.New("the bag cannot place")
	}
	move := func(h *avatar.Held, bagIdx int) error {
		inst, err := inventory.Take(ctx, d.Avatars, cid, h.Slot.Index, h.Slot.Quantity, h.Slot.ItemID, h.Slot.Instance())
		if err != nil {
			return err
		}
		return placer.PlaceItemInstance(ctx, cid, bagIdx, h.Slot.ItemID, h.Slot.Quantity, inst)
	}
	res := &AvatarMoveResult{OK: true, Type: m.Type, Src: m.Src, Dst: byte(free[0] + ItemWireBagOffset), Subs: []AvatarSubOp{}}
	var moved []movedAvatar
	if att != nil {
		if err := move(att, free[1]); err != nil {
			return nil, nil, err
		}
		res.Subs = append(res.Subs, AvatarSubOp{Type: m.Type, Src: byte(att.Slot.Index), Dst: byte(free[1] + ItemWireBagOffset)})
		moved = append(moved, movedAvatar{avatarSlot: att.Slot.Index, itemID: att.Slot.ItemID})
	}
	if err := move(src, free[0]); err != nil {
		return nil, nil, err
	}
	moved = append(moved, movedAvatar{avatarSlot: src.Slot.Index, itemID: src.Slot.ItemID})
	return res, moved, nil
}

// ---- the world entry: CheckAvatarsetIntegrity ----

// errAvatarIntegrity refuses a world entry whose avatar inventory fails the
// check and cannot be mended.
var errAvatarIntegrity = errors.New("the avatar inventory holds an item it may not, and the bag has no room for it")

// mendAvatarsAtEntry is CGObjPC::Create's CheckAvatarsetIntegrity (READ
// s:0x4e0dc0 -> s:0x4bb8a0; avatar.IntegrityFailure). Retail refuses the
// character's login when it fails (FUN_004df050(4)). OURS: OpenSRO moves
// each failing item to the bag instead, and refuses the entry only when the
// bag has no room. Why: every failing state is reached only from outside the
// game -- an operator's item table changing a row's gender or type, a
// database edit, a bug -- and retail's answer locks the character out until
// an operator repairs the database; moving the item keeps it and restores the
// invariant retail checks. Then the worn devil's spirits' expiries are armed.
func mendAvatarsAtEntry(ctx context.Context, owned *character.Character) error {
	reg := avatarRegistryOf()
	if reg == nil || owned == nil {
		return nil
	}
	held, err := avatar.List(ctx, reg.store, reg.items, owned.ID)
	if err != nil {
		return nil // read again by the list; nothing to mend from an error
	}
	var bad []avatar.Held
	var seen []avatar.Held
	for _, h := range held {
		if why := avatar.IntegrityFailure(owned, h, seen); why != "" && reg.items != nil {
			log.Printf("session: %q's avatar slot %d (item %d): %s; moved to the bag", owned.Name, h.Slot.Index, h.Slot.ItemID, why)
			bad = append(bad, h)
			continue
		}
		seen = append(seen, h)
	}
	if len(bad) > 0 {
		if reg.bag == nil {
			return errAvatarIntegrity
		}
		err := txn.For(reg.bag, reg.store).Run(ctx, func(ctx context.Context) error {
			for _, h := range bad {
				inst, err := inventory.Take(ctx, reg.store, owned.ID, h.Slot.Index, h.Slot.Quantity, h.Slot.ItemID, h.Slot.Instance())
				if err != nil {
					return err
				}
				if err := reg.bag.AddItemInstance(ctx, owned.ID, h.Slot.ItemID, h.Slot.Quantity, inst); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			log.Printf("session: mending %q's avatars: %v", owned.Name, err)
			return errAvatarIntegrity
		}
		invalidateAvatarStats(owned.ID)
	}
	armWornSpirits(seen, owned.ID)
	return nil
}

// ---- the grant at the blacksmith (CBless_AvatarItemWithNPC) ----

// The grant's codes (READ gs:0x5079c0, 0x5055a0, 0x505810; the client's
// texts are category 0x20, AVATAR_ALCHEMY_RESEARCH.md section 1).
const (
	GrantErrCapNew      uint16 = 2   // a new option with the cap reached; _BlessItem's other failures
	GrantErrNoItem      uint16 = 3   // no item at the slot (or an expired rental)
	GrantErrOverCap     uint16 = 6   // UIIT_MSG_AVATAR_MAGICOPTION_ADD_ERORR: already over the cap
	GrantErrLostRoll    uint16 = 7   // UIIT_STT_AVATAR_MAGICOPTION_ADD_FAIL: unreachable at rate 100
	GrantErrNotAvatar   uint16 = 8   // UIIT_STT_AVATAR_MAGICOPTION_ONLY_AVATAR
	GrantErrSlot        uint16 = 9   // the slot outside 13..111
	GrantErrWrongOption uint16 = 0xa // UIIT_STT_AVATAR_MAGICOPTION_WRONG: no such option / degree / kind
	GrantErrNoRecord    uint16 = 0xb // no record (unreachable after 0xa's test)
)

// grantRand is the grant's rand(); a test replaces it.
var grantRand magicopt.Rand = defaultCombatRand{}

// GrantCap is FUN_00491780: MaxMagicOptCount (itemdata col 158) plus one per
// 'dura' / 'nrep' option the item carries, at most 12 (READ gs:0x505810).
func GrantCap(it *refdata.Item, params []uint64, table *magicopt.Table) int {
	n := it.MaxMagicOptions
	dura, nrep := magicopt.PackTag("dura"), magicopt.PackTag("nrep")
	for _, p := range params {
		if r := table.ByID(inventory.MagParamOption(p)); r != nil && (r.Tag == dura || r.Tag == nrep) {
			n++
		}
	}
	return min(n, inventory.MaxMagParams)
}

// The bless tags the grant counts up rather than rolls (READ gs:0x505810:
// atha/luck/soli/astr refused 6 past 6; 'rep' past 7, INFERRED from the
// decompile's flags). No avatar assign row names them; the kind test can
// still let one through by name, so they are kept.
var grantBlessBound = map[uint32]uint32{
	magicopt.PackTag("atha"): 6, magicopt.PackTag("luck"): 6, magicopt.PackTag("soli"): 6,
	magicopt.PackTag("astr"): 6, magicopt.PackTag("rep"): 7,
}

// BlessAvatar is _BlessItem (gs:0x505810) on an avatar's options: the MATTR
// group by name (case-insensitive), its record at the item's degree
// ((ItemClass-1)/3+1), the kind test, then the option with the record's tag
// AND id re-rolled in place (a bless tag counted up) or a new one appended
// while under the cap. The value is the record's generator, clamped 1..1700.
// It returns the new options, or the refusal code.
func BlessAvatar(it *refdata.Item, params []uint64, code string, table *magicopt.Table, rng magicopt.Rand) ([]uint64, uint16) {
	if it == nil {
		return nil, GrantErrNoItem
	}
	limit := GrantCap(it, params, table)
	if len(params) > limit {
		return nil, GrantErrOverCap
	}
	code = strings.TrimSpace(code)
	if code == "" || len(table.Group(code)) == 0 {
		return nil, GrantErrWrongOption
	}
	degree := (it.ItemClass-1)/3 + 1
	rec := table.Record(code, degree)
	if rec == nil || !rec.AllowedOn(it.TypeID3, it.TypeID4, it.CodeName) {
		return nil, GrantErrWrongOption
	}
	at := -1
	for i, p := range params {
		if r := table.ByID(inventory.MagParamOption(p)); r != nil && r.Tag == rec.Tag && r.ID == rec.ID {
			at = i
		}
	}
	var value uint32
	if bound, bless := grantBlessBound[rec.Tag]; bless && at >= 0 {
		value = inventory.MagParamValue(params[at]) + 1
		if value > bound {
			return nil, GrantErrOverCap
		}
	} else {
		value = rec.Generate(rng)
	}
	if value == 0 {
		value = 1
	}
	if value > 1699 {
		value = 1700
	}
	out := append([]uint64(nil), params...)
	if at >= 0 {
		out[at] = inventory.MagParam(rec.ID, value)
		return out, 0
	}
	if len(out) >= limit {
		return nil, GrantErrCapNew
	}
	return append(out, inventory.MagParam(rec.ID, value)), 0
}

// handleAvatarGrant is 0x34A9 -> 0x34AA (gs:0x5079c0). Nothing is spent
// (READ). OURS: like retail, no NPC, distance or talk state is required --
// the window is opened by the blacksmith's 0x7046 {npc, 0x20} (npctalk.go),
// and the grant itself is free, so a request without it gains nothing a walk
// to the blacksmith would not.
func handleAvatarGrant(ctx context.Context, sess *gateway.Session, data []byte, d AvatarDeps) error {
	send := func(r *AvatarGrantResult) error {
		return sess.Send(&proto.Packet{Opcode: OpAvatarGrantResult, Data: r.Encode()})
	}
	refuse := func(code uint16) error { return send(&AvatarGrantResult{Code: code}) }
	if d.Hub == nil {
		return nil
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	cid := e.CharacterID
	if len(data) >= 1 && (data[0] < AlchemyFirstBagSlot || data[0] > AlchemyLastBagSlot) {
		return refuse(GrantErrSlot)
	}
	req, err := DecodeAvatarGrantRequest(data)
	if err != nil {
		// The server would look the clamped name up and not find it.
		return refuse(GrantErrWrongOption)
	}
	table := magicOptions.Load()
	if d.Inv == nil || d.Items == nil || table == nil {
		return refuse(GrantErrWrongOption) // OURS: no option table loaded
	}
	idx := int(req.Slot) - AlchemyFirstBagSlot
	var after inventory.Slot
	err = txn.For(d.Inv).Run(ctx, func(ctx context.Context) error {
		bag, err := d.Inv.List(ctx, cid)
		if err != nil {
			return err
		}
		var sl *inventory.Slot
		for i := range bag {
			if bag[i].Index == idx {
				sl = &bag[i]
			}
		}
		if sl == nil {
			return avatarCode(GrantErrNoItem)
		}
		it, err := d.Items.GetItem(ctx, sl.ItemID)
		if err != nil || !avatar.IsAvatar(it) {
			return avatarCode(GrantErrNotAvatar)
		}
		params, code := BlessAvatar(it, sl.MagParams, req.Code, table, grantRand)
		if code != 0 {
			return avatarCode(code)
		}
		inst := sl.Instance()
		inst.MagParams = params
		if err := d.Inv.SetInstance(ctx, cid, idx, inst); err != nil {
			return err
		}
		after = *sl
		after.SetInstance(inst)
		return nil
	})
	if code, ok := avatarRefusal(err); ok {
		return refuse(code)
	}
	if err != nil {
		log.Printf("session: avatar grant of %d: %v", cid, err)
		return refuse(GrantErrCapNew)
	}
	it, _ := d.Items.GetItem(ctx, after.ItemID)
	return send(&AvatarGrantResult{OK: true, Flag: 1, Slot: req.Slot, Item: avatarRecordOf(it, after, time.Now())})
}

// ---- the avatar enchant, alchemy op 7 (CEnchant_EnchantAvatarItem) ----

// AvatarEnchantDeadCode is what op 7 always ends in: its _BlessItem
// (gs:0x504170) reads the option name from a string only vtable slot 13 sets,
// and nothing calls slot 13, so it returns 2 and nothing is spent (READ,
// AVATAR_ALCHEMY_RESEARCH.md section 2).
const AvatarEnchantDeadCode = 2

// avatarEnchantRefusal is op 7's request: the checks every alchemy op makes
// (FUN_00507cf0: a slot outside 13..111 0x5414, an empty one 3, a first slot
// that is not equipment 0x5408), the magic stone's loader it shares (an
// equipment target to slot 0, a magic or bless stone to slot 1, anything else
// 0x5410, twice 0x5412), then the dead end, 2. OURS: answered at once, not
// after the operation's wait -- it cannot succeed, and nothing waits on it.
func avatarEnchantRefusal(ctx context.Context, inv inventory.Store, items ItemLookup, cid int64, slots []int) uint16 {
	if inv == nil || items == nil {
		return AvatarEnchantDeadCode
	}
	bag, err := inv.List(ctx, cid)
	if err != nil {
		return AvatarEnchantDeadCode
	}
	var loaded [2]bool
	for i, wire := range slots {
		if wire < AlchemyFirstBagSlot || wire > AlchemyLastBagSlot {
			return AlchemyErrInvalidSlot
		}
		var found *inventory.Slot
		for k := range bag {
			if bag[k].Index == wire-AlchemyFirstBagSlot {
				found = &bag[k]
			}
		}
		if found == nil {
			return AlchemyErrEmptySlot
		}
		it, err := items.GetItem(ctx, found.ItemID)
		if err != nil || it == nil {
			return 0x5410
		}
		if i == 0 && !isEquipment(it) {
			return 0x5408
		}
		at := -1
		switch {
		case isEquipment(it):
			at = 0
		case itemKind(it, 3, 3, 11, 1), itemKind(it, 3, 3, 11, 7):
			at = 1
		default:
			return 0x5410
		}
		if loaded[at] {
			return 0x5412
		}
		loaded[at] = true
	}
	return AvatarEnchantDeadCode
}

// handleAvatarEnchant is 0x34A7 (gs:0x507910): `u8 action`; 2 starts with
// `u8 n, n x u8 slot` and is answered `0x34A8 {2, u16 code}`; any other
// action cancels, which with nothing pending answers nothing (READ).
func handleAvatarEnchant(ctx context.Context, sess *gateway.Session, data []byte, d AvatarDeps) error {
	if len(data) < 1 || data[0] != AlchemyActionStart || d.Hub == nil {
		return nil
	}
	e, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	var slots []int
	if len(data) >= 2 {
		n := int(data[1])
		for i := 0; i < n && 2+i < len(data); i++ {
			slots = append(slots, int(data[2+i]))
		}
	}
	code := avatarEnchantRefusal(ctx, d.Inv, d.Items, e.CharacterID, slots)
	return sess.Send(&proto.Packet{Opcode: OpAvatarEnchantResult, Data: EncodeItemFail(code)})
}

// sortedHeld is held in storage order (the stores list it so already; a
// guard for a store that does not).
func sortedHeld(held []avatar.Held) []avatar.Held {
	sort.SliceStable(held, func(i, j int) bool { return held[i].Slot.Index < held[j].Slot.Index })
	return held
}

// avatarSpawnItems is the spawn record's avatar block for characterID: the
// 3/1/13 and 3/1/14 items in storage order, each with its plus (OptLevel +
// the advanced elixir; READ s:0x4ba720 mode 2, the client reads the plus only
// for 13/14, c:0x9de3e2). An id the item table does not know is left out:
// the client would read it without its plus byte.
func avatarSpawnItems(ctx context.Context, characterID int64) []avatarSpawnItem {
	reg := avatarRegistryOf()
	if reg == nil || reg.items == nil {
		return nil
	}
	held, err := avatar.List(ctx, reg.store, reg.items, characterID)
	if err != nil {
		return nil
	}
	var out []avatarSpawnItem
	for _, h := range sortedHeld(held) {
		if !avatar.IsAvatarItem(h.Item) {
			continue
		}
		out = append(out, avatarSpawnItem{ref: uint32(h.Slot.ItemID), plus: byte(int(h.Slot.OptLevel) + int(h.Slot.AdvElixir))})
	}
	return out
}

type avatarSpawnItem struct {
	ref  uint32
	plus byte
}
