package navmesh

import (
	"encoding/binary"
	"testing"
)

// Round 869: a compound's navigation mesh is the .bsr its header word 0x0C
// names (READ MapLoader::FUN_0042bc00), as the client's NavObjectSource.
func TestCollisionPathCompound(t *testing.T) {
	name := "res\\dun\\x\\ship.bsr"
	cpd := append([]byte("JMXVCPD 0101"), make([]byte, 61)...)
	binary.LittleEndian.PutUint32(cpd[0x0C:], uint32(len(cpd)))
	l := make([]byte, 4)
	binary.LittleEndian.PutUint32(l, uint32(len(name)))
	cpd = append(append(cpd, l...), name...)
	mesh := "res\\dun\\x\\ship_nav.bms"
	bsr := make([]byte, 0x30)
	binary.LittleEndian.PutUint32(bsr[0x28:], 0x30)
	binary.LittleEndian.PutUint32(l, uint32(len(mesh)))
	bsr = append(append(bsr, l...), mesh...)
	read := func(p string) []byte {
		switch p {
		case "a.cpd":
			return cpd
		case name:
			return bsr
		}
		return nil
	}
	if got := CollisionPath("a.cpd", read); got != mesh {
		t.Fatalf("compound collision path %q, want %q", got, mesh)
	}
	if NavmeshBSROfCPD([]byte("JMXVCPD 0101\x00\x00\x00\x00")) != "" {
		t.Fatal("a zero word names nothing")
	}
}
