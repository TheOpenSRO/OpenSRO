package session

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// The pet composite (round 838): a 3/3/13/15 item, whose Param2 carries
// "[PSU1:<skill>,<n>]" (ReferenceData::FUN_00864bc0 parses it as it parses
// the 3/3/13/14 list, two Param slots, refdata.Item.CompositeDesc). The mall's
// ITEM_MALL_PET_GROWTH_POTION (22712, "[PSU1:SKILL_MALL_PET_GROWTH_POTION_01,0]")
// and its event copy (35874) are the archive's. READ, SR_GameServer.exe:
//
//   - The parser. PSU::vslot_001 (0x864380; PSU and USU both derive from
//     UsedObjectUnLimit, FourCC 0x50535531 from the ctor 0x863a70) reads the
//     skill code up to "," and atols the rest up to "]" into +0x28. A
//     non-zero +0x28 makes the code sprintf("%s_%03d", code, the pet's level)
//     (0x49f298, 0x49f6d1; the per-level elemental pet skills carry 1).
//   - The use. UseByKind (0x49c2b0) case 0xf -> FUN_0049d890: the request's
//     extra byte is the bag slot (+13) of the pet's SUMMON ITEM (the client,
//     SendItem_HandleUseItem 0x796660, sends it for the item dropped on that
//     slot). Outside 13..111 answers 3; no COS summoner there with a COS out,
//     or the owner's vslot_375 not finding that COS, answers 0x18b8. Then
//     FUN_0049f590 runs with the PET as its object: FUN_0049f090's pre-check
//     looks the skill up (none: 2), refuses 0x1894 while a type-0 job keyed by
//     the skill id runs on the pet (FUN_00411560(0, id), 0x49f335) and a
//     skill with no 'dura' (0x650d40: 2), and the pet's kind against the
//     item's Param6 (+0x2c8): a growth pet (1/2/3/3, slot 270) needs bit 1, an
//     ability pet (1/2/3/4, slot 271, FUN_0049efc0) bit 2, else 3; a ride or a
//     transport answers 2. The job (0x49f7c5..0x49f842 -> 0x49fd46) is a
//     type-0 CTJ_SkillKeeperForPet on the pet's own job manager, keyed by the
//     skill id, lasting dura / 1000 s divided UNSIGNED (0x49f7ee) -- the item's
//     Param1 (1800) is not read; the growth potion's dura is 1,800,000 ms
//     (MEASURED), the same 30 minutes. Its slot 12 (0x650e70, shared with the
//     PC's CTJ_SkillKeeper) engages the skill and broadcasts 0xB0BD with the
//     pet's uid.
//   - The effect. SKILL_MALL_PET_GROWTH_POTION_01's params are "dura 1800000,
//     expi 0 100" (MEASURED); ApplySkillParamsToChar (0x594ac0) puts expi[1]
//     in the pet's ParamKeeper param 186, and the pet's EXP
//     (GObjPC::FUN_004fcb00, 0x4fccdb..0x4fcd18) adds trunc(E * p186 / 100.0)
//     to the pet's share E (the reward after its multiplier, before the rate
//     term): +100 %, the pet's EXP doubled.
//
// OURS: OpenSRO's use request carries the target as UseOptionCOSTarget with
// the summon item's bag index (as the clock and the revival, cosuse.go). The
// buff is kept per COS record in memory: it survives the pet being put away
// and called again (retail persists the job per pet, CTimedJob::
// PersistToDBForPet; INFERRED that it is kept across the unsummon), not a
// server restart. It is told as OpBuffStart / OpBuffEnd under the pet's uid
// with OwnerMonster (a COS is not a character; its uids do not meet the
// monsters', cosworld.go). Not modelled (disclosed): the skill gate 0x58d8f0,
// and the owner's own p256 + p186 term FUN_004fcb00 adds for the pet.

// The pet composite's refusals (READ, above).
const (
	petCompositeErrSlot   uint16 = 3      // the target outside 13..111, or a kind the item is not for
	petCompositeErrNoPet  uint16 = 0x18b8 // no summon item there with its COS out
	petCompositeErrNoSkil uint16 = 2      // the skill unknown, no 'dura', a ride or transport
	petCompositeErrInUse  uint16 = 0x1894 // UIIT_SKILL_USE_FAIL_OVERLAP
)

// isPetComposite reports a 3/3/13/15 item with a composite list.
func isPetComposite(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 13 && it.TypeID4 == 15 && it.CompositeDesc != ""
}

// psu1Entry is one "[PSU1:code,n]".
type psu1Entry struct {
	code    string
	byLevel bool // n != 0: code + "_%03d" of the pet's level
}

