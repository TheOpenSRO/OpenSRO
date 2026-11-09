package session

// Round 865 stage 2: what the academy's members learn of each other while
// they play (docs/protocol/academy.md sections 5, 6 and 9): the world
// entry's 0x3C81, the online flips, the moves, a level-up, a rename, the
// daily honor rank and the guardian's honor buffs.

import (
	"context"
	"encoding/binary"
	"fmt"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// academyPlaceOf is e's location group: the open world's id (MEASURED 0x00010001;
// OURS for a dungeon, whose world id OpenSRO does not model), the region and
// the region-local x, y, z truncated as the party record's (partyPosition,
// READ s:0x5dcde0: ftol of pc+0x88..0x90).
func academyPlaceOf(e world.Entity) (academy.Live, bool) {
	region, x, y, z, ok := partyPosition(e)
	if !ok {
		return academy.Live{}, false
	}
	return academy.Live{World: academy.WorldOpen, Region: region, X: int16(x), Y: int16(y), Z: int16(z)}, true
}

// displayName is field 17 while the character is in the world (READ
// s:0x5dd0d8: job state 4, no suit, its name; else its nickname, the job
// alias; MEASURED a job alias there).
func displayName(ctx context.Context, e world.Entity) string {
	if jobStateNow(ctx, e.CharacterID) != pcspawn.JobStateNone {
		if a := jobRecord(ctx, e.CharacterID).Alias; a != "" {
			return a
		}
	}
	return e.Name
}

// attach is TrainingCamp's member attach (s:0x5dcde0): the character's place
// copied into its member, its character held; the play state stays what it
// was (1 for one not yet flipped online, MEASURED at a login, a join and a
// founding; 0 at a teleport).
func (rt *academyRuntime) attach(e world.Entity, campID int64) {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	l := rt.live[e.CharacterID]
	if l == nil || l.campID != campID {
		l = &acLive{campID: campID, live: academy.Unplaced}
		rt.live[e.CharacterID] = l
	}
	if p, ok := academyPlaceOf(e); ok {
		state := l.live.PlayState
		l.live = p
		l.live.PlayState = state
	}
	l.inWorld = true
}

// liveOf is m's run-time part as an entry carries it.
func (rt *academyRuntime) liveOf(m academy.Member) academy.Live {
	rt.mu.Lock()
	l := rt.live[m.CharID]
	var out academy.Live
	in := false
	if l == nil || l.campID != m.CampID {
		out = academy.Unplaced
	} else {
		out, in = l.live, l.inWorld
	}
	rt.mu.Unlock()
	out.Display = ""
	if in {
		if e, ok := reachOf(rt.Hub, m.CharID); ok {
			out.Display = displayName(context.Background(), e)
		}
	}
	return out
}

// setOnline flips charID's play state and sends 0x3C80 {05, id, 01, state}:
// online to every member (the subject included, last), offline to the
// others.
func (rt *academyRuntime) setOnline(campID, charID int64, online bool) {
	state := academy.PlayOffline
	if online {
		state = academy.PlayOnline
	}
	rt.mu.Lock()
	if l := rt.live[charID]; l != nil && l.campID == campID {
		l.live.PlayState = state
	}
	rt.mu.Unlock()
	msg := academy.EncodeFieldU8(charID, academy.FieldPlayState, state)
	rt.push(campID, msg, charID)
	if online {
		if e, ok := reachOf(rt.Hub, charID); ok {
			acSend(e.Session, proto.OpAcademyUpdate, msg)
		}
	}
}

// sendPosition sends charID's 0x3C80 0d to the camp's other members.
func (rt *academyRuntime) sendPosition(campID, charID int64) {
	m := academy.Member{CampID: campID, CharID: charID}
	rt.push(campID, academy.EncodePosition(charID, rt.liveOf(m)), charID)
}

// forget drops charID's run-time state (it left the camp).
func (rt *academyRuntime) forget(charID int64) {
	rt.mu.Lock()
	delete(rt.live, charID)
	rt.mu.Unlock()
}

// forgetCamp drops every member of c (a disband).
func (rt *academyRuntime) forgetCamp(c *academy.Camp) {
	rt.mu.Lock()
	for id, l := range rt.live {
		if l.campID == c.ID {
			delete(rt.live, id)
		}
	}
	rt.mu.Unlock()
}

// listed is campID's matching entry, if any.
func (rt *academyRuntime) listed(campID int64) (academy.MatchEntry, bool) {
	for _, e := range rt.board.Entries() {
		if e.CampID == uint32(campID) {
			return e, true
		}
	}
	return academy.MatchEntry{}, false
}

// academyArrived is the world entry (CGObjPC::vslot_391, READ
// s:0x4dfc35..0x4dfefe; MEASURED at a login and at every teleport): the
// member attached, 0x3C81 to it, the guardian's honor buffs, its donated buff
// slots (0xB483 {01, ...}), then 0x3C80 0d to the others and 05 field 1 = 0
// to everyone, the member last.
func academyArrived(ctx context.Context, e world.Entity) {
	rt := academyRT.Load()
	if rt == nil || e.Session == nil {
		return
	}
	c := rt.campOf(ctx, e.CharacterID)
	if c == nil {
		return
	}
	rt.attach(e, c.ID)
	acSend(e.Session, proto.OpAcademyInfo, academy.EncodeCampInfo(c, rt.liveOf))
	if m, ok := c.Member(e.CharacterID); ok && m.Class == academy.MemberClassGuardian {
		rt.engageHonorBuffs(ctx, e.CharacterID, c.Rank)
	}
	rt.sendDonatedBuffs(ctx, e)
	rt.sendPosition(c.ID, e.CharacterID)
	rt.setOnline(c.ID, e.CharacterID, true)
}

// sendDonatedBuffs is vslot_391's 0xB483 {01, u8 n, n x {u32 minutes left,
// u32 donor, u32 points}} for the member's BuffType-4 rows with a donor (READ
// s:0x4dfd15..0x4dfe2c: minutes left 1440 - elapsed, clamped at 0). OpenSRO
// never writes such a row (the transfer is OPEN), so this sends nothing yet.
func (rt *academyRuntime) sendDonatedBuffs(ctx context.Context, e world.Entity) {
	rows, err := rt.Store.BuffRows(ctx, e.CharacterID)
	if err != nil {
		return
	}
	out := []byte{academy.ResultOK, 0}
	n := 0
	for _, b := range rows {
		if b.Type != 4 || b.DonorID == 0 {
			continue
		}
		left := 1440 - int64(rt.now().Sub(b.Start)/time.Minute)
		if left < 0 {
			left = 0
		}
		out = binary.LittleEndian.AppendUint32(out, uint32(left))
		out = binary.LittleEndian.AppendUint32(out, uint32(b.DonorID))
		out = binary.LittleEndian.AppendUint32(out, uint32(b.Points))
		n++
	}
	if n == 0 {
		return
	}
	out[1] = byte(n)
	acSend(e.Session, proto.OpAcademyBuffTransferAck, out)
}

// academyLeftWorld is the logout: 0x3C80 {05, id, 01, 01} to the others
// (MEASURED); the place stays as last known and the name goes (the entry an
// offline member carries, MEASURED). A guardian's matching entry is dropped
// (READ m:0x459b04).
func academyLeftWorld(characterID int64) {
	rt := academyRT.Load()
	if rt == nil {
		return
	}
	rt.mu.Lock()
	l := rt.live[characterID]
	if l == nil || !l.inWorld {
		rt.mu.Unlock()
		return
	}
	l.inWorld = false
	campID := l.campID
	rt.mu.Unlock()
	rt.setOnline(campID, characterID, false)
	if c, err := rt.Store.Get(context.Background(), campID); err == nil {
		if g, ok := c.Guardian(); ok && g.CharID == characterID {
			rt.board.DropCamp(uint32(campID))
		}
	}
	rt.dropJoins(characterID)
}

// academyUpdateInterval is how often the members' places are sampled for
// 0x3C80 0d. OURS: the original sends at each change event (the party
// position's trigger, CGObjPC::vslot_323 bit 1), as OpenSRO's party sampler
// does each second (party.go partyUpdateInterval).
const academyUpdateInterval = time.Second

// RunAcademyUpdates sends each moved member's 0x3C80 0d to its camp's other
// members every academyUpdateInterval, until ctx ends.
func RunAcademyUpdates(ctx context.Context) {
	t := time.NewTicker(academyUpdateInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			if rt := academyRT.Load(); rt != nil {
				rt.samplePlaces()
			}
		}
	}
}

