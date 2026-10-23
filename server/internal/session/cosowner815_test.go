package session

import (
	"bytes"
	"context"
	"encoding/binary"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
)

// Round 815: a suit put on or taken off spawns the owner's COS again in
// place, so its owner line follows ("*alias" in the suit, the name out of
// it). The user: a pet kept "*Vz_Pain" after the suit came off.
func TestRound815SuitChangeRespawnsTheCOS(t *testing.T) {
	rig := newCOSRig(t, 7)
	// An ability pet: its spawn names its owner (a ride's does not).
	if res, _ := rig.use(fxRabbit); res.Error != "" {
		t.Fatalf("the rabbit: %+v", res)
	}
	owned := cosWorld.owned(rig.charID)
	if len(owned) != 1 {
		t.Fatalf("owned COS: %d", len(owned))
	}
	uid := owned[0].uid
	jobRecs.Store(rig.charID, jobs.Record{CharID: rig.charID, Kind: jobs.KindTrader, Alias: "Vz_Pain"})
	t.Cleanup(func() { jobRecs.Delete(rig.charID); jobStates.Delete(rig.charID) })

	spawnOf := func(got map[uint16][][]byte) []byte {
		for _, d := range got[npcspawn.OpSingleSpawn] {
			if bytes.Contains(d, binary.LittleEndian.AppendUint32(nil, uid)) {
				return d
			}
		}
		return nil
	}
	ctx := context.Background()
	setJobState(ctx, rig.charID, jobs.StateTrader)
	got := rig.drain()
	if len(got[cos.OpCOSOwnerState]) == 0 {
		t.Fatal("no 0x30CA for the suit")
	}
	if d := spawnOf(got); d == nil || !bytes.Contains(d, []byte("Vz_Pain")) {
		t.Fatalf("the COS's spawn in the suit: %x, want the alias", d)
	}
	setJobState(ctx, rig.charID, pcspawn.JobStateNone)
	d := spawnOf(rig.drain())
	if d == nil || !bytes.Contains(d, []byte("Aria")) || bytes.Contains(d, []byte("Vz_Pain")) {
		t.Fatalf("the COS's spawn out of the suit: %x, want the name, not the alias", d)
	}
}