// parsePSU1 reads the PSU1 entries of a pet composite's list; any other kind
// in it is reported and skipped (none occurs in the archive, MEASURED).
func parsePSU1(desc string) (out []psu1Entry, other []string, err error) {
	rest := strings.TrimSpace(desc)
	for rest != "" {
		rest = strings.TrimLeft(rest, ", ")
		if rest == "" {
			break
		}
		if rest[0] != '[' {
			return nil, nil, fmt.Errorf("pet composite: %q: want '['", rest)
		}
		end := strings.IndexByte(rest, ']')
		if end < 0 {
			return nil, nil, fmt.Errorf("pet composite: %q: no ']'", rest)
		}
		body := rest[1:end]
		rest = rest[end+1:]
		kind, fields, ok := strings.Cut(body, ":")
		if !ok {
			return nil, nil, fmt.Errorf("pet composite: %q: no ':'", body)
		}
		if kind != "PSU1" {
			other = append(other, body)
			continue
		}
		code, n, _ := strings.Cut(fields, ",")
		code, n = strings.TrimSpace(code), strings.TrimSpace(n)
		if code == "" {
			return nil, nil, fmt.Errorf("pet composite: %q: no skill", body)
		}
		out = append(out, psu1Entry{code: code, byLevel: n != "" && n != "0"})
	}
	return out, other, nil
}

// petSkillCode is the skill an entry names for a pet of level.
func (e psu1Entry) petSkillCode(level int) string {
	if !e.byLevel {
		return e.code
	}
	return fmt.Sprintf("%s_%03d", e.code, level)
}

// petBuff is one running pet skill job.
type petBuff struct {
	skillID int64
	token   uint32
	expPct  int // the skill's expi[1]: ParamKeeper param 186 on the pet
	start   time.Time
	until   time.Time
	gen     uint64
}

// petBuffBook holds every COS record's running skill jobs (OURS storage, in
// memory; see the header).
type petBuffBook struct {
	mu    sync.Mutex
	byRec map[int64][]*petBuff
	gen   uint64
	token uint32
}

var petBuffs = &petBuffBook{byRec: map[int64][]*petBuff{}, token: 0x50000000}

// running returns rec's unexpired jobs, dropping the rest.
func (b *petBuffBook) running(rec int64, now time.Time) []petBuff {
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []petBuff
	kept := b.byRec[rec][:0]
	for _, p := range b.byRec[rec] {
		if now.Before(p.until) {
			kept = append(kept, p)
			out = append(out, *p)
		}
	}
	if len(kept) == 0 {
		delete(b.byRec, rec)
	} else {
		b.byRec[rec] = kept
	}
	return out
}

func (b *petBuffBook) has(rec, skillID int64, now time.Time) bool {
	for _, p := range b.running(rec, now) {
		if p.skillID == skillID {
			return true
		}
	}
	return false
}

// add starts a job and its end timer (lasts of real time).
func (b *petBuffBook) add(rec int64, p petBuff, lasts time.Duration) petBuff {
	b.mu.Lock()
	b.gen++
	b.token++
	p.gen, p.token = b.gen, b.token
	cp := p
	b.byRec[rec] = append(b.byRec[rec], &cp)
	b.mu.Unlock()
	time.AfterFunc(lasts, func() { b.expire(rec, cp.gen) })
	return cp
}

// expire ends the job the timer was started for, telling the pet's watchers
// when it is out.
func (b *petBuffBook) expire(rec int64, gen uint64) {
	b.mu.Lock()
	var ended *petBuff
	list := b.byRec[rec]
	for i, p := range list {
		if p.gen == gen {
			ended = p
			b.byRec[rec] = append(list[:i:i], list[i+1:]...)
			break
		}
	}
	if len(b.byRec[rec]) == 0 {
		delete(b.byRec, rec)
	}
	b.mu.Unlock()
	if ended == nil {
		return
	}
	if o := cosWorld.byRecord(rec); o != nil {
		sendAboutCOS(o, OpBuffEnd, (&BuffEnd{OwnerID: int64(o.uid), Tokens: []uint32{ended.token}, OwnerKind: OwnerMonster}).Encode())
	}
}

// expPercent is param 186 on the pet now: the sum of its running jobs'.
func (b *petBuffBook) expPercent(rec int64, now time.Time) int {
	n := 0
	for _, p := range b.running(rec, now) {
		n += p.expPct
	}
	return n
}

// petBuffStartPacket is p as OpBuffStart for the pet uid at now.
func petBuffStartPacket(uid uint32, p petBuff, now time.Time) []byte {
	left := p.until.Sub(now)
	if left < 0 {
		left = 0
	}
	return (&BuffStart{OwnerID: int64(uid), SkillID: p.skillID, Token: p.token,
		DurationMs: p.until.Sub(p.start).Milliseconds(), RemainingMs: left.Milliseconds(), OwnerKind: OwnerMonster}).Encode()
}