func (rt *academyRuntime) samplePlaces() {
	type moved struct{ campID, charID int64 }
	var out []moved
	rt.mu.Lock()
	for id, l := range rt.live {
		if !l.inWorld {
			continue
		}
		e, ok := entityOf(rt.Hub, id)
		if !ok {
			continue
		}
		p, ok := academyPlaceOf(e)
		if !ok {
			continue
		}
		cur := l.live
		if cur.World != p.World || cur.Region != p.Region || cur.X != p.X || cur.Y != p.Y || cur.Z != p.Z {
			p.PlayState = cur.PlayState
			l.live = p
			out = append(out, moved{l.campID, id})
		}
	}
	rt.mu.Unlock()
	for _, m := range out {
		rt.sendPosition(m.campID, m.charID)
	}
}

// academyLevelChanged is GObjPC_SetLevel's refresh (READ s:0x4e4e13 /
// s:0x4e4e42): the member row's levels follow, and 0x3C80 05 field 6 (the
// current level) goes to every member, then field 2 (the max level) when it
// rose. Only an in-game change reaches here (choice 4: a level changed while
// offline stays as stored).
func academyLevelChanged(characterID int64, level int) {
	rt := academyRT.Load()
	if rt == nil {
		return
	}
	rt.mu.Lock()
	l := rt.live[characterID]
	rt.mu.Unlock()
	if l == nil {
		return
	}
	ctx := context.Background()
	c := rt.campOf(ctx, characterID)
	if c == nil {
		return
	}
	m, ok := c.Member(characterID)
	if !ok {
		return
	}
	maxLevel := max(m.MaxLevel, level)
	if err := rt.Store.SetLevels(ctx, characterID, level, maxLevel); err != nil {
		rt.log().Warn("academy: the member's levels were not saved", "character_id", characterID, "err", err)
		return
	}
	rt.push(c.ID, academy.EncodeFieldU8(characterID, academy.FieldCurLevel, byte(level)), 0)
	if maxLevel > m.MaxLevel {
		rt.push(c.ID, academy.EncodeFieldU8(characterID, academy.FieldMaxLevel, byte(maxLevel)), 0)
	}
}

