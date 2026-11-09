package session

// The Forgotten World timer reset (round 872, OURS: the user's "add an item
// to the test item npc to reset dimensional gate time and stuff"). Labels:
// READ (s: the game server, c: the client), MEASURED, INFERRED, OURS, OPEN.
//
// What it clears, for one character, at once:
//
//  1. the Dimension holes' shared cool time: the kept timed job of category
//     6 (TimedJobItemCoolTime) whose key is the holes' group 0x71, and the
//     process-wide tracker's timer of that group (itemCooldowns) -- the
//     tracker outlives a logout, so the rows alone are not enough;
//  2. the Forgotten World's re-entry limit: the timed job of category 12
//     (TimedJobWorldGroup) of every world group an INS_GOD_* world is bound
//     to (GROUP_INS_GOD, group 1) -- the 0x320C icon's job;
//  3. the stored instance rows (char_instance_world, _CharInstanceWorldData)
//     of every INS_GOD_* world.
//
// Nothing else: another item's or skill's cool time, another world group's
// limit, another world's row and every other timed job stay
// (fgwreset_test.go).
//
// Two ways in, the same reset behind the same confirm box (the client's
// UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN, "If you use the Dungeon
// entrance ticket, dungeon cooltime will disappear. Do you want to use the
// entrance ticket?"):
//
//   - the Test Items NPC's action line "Reset Forgotten World Timers"
//     (testnpc.OpNpcActionDef / OpNpcAction): free, at the NPC; with nothing
//     running it answers that line and clears nothing worth saying;
//   - the Forgotten World entrance ticket, TypeID 3/3/13/23
//     (ITEM_MALL_DUNGEON_FREE_TICKET_FORGOTTEN_WORLD 36781 and
//     ITEM_PRE_MALL_... 38295 in the data: MEASURED stack 50, CanUse 255,
//     Param1 1 / Desc1 GROUP_INS_GOD, no COOLTIME, Service 0), where an
//     operator's item table has its row (this project's client archive has
//     none, MEASURED: its text strings only). The original's binaries never
//     reference it (READ, forgotten_world.md 9: the server's item-use switch
//     has no case for TypeID4 23), so its use is OURS: a used ticket is
//     spent and does the reset; with nothing to reset it is kept and the
//     use is refused with UIIT_MSG_DUNGEON_FREE_TICKET_ENTERD_NOT_USED
//     ("Entrance ticket was not used because ...", INFERRED from the Korean
//     "the dungeon's entry limit is lifted, so the ticket is not used").
//
// The client hears OpTimersReset, OURS: the original has no message that
// clears a running item cool time or a 0x320C icon. READ: 0x320C kind 0x0C
// with remaining <= 0 does nothing (c:0x88dad0); the 0x3077 restore
// (c:0x88e090) sets a cool time through std::map inserts (c:0x9b95d0 for a
// group, c:0x9b99d0 for an id), which keep an entry already there, so it
// cannot shorten or clear one; an entry goes only when the per-frame tick
// (c:0x9b9f60) finds its time spent.

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"sort"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/testnpc"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// OpTimersReset is OpenSRO's own message (OURS, server -> client, round
// 872): the answer to a Forgotten World timer reset and what the client
// drops. 0x00BF was free in server/ and client/scripts (grep, 2026-11-09).
// Layout:
//
//	u8 status        1 done, 2 nothing to reset, 3 refused
//	u16 n, n bytes   the system line (UTF-8; a text key or text)
//	u8 n, n x u32    the item cool time groups cleared (the client's "g<n>")
//	u8 n, n x u32    the world groups whose re-entry icon goes (0x320C's)
const OpTimersReset uint16 = 0x00bf

// OpTimersReset's statuses.
const (
	TimersResetDone    byte = 1
	TimersResetNothing byte = 2
	TimersResetRefused byte = 3
)

// The system lines (OURS text; the ticket's refusal is the client's key).
const (
	fgwResetDoneText    = "Your Forgotten World timers have been reset: a Dimension Hole can be used and a new layer opened at once."
	fgwResetNothingText = "You have no Forgotten World timers to reset."
	fgwResetFarText     = "You are too far away from the NPC."
	fgwResetOfferText   = "This NPC does not offer that."
	ticketNotUsedKey    = "UIIT_MSG_DUNGEON_FREE_TICKET_ENTERD_NOT_USED"
)

// TimersReset is OpTimersReset's payload.
type TimersReset struct {
	Status      byte
	Text        string
	CoolGroups  []uint32
	WorldGroups []uint32
}

