package session

import (
	"encoding/binary"
	"fmt"
	"sync/atomic"

	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/party"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// The unique monster notices (round 657): "Tiger Girl has appeared on Tiger
// Mountain." when a unique hatches, "[Name] killed Tiger girl from Tiger
// Mountain." when one dies -- a line in the system window and the blue banner
// at the top of the screen. docs/protocol/unique_notice.md has the whole read.
//
// READ, server (SR_GameServer.exe):
//   - Spawn: 0x5f6eb0 relays 0x300C with the word 0x0C05 and the monster's
//     RefObjID when the new object's class (vslot 300, `cmp al,3`) is 3.
//   - Kill: CGObjMob vslot 398 (0x4c1c80) sends 0x300C / 0x0C06 {RefObjID,
//     killer name} when the dead monster's class is 3 and there IS a killer
//     (`test ebp,ebp; je` at 0x4c1cd7: no killer, no notice). The killer
//     comes from vslot 399 (0x4c44a0) over the damage list, see UniqueKiller.
//     A killer that is not a live player (its vslot 0x1c answers 0) is named
//     "???" (0x4c1dd1: the string at 0xaedda4).
//   - Both are skipped for a world whose +0x108 flag is set (0x5f9910 asks
//     the world; 0x608350 returns +0x108), and the flag is set when the world
//     config's CONTROL_NOTIFY_SPAWN_UNIQUE_MONSTER_MSG equals "ON"
//     (0x60936f..0x6093b1). Absent, both are announced.
//   - Class 3 only: the rank-8 bosses are not announced.
//
// READ, client (sro_client.exe): the handler 0x874ea0 reads the word, then
// a u32 RefObjID for 0x0C05 (`push 4` at 0x8752ad) and a u32 plus a u16-length
// string for 0x0C06 (0x875521, 0x875541). client/scripts/net/unique_notice.gd
// picks the line; the wire here is that payload behind srrevamp's own opcode
// (docs/protocol/PROTOCOL_DECISION.md; decision D11 of the monster epic).
const (
	// OpUniqueNotice is server -> every character in the world. OURS: the
	// opcode is srrevamp's; the payload is retail 0x300C's.
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

// UniqueNoticeFor reports whether a monster of this rarity is announced.
func UniqueNoticeFor(rarity int) bool {
	return rarity == RarityUnique && !uniqueNoticeOff.Load()
}

// UniqueKiller is the character the kill notice names: the top-damage member
// of the top-damage group, read off CGObjMob vslot 399 (0x4c44a0):
//
//   - it walks the monster's damage list (+0x1ca4), skipping any attacker
//     that is not a player (vslot 0x1c) -- srrevamp's list holds only
//     characters -- and maps a pet to its owner (+0x736 * 4; srrevamp has no
//     pet that deals damage);
//   - the group is the player's party when the party shares experience
//     (+0x72e * 4 non-null and its flag bit 0), else the player alone. Every
//     srrevamp party shares experience, and a party of one is no party (the
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

// partyGroupOf is UniqueKiller's grouping over the party hub: the party's id
// for a character in a party of two or more, else 0.
func partyGroupOf(parties *party.Hub) func(int64) int64 {
	return func(characterID int64) int64 {
		if parties == nil {
			return 0
		}
		pt, in := parties.Get(characterID)
		if !in || pt == nil || len(pt.Members) < 2 {
			return 0
		}
		return pt.ID
	}
}

// broadcastUniqueNotice sends n to every character in the world (READ: the
// notice is relayed to every world, 0x414970 -> 0x5f8620), returning how many
// it reached.
func broadcastUniqueNotice(hub *world.Hub, n *UniqueNotice) int {
	if hub == nil {
		return 0
	}
	p := &proto.Packet{Opcode: OpUniqueNotice, Data: n.Encode()}
	sent := 0
	for _, e := range hub.AllEntities() {
		if e.Session == nil {
			continue
		}
		if e.Session.Send(p) == nil {
			sent++
		}
	}
	return sent
}

// AnnounceUniqueSpawn tells the world a unique has appeared: nothing for any
// other rank, or with the notices off. Returns the characters reached.
func AnnounceUniqueSpawn(hub *world.Hub, m combat.Monster) int {
	if !UniqueNoticeFor(m.Rarity) {
		return 0
	}
	return broadcastUniqueNotice(hub, &UniqueNotice{Kind: UniqueNoticeSpawn, RefObjID: uint32(m.RefObjID)})
}

// AnnounceUniqueKill tells the world who killed a unique, from the damage
// list its killing blow returned (combat.Hub.ApplyDamageFrom). Nothing for
// any other rank, with the notices off, or with no one on the list (READ:
// no killer, no notice). A killer no longer in the world is "???".
func AnnounceUniqueKill(hub *world.Hub, parties *party.Hub, m combat.Monster, hits []combat.Hit) int {
	if !UniqueNoticeFor(m.Rarity) {
		return 0
	}
	killer, ok := UniqueKiller(hits, partyGroupOf(parties))
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
