package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"math"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/species"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 795: the COS end to end -- a character in the world calls a growth
// pet out with its item, names it, recalls it with the item again; calls a
// tiger with a ride scroll and is mounted, steers it, gets off and loses it;
// and is refused a second ability pet. The rows are the real ones' shape
// (ids and TypeIDs from the retail tables, MEASURED round 795).
const (
	fxFlute       = 7488  // ITEM_COS_P_FLUTE, 3/2/1/1 -> COS_P_WOLF_001
	fxRabbit      = 10365 // ITEM_COS_P_RABBIT_SCROLL, 3/2/1/2 -> COS_P_RABBIT, Param1 4320
	fxMyowon      = 7489  // ITEM_COS_P_MYOWON_SCROLL, 3/2/1/2 -> COS_P_MYOWON
	fxTigerScroll = 23277 // ITEM_COS_C_TIGER_SCROLL, 3/3/3/2 -> COS_C_TIGER_<bracket>
	fxCOSPotion   = 2143  // ITEM_ETC_COS_HP_POTION_01, 3/3/1/4, Param1 360
)

func cosFixtureTable(t *testing.T) *species.Table {
	t.Helper()
	row := func(fields map[string]string) string {
		out := make([]string, len(species.CSVColumns))
		for i, c := range species.CSVColumns {
			out[i] = "0"
			if v, ok := fields[c]; ok {
				out[i] = v
			}
			if c == "Model" || c == "OrgCodeName" || c == "NameKey" || c == "Name" || c == "DescStrID" {
				if _, ok := fields[c]; !ok {
					out[i] = ""
				}
			}
		}
		return strings.Join(out, ",")
	}
	lines := []string{strings.Join(species.CSVColumns, ","),
		row(map[string]string{"ID": "6106", "CodeName": "COS_P_WOLF_001", "TypeID4": "3", "Level": "1", "MaxHP": "360",
			"WalkSpeed": "50", "RunSpeed": "75", "BCRadius": "3", "Model": "cos\\p_wolf_01.bsr", "DescStrID": "COS_P_WOLF_002"}),
		row(map[string]string{"ID": "6107", "CodeName": "COS_P_WOLF_002", "TypeID4": "3", "Level": "2", "MaxHP": "441",
			"WalkSpeed": "50", "RunSpeed": "75", "BCRadius": "3", "Model": "cos\\p_wolf_01.bsr"}),
		row(map[string]string{"ID": "10369", "CodeName": "COS_P_RABBIT", "TypeID4": "4", "Level": "1", "MaxHP": "109",
			"WalkSpeed": "50", "RunSpeed": "120", "BCRadius": "6", "Model": "cos\\p_rabbit.bsr"}),
		row(map[string]string{"ID": "7493", "CodeName": "COS_P_MYOWON", "TypeID4": "4", "Level": "1", "MaxHP": "109",
			"WalkSpeed": "50", "RunSpeed": "120", "BCRadius": "6", "Model": "cos\\p_myowon.bsr"}),
		row(map[string]string{"ID": "23310", "CodeName": "COS_C_TIGER_5", "TypeID4": "1", "Level": "15", "MaxHP": "726",
			"WalkSpeed": "45", "RunSpeed": "150", "BCRadius": "12", "Model": "cos\\c_tiger.bsr"}),
	}
	tab, err := species.Read(strings.NewReader(strings.Join(lines, "\n") + "\n"))
	if err != nil {
		t.Fatalf("COS table: %v", err)
	}
	return tab
}

type cosRig struct {
	t      *testing.T
	inv    *inventory.MemStore
	store  *cos.MemStore
	conn   net.Conn
	r      *bufio.Reader
	charID int64
}

// resetCOSWorld empties the process-wide COS registry between tests.
func resetCOSWorld() {
	cosWorld.mu.Lock()
	cosWorld.byUID = map[uint32]*cosObj{}
	cosWorld.byOwner = map[int64][]*cosObj{}
	cosWorld.mu.Unlock()
	riders.Range(func(k, _ any) bool { riders.Delete(k); return true })
}

