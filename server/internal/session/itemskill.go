package session

import (
	"context"
	"log/slog"
	"strings"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skilljob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The skill items (round 838): TypeID 3/3/13/1..3, an item whose use casts
// the skill its Desc128_1 names -- the archive's Godbless wings
// (ITEM_NEW_GODBLESS_*), the Boots of Speed (ITEM_SPEED_105), the damage
// absorption scrolls (ITEM_MALL_DAMAGE_ABS_*) and the movement-speed drugs
// (ITEM_ETC_ARCHEMY_POTION_SPEED_*). READ, SR_GameServer.exe:
//
//   - The load. The item reference loader (0x6a4b00 region, RefObjItem::
//     ExtractData's parameter pass) takes a 3/3/13 row whose TypeID4 is 1..3
//     (`(tid & 0x780) == 0x680`, `(tid >> 11) - 1 <= 2`), reads its
//     Desc128_1 (+0x2a4) as a skill code, finds the skill in the skill map
//     (DAT_00d6aa14 + 0x894) and OVERWRITES Param1 (+0x2a0) with that
//     skill's id ("Ooops! Item skill is not set..!!" when the text is empty,
//     "Can't find Item bound skill" when it names none). So the file's own
//     Param1 -- 0 on the wings, 5 / 11 on the drugs, 11 on the boots -- is
//     never read by the server: it is the Desc128_1 skill that is cast.
//   - The use. Item_HandleUseItem checks the item's COOLTIME, then
//     CGItemExpendable::UseByKind (0x0049c2b0) cases 1, 2 and 3 look the
//     skill up by Param1 (FUN_0046c1f0) and call FUN_0059b8d0(book, skill):
//     a row carrying 'cbuf' (+0x358) AND 'dura' (+0x280) queues a type-0
//     timed job, GObjPC::FUN_0049a390(0, skill id, dura / 1000) -- the
//     division unsigned (`**(uint **)(skill + 0x280) / 1000`), the same
//     CTJ_SkillKeeper a composite's USU1 entry makes (composite.go) -- and
//     answers 1; any other row builds a skill-use context, runs
//     Skill_CheckUseConditions (a refusal is sent through
//     Skill_SendActionResult and the use answers 2) and engages it at once.
//     A use that answers 1 spends the item and logs ItemEventLog 0x6e.
//   - The job's start (CTJ_SkillKeeper slot 12, 0x650e70) registers the
//     skill in the book, broadcasts 0xB0BD (Skill_BroadcastBuffAdded), sets
//     the row's Action_Overlap and 'ovl2' bits and engages it: an ordinary
//     buff every client in view is told of and draws.
//
// Every row this round meets carries 'cbuf' and 'dura' (MEASURED,
// skilldata_*.txt of the player's archive): the wings 2,419,200 s (the
// signed column's -1875767296), the boots 604,800 s with 'hste' 115, the
// drugs 1,800 s with 'hste' 50 / 100, the scrolls 1,800 s with 'odar'
// 15,10 and 15,20. A row without them -- the context path -- is not
// modelled and the item is refused, not spent.
//
// INFERRED, the overlap: the job's start sets the row's overlap bits without
// testing them, and the cbuf path calls no Skill_CheckUseConditions, so the
// engine's own refusal for a second item of one family was not found on
// this path (OPEN). OpenSRO runs the book's recast rule (buff.Books.
// CheckOverlap: FUN_0059d870's bit test) BEFORE the spend and refuses with
// 0x300c, so the item is kept -- what the scroll's description says
// ("Cannot be used with another item or skill that has a similar effect")
// and what the rows' bytes give: the two absorption scrolls share 0x0a and
// 0x09, every speed row byte 6 (the drugs, the boots, Grass Walk), every
// wing 0x72/0x75/0x63 (the Godbless wings and the VSROEDITORCOM wings).
// Starting after the spend instead would have eaten the item on the engage
// test's refusal.
//
// OURS, the character visuals: the VSROEDITORCOM visual and trail scrolls'
// description reads "This scroll cannot be used with other character effect
// scrolls". The rows' overlap bytes only keep one per kind (horns 0x31/0x9b/
// 0x94, crowns 0x6d, capes 0x55, wings 'rcur', trails 0x57/0xb3/0xe2), so
// OpenSRO adds the description's rule: a visual -- a VSROEDITORCOM visual or
// trail, or a Godbless wing, which the mall sells beside them -- is refused
// with 0x1894's text while another visual runs. Refused, not replaced: the
// description says "cannot be used with", and the engine's answer to an
// overlap is a refusal.
//
// The job (skilljob): it outlives the character object, as the engine's
// timed jobs do, so the buff comes back at the next entry with what is left
// of it (restoreSkillJobs), and a death does not end it (OURS: endBuffsOf).

// skillJobs is the item-started skill jobs' store (cmd/server sets the SQL
// one; a server without a database keeps them in memory, across relogs).
var skillJobs atomic.Pointer[skillJobStore]

type skillJobStore struct{ s skilljob.Store }

func init() { skillJobs.Store(&skillJobStore{s: skilljob.NewMemStore()}) }

// SetSkillJobStore replaces the jobs' store (cmd/server: the SQL store).
func SetSkillJobStore(s skilljob.Store) {
	if s != nil {
		skillJobs.Store(&skillJobStore{s: s})
	}
}

func jobStore() skilljob.Store { return skillJobs.Load().s }

// skillJobRefs is the skill lookup the world entry restores jobs through:
// the item lookup UseItemHandler was built with, when it carries skills.
var skillJobRefs atomic.Pointer[skillRefHolder]

type skillRefHolder struct{ r SkillRefStore }

func noteSkillJobRefs(items combat.ItemLookup) {
	if r, ok := items.(SkillRefStore); ok {
		skillJobRefs.Store(&skillRefHolder{r: r})
	}
}

// isSkillItem reports whether the use goes to UseByKind cases 1-3: TypeID
// 3/3/13 with TypeID4 1, 2 or 3, its Desc128_1 a skill code.
func isSkillItem(it *refdata.Item) bool {
	return it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable && it.TypeID3 == 13 &&
		it.TypeID4 >= 1 && it.TypeID4 <= 3 && boundSkillCode(it) != "" && !isPlaceholderSkill(boundSkillCode(it))
}

// placeholderSkillPrefixes are the private server's stand-in skills (round
// 838 lane 6, MEASURED in the player's archive): rows with 'cbuf' and a
// 'dura' of 1000 ms and no effect at all, named by the Desc128_1 of rows
// whose use was that server's filter -- SKILL_CELESTIUS_SILK_SCROLL_10
// (ITEM_ACCESSORY_UPGRADE, ITEM_NAME_CHANGE, ITEM_RACE_CHANGE,
// ITEM_RANDOM_WING, ITEM_SANTA_BOX, ITEM_SET_UPGRADE),
// SKILL_CELESTIUS_SILK_SCROLL_2500 (the four ITEM_ELIXIR_COUPON_*),
// SKILL_CRATE_* (the five ITEM_CRATE_*) and SKILL_SILK_LOTTERY. Casting one
// would spend the item for a second of nothing, so such an item is no skill
// item (OURS): a path above claims it (the service scrolls), or it is refused
// and kept.
var placeholderSkillPrefixes = []string{"SKILL_CELESTIUS_SILK_SCROLL_", "SKILL_CRATE_", "SKILL_SILK_LOTTERY"}

// isPlaceholderSkill reports whether a skill code is one of those.
func isPlaceholderSkill(code string) bool {
	for _, p := range placeholderSkillPrefixes {
		if strings.HasPrefix(code, p) {
			return true
		}
	}
	return false
}

// boundSkillCode is the row's Desc128_1, the skill the loader binds (READ,
// see the header); "" for none ("xxx" is the table's empty text).
func boundSkillCode(it *refdata.Item) string {
	c := strings.TrimSpace(it.Desc1)
	if c == "" || strings.EqualFold(c, "xxx") {
		return ""
	}
	return c
}

// visualSkillPrefixes are the character visuals' skill codes (OURS, see the
// header): what the description's "other character effect scrolls" names.
var visualSkillPrefixes = []string{"SKILL_VSROEDITORCOM_VISUAL_", "SKILL_VSROEDITORCOM_TRAIL_", "SKILL_NEW_GODBLESS_"}

// isVisualSkill reports whether a skill code is a character visual's.
func isVisualSkill(code string) bool {
	for _, p := range visualSkillPrefixes {
		if strings.HasPrefix(code, p) {
			return true
		}
	}
	return false
}

// visualRunning reports whether characterID carries a character visual's
// buff other than skillID's: the description's restriction (OURS).
func visualRunning(ctx context.Context, refs SkillRefStore, characterID, skillID int64) bool {
	if refs == nil {
		return false
	}
	for _, r := range buffBooks.Active(characterID) {
		if r.SkillID == skillID {
			continue
		}
		if ref, err := refs.GetSkill(ctx, r.SkillID); err == nil && ref != nil && isVisualSkill(ref.BasicCode) {
			return true
		}
	}
	return false
}

// itemSkillRefusal is the gate an item-started skill job meets before the
// item is spent (see the header): the same skill running (FUN_00411560(0,
// id), the composite's pre-check), the visuals' rule, then the book's recast
// rule. "" when it may start.
func itemSkillRefusal(ctx context.Context, refs SkillRefStore, characterID int64, ref *refdata.Skill) string {
	for _, r := range buffBooks.Active(characterID) {
		if r.SkillID == ref.ID {
			return compositeOverlapRefusal
		}
	}
	if isVisualSkill(ref.BasicCode) && visualRunning(ctx, refs, characterID, ref.ID) {
		return compositeOverlapRefusal
	}
	if r := buffBooks.CheckOverlap(characterID, buffSpec(ref, characterID)); r != buff.NotRefused {
		return refusalText(r)
	}
	return ""
}

// useSkillItem is UseByKind cases 1-3 (see the header): the COOLTIME gate,
// the bound skill, the gate above, the spend, the job, the COOLTIME arm.
func useSkillItem(ctx context.Context, sess *gateway.Session, fail func(string) error, inv inventory.Store,
	items combat.ItemLookup, hub *world.Hub, characterID int64, it *refdata.Item, held inventory.Slot, have int) error {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	now := useItemClock()
	if it.CooltimeMs > 0 && !itemCooldowns.ReadyItem(characterID, it.ID, it.CooltimeGroup, now) {
		return fail(reuseDelayRefusal)
	}
	bySkill, ok := items.(skillByCode)
	if !ok {
		return fail("that cannot be used")
	}
	ref, err := bySkill.GetSkillByCode(ctx, boundSkillCode(it))
	if err != nil || ref == nil {
		return fail("that cannot be used")
	}
	// FUN_0059b8d0's job branch: 'cbuf' and 'dura'. The other branch (the
	// context and Skill_CheckUseConditions) is not modelled.
	if !ref.Cbuf || ref.DuraMs == 0 {
		return fail("that cannot be used")
	}
	refs, _ := items.(SkillRefStore)
	l := buffLock(characterID)
	l.Lock()
	if refusal := itemSkillRefusal(ctx, refs, characterID, ref); refusal != "" {
		l.Unlock()
		return fail(refusal)
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		l.Unlock()
		return fail("using failed")
	}
	lasts := usu1Duration(ref.DuraMs)
	started := startSkillJobLocked(ctx, hub, ref, lasts, characterID, it.ID, now)
	l.Unlock()
	slog.Info("skill item: bound skill buff", "item", it.ID, "code", it.CodeName, "character_id", characterID,
		"skill", ref.ID, "seconds", int64(lasts/time.Second), "started", started)
	if it.CooltimeMs > 0 {
		itemCooldowns.ArmItem(characterID, it.ID, it.CooltimeGroup, time.Duration(it.CooltimeMs)*time.Millisecond, now)
	}
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1)}).Encode()})
}