// academyRenamed follows a rename (the shard's sub 9, READ: 0x3C80 {05, id,
// 05, str} to the members) and the member row's CharName.
func academyRenamed(ctx context.Context, characterID int64, name string) {
	rt := academyRT.Load()
	if rt == nil {
		return
	}
	c := rt.campOf(ctx, characterID)
	if c == nil {
		return
	}
	if err := rt.Store.SetName(ctx, characterID, name); err != nil {
		rt.log().Warn("academy: the member's name was not saved", "character_id", characterID, "err", err)
		return
	}
	rt.push(c.ID, academy.EncodeFieldStr(characterID, academy.FieldName, name), 0)
}

// academyBodyChanged follows a body change (UpdateCharRefObjIDAndScale,
// READ s:0x4efff8: 0x3C80 {05, id, 07, u32 RefObjID}).
func academyBodyChanged(ctx context.Context, characterID, refObjID int64) {
	rt := academyRT.Load()
	if rt == nil {
		return
	}
	c := rt.campOf(ctx, characterID)
	if c == nil {
		return
	}
	if err := rt.Store.SetRefObj(ctx, characterID, refObjID); err != nil {
		return
	}
	rt.push(c.ID, academy.EncodeFieldU32(characterID, academy.FieldRefObj, uint32(refObjID)), 0)
}

// academyCharactersPurged removes characters whose deletion ended (the
// database's _DeleteCharPermanently -> _TRAINING_CAMP_DELMEMBER, MEASURED as
// the stored rule; the shard's reason 3, no message to the removed one). A
// guardian is kept (the store never removes one; what the original does with
// a deleted guardian's camp is OPEN).
func academyCharactersPurged(ctx context.Context, ids []int64) {
	rt := academyRT.Load()
	if rt == nil {
		return
	}
	for _, id := range ids {
		c := rt.campOf(ctx, id)
		if c == nil {
			continue
		}
		online := rt.onlineOf(c.ID)
		if _, _, err := rt.Store.RemoveMember(ctx, id, academy.RemoveSilent); err != nil {
			continue
		}
		rt.removed(c.ID, online, id, academy.RemoveSilent)
	}
}

// academyLobbyByte is the character list's academy byte (MEASURED: 2 the
// guardian, 1 an assistant or an apprentice, 0 none).
func academyLobbyByte(ctx context.Context, characterID int64) uint8 {
	rt := academyRT.Load()
	if rt == nil {
		return 0
	}
	c, err := rt.Store.CampOf(ctx, characterID)
	if err != nil || c == nil {
		return 0
	}
	if m, ok := c.Member(characterID); ok && m.Class == academy.MemberClassGuardian {
		return 2
	}
	return 1
}

