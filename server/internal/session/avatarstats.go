package session

// The avatar inventory's part in a character's stats (round 789). READ: an
// avatar's and a devil's spirit's blue options are published by the same path
// as equipment's -- CGAvatarInventoryOP::RefreshEquipParamEntryForPC
// (s:0x4bbcd0) -> GObjPC::PublishEquipItemParams (s:0x4e3760) ->
// CAlchemyMagicOptionOP::SetParamKeeperForMagicOpt (s:0x66b180) ->
// Stat_ApplyTaggedModifier (s:0x498690) -- each option a ParamKeeper entry
// keyed by the item; no set bonus. The avatar tags' params and entry slots,
// READ from Stat_ApplyTaggedModifier's disassembly on 2026-10-16 (each leaf's
// `mov edi,N` and the slot it pushes before ParamKeeper_SetParam 0x4b3510;
// slot 0 flat, 1 percent, 2 a multiplier, buff/stats.go):
//
//	stra, strv  p1 slot 0     (0x499123 / 0x49919c)   inta, intv  p2 slot 0 (0x498dd0 / 0x498e0b)
//	hpa         p3 slot 0     (0x4989a6)              mpa         p4 slot 0 (0x498a12)
//	era         p9 slot 1     (0x49890f)              hra         p11 slot 1 (0x498a8e)
//	hprg        p25 slot 1    (0x498d90)              mprg        p26 slot 1 (0x498f32)
//	hpna        p52 slot 1    (0x498cec)              mpna        p53 slot 1 (0x498ef4)
//	drua        p128..131 slot 0 (0x498bfb..0x498c39)
//	dara        p174..177 slot 2, the value negated (fchs 0x498b2e; 0x498b35..)
//	luca        p173 slot 0   (0x498e8f)              mdia        p188 slot 0 (0x498e42)
//	umdu        p259 slot 0   (0x499192)
//
// stra, inta, luca and mdia add to the entry the item already has for the
// param (0x4b3830 reads it), so two options of one tag on one item sum.
// 'brna' (MATTR_NASRUN_BLOCKRATE, p10) branches on the item's +0x190 first,
// as 'bri' does; its leaf was not followed (OPEN, not applied).
//
// OpenSRO adds these entries to the character's param totals beside its
// buffs' and passives' (charTotals), so every stat that reads a param through
// buffStat / buffBonus sees them: Str and Int, max HP and MP, parry, hit
// rate, the attacker's damage percent, and the regeneration rate (regen.go).
// Params OpenSRO's combat does not read yet -- 52/53, 173, 174..177 on a
// player, 188, 259 -- are carried and change nothing (OPEN, docs/TODO.md).
//
// The conditions (READ): a rental must not have expired (OpenSRO has no
// rentals); a devil's spirit only while awake (DetachAbilityByItemOptLevel
// s:0x4bbd60 strips an expired one) and after its opt-level ability step
// (FUN_00498020: RefMagicOptByItemOptLevel / RefAbilityByItemOptLevel by
// RefItemID + OptLevel). OpenSRO loads neither table, so a devil's spirit's
// opt-level abilities are not applied (OPEN); its own blue options are,
// while it is awake (OURS: the step's tables missing is not read as the step
// failing).