// startSkillJobLocked starts an item's skill job: the buff on characterID,
// cast by itself, lasting lasts, told to its view (OpBuffStart), with its
// stats pushed, and the job recorded so the buff outlives the character
// object. The caller holds buffLock(characterID).
func startSkillJobLocked(ctx context.Context, hub *world.Hub, ref *refdata.Skill, lasts time.Duration, characterID, itemID int64, now time.Time) bool {
	spec := buffSpec(ref, characterID)
	spec.DuraMs = int(lasts.Milliseconds())
	rec, ended, refused, sp := buffBooks.Start(characterID, spec, now)
	if refused != buff.NotRefused {
		return false
	}
	zone := zoneOf(hub, characterID)
	broadcastBuffEnd(zone, characterID, ended, sp)
	sendAboutOwner(zone, characterID, OpBuffStart, buffStartPacket(rec, now, speedField(sp)))
	if len(rec.Stats) > 0 {
		pushOwnerStats(characterID)
	}
	if err := jobStore().Put(ctx, skilljob.Job{CharacterID: characterID, SkillID: ref.ID, ItemID: itemID, Until: now.Add(lasts)}); err != nil {
		slog.Warn("skill job: not recorded", "character_id", characterID, "skill", ref.ID, "err", err)
	}
	return true
}