// academyChatAudience is who hears characterID's academy line: the camp's
// members in the world, the sender included, in camp order; nil when it is in
// no academy.
func academyChatAudience(ctx context.Context, characterID int64) []int64 {
	rt := academyRT.Load()
	if rt == nil {
		return nil
	}
	c := rt.campOf(ctx, characterID)
	if c == nil {
		return nil
	}
	in := map[int64]bool{characterID: true}
	for _, id := range rt.onlineOf(c.ID) {
		in[id] = true
	}
	out := []int64{}
	for _, m := range c.Members {
		if in[m.CharID] {
			out = append(out, m.CharID)
		}
	}
	return out
}

// --- the honor rank -----------------------------------------------------------

// RunAcademyRanks is the honor rank update (MEASURED: the schedule row is
// daily at 00:00:00 server time, and the shard catches up at start when the
// last update was not today): each run's changed camps get 0x3C80 0c and
// their guardian's honor buffs again (READ s:0x5e1410 / s:0x5dd830).
func RunAcademyRanks(ctx context.Context) {
	for {
		rt := academyRT.Load()
		if rt == nil {
			return
		}
		now := rt.now()
		if last, err := rt.Store.LastRankUpdate(ctx); err == nil && academy.RankUpdateDue(last, now) {
			rt.updateRanks(ctx, now)
		}
		wait := academy.NextRankUpdate(now).Sub(now)
		select {
		case <-ctx.Done():
			return
		case <-time.After(wait):
		case <-academyClockMoved:
			// Round 873 (OURS, the QA aid's): a /academytime past the
			// day's 00:00 runs the update, as the day turning would.
		}
	}
}

// updateRanks runs one update and tells the changed camps.
func (rt *academyRuntime) updateRanks(ctx context.Context, now time.Time) {
	changes, err := rt.Store.UpdateRanks(ctx, now)
	if err != nil {
		rt.log().Warn("academy: the honor rank update failed", "err", err)
		return
	}
	for _, ch := range changes {
		rt.push(ch.CampID, academy.EncodeRank(ch.Rank), 0)
		if c, err := rt.Store.Get(ctx, ch.CampID); err == nil {
			if g, ok := c.Guardian(); ok {
				// Round 873: wherever it plays (an instance is a hub of
				// its own, hubOfChar).
				if _, online := entityOf(hubOfChar(rt.Hub, g.CharID), g.CharID); online {
					rt.engageHonorBuffs(ctx, g.CharID, ch.Rank)
				}
			}
		}
	}
	rt.log().Info("academy: honor ranks updated", "changed", len(changes))
}

// honorBuffCodes is the guardian's honor buffs by rank, cumulative (READ
// s:0x5dd9b0 from the table s:0xc6748c): rank 4 the copper, 3 adds the
// silver, 2 the gold, 1 the crown; rank 5 none.
var honorBuffCodes = []string{"SKILL_TC_CROWN_BUFF_01", "SKILL_TC_GOLD_BUFF_01", "SKILL_TC_SILVER_BUFF_01", "SKILL_TC_COPPER_BUFF_01"}

// HonorBuffsFor is rank's buff codes.
func HonorBuffsFor(rank int) []string {
	if rank < 1 || rank > 4 {
		return nil
	}
	return honorBuffCodes[rank-1:]
}

// engageHonorBuffs is s:0x5dd8b0: the guardian's honor buffs cancelled
// (s:0x5dd8f0: GObjPC::FUN_0059f0c0 for each of the table's skills), then
// engaged by rank (s:0x5dd9b0: FUN_0059b8d0 for each). What each does is its
// skill row's own params (OPEN here: OpenSRO's skill data). Round 873: the
// cancel and the engage under one buffLock, both told to honorAudience.
func (rt *academyRuntime) engageHonorBuffs(ctx context.Context, characterID int64, rank int) {
	if rt.Skills == nil {
		return
	}
	l := buffLock(characterID)
	l.Lock()
	defer l.Unlock()
	rt.cancelHonorBuffsLocked(ctx, characterID)
	now := time.Now()
	for _, code := range HonorBuffsFor(rank) {
		ref, err := rt.Skills.GetSkillByCode(ctx, code)
		if err != nil || ref == nil {
			continue
		}
		rec, ended, refused, sp := buffBooks.Start(characterID, buffSpec(ref, characterID), now)
		if refused != buff.NotRefused {
			rt.log().Info("academy: an honor buff was refused", "character_id", characterID, "skill", code, "refused", refused)
			continue
		}
		to := honorAudience(rt.Hub, characterID)
		broadcastBuffEnd(to, characterID, ended, sp)
		sendAboutOwner(to, characterID, OpBuffStart, buffStartPacket(rec, now, speedField(sp)))
		if len(rec.Stats) > 0 {
			pushOwnerStats(characterID)
		}
	}
}