func (r *TimersReset) Encode() []byte {
	out := []byte{r.Status}
	t := r.Text
	if len(t) > 0xffff {
		t = t[:0xffff]
	}
	out = binary.LittleEndian.AppendUint16(out, uint16(len(t)))
	out = append(out, t...)
	for _, list := range [][]uint32{r.CoolGroups, r.WorldGroups} {
		if len(list) > 255 {
			list = list[:255]
		}
		out = append(out, byte(len(list)))
		for _, g := range list {
			out = binary.LittleEndian.AppendUint32(out, g)
		}
	}
	return out
}

// DecodeTimersReset reads OpTimersReset (tests).
func DecodeTimersReset(b []byte) (*TimersReset, error) {
	bad := errors.New("session: malformed OpTimersReset")
	if len(b) < 3 {
		return nil, bad
	}
	r := &TimersReset{Status: b[0]}
	n := int(binary.LittleEndian.Uint16(b[1:]))
	b = b[3:]
	if len(b) < n {
		return nil, bad
	}
	r.Text, b = string(b[:n]), b[n:]
	for _, list := range []*[]uint32{&r.CoolGroups, &r.WorldGroups} {
		if len(b) < 1 || len(b) < 1+4*int(b[0]) {
			return nil, bad
		}
		c := int(b[0])
		for i := 0; i < c; i++ {
			*list = append(*list, binary.LittleEndian.Uint32(b[1+4*i:]))
		}
		b = b[1+4*c:]
	}
	if len(b) != 0 {
		return nil, bad
	}
	return r, nil
}

// fgwScope is the Forgotten World as the reset reads it: every INS_GOD_*
// world and the world groups they are bound to (none without the instance
// tables loaded).
func fgwScope() (groups map[int64]bool, worlds map[uint16]bool) {
	groups, worlds = map[int64]bool{}, map[uint16]bool{}
	m := GameWorlds()
	if m == nil || m.Ref() == nil {
		return groups, worlds
	}
	for id, w := range m.Ref().Worlds {
		if !w.IsGodWorld() {
			continue
		}
		worlds[id] = true
		if w.Group != nil {
			groups[int64(w.Group.ID)] = true
		}
	}
	return groups, worlds
}

// keyHasGroup reports whether a COOLTIME key holds the one-byte group
// (ReadyItem's reading of a key: each non-zero byte a group).
func keyHasGroup(key, group uint32) bool {
	for shift := 0; shift < 32; shift += 8 {
		if b := (key >> shift) & 0xff; b != 0 && b == group {
			return true
		}
	}
	return false
}

// fgwReset is what a reset found (and, applied, took away).
type fgwReset struct {
	// CoolRows / LimitRows / InstanceRows count the timed jobs of category 6
	// and 12 and the instance rows in scope, running or not.
	CoolRows, LimitRows, InstanceRows int
	// CoolRunning: the holes' cool time was running (a row or the
	// tracker); LimitRunning: a re-entry limit was.
	CoolRunning, LimitRunning bool
	// WorldGroups are the scope's world groups, ascending.
	WorldGroups []uint32
}

// pending reports whether there was anything a player would call a timer:
// a running cool time or limit, or a stored instance row.
func (r fgwReset) pending() bool { return r.CoolRunning || r.LimitRunning || r.InstanceRows > 0 }

// resetForgottenWorld finds characterID's Forgotten World timers at now and,
// with apply, clears them (the package note's three things; expired rows in
// scope go too). An error leaves what was cleared before it cleared.
func resetForgottenWorld(ctx context.Context, characterID int64, now time.Time, apply bool) (fgwReset, error) {
	d := gameWorldDeps()
	groups, worlds := fgwScope()
	var r fgwReset
	for g := range groups {
		r.WorldGroups = append(r.WorldGroups, uint32(g))
	}
	sort.Slice(r.WorldGroups, func(i, j int) bool { return r.WorldGroups[i] < r.WorldGroups[j] })
	if st := d.Timed; st != nil {
		jobs, err := st.List(ctx, characterID)
		if err != nil {
			return r, err
		}
		for _, j := range jobs {
			hole := j.Type == TimedJobItemCoolTime && keyHasGroup(uint32(j.Key), gameworld.HoleCoolGroup)
			limit := j.Type == TimedJobWorldGroup && groups[j.Ref]
			if !hole && !limit {
				continue
			}
			if hole {
				r.CoolRows++
				r.CoolRunning = r.CoolRunning || now.Before(j.End)
			} else {
				r.LimitRows++
				r.LimitRunning = r.LimitRunning || now.Before(j.End)
			}
			if apply {
				if err := st.Delete(ctx, characterID, j.Type, j.Sub, j.Ref); err != nil {
					return r, err
				}
			}
		}
	}
	if apply {
		r.CoolRunning = itemCooldowns.ClearGroup(characterID, gameworld.HoleCoolGroup, now) || r.CoolRunning
	} else if !itemCooldowns.Ready(characterID, gameworld.HoleCoolGroup, now) {
		r.CoolRunning = true
	}
	if d.Instances != nil {
		rows, err := d.Instances.List(ctx, characterID)
		if err != nil {
			return r, err
		}
		for _, row := range rows {
			if !worlds[row.World] {
				continue
			}
			r.InstanceRows++
			if apply {
				if err := d.Instances.Delete(ctx, characterID, row.World); err != nil {
					return r, err
				}
			}
		}
	}
	return r, nil
}