func newCOSRig(t *testing.T, level int) *cosRig {
	t.Helper()
	ctx := context.Background()
	resetCOSWorld()
	t.Cleanup(func() {
		resetCOSWorld()
		cosWorld.deps.Store(nil)
	})
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: fxFlute, CodeName: "ITEM_COS_P_FLUTE", MaxStack: 1, TypeID1: 3, TypeID2: 2, TypeID3: 1, TypeID4: 1,
			Desc1: "COS_P_WOLF_001", CanUse: true, CanTrade: true},
		{ID: fxRabbit, CodeName: "ITEM_COS_P_RABBIT_SCROLL", MaxStack: 1, TypeID1: 3, TypeID2: 2, TypeID3: 1, TypeID4: 2,
			Desc1: "COS_P_RABBIT", Param1: 4320, CanUse: true},
		{ID: fxMyowon, CodeName: "ITEM_COS_P_MYOWON_SCROLL", MaxStack: 1, TypeID1: 3, TypeID2: 2, TypeID3: 1, TypeID4: 2,
			Desc1: "COS_P_MYOWON", Param1: 40320, CanUse: true},
		{ID: fxTigerScroll, CodeName: "ITEM_COS_C_TIGER_SCROLL", MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 3, TypeID4: 2,
			Desc1: "COS_C_TIGER", Desc2: "5,10,20,30,45,60,75,90,105,120", CanUse: true},
		{ID: fxCOSPotion, CodeName: "ITEM_ETC_COS_HP_POTION_01", MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 4,
			RestoreHP: 360, CanUse: true},
	}); err != nil {
		t.Fatal(err)
	}
	chars := character.NewMemStore()
	hub := world.NewHub()
	rig := &cosRig{t: t, inv: inventory.NewMemStore(items), store: cos.NewMemStore()}
	accounts := account.NewMemStore()
	if _, err := accounts.Register(ctx, "alice", "pw"); err != nil {
		t.Fatal(err)
	}
	acct, _ := accounts.Authenticate(ctx, "alice", "pw")
	c, err := chars.Create(ctx, acct.ID, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	if err := chars.SetLeveling(ctx, c.ID, level, 0, 0, c.Str, c.Int); err != nil {
		t.Fatal(err)
	}
	rig.charID = c.ID
	for _, id := range []int64{fxFlute, fxRabbit, fxMyowon} {
		if err := rig.inv.AddItem(ctx, c.ID, id, 1); err != nil {
			t.Fatal(err)
		}
	}
	if err := rig.inv.AddItem(ctx, c.ID, fxTigerScroll, 3); err != nil {
		t.Fatal(err)
	}
	if err := rig.inv.AddItem(ctx, c.ID, fxCOSPotion, 5); err != nil {
		t.Fatal(err)
	}
	bags := inventory.NewMemStore(items)
	bags.SetCapacity(cos.AbilityPetSlots)
	SetCOSDeps(rig.store, bags, cosFixtureTable(t), nil, rig.inv, items, chars, hub, nil, nil)
	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	handle := gateway.Chain(COSHandler(hub, chars), LoginHandler(accounts), WorldHandler(chars, eq, hub),
		UseItemHandler(chars, rig.inv, items, nil, nil, nil, hub, nil, nil, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	rig.conn = dialTestServer(t, addr)
	t.Cleanup(func() { rig.conn.Close() })
	rig.r = bufio.NewReader(rig.conn)
	rig.send(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(rig.until(OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %+v %v", lr, err)
	}
	rig.send(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(rig.until(OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %+v %v", ewr, err)
	}
	rig.drain()
	return rig
}

func (rig *cosRig) send(op uint16, data []byte) {
	rig.t.Helper()
	if err := proto.Write(rig.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		rig.t.Fatalf("write: %v", err)
	}
}

func (rig *cosRig) read(wait time.Duration) *proto.Packet {
	rig.t.Helper()
	rig.conn.SetReadDeadline(time.Now().Add(wait))
	p, err := proto.Read(rig.r, nil, nil)
	if err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			return nil
		}
		rig.t.Fatalf("read: %v", err)
	}
	return p
}

// until reads to the first packet of op.
func (rig *cosRig) until(op uint16) *proto.Packet {
	rig.t.Helper()
	for {
		p := rig.read(2 * time.Second)
		if p == nil {
			rig.t.Fatalf("no 0x%04x", op)
		}
		if p.Opcode == op {
			return p
		}
	}
}

// drain reads what arrives within a short quiet, by opcode.
func (rig *cosRig) drain() map[uint16][][]byte {
	out := map[uint16][][]byte{}
	for {
		p := rig.read(300 * time.Millisecond)
		if p == nil {
			return out
		}
		out[p.Opcode] = append(out[p.Opcode], p.Data)
	}
}

func (rig *cosRig) slot(id int64) inventory.Slot {
	slots, _ := rig.inv.List(context.Background(), rig.charID)
	for _, s := range slots {
		if s.ItemID == id {
			return s
		}
	}
	return inventory.Slot{Index: -1}
}

// use sends the client's use of item id and returns its reply and what
// followed it.
func (rig *cosRig) use(id int64) (*UseItemResult, map[uint16][][]byte) {
	rig.t.Helper()
	rig.send(OpUseItem, clientUse("Aria", rig.slot(id).Index, 0, 0))
	res, err := DecodeUseItemResult(rig.until(OpUseItemResult).Data)
	if err != nil {
		rig.t.Fatal(err)
	}
	return res, rig.drain()
}

func TestRound795GrowthPetSummonNameRecall(t *testing.T) {
	rig := newCOSRig(t, 30)
	res, got := rig.use(fxFlute)
	if res.Error != "" || res.Remaining != 1 {
		t.Fatalf("the flute's use: %+v (a pet item is kept)", res)
	}
	slot := rig.slot(fxFlute)
	if slot.Durability <= 0 {
		t.Fatalf("the flute holds no COS record: Data word %d", slot.Durability)
	}
	if st := got[cos.OpItemState]; len(st) == 0 || st[0][0] != byte(slot.Index+13) || st[0][1] != cos.ItemFieldCOSState ||
		st[0][2] != cos.ItemStateSummoned {
		t.Fatalf("0x3040: %x, want the flute's slot+13, 0x40, state 2", st)
	}
	spawns := got[npcspawn.OpSingleSpawn]
	if len(spawns) == 0 || binary.LittleEndian.Uint32(spawns[0]) != 6106 || spawns[0][len(spawns[0])-1] != cosSpawnTypeSummoned {
		t.Fatalf("0x3015 of the wolf: %x", spawns)
	}
	data := got[cos.OpCOSData]
	if len(data) != 1 {
		t.Fatalf("0x30C8: %d", len(data))
	}
	uid := binary.LittleEndian.Uint32(data[0])
	if ref := binary.LittleEndian.Uint32(data[0][4:]); ref != 6106 {
		t.Fatalf("0x30C8 ref %d", ref)
	}
	if hp := binary.LittleEndian.Uint32(data[0][8:]); hp != 360 {
		t.Errorf("0x30C8 HP %d, want the row's 360", hp)
	}
	// The last byte is the flute's slot + 13.
	if last := data[0][len(data[0])-1]; last != byte(slot.Index+13) {
		t.Errorf("0x30C8's item slot %d, want %d", last, slot.Index+13)
	}
	// Named once.
	name := binary.LittleEndian.AppendUint32(nil, uid)
	name = binary.LittleEndian.AppendUint16(name, 3)
	name = append(name, "Rex"...)
	rig.send(cos.OpCOSName, name)
	got = rig.drain()
	if up := got[cos.OpCOSUpdate]; len(up) == 0 || up[0][4] != cos.UpdateName || string(up[0][7:]) != "Rex" {
		t.Fatalf("0x30C9 type 5: %x", up)
	}
	rig.send(cos.OpCOSName, name)
	if ack := rig.until(cos.OpCOSNameAck); ack.Data[0] != 2 {
		t.Errorf("a second name was not refused: %x", ack.Data)
	}
	// The flute again: the wolf is recalled.
	res, got = rig.use(fxFlute)
	if res.Error != "" {
		t.Fatalf("the recall: %+v", res)
	}
	if up := got[cos.OpCOSUpdate]; len(up) == 0 || up[0][4] != cos.UpdateRemoved {
		t.Errorf("0x30C9 type 1 on the recall: %x", up)
	}
	if st := got[cos.OpItemState]; len(st) == 0 || st[0][2] != cos.ItemStateStored {
		t.Errorf("0x3040 on the recall: %x, want state 3", st)
	}
	rec, err := rig.store.Get(context.Background(), int64(slot.Durability))
	if err != nil || rec.Summoned() || !rec.Alive() || rec.Name != "Rex" {
		t.Errorf("the record after the recall: %+v %v", rec, err)
	}
}

func TestRound795OneAbilityPet(t *testing.T) {
	rig := newCOSRig(t, 30)
	if res, _ := rig.use(fxRabbit); res.Error != "" {
		t.Fatalf("the rabbit: %+v", res)
	}
	res, _ := rig.use(fxMyowon)
	if res.Code != cos.ErrDuplicatePetType {
		t.Fatalf("a second ability pet: %+v, want 0x%x", res, cos.ErrDuplicatePetType)
	}
	rec, _ := rig.store.Get(context.Background(), int64(rig.slot(fxRabbit).Durability))
	if rec.InvSize != cos.AbilityPetSlots || rec.RentEnd.Before(time.Now().Add(4319*time.Minute)) {
		t.Errorf("the rabbit's record: %+v (28 slots, 3 days' rent)", rec)
	}
}

func TestRound795PetLevelFloor(t *testing.T) {
	rig := newCOSRig(t, 4)
	if res, _ := rig.use(fxFlute); res.Code != cos.ErrHigherLevelRequired {
		t.Fatalf("a level-4 owner: %+v, want 0x%x", res, cos.ErrHigherLevelRequired)
	}
}

func TestRound795RideScrollMountDismount(t *testing.T) {
	rig := newCOSRig(t, 7)
	res, got := rig.use(fxTigerScroll)
	if res.Error != "" || res.Remaining != 2 {
		t.Fatalf("the tiger scroll: %+v (one of three spent)", res)
	}
	spawns := got[npcspawn.OpSingleSpawn]
	if len(spawns) == 0 || binary.LittleEndian.Uint32(spawns[0]) != 23310 {
		t.Fatalf("0x3015 of COS_C_TIGER_5 (owner level 7, bracket 5): %x", spawns)
	}
	acks := got[cos.OpCOSRideAck]
	if len(acks) == 0 || acks[0][0] != 1 || acks[0][5] != 1 {
		t.Fatalf("0xB0CB: the summon mounts its owner: %x", acks)
	}
	tiger := binary.LittleEndian.Uint32(acks[0][6:])
	if riderMount(rig.charID) == nil || moverUID(rig.charID) != tiger {
		t.Fatalf("the server does not have the rider on the tiger")
	}
	if _, run, ok := riderSpeeds(rig.charID); !ok || run != 150 {
		t.Errorf("the rider's run %v, want the tiger's 150", run)
	}
	// Getting off a ride ends it.
	rig.send(cos.OpCOSRide, cos.RideAck(0, false, tiger)[5:])
	got = rig.drain()
	if acks := got[cos.OpCOSRideAck]; len(acks) == 0 || acks[0][5] != 0 {
		t.Fatalf("0xB0CB flag 0: %x", acks)
	}
	if up := got[cos.OpCOSUpdate]; len(up) == 0 || up[0][4] != cos.UpdateRemoved {
		t.Errorf("the dismounted ride is not removed: %x", up)
	}
	if len(cosWorld.owned(rig.charID)) != 0 {
		t.Errorf("the ride is still out")
	}
}

// Round 796: FOLLOW's point (and the leash's landing) is beside the owner,
// perpendicular to the owner's facing on the pet's side, never on the owner.
func TestRound796SidePoint(t *testing.T) {
	owner := world.Position{X: 100, Y: 5, Z: 200}
	// Facing +z (heading 0): the sides are -x and +x.
	left := cosSidePoint(owner, 0, world.Position{X: 50, Z: 210}, 15)
	if math.Abs(left.X-85) > 1e-9 || math.Abs(left.Z-200) > 1e-9 || left.Y != 5 {
		t.Fatalf("pet on the -x side: got %+v, want (85, 5, 200)", left)
	}
	right := cosSidePoint(owner, 0, world.Position{X: 400, Z: 150}, 15)
	if math.Abs(right.X-115) > 1e-9 || math.Abs(right.Z-200) > 1e-9 {
		t.Fatalf("pet on the +x side: got %+v, want (115, 5, 200)", right)
	}
	// Facing +x (heading pi/2): the sides are +z and -z.
	side := cosSidePoint(owner, math.Pi/2, world.Position{X: 100, Z: 900}, 15)
	if math.Abs(side.X-100) > 1e-9 || math.Abs(side.Z-215) > 1e-9 {
		t.Fatalf("facing +x, pet at +z: got %+v, want (100, 5, 215)", side)
	}
}