import (
	"context"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// avatarRegistry is the avatar inventory the spawn record, the stats and the
// world entry read (cmd/server: SetAvatarStore).
type avatarRegistry struct {
	store inventory.Store
	bag   inventory.Store
	items ItemLookup
	hub   *world.Hub
}

var avatarReg atomic.Pointer[avatarRegistry]

// SetAvatarStore installs the avatar inventory, the bag the world entry's
// integrity check moves a bad item to, the item table they are read through
// and the world hub the expiry notices go to. nil store: no character has
// avatars.
func SetAvatarStore(store, bag inventory.Store, items ItemLookup, hub *world.Hub) {
	if store == nil {
		avatarReg.Store(nil)
	} else {
		avatarReg.Store(&avatarRegistry{store: store, bag: bag, items: items, hub: hub})
	}
	avatarTotalsCache.Range(func(k, _ any) bool { avatarTotalsCache.Delete(k); return true })
	lookEpoch.Add(1)
	looks.Range(func(k, _ any) bool { looks.Delete(k); return true })
}

func avatarRegistryOf() *avatarRegistry { return avatarReg.Load() }

// avatarTag is one tag's ParamKeeper writes (the table above).
type avatarTag struct {
	params []int
	slot   int // 0 flat, 1 percent, 2 multiplier
	negate bool
}

var avatarTags = map[uint32]avatarTag{
	magicopt.PackTag("stra"): {params: []int{buff.ParamStr}},
	magicopt.PackTag("strv"): {params: []int{buff.ParamStr}},
	magicopt.PackTag("inta"): {params: []int{buff.ParamInt}},
	magicopt.PackTag("intv"): {params: []int{buff.ParamInt}},
	magicopt.PackTag("hpa"):  {params: []int{buff.ParamMaxHP}},
	magicopt.PackTag("mpa"):  {params: []int{buff.ParamMaxMP}},
	magicopt.PackTag("era"):  {params: []int{buff.ParamParry}, slot: 1},
	magicopt.PackTag("hra"):  {params: []int{buff.ParamHitRate}, slot: 1},
	magicopt.PackTag("hprg"): {params: []int{buff.ParamHPRegen}, slot: 1},
	magicopt.PackTag("mprg"): {params: []int{buff.ParamMPRegen}, slot: 1},
	magicopt.PackTag("hpna"): {params: []int{52}, slot: 1},
	magicopt.PackTag("mpna"): {params: []int{53}, slot: 1},
	magicopt.PackTag("drua"): {params: []int{buff.ParamDamagePhysA, buff.ParamDamagePhysB, buff.ParamDamageMagA, buff.ParamDamageMagB}},
	magicopt.PackTag("dara"): {params: []int{buff.ParamDefenderMult, buff.ParamDefenderMult + 1, buff.ParamDefenderMult + 2, buff.ParamDefenderMult + 3}, slot: 2, negate: true},
	magicopt.PackTag("luca"): {params: []int{173}},
	magicopt.PackTag("mdia"): {params: []int{188}},
	magicopt.PackTag("umdu"): {params: []int{259}},
}

// AvatarParamTotals is what a set of worn avatar items writes into the
// params at now: each option's tag through the table above, a devil's spirit
// only while awake. items resolves the rows; table the options.
func AvatarParamTotals(held []avatar.Held, table *magicopt.Table, now time.Time) map[int]buff.Totals {
	if table == nil {
		return nil
	}
	out := map[int]buff.Totals{}
	for _, h := range held {
		if !avatar.IsAvatarItem(h.Item) {
			continue
		}
		if avatar.IsDevilSpirit(h.Item) && !avatar.Awake(h.Slot.Durability, now) {
			continue
		}
		for _, p := range h.Slot.MagParams {
			row := table.ByID(inventory.MagParamOption(p))
			if row == nil {
				continue
			}
			tag, ok := avatarTags[row.Tag]
			if !ok {
				continue
			}
			v := float64(inventory.MagParamValue(p))
			if tag.negate {
				v = -v
			}
			for _, param := range tag.params {
				t := out[param]
				switch tag.slot {
				case 0:
					t.Flat += v
				case 1:
					t.Pct += v
				case 2:
					if !t.HasMult {
						t.Mult, t.HasMult = 1, true
					}
					t.Mult *= 1 + v/100
				}
				out[param] = t
			}
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// avatarTotalsEntry is a character's cached totals, good until `until` (the
// first worn devil's spirit's expiry; zero: no end) and while its generation
// holds.
type avatarTotalsEntry struct {
	totals map[int]buff.Totals
	until  time.Time
	gen    uint64
}

var (
	avatarTotalsCache sync.Map // int64 -> avatarTotalsEntry
	avatarTotalsGens  sync.Map // int64 -> *atomic.Uint64
)

func avatarTotalsGen(characterID int64) *atomic.Uint64 {
	if g, ok := avatarTotalsGens.Load(characterID); ok {
		return g.(*atomic.Uint64)
	}
	g, _ := avatarTotalsGens.LoadOrStore(characterID, new(atomic.Uint64))
	return g.(*atomic.Uint64)
}

// invalidateAvatarStats drops characterID's cached avatar totals (a move, a
// grant, an expiry) and the gear bonus the registry caches.
func invalidateAvatarStats(characterID int64) {
	avatarTotalsGen(characterID).Add(1)
	avatarTotalsCache.Delete(characterID)
	character.InvalidateBonus(characterID)
}

// avatarTotals is characterID's avatar param totals now (cached).
func avatarTotals(characterID int64) map[int]buff.Totals {
	reg := avatarRegistryOf()
	if reg == nil || characterID == 0 {
		return nil
	}
	now := time.Now()
	gen := avatarTotalsGen(characterID).Load()
	if v, ok := avatarTotalsCache.Load(characterID); ok {
		e := v.(avatarTotalsEntry)
		if e.gen == gen && (e.until.IsZero() || now.Before(e.until)) {
			return e.totals
		}
	}
	held, err := avatar.List(context.Background(), reg.store, reg.items, characterID)
	if err != nil {
		return nil
	}
	e := avatarTotalsEntry{totals: AvatarParamTotals(held, magicOptions.Load(), now), gen: gen}
	for _, h := range held {
		if avatar.IsDevilSpirit(h.Item) && avatar.Awake(h.Slot.Durability, now) {
			if at := time.Unix(int64(h.Slot.Durability), 0); e.until.IsZero() || at.Before(e.until) {
				e.until = at
			}
		}
	}
	if avatarTotalsGen(characterID).Load() == gen {
		avatarTotalsCache.Store(characterID, e)
	}
	return e.totals
}

// mergeTotals adds b's entries into a (a fresh map when both have some).
func mergeTotals(a, b map[int]buff.Totals) map[int]buff.Totals {
	if len(b) == 0 {
		return a
	}
	if len(a) == 0 {
		return b
	}
	out := make(map[int]buff.Totals, len(a)+len(b))
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		t, seen := out[k]
		if !seen {
			out[k] = v
			continue
		}
		t.Flat += v.Flat
		t.Pct += v.Pct
		if v.HasMult {
			if !t.HasMult {
				t.Mult = 1
			}
			t.Mult *= v.Mult
			t.HasMult = true
		}
		out[k] = t
	}
	return out
}

// The devil's spirit's expiry while worn (READ s:0x4bbd60, run on every
// storage operation): its params are removed, its opt-level abilities
// detached, and its owner told `0x3078 {3, avatar slot}`; the item stays in
// its slot. OpenSRO runs it on a timer at the expiry (OURS: retail's check
// rides the storage operations; a timer tells the player when it happens).
var spiritTimers = struct {
	sync.Mutex
	m map[[2]int64]*time.Timer // {character, slot} -> timer
}{m: map[[2]int64]*time.Timer{}}

// scheduleSpiritExpiry arms the expiry of the devil's spirit characterID
// wears in slot, expiring at data (a unix second). An earlier timer for the
// slot is replaced.
func scheduleSpiritExpiry(characterID int64, slot int, data int) {
	if data <= 0 {
		return
	}
	key := [2]int64{characterID, int64(slot)}
	d := time.Until(time.Unix(int64(data), 0))
	if d < 0 {
		d = 0
	}
	spiritTimers.Lock()
	if t := spiritTimers.m[key]; t != nil {
		t.Stop()
	}
	spiritTimers.m[key] = time.AfterFunc(d, func() { spiritExpired(characterID, slot, data) })
	spiritTimers.Unlock()
}

// spiritExpired is the timer's work: when the slot still holds a devil's
// spirit with that expiry, the stats lose it and the owner hears 0x3078.
func spiritExpired(characterID int64, slot int, data int) {
	spiritTimers.Lock()
	delete(spiritTimers.m, [2]int64{characterID, int64(slot)})
	spiritTimers.Unlock()
	reg := avatarRegistryOf()
	if reg == nil {
		return
	}
	held, err := avatar.List(context.Background(), reg.store, reg.items, characterID)
	if err != nil {
		return
	}
	for _, h := range held {
		if h.Slot.Index != slot || !avatar.IsDevilSpirit(h.Item) || h.Slot.Durability != data {
			continue
		}
		invalidateAvatarStats(characterID)
		if reg.hub != nil {
			if e, ok := reg.hub.EntityByCharacterID(characterID); ok && e.Session != nil {
				_ = e.Session.Send(&proto.Packet{Opcode: OpItemStateNotice, Data: []byte{ItemStateSpiritExpiry, byte(slot)}})
			}
		}
		pushOwnerStats(characterID)
		return
	}
}

// armWornSpirits arms the expiry of every awake devil's spirit characterID
// wears (the world entry).
func armWornSpirits(held []avatar.Held, characterID int64) {
	now := time.Now()
	for _, h := range held {
		if avatar.IsDevilSpirit(h.Item) && avatar.Awake(h.Slot.Durability, now) {
			scheduleSpiritExpiry(characterID, h.Slot.Index, h.Slot.Durability)
		}
	}
}