// sendTimersReset answers a reset to the client.
func sendTimersReset(sess *gateway.Session, status byte, text string, r fgwReset) error {
	msg := &TimersReset{Status: status, Text: text}
	if status == TimersResetDone {
		msg.CoolGroups = []uint32{gameworld.HoleCoolGroup}
		msg.WorldGroups = r.WorldGroups
	}
	return sess.Send(&proto.Packet{Opcode: OpTimersReset, Data: msg.Encode()})
}

// runFGWReset is the reset for characterID, answered on sess; via names the
// way in for the log.
func runFGWReset(ctx context.Context, sess *gateway.Session, characterID int64, via string) error {
	r, err := resetForgottenWorld(ctx, characterID, fgwClock(), true)
	if err != nil {
		slog.Warn("forgotten world timer reset failed", "character_id", characterID, "via", via, "err", err)
		return sendTimersReset(sess, TimersResetRefused, "The Forgotten World timers could not be reset.", r)
	}
	slog.Info("forgotten world timers reset (round 872, OURS)", "character_id", characterID, "via", via,
		"cool_rows", r.CoolRows, "cool_running", r.CoolRunning, "limit_rows", r.LimitRows, "limit_running", r.LimitRunning,
		"instance_rows", r.InstanceRows)
	if !r.pending() {
		return sendTimersReset(sess, TimersResetNothing, fgwResetNothingText, r)
	}
	return sendTimersReset(sess, TimersResetDone, fgwResetDoneText, r)
}

// handleNPCAction is OpNpcAction (round 872, OURS): an action line of an NPC
// of OpenSRO's own, in reach.
func handleNPCAction(ctx context.Context, sess *gateway.Session, data []byte, hub *world.Hub) {
	uid, id, err := testnpc.DecodeAction(data)
	if err != nil {
		return
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	do := npcActionOf(uid, id)
	if do == "" {
		_ = sendTimersReset(sess, TimersResetRefused, fgwResetOfferText, fgwReset{})
		return
	}
	if _, code := npcTarget(e, uid); code != 0 {
		_ = sendTimersReset(sess, TimersResetRefused, fgwResetFarText, fgwReset{})
		return
	}
	switch do {
	case testnpc.ActionResetForgottenWorld:
		_ = runFGWReset(ctx, sess, e.CharacterID, fmt.Sprintf("npc %#x", uid))
	}
}

// isForgottenWorldTicket reports the Forgotten World entrance ticket,
// TypeID 3/3/13/23 (MEASURED: its two rows are the only items of that type).
func isForgottenWorldTicket(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == 3 && it.TypeID2 == 3 && it.TypeID3 == 13 && it.TypeID4 == 23
}

// useForgottenWorldTicket is the ticket's use (the package note): with
// nothing to reset the ticket is kept and the use refused; else it is spent
// and the reset done.
func useForgottenWorldTicket(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64,
	it *refdata.Item, held inventory.Slot, have int) error {
	now := fgwClock()
	found, err := resetForgottenWorld(ctx, characterID, now, false)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: "lookup failed"}).Encode()})
	}
	if !found.pending() {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: ticketNotUsedKey}).Encode()})
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: "cannot use items"}).Encode()})
	}
	if err := sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Remaining: int32(have - 1), ItemID: uint32(it.ID)}).Encode()}); err != nil {
		return err
	}
	return runFGWReset(ctx, sess, characterID, "ticket "+it.CodeName)
}