// announcePetBuffs tells o's watchers its running jobs (a summon, an
// arrival): the jobs outlive the pet's time in its item.
func announcePetBuffs(o *cosObj, now time.Time) {
	cosWorld.mu.Lock()
	rec, uid := o.rec.ID, o.uid
	cosWorld.mu.Unlock()
	for _, p := range petBuffs.running(rec, now) {
		sendAboutCOS(o, OpBuffStart, petBuffStartPacket(uid, p, now))
	}
}

// petExpBonus is FUN_004fcb00's pet term for the pet's share e:
// trunc(e * p186 / 100.0), nothing when the ratio is not above 0.
func petExpBonus(e int64, p186 int) int64 {
	ratio := float32(p186) / 100
	if ratio <= 0 || e <= 0 {
		return 0
	}
	return int64(float64(e) * float64(ratio))
}

// usePetComposite is the pet composite's use (UseByKind case 0xf).
func usePetComposite(ctx context.Context, sess *gateway.Session, inv inventory.Store, items ItemLookup, characterID int64,
	it *refdata.Item, held inventory.Slot, have int, req *UseItemRequest) error {
	refuse := func(code uint16, why string) error {
		return sendUseResult(sess, &UseItemResult{Error: why, Code: code, Remaining: int32(have)})
	}
	d := cosWorld.depsNow()
	if !d.enabled {
		return refuse(cos.ErrCannotBeUsed, "no COS table on this server")
	}
	// The target: the summon item's bag index (OURS form; retail's slot
	// byte outside 13..111 answers 3).
	if req.Option != UseOptionCOSTarget || int(req.Target)+AlchemyFirstBagSlot > AlchemyLastBagSlot {
		return refuse(petCompositeErrSlot, "choose the pet's summon item")
	}
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return refuse(cos.ErrCannotBeUsed, "lookup failed")
	}
	var target *inventory.Slot
	for i := range slots {
		if slots[i].Index == int(req.Target) {
			target = &slots[i]
		}
	}
	var o *cosObj
	if target != nil && target.Durability > 0 {
		if ref, err := items.GetItem(ctx, target.ItemID); err == nil && ref != nil && cos.IsPetItem(ref.TypeID1, ref.TypeID2, ref.TypeID3, ref.TypeID4) {
			o = cosWorld.byRecord(int64(target.Durability))
		}
	}
	if o == nil || o.owner != characterID {
		return refuse(petCompositeErrNoPet, "the pet is not summoned")
	}
	bySkill, ok := items.(skillByCode)
	if !ok {
		return refuse(petCompositeErrNoSkil, "that cannot be used")
	}
	entries, other, err := parsePSU1(it.CompositeDesc)
	if err != nil || len(entries) == 0 {
		return refuse(cos.ErrCannotBeUsed, "that cannot be used")
	}
	now := useItemClock()
	cosWorld.mu.Lock()
	kind, level, rec, uid, dead := o.kind, o.rec.Level, o.rec.ID, o.uid, o.dead
	cosWorld.mu.Unlock()
	if dead {
		return refuse(petCompositeErrNoPet, "the pet is dead")
	}
	type planned struct {
		ref   *refdata.Skill
		lasts time.Duration
	}
	var plan []planned
	for _, e := range entries {
		ref, err := bySkill.GetSkillByCode(ctx, e.petSkillCode(level))
		if err != nil || ref == nil {
			return refuse(petCompositeErrNoSkil, "that cannot be used")
		}
		if petBuffs.has(rec, ref.ID, now) {
			return refuse(petCompositeErrInUse, compositeOverlapRefusal)
		}
		if ref.DuraMs == 0 {
			return refuse(petCompositeErrNoSkil, "that cannot be used")
		}
		switch kind {
		case cos.KindGrowth:
			if it.Param6&1 == 0 {
				return refuse(petCompositeErrSlot, "that pet cannot use it")
			}
		case cos.KindAbility:
			if it.Param6&2 == 0 {
				return refuse(petCompositeErrSlot, "that pet cannot use it")
			}
		default:
			return refuse(petCompositeErrNoSkil, "that pet cannot use it")
		}
		plan = append(plan, planned{ref: ref, lasts: usu1Duration(ref.DuraMs)})
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return refuse(cos.ErrCannotBeUsed, "using failed")
	}
	for _, p := range plan {
		expPct := int(p.ref.Runs().Value("expi", 1))
		b := petBuffs.add(rec, petBuff{skillID: p.ref.ID, expPct: expPct, start: now, until: now.Add(p.lasts)}, p.lasts)
		sendAboutCOS(o, OpBuffStart, petBuffStartPacket(uid, b, now))
		slog.Info("pet composite: PSU1 skill job", "item", it.ID, "character_id", characterID, "cos", rec, "uid", uid,
			"skill", p.ref.ID, "seconds", int64(p.lasts/time.Second), "exp_percent", expPct)
	}
	if len(other) > 0 {
		slog.Info("pet composite: entries not modelled, skipped", "item", it.ID, "entries", other)
	}
	return sendUseResult(sess, &UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)})
}