// honorAudience is who hears a guardian's honor buffs start and end: the
// players in view of it (zoneOf) and always its own client. Round 873: a
// character its arrival holds out of the world (world.Entity.Held, from a
// teleport to its client's 0x3012) is in no message block, so zoneOf left
// its own client out. A revive at the return point (the move, then the
// revive while held) engaged the buffs there unheard -- the zone change had
// already listed the old tokens (sendOwnBuffs) -- and the arrival's engage
// then ended tokens the client never had and added new ones: every honor
// icon twice on the board (MEASURED in a player's log: tokens 12-15 kept,
// 16-19 ended unseen, 20-23 added). A rank change or the disband during a
// load went unheard the same way.
func honorAudience(hub *world.Hub, characterID int64) []world.Entity {
	to := zoneOf(hub, characterID)
	for _, e := range to {
		if e.CharacterID == characterID {
			return to
		}
	}
	if h := hubOfChar(hub, characterID); h != nil {
		if e, ok := h.EntityByCharacterID(characterID); ok && e.Session != nil {
			to = append(to, e)
		}
	}
	return to
}

// academyTimeCommand is a GM's /academytime <duration> (round 865, OURS, a
// QA aid for the 24 h and 7-day windows and the penalties): the academy's
// clock moved forward. ok is false for any other line. It is not in the
// gm package's dispatcher, so the client's console does not forward it:
// cmd/partybot -mode academy sends it.
func academyTimeCommand(line string) (gm.Result, bool) {
	f := strings.Fields(strings.TrimPrefix(strings.TrimSpace(line), "/"))
	if len(f) == 0 || !strings.EqualFold(f[0], "academytime") {
		return gm.Result{}, false
	}
	usage := gm.Result{Refused: true, Text: "usage: /academytime <duration, e.g. 25h>"}
	if len(f) != 2 {
		return usage, true
	}
	step, err := time.ParseDuration(f[1])
	if err != nil || step <= 0 {
		return usage, true
	}
	now := AdvanceAcademyClock(step)
	return gm.Result{Text: fmt.Sprintf("academy clock moved %s, now %s", step, now.Format("2006-01-02 15:04:05"))}, true
}

// academyRevived re-engages a guardian's honor buffs at its revival (READ
// s:0x46cd5e, in the resurrection's answer trs_wait_response::vslot_002
// s:0x46cb30, and the resurrection scroll's s:0x49ff20: each calls
// s:0x5dd8b0 after GObjPC::Revive(1)). Round 873: not while its arrival
// holds it -- the return point, which OpenSRO revives after the move. READ:
// the 0x3053 handler (s:0x50fee0) takes option 1 with GObjPC::Revive(0) and
// calls no s:0x5dd8b0; the re-entry's CGObjPC::vslot_391 (s:0x4df9e0)
// engages them, academyArrived at the client's 0x3012. One engage, as the
// original, where OpenSRO made two (the first one unheard, honorAudience).
func academyRevived(ctx context.Context, characterID int64) {
	rt := academyRT.Load()
	if rt == nil {
		return
	}
	if h := hubOfChar(rt.Hub, characterID); h != nil {
		if e, ok := h.EntityByCharacterID(characterID); ok && e.Held {
			return
		}
	}
	c := rt.campOf(ctx, characterID)
	if c == nil {
		return
	}
	if g, ok := c.Guardian(); ok && g.CharID == characterID {
		rt.engageHonorBuffs(ctx, characterID, c.Rank)
	}
}

// cancelHonorBuffs ends the guardian's honor buffs (the disband, s:0x5dd8f0).
func (rt *academyRuntime) cancelHonorBuffs(characterID int64) {
	if rt.Skills == nil {
		return
	}
	l := buffLock(characterID)
	l.Lock()
	defer l.Unlock()
	rt.cancelHonorBuffsLocked(context.Background(), characterID)
}

// cancelHonorBuffsLocked is cancelHonorBuffs with buffLock(characterID)
// held (the engage's first half too), told to honorAudience.
func (rt *academyRuntime) cancelHonorBuffsLocked(ctx context.Context, characterID int64) {
	ids := map[int64]bool{}
	for _, code := range honorBuffCodes {
		if ref, err := rt.Skills.GetSkillByCode(ctx, code); err == nil && ref != nil {
			ids[ref.ID] = true
		}
	}
	if len(ids) == 0 {
		return
	}
	ended, sp := buffBooks.EndWhere(characterID, func(r buff.Record) bool { return ids[r.SkillID] })
	if len(ended) > 0 {
		broadcastBuffEnd(honorAudience(rt.Hub, characterID), characterID, ended, sp)
	}
}
