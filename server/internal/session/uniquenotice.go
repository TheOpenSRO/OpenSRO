package session

import (
	"encoding/binary"
	"fmt"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The unique monster notices (round 657): "Tiger Girl has appeared on Tiger
// Mountain." when a unique hatches, "[Name] killed Tiger girl from Tiger
// Mountain." when one dies -- a line in the system window and the blue banner
// at the top of the screen. docs/protocol/unique_notice.md has the whole read.
//
// READ, server (SR_GameServer.exe):
//   - Spawn: 0x5f6eb0 relays 0x300C with the word 0x0C05 and the monster's
//     RefObjID when its 13th argument, the announce flag, is 1
//     (`cmp [esp+0x74],1` at 0x5f71bd) and the new object's class is 3 (the
//     call through vtable +0x12c -- slot 75, the rank getter
//     combat/rarity.go names -- then `cmp al,3` at 0x5f71d4).
//   - The announce flag: Nest_Hatch (0x5607b0) passes `world flag clear`
//     (0x5f9910's answer at 0x560c32, `neg; sbb; add 1`, pushed first at
//     0x560c44), so a nest's hatch is announced unless the key below is ON.
//     The other callers pass a constant 1 -- among them the GM command
//     handler GObjPC_MsgHandler_SpecialCommand (`push 1` at 0x520bd5) and
//     the minion executor 0x596e50 (0x5977a4) -- so a GM-spawned unique is
//     announced whatever the key says. AnnounceUniqueSpawn's fromNest.
//   - Kill: CGObjMob vslot 398 (0x4c1c80) sends 0x300C / 0x0C06 {RefObjID,
//     killer name} when the dead monster's class is 3 (vtable +0x12c again,
//     `cmp al,3` at 0x4c1ccb) and there IS a killer (`test ebp,ebp; je` at
//     0x4c1cd7: no killer, no notice), and not for a world whose flag is set
//     (0x5f9910 at 0x4c1d06). The killer comes from vslot 399 (0x4c44a0), see
//     UniqueKiller. 0x4c1dd1's "???" (0xaedda4) is for a killer whose vtable
//     +0x1c answers 0, which vslot 399 has already filtered out, so from this
//     caller it is not reached.
//   - The world flag is +0x108 (0x608350 returns it), set when the world
//     config's CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG equals "ON"
//     (0x60936f..0x6093b1). Absent, nest hatches and kills are announced.
//   - Class 3 only: the rank-8 bosses are not announced.
//
// READ, client (sro_client.exe): the handler 0x874ea0 reads the word, then
// a u32 RefObjID for 0x0C05 (`push 4` at 0x8752ad) and a u32 plus a u16-length
// string for 0x0C06 (0x875521, 0x875541). client/scripts/net/unique_notice.gd
// picks the line; the wire here is that payload behind OpenSRO's own opcode
// (docs/protocol/PROTOCOL_DECISION.md; decision D11 of the monster epic).
const (
	// OpUniqueNotice is server -> every character in the world. OURS: the
	// opcode is OpenSRO's; the payload is retail 0x300C's.
	OpUniqueNotice uint16 = 0x0110

	// UniqueNoticeSpawn / UniqueNoticeKill are 0x300C's words (READ).
	UniqueNoticeSpawn uint16 = 0x0C05
	UniqueNoticeKill  uint16 = 0x0C06

	// RarityUnique is the class the notices are sent for (READ: `cmp al,3`
	// at 0x4c1ccb and in 0x5f6eb0) -- characterdata column 15's 3.
	RarityUnique = 3

	// UnknownKiller is what a killer that is not a live player is called
	// (READ: 0xaedda4 in SR_GameServer.exe). The client answers it with the
	// UIIT_MSG_DEAD_* ("... has disappeared") lines.
	UnknownKiller = "???"
)

// UniqueNotice is OpUniqueNotice's payload: retail 0x300C's word, the
// monster's RefObjID and, for a kill, the killer's name.
type UniqueNotice struct {
	Kind     uint16
	RefObjID uint32
	Killer   string
}

// Encode lays the notice out as 0x300C does: u16 kind, u32 RefObjID, and for
// a kill a u16 byte length and the name.
func (n *UniqueNotice) Encode() []byte {
	out := make([]byte, 6, 8+len(n.Killer))
	binary.LittleEndian.PutUint16(out, n.Kind)
	binary.LittleEndian.PutUint32(out[2:], n.RefObjID)
	if n.Kind == UniqueNoticeKill {
		out = append(out, encodeStrings(n.Killer)...)
	}
	return out
}

// DecodeUniqueNotice parses what Encode produces.
func DecodeUniqueNotice(data []byte) (*UniqueNotice, error) {
	if len(data) < 6 {
		return nil, fmt.Errorf("session: decoding UniqueNotice: %d bytes, want 6 or more", len(data))
	}
	n := &UniqueNotice{Kind: binary.LittleEndian.Uint16(data), RefObjID: binary.LittleEndian.Uint32(data[2:])}
	rest := data[6:]
	switch n.Kind {
	case UniqueNoticeSpawn:
		if len(rest) != 0 {
			return nil, fmt.Errorf("session: decoding UniqueNotice: %d trailing byte(s) after a spawn", len(rest))
		}
	case UniqueNoticeKill:
		f, err := decodeStrings(rest, 1)
		if err != nil {
			return nil, fmt.Errorf("session: decoding UniqueNotice: %w", err)
		}
		n.Killer = f[0]
	default:
		return nil, fmt.Errorf("session: decoding UniqueNotice: unknown kind %#04x", n.Kind)
	}
	return n, nil
}

// uniqueNoticeOff is the server's CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG
// ("ON" silences both notices), cmd/server's -unique-notice-off. Off by
// default: retail announces when the key is absent.
var uniqueNoticeOff atomic.Bool

// SetUniqueNoticeOff silences (true) or restores (false) the unique notices.
func SetUniqueNoticeOff(off bool) { uniqueNoticeOff.Store(off) }

// UniqueNoticeFor reports whether a monster of this rarity is announced on a
// nest hatch or a death: rank 3, with the key not ON.
func UniqueNoticeFor(rarity int) bool {
	return rarity == RarityUnique && !uniqueNoticeOff.Load()
}

// UniqueKiller is the character the kill notice names: the top-damage member
// of the top-damage group, read off CGObjMob vslot 399 (0x4c44a0):
//
//   - it walks the monster's damage list (+0x1ca4), resolving each entry's
//     id to its object (0x485d90 -> 0x41ccf0, a map lookup that answers 0
//     for an object no longer in the world) and skipping a null one, maps a
//     pet to its owner (+0x736 * 4; OpenSRO has no pet that deals damage),
//     and skips any attacker that is not a player (vtable +0x1c). The caller
//     does the first step: presentHits keeps the characters still in the
//     world;
//   - the group is the player's party when the party shares experience
//     (+0x72e * 4 non-null and its flag bit 0), else the player alone. Every
//     OpenSRO party shares experience, and a party of one is no party (the
//     engine never makes one, see inPartyWithOthers), so the group is a
//     party of two or more;
//   - a group's damage is its members' sum; within it the member with the
//     most damage is kept (`[9] < damage` then `[8] = player`);
//   - the group with the most damage wins (`uVar4 < piVar5[6]`), and its
//     kept member is the killer.
//
// Ties: both comparisons are strict, so the first one met stays; the order
// the engine meets them in is its map's, which was not read. OURS: the first
// in first-hit order. ok is false for an empty list: no killer, no notice.
func UniqueKiller(hits []combat.Hit, groupOf func(characterID int64) int64) (killerID int64, ok bool) {
	type group struct {
		total      int
		best       int64
		bestDamage int
	}
	var order []int64
	groups := map[int64]*group{}
	for _, h := range hits {
		if h.AttackerID == 0 || h.Damage <= 0 {
			continue
		}
		key := -h.AttackerID // alone: a key no party id takes
		if groupOf != nil {
			if pid := groupOf(h.AttackerID); pid != 0 {
				key = pid
			}
		}
		g, seen := groups[key]
		if !seen {
			g = &group{}
			groups[key] = g
			order = append(order, key)
		}
		g.total += h.Damage
		if h.Damage > g.bestDamage {
			g.best, g.bestDamage = h.AttackerID, h.Damage
		}
	}
	var top *group
	for _, k := range order {
		if g := groups[k]; top == nil || g.total > top.total {
			top = g
		}
	}
	if top == nil {
		return 0, false
	}
	return top.best, true
}

// presentHits is hits without the attackers no longer in the world (0x4c44a0
// resolves each entry through 0x485d90 and skips the ones that are gone).
func presentHits(hub *world.Hub, hits []combat.Hit) []combat.Hit {
	if hub == nil {
		return nil
	}
	out := make([]combat.Hit, 0, len(hits))
	for _, h := range hits {
		if _, in := hub.EntityByCharacterID(h.AttackerID); in {
			out = append(out, h)
		}
	}
	return out
}

// partyGroupOf is UniqueKiller's grouping over the party hub: the party's id
// for a character in an Exp Auto Share party (flag bit 0), else 0 -- the
// grouping CGObjMob vslot 399 uses (round 712: the party's own flag since
// round 710; planKill groups the same way).
func partyGroupOf(parties *party.Hub) func(int64) int64 {
	return func(characterID int64) int64 {
		if parties == nil {
			return 0
		}
		pt, in := parties.Get(characterID)
		if !in || pt == nil || !pt.Flags.ExpShare() {
			return 0
		}
		return int64(pt.ID)
	}
}

// broadcastUniqueNotice queues n for every character in the world (READ: the
// notice is relayed to every world, 0x414970 -> 0x5f8620), returning how many
// it was queued for. Send only queues (round 662: every session has its own
// outbound queue and writer), so a client that is slow to read holds up only
// its own queue, never the caller -- the killing blow's, the GM's, a spawn
// loop's. Round 657's per-session notice queue did this for the notices
// alone and is folded into the general one.
func broadcastUniqueNotice(hub *world.Hub, n *UniqueNotice) int {
	if hub == nil {
		return 0
	}
	p := &proto.Packet{Opcode: OpUniqueNotice, Data: n.Encode()}
	queued := 0
	// Round 869 lane W2: every world of this process (an instance's players
	// too: the notice is relayed to every world, READ above), then every
	// other process in one message.
	for _, e := range allEntitiesAnywhere(hub) {
		if e.Session == nil {
			continue
		}
		_ = e.Session.Send(p)
		queued++
	}
	if clusterOn() {
		sendEverywhere(0, p)
	}
	return queued
}

// AnnounceUniqueSpawn tells the world a unique has appeared: nothing for any
// other rank. fromNest is a nest's hatch (cmd/server's roster), announced only
// with the key not ON; any other spawn -- the GM console's -- is announced
// whatever the key says, as retail's GM spawn passes the flag as a constant 1
// (see the top of this file). Returns the characters it was queued for.
func AnnounceUniqueSpawn(hub *world.Hub, m combat.Monster, fromNest bool) int {
	if m.Rarity != RarityUnique || (fromNest && uniqueNoticeOff.Load()) {
		return 0
	}
	return broadcastUniqueNotice(hub, &UniqueNotice{Kind: UniqueNoticeSpawn, RefObjID: uint32(m.RefObjID)})
}

// AnnounceUniqueKill tells the world who killed a unique, from the damage
// list its killing blow returned (combat.Hub.ApplyDamageFrom). Nothing for
// any other rank, with the notices off, or with no one left on the list once
// the attackers who have left the world are dropped (READ: 0x4c44a0 skips
// them; no killer, no notice).
func AnnounceUniqueKill(hub *world.Hub, parties *party.Hub, m combat.Monster, hits []combat.Hit) int {
	if !UniqueNoticeFor(m.Rarity) {
		return 0
	}
	killer, ok := UniqueKiller(presentHits(hub, hits), partyGroupOf(parties))
	if !ok {
		return 0
	}
	name := UnknownKiller
	if hub != nil {
		if e, in := hub.EntityByCharacterID(killer); in && e.Name != "" {
			name = e.Name
		}
	}
	return broadcastUniqueNotice(hub, &UniqueNotice{Kind: UniqueNoticeKill, RefObjID: uint32(m.RefObjID), Killer: name})
}