// restoreSkillJobs puts a character's running item skill jobs back on its
// book at its world entry, each with what is left of it (CTJ_SkillKeeper
// slot 12's restart, READ: the job rebuilds its buff from its end stamp).
// Silent: the arrival's own buffs and its spawn carry them (sendOwnBuffs,
// buffStateFrames). Jobs that ended are dropped.
func restoreSkillJobs(ctx context.Context, characterID int64, now time.Time) int {
	h := skillJobRefs.Load()
	if h == nil {
		return 0
	}
	st := jobStore()
	_ = st.DeleteEnded(ctx, characterID, now)
	jobs, err := st.List(ctx, characterID)
	if err != nil || len(jobs) == 0 {
		return 0
	}
	l := buffLock(characterID)
	l.Lock()
	defer l.Unlock()
	n := 0
	for _, j := range jobs {
		if !now.Before(j.Until) || hasBuffOf(characterID, j.SkillID) {
			continue
		}
		ref, err := h.r.GetSkill(ctx, j.SkillID)
		if err != nil || ref == nil {
			continue
		}
		full := usu1Duration(ref.DuraMs)
		left := j.Until.Sub(now)
		if full <= 0 || left > full {
			full = left
		}
		spec := buffSpec(ref, characterID)
		spec.DuraMs = int(full.Milliseconds())
		// Started where the job's end puts it, so its remaining time is the
		// job's.
		if _, _, refused, _ := buffBooks.Start(characterID, spec, j.Until.Add(-full)); refused != buff.NotRefused {
			slog.Info("skill job: not restored", "character_id", characterID, "skill", j.SkillID, "refused", refused)
			continue
		}
		n++
	}
	if n > 0 {
		slog.Info("skill job: restored at entry", "character_id", characterID, "buffs", n)
	}
	return n
}

// hasBuffOf reports whether characterID carries a record of skillID.
func hasBuffOf(characterID, skillID int64) bool {
	for _, r := range buffBooks.Active(characterID) {
		if r.SkillID == skillID {
			return true
		}
	}
	return false
}

// isSkillJobBuff reports whether r is a running item skill job's buff: a
// self-cast record of a skill the character holds a job for.
func isSkillJobBuff(ctx context.Context, r buff.Record, now time.Time) bool {
	if !r.SelfCast() {
		return false
	}
	jobs, err := jobStore().List(ctx, r.OwnerID)
	if err != nil {
		return false
	}
	for _, j := range jobs {
		if j.SkillID == r.SkillID && now.Before(j.Until) {
			return true
		}
	}
	return false
}

// forgetSkillJob drops the job of a buff its owner ended (a cancel).
func forgetSkillJob(characterID, skillID int64) {
	_ = jobStore().Delete(context.Background(), characterID, skillID)
}
