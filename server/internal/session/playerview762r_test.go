package session

import (
	"bufio"
	"context"
	"sort"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// Round 762's review ("The server change", coverage): spawnPlayersTo and
// despawnPlayersFrom driven over a real session, and the frames they send
// decoded -- a group per block, the viewer's own block last, each group's
// records (or ids) by unique id. TestOwnBlockGoesLast and
// TestGroupRecordsByUniqueID hold the two helpers only.
func TestSpawnAndDespawnGroupsGoInBlockAndUniqueIDOrder(t *testing.T) {
	ctx := context.Background()
	SetSpawnItemRefs(nil)
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	chars := character.NewMemStore()
	hub := world.NewHub()

	// A server whose only handler hands the test the session that spoke.
	got := make(chan *gateway.Session, 1)
	addr, cleanup := startTestServer(t, func(_ context.Context, sess *gateway.Session, _ *proto.Packet) error {
		select {
		case got <- sess:
		default:
		}
		return nil
	})
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	if err := proto.Write(conn, &proto.Packet{Opcode: 0x7762}, nil, nil); err != nil {
		t.Fatal(err)
	}
	var sess *gateway.Session
	select {
	case sess = <-got:
	case <-time.After(2 * time.Second):
		t.Fatal("the server never saw the viewer's session")
	}

	viewer, _ := chars.Create(ctx, 1, "Viewer")
	home := world.Position{X: 10, Z: 10}
	hub.Enter(sess, viewer.ID, "Viewer", 1, "jangan", home)
	ownCell := world.CellOf("jangan", home)

	// Six others: three in the viewer's own block, three in the block east of
	// it (one block line at x = 320 * k - 960), made in an order that is not
	// their unique ids'.
	spots := []world.Position{{X: 20, Z: 10}, {X: 400, Z: 20}, {X: 30, Z: 30}, {X: 420, Z: 10}, {X: 15, Z: 40}, {X: 410, Z: 40}}
	var ids []int64
	for i := range spots {
		c, err := chars.Create(ctx, int64(10+i), string(rune('A'+i))+"_762r")
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, c.ID)
	}
	// Entered in reverse, so the hub's and the call's order is not the uid's.
	var others []world.Entity
	for i := len(ids) - 1; i >= 0; i-- {
		hub.Enter(gateway.NewTestSession(uint64(762000+i)), ids[i], "o", 1, "jangan", spots[i])
	}
	for i := len(ids) - 1; i >= 0; i-- {
		e, ok := hub.EntityByCharacterID(ids[i])
		if !ok {
			t.Fatalf("other %d not in the hub", ids[i])
		}
		others = append(others, e)
	}
	byCell := map[combat.Cell][]uint32{}
	for i, id := range ids {
		c := world.CellOf("jangan", spots[i])
		byCell[c] = append(byCell[c], uint32(id))
	}
	if len(byCell) != 2 || len(byCell[ownCell]) != 3 {
		t.Fatalf("setup: the others are in %d blocks, %d in the viewer's own", len(byCell), len(byCell[ownCell]))
	}
	var east combat.Cell
	for c := range byCell {
		if c != ownCell {
			east = c
		}
		sort.Slice(byCell[c], func(i, j int) bool { return byCell[c][i] < byCell[c][j] })
	}

	d := viewDeps{hub: hub, eq: eq, chars: chars}
	ve, _ := hub.EntityByCharacterID(viewer.ID)
	playerViews.Store(viewer.ID, openedView(sess, d))
	t.Cleanup(func() { playerViews.Delete(viewer.ID) })

	spawnPlayersTo(d, ve, others)
	next := func() *proto.Packet { return readFrame737(t, conn, r) }
	for gi, want := range [][]uint32{byCell[east], byCell[ownCell]} {
		recs := playerSpawnsIn(t, next(), next)
		var uids []uint32
		for _, rec := range recs {
			uids = append(uids, rec.UID)
		}
		if !equalUIDs(uids, want) {
			t.Fatalf("spawn group %d names %v, want %v (the neighbour block first, the own block last, by uid)", gi, uids, want)
		}
	}

	// They all leave the view: the despawns in the same order.
	for i := range ids {
		hub.Leave(gateway.NewTestSession(uint64(762000 + i)))
	}
	despawnPlayersFrom(d, ve, others)
	for gi, want := range [][]uint32{byCell[east], byCell[ownCell]} {
		uids := playerDespawnsIn(t, next(), next)
		if !equalUIDs(uids, want) {
			t.Fatalf("despawn group %d names %v, want %v", gi, uids, want)
		}
	}
}

func equalUIDs(a, b []uint32) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
