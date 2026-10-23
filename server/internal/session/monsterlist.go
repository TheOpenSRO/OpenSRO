package session

import (
	"encoding/binary"
	"sort"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The monster list, paged (round 656). One OpMonsterListResult frame carries
// at most proto.MaxPayload (32,767) bytes and a record is 60-odd (the id, the
// two names, the position and four words: ~68 for the roster), so a list of
// more than about 480 monsters could not be written at all -- proto.Write
// refused it, handleMonsterList returned the error and the gateway closed the
// session (docs/TODO.md). The area of interest bounds the list to a window of
// 25 regions, but a window of the full map's densest regions still holds more
// than that, so the list goes as pages: each page is an ordinary
// OpMonsterListResult with its share of the records and a four-byte trailer,
// u16 page and u16 pages (MonsterListResult). A list that fits one frame is
// sent exactly as before, with no trailer. The client gathers the pages and
// reconciles its bodies once, on the last (NetClient, round 656).
//
// The motion list that follows with the monster AI on is split the same way,
// at most monsterMotionPageMax entries a frame; its pages need no trailer,
// since each entry stands on its own (World3D._on_monster_motion_list applies
// each to its body).

// MonsterListFlagPaged is bit 0 of the OpMonsterList request's one optional
// byte (round 656's review): the client gathers a paged list. Only a request
// that carries it is answered in pages; an older client sends an empty request
// and gets the old form -- one frame, no trailer -- and, when its window holds
// more than a frame's worth, only the monsters nearest to it that fit
// (monsterListNearestThatFit). OURS, an additive capability byte.
const MonsterListFlagPaged byte = 0x01

// MonsterListFlagParty is bit 1 of the same byte (round 660): the client
// reads the party flag in the rarity word (MonsterRarityPartyBit). Only a
// session whose request carries it is sent the flag, in the list, the spawn
// push and the area of interest's enter; an older client is sent the rank
// alone.
const MonsterListFlagParty byte = 0x02

// MonsterListFlagBody is bit 2 (round 805): the client reads the body byte
// in the rarity word (MonsterRarityBodyBit); only such a session is sent it.
const MonsterListFlagBody byte = 0x04

// monsterListPartyAsked reads MonsterListFlagParty off a request.
func monsterListPartyAsked(data []byte) bool {
	return len(data) >= 1 && data[0]&MonsterListFlagParty != 0
}

// noteMonsterListCaps records what a list request's capability byte says
// the session reads beyond the list itself: the party flag.
func noteMonsterListCaps(sess *gateway.Session, data []byte) {
	if monsterListPartyAsked(data) {
		sess.Set(monsterPartyKey, true)
	}
	if len(data) >= 1 && data[0]&MonsterListFlagBody != 0 {
		sess.Set(monsterBodyKey, true)
	}
}

// monsterListPagedAsked reads the request's capability byte.
func monsterListPagedAsked(data []byte) bool {
	return len(data) >= 1 && data[0]&MonsterListFlagPaged != 0
}

// monsterListNearestThatFit keeps, of listed, the monsters nearest to (x, z)
// whose records fit one frame with the list's 4-byte header, for a client that
// cannot take pages. listed comes back in id order when it all fits, else
// nearest first.
func monsterListNearestThatFit(listed []combat.Monster, x, z float64) []combat.Monster {
	size := 4
	for _, m := range listed {
		s := monsterSnapshotOf(m)
		size += len(s.Encode())
	}
	if size <= proto.MaxPayload {
		return listed
	}
	sort.SliceStable(listed, func(i, j int) bool {
		di := (listed[i].X-x)*(listed[i].X-x) + (listed[i].Z-z)*(listed[i].Z-z)
		dj := (listed[j].X-x)*(listed[j].X-x) + (listed[j].Z-z)*(listed[j].Z-z)
		return di < dj
	})
	size = 4
	for i, m := range listed {
		s := monsterSnapshotOf(m)
		size += len(s.Encode())
		if size > proto.MaxPayload {
			return listed[:i]
		}
	}
	return listed
}

// monsterListTrailer is the paging trailer's length.
const monsterListTrailer = 4

// monsterMotionPageMax is how many 21-byte entries one OpMonsterMotionList
// frame carries: (MaxPayload - 2) / 21 = 1,560.
const monsterMotionPageMax = (proto.MaxPayload - 2) / MonsterMotionSize

// monsterListPages encodes snaps as the OpMonsterListResult payloads to send:
// one payload with no trailer when it fits a frame, else as many pages as the
// records need, in order, each at most proto.MaxPayload bytes. An empty list
// is one empty payload.
func monsterListPages(snaps []MonsterSnapshot) [][]byte {
	recs := make([][]byte, len(snaps))
	total := 4 // the empty error string's length and the count
	for i := range snaps {
		recs[i] = snaps[i].Encode()
		total += len(recs[i])
	}
	if total <= proto.MaxPayload {
		return [][]byte{(&MonsterListResult{Monsters: snaps}).Encode()}
	}
	// Split greedily, then write each page with its trailer.
	budget := proto.MaxPayload - 4 - monsterListTrailer
	var bounds [][2]int
	start, size := 0, 0
	for i, r := range recs {
		if size+len(r) > budget && i > start {
			bounds = append(bounds, [2]int{start, i})
			start, size = i, 0
		}
		size += len(r)
	}
	bounds = append(bounds, [2]int{start, len(recs)})
	pages := make([][]byte, len(bounds))
	for p, b := range bounds {
		out := make([]byte, 4, proto.MaxPayload)
		// out[0:2] is the empty error string's length, 0.
		binary.LittleEndian.PutUint16(out[2:4], uint16(b[1]-b[0]))
		for _, r := range recs[b[0]:b[1]] {
			out = append(out, r...)
		}
		out = binary.LittleEndian.AppendUint16(out, uint16(p))
		out = binary.LittleEndian.AppendUint16(out, uint16(len(bounds)))
		pages[p] = out
	}
	return pages
}

// handleMonsterList responds with every live monster in the requesting
// session's area of interest (aoi.go: the monsters within AOIRadius region
// cells of the cell it stands in, in its zone), as one frame or as pages
// (monsterListPages). Without this, a client has no way to discover a
// monster's ID to attack it at all. Under the area-of-interest runtime the
// request also centres the player's view where it stands (setView): the list
// is the window's whole truth.
//
// With the monster AI on (-monster-ai, round 537) the listed monsters' legs
// follow as OpMonsterMotionList frames (n may be 0; one frame per
// monsterMotionPageMax legs), and everything is built and queued under the
// session's monster wire lock -- the lock the AI tick takes to push to this
// session -- so a push for a newer leg can never arrive ahead of a list built
// before it (monsterWireLock). With it off no motion list is sent.
//
// paged is the request's capability byte (MonsterListFlagPaged): without it
// the reply is the old single frame (monsterListNearestThatFit).
func handleMonsterList(sess *gateway.Session, hub *world.Hub, monsters *combat.Hub, paged bool) error {
	entity, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpMonsterListResult, Data: (&MonsterListResult{Error: "not in the world"}).Encode()})
	}
	rt := monsterAIRuntime.Load()
	wire := monsterWireLock(sess)
	wire.Lock()
	defer wire.Unlock()

	cell := combat.CellOf(entity.Zone, entity.Pos.X, entity.Pos.Z)
	if v := aoiFor(monsters); v != nil {
		v.setView(sess, cell)
	}
	listed := monsterWindow(monsters, cell)
	if !paged {
		listed = monsterListNearestThatFit(listed, entity.Pos.X, entity.Pos.Z)
	}
	snapshots := make([]MonsterSnapshot, len(listed))
	for i, m := range listed {
		snapshots[i] = monsterSnapshotFor(sess, m)
	}
	// The pages, the motion pages and the statuses go as one batch (round
	// 662): queued together, no other frame for this session -- a chat
	// line, a stat update, anything not under the wire lock -- comes between
	// them.
	var frames []*proto.Packet
	for _, page := range monsterListPages(snapshots) {
		frames = append(frames, &proto.Packet{Opcode: OpMonsterListResult, Data: page})
	}
	if rt != nil {
		motion := motionListOf(listed)
		for first := true; first || len(motion.Entries) > 0; first = false {
			n := min(len(motion.Entries), monsterMotionPageMax)
			page := &MonsterMotionList{Entries: motion.Entries[:n]}
			frames = append(frames, &proto.Packet{Opcode: OpMonsterMotionList, Data: page.Encode()})
			motion.Entries = motion.Entries[n:]
		}
	}
	// After the list and its legs, in the same batch: the masks already on
	// (round 659, status.go; one batch since round 662's review).
	frames = append(frames, statusPacketsOfList(hub, listed, entity.Zone)...)
	return sess.SendBatch(frames...)
}
