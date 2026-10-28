package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cos"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 838: the 3/3/13/8 tools through UseItemHandler (switcher.go). The
// rows are the archive's own (MEASURED, itemdata_*.txt on the RE box): ids,
// code names, OrgObjCodeName, TypeIDs, ReqGender, ItemClass, durability
// range and Param1.
func switcherRows() []refdata.Item {
	tool := func(id int64, code string, p1 uint32) refdata.Item {
		return refdata.Item{ID: id, CodeName: code, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 8,
			Param1: p1, ItemClass: 11, CanUse: true, CashItem: true}
	}
	gear := func(id int64, code, org string, t3, t4, gender, class int, dmin, dmax float64) refdata.Item {
		return refdata.Item{ID: id, CodeName: code, OrgCodeName: org, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: t3, TypeID4: t4,
			ReqGender: gender, ItemClass: class, DurabilityMin: dmin, DurabilityMax: dmax}
	}
	return []refdata.Item{
		tool(23352, "ITEM_MALL_EQUIP_TRANSGENDER_4", 12),
		tool(24461, "ITEM_EVENT_EQUIP_TRANSGENDER_1", 3),
		tool(57835, "ITEM_AVATAR_SWITCHER", 3),
		tool(57836, "ITEM_DEVIL_SWITCHER", 3),
		tool(57837, "ITEM_GDF_SWITCHER", 3),
		tool(61199, "ITEM_EU_AXE_SWITCHER", 3),
		tool(61186, "ITEM_CH_SWORD_SWITCHER", 3),
		tool(61189, "ITEM_CH_SHIELD_SWITCHER", 3),
		tool(61247, "ITEM_MODEL_05", 3),
		tool(61253, "ITEM_MODEL_11", 3),
		tool(61258, "ITEM_MODEL_16", 3),
		gear(3637, "ITEM_CH_M_HEAVY_01_BA_A_DEF", "ITEM_CH_W_HEAVY_01_BA_A_DEF", 3, 3, 1, 1, 48, 59),
		gear(3646, "ITEM_CH_W_HEAVY_01_BA_A_DEF", "ITEM_CH_M_HEAVY_01_BA_A_DEF", 3, 3, 0, 1, 48, 59),
		gear(11665, "ITEM_EU_M_HEAVY_11_HA_A", "ITEM_EU_W_HEAVY_11_HA_A", 11, 1, 1, 31, 91, 136),
		gear(13177, "ITEM_EU_W_HEAVY_11_HA_A", "ITEM_EU_M_HEAVY_11_HA_A", 11, 1, 0, 31, 91, 136),
		gear(101, "ITEM_CH_SWORD_11_A", "", 6, 2, 2, 31, 124, 151),
		gear(62515, "ITEM_CH_SWORD_11_A_SWITCH16", "", 6, 2, 2, 31, 124, 151),
		gear(4045, "ITEM_CH_SWORD_11_B_RARE", "", 6, 2, 2, 32, 130, 159),
		gear(281, "ITEM_CH_SHIELD_11_A", "", 4, 1, 2, 31, 91, 111),
		gear(62449, "ITEM_CH_SHIELD_11_A_SWITCH12", "", 4, 1, 2, 31, 91, 111),
		gear(25611, "ITEM_CH_SWORD_11_SET_A_RARE", "", 6, 2, 2, 31, 128, 157),
		gear(61449, "ITEM_CH_SWORD_11_SET_A_RARE_SWITCH05", "", 6, 2, 2, 31, 128, 157),
		gear(25622, "ITEM_EU_AXE_11_SET_A_RARE", "", 6, 9, 2, 31, 136, 204),
		gear(61541, "ITEM_EU_AXE_11_SET_A_RARE_SWITCH05", "", 6, 9, 2, 31, 136, 204),
		gear(22916, "ITEM_MALL_AVATAR_M_CH_WEDDING", "", 13, 2, 1, 1, 0, 0),
		gear(22917, "ITEM_MALL_AVATAR_W_CH_WEDDING", "", 13, 2, 0, 1, 0, 0),
		gear(24375, "ITEM_MALL_AVATAR_M_SHOGUN", "", 13, 2, 1, 1, 0, 0),
		gear(24405, "ITEM_MALL_AVATAR_M_NASRUN", "", 14, 1, 1, 1, 0, 0),
		gear(24406, "ITEM_MALL_AVATAR_W_NASRUN", "", 14, 1, 0, 1, 0, 0),
		gear(9374, "ITEM_ETC_E060529_GOLDDRAGONFLAG_M", "", 13, 4, 1, 1, 0, 0),
		gear(9375, "ITEM_ETC_E060529_GOLDDRAGONFLAG_F", "", 13, 4, 0, 1, 0, 0),
	}
}

type switchHarness struct {
	t    *testing.T
	ctx  context.Context
	inv  *inventory.MemStore
	char int64
	send func(op uint16, data []byte) (*UseItemResult, [][]byte)
}

// newSwitchHarness puts one of each id in held into the bag, in order.
func newSwitchHarness(t *testing.T, held ...int64) *switchHarness {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, switcherRows()); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	for _, id := range held {
		if err := inv.AddItem(ctx, c.ID, id, 1); err != nil {
			t.Fatalf("add %d: %v", id, err)
		}
	}
	h := &switchHarness{t: t, ctx: ctx, inv: inv, char: c.ID}
	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, nil, nil, nil, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	read := func() *proto.Packet {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return p
	}
	write := func(op uint16, data []byte) {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(read().Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	h.send = func(op uint16, data []byte) (*UseItemResult, [][]byte) {
		t.Helper()
		write(op, data)
		var states [][]byte
		for {
			p := read()
			switch p.Opcode {
			case cos.OpItemState:
				states = append(states, p.Data)
			case OpUseItemResult:
				res, err := DecodeUseItemResult(p.Data)
				if err != nil {
					t.Fatalf("decode: %v", err)
				}
				return res, states
			}
		}
	}
	return h
}

// slotOf is the bag index holding id (-1 none) and the slot.
func (h *switchHarness) slotOf(id int64) (int, inventory.Slot) {
	h.t.Helper()
	slots, err := h.inv.List(h.ctx, h.char)
	if err != nil {
		h.t.Fatalf("list: %v", err)
	}
	for _, sl := range slots {
		if sl.ItemID == id {
			return sl.Index, sl
		}
	}
	return -1, inventory.Slot{}
}

// use uses tool on the bag item target (its wire slot, index + 13; or the
// raw byte when raw is set).
func (h *switchHarness) use(tool, target int64) (*UseItemResult, [][]byte) {
	h.t.Helper()
	ti, _ := h.slotOf(tool)
	gi, _ := h.slotOf(target)
	if ti < 0 || gi < 0 {
		h.t.Fatalf("tool %d at %d, target %d at %d", tool, ti, target, gi)
	}
	return h.useRaw(tool, byte(gi+AlchemyFirstBagSlot))
}

func (h *switchHarness) useRaw(tool int64, wire byte) (*UseItemResult, [][]byte) {
	h.t.Helper()
	ti, _ := h.slotOf(tool)
	return h.send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(ti), Option: wire}).Encode())
}

func (h *switchHarness) has(id int64) bool {
	i, _ := h.slotOf(id)
	return i >= 0
}

// The retail tool (UseByKind case 8): armour becomes its OrgObjCodeName,
// in place, its instance kept; the owner hears 0x3040 {slot+13, 1, ref}
// before the reply; one tool is spent.
func TestRetailGenderToolMutatesArmour(t *testing.T) {
	h := newSwitchHarness(t, 23352, 3637)
	idx, before := h.slotOf(3637)
	inst := before.Instance()
	inst.OptLevel, inst.MagParams = 5, []uint64{inventory.MagParam(7, 3)}
	if err := h.inv.SetInstance(h.ctx, h.char, idx, inst); err != nil {
		t.Fatal(err)
	}
	res, states := h.use(23352, 3637)
	if res.Error != "" || res.Remaining != 0 || res.ItemID != 23352 {
		t.Fatalf("use: %+v", res)
	}
	i2, after := h.slotOf(3646)
	if i2 != idx || h.has(3637) || h.has(23352) {
		t.Fatalf("after: twin at %d (want %d), old there %v, tool there %v", i2, idx, h.has(3637), h.has(23352))
	}
	if !after.Instance().Equal(inst) {
		t.Errorf("instance changed: %+v -> %+v", inst, after.Instance())
	}
	if len(states) != 1 || len(states[0]) != 6 || states[0][0] != byte(idx+13) || states[0][1] != 1 ||
		binary.LittleEndian.Uint32(states[0][2:]) != 3646 {
		t.Errorf("0x3040: %x", states)
	}
}

// Its refusals, each in retail's order and code, keep the tool and the item.
func TestRetailGenderToolRefusals(t *testing.T) {
	h := newSwitchHarness(t, 23352, 24461, 101, 11665)
	cases := []struct {
		name   string
		tool   int64
		target int64
		wire   byte
		code   uint16
	}{
		{"an equipped slot", 23352, 0, 6, SwitchErrEquipped},
		{"no target at all", 23352, 0, 0, SwitchErrEquipped},
		{"a weapon is not armour", 23352, 101, 0, SwitchErrTarget},
		{"degree 11 over Param1 3", 24461, 11665, 0, SwitchErrDegree},
		{"the tool itself", 23352, 23352, 0, SwitchErrTarget},
	}
	for _, tc := range cases {
		var res *UseItemResult
		if tc.target != 0 {
			res, _ = h.use(tc.tool, tc.target)
		} else {
			res, _ = h.useRaw(tc.tool, tc.wire)
		}
		if res.Error == "" || res.Code != tc.code {
			t.Errorf("%s: %+v, want code 0x%x", tc.name, res, tc.code)
		}
	}
	for _, id := range []int64{23352, 24461, 101, 11665} {
		if !h.has(id) {
			t.Errorf("item %d was taken", id)
		}
	}
	// Param1 12 takes degree 11.
	if res, _ := h.use(23352, 11665); res.Error != "" || !h.has(13177) {
		t.Errorf("degree 11 with Param1 12: %+v", res)
	}
}

// The OURS gender switchers: each its own kind, the twin by the code name's
// gender token with the same TypeIDs and the other ReqGender.
func TestOursGenderSwitchers(t *testing.T) {
	h := newSwitchHarness(t, 57835, 57836, 57837, 22916, 24406, 9374, 24375)
	if res, _ := h.use(57835, 24406); res.Error == "" {
		t.Errorf("avatar switcher on a devil's spirit: %+v", res)
	}
	if res, _ := h.use(57836, 22916); res.Error == "" {
		t.Errorf("devil switcher on an avatar: %+v", res)
	}
	if res, _ := h.use(57835, 24375); res.Error == "" || !h.has(57835) {
		t.Errorf("a male-only avatar (no twin): %+v", res)
	}
	for _, c := range []struct{ tool, from, to int64 }{{57835, 22916, 22917}, {57836, 24406, 24405}, {57837, 9374, 9375}} {
		res, states := h.use(c.tool, c.from)
		if res.Error != "" || !h.has(c.to) || h.has(c.from) || h.has(c.tool) || len(states) != 1 {
			t.Errorf("%d on %d: %+v (to there %v)", c.tool, c.from, res, h.has(c.to))
		}
	}
}

// A type switcher on an Egy A weapon: the chosen weapon's same row, the plus,
// options and variance kept, the durability scaled, a model remapped.
func TestWeaponTypeSwitcher(t *testing.T) {
	h := newSwitchHarness(t, 61199, 61186, 25611, 101, 61189)
	idx, sl := h.slotOf(25611)
	inst := sl.Instance()
	inst.OptLevel, inst.MagParams, inst.Durability, inst.Model = 7, []uint64{inventory.MagParam(4, 9)}, 50, 61449
	if err := h.inv.SetInstance(h.ctx, h.char, idx, inst); err != nil {
		t.Fatal(err)
	}
	oldMax := 128 + int(float64(sl.Variance&31)/31*(157-128)+0.5)
	if res, _ := h.use(61186, 25611); res.Error == "" {
		t.Errorf("to its own type: %+v", res)
	}
	if res, _ := h.use(61199, 101); res.Error == "" {
		t.Errorf("a plain D11 sword is not Egy A: %+v", res)
	}
	if res, _ := h.use(61189, 25611); res.Error == "" || !h.has(61189) {
		t.Errorf("the shield switcher is not sold, refused: %+v", res)
	}
	res, states := h.use(61199, 25611)
	if res.Error != "" || len(states) != 1 {
		t.Fatalf("to an axe: %+v %x", res, states)
	}
	i2, axe := h.slotOf(25622)
	if i2 != idx {
		t.Fatalf("axe at %d, want %d", i2, idx)
	}
	got := axe.Instance()
	if got.OptLevel != 7 || len(got.MagParams) != 1 || got.MagParams[0] != inventory.MagParam(4, 9) || got.Variance != inst.Variance {
		t.Errorf("instance not kept: %+v", got)
	}
	newMax := 136 + int(float64(sl.Variance&31)/31*(204-136)+0.5)
	if want := int(float64(50)*float64(newMax)/float64(oldMax) + 0.5); got.Durability != want {
		t.Errorf("durability %d, want %d (50 of %d -> of %d)", got.Durability, want, oldMax, newMax)
	}
	if got.Model != 61541 {
		t.Errorf("model %d, want the axe's SWITCH05 61541", got.Model)
	}
}

// A model switcher: degree 11 weapons and shields only; the item keeps its
// row; the Default switcher takes the model off; refusals keep the tool.
func TestModelSwitcher(t *testing.T) {
	h := newSwitchHarness(t, 61258, 61247, 61253, 101, 4045, 281, 3637)
	if res, _ := h.use(61253, 101); res.Error == "" || !h.has(61253) {
		t.Errorf("Default on an item with its own model: %+v", res)
	}
	if res, _ := h.use(61258, 4045); res.Error == "" {
		t.Errorf("a B grade has no _SWITCH rows: %+v", res)
	}
	if res, _ := h.use(61258, 3637); res.Error == "" {
		t.Errorf("armour: %+v", res)
	}
	res, states := h.use(61258, 101)
	if res.Error != "" || len(states) != 0 {
		t.Fatalf("model 16: %+v %x", res, states)
	}
	if _, sl := h.slotOf(101); sl.Model != 62515 {
		t.Errorf("model %d, want 62515 (ITEM_CH_SWORD_11_A_SWITCH16)", sl.Model)
	}
	if res, _ := h.use(61247, 281); res.Error == "" {
		t.Errorf("a shield has no _SWITCH05 row here: %+v", res)
	}
	res, _ = h.use(61253, 101)
	if res.Error != "" {
		t.Fatalf("Default: %+v", res)
	}
	if _, sl := h.slotOf(101); sl.Model != 0 {
		t.Errorf("Default left model %d", sl.Model)
	}
}

// The models block rides after the item-info block and comes back.
func TestItemInfoModelsBlock(t *testing.T) {
	infos := []ItemInfo{{Slot: 3, RefItemID: 101, Durability: 9}, {Slot: 5, RefItemID: 25611, Model: 61449}}
	b := encodeItemInfoBlock(nil, infos)
	got, err := decodeItemInfoBlock(b)
	if err != nil || len(got) != 2 || got[0].Model != 0 || got[1].Model != 61449 {
		t.Fatalf("decode: %v %+v", err, got)
	}
	plain := encodeItemInfoBlock(nil, infos[:1])
	if len(b) != len(plain)+itemInfoEntrySize(infos[1])+2+modelEntrySize {
		t.Errorf("block %d bytes, plain %d", len(b), len(plain))
	}
	if again, _ := decodeItemInfoBlock(plain); len(again) != 1 || again[0].Model != 0 {
		t.Errorf("a block without models: %+v", again)
	}
}

// The gender tokens.
func TestGenderTwinCodes(t *testing.T) {
	for code, want := range map[string]string{
		"ITEM_MALL_AVATAR_M_CH_WEDDING":     "ITEM_MALL_AVATAR_W_CH_WEDDING",
		"ITEM_ETC_E060529_GOLDDRAGONFLAG_F": "ITEM_ETC_E060529_GOLDDRAGONFLAG_M",
		"ITEM_EVENT_E081126_SILKROAD_PLAG_W": "ITEM_EVENT_E081126_SILKROAD_PLAG_M",
	} {
		found := false
		for _, c := range genderTwinCodes(code) {
			found = found || c == want
		}
		if !found {
			t.Errorf("%s: %v lacks %s", code, genderTwinCodes(code), want)
		}
	}
}

// Round 838: other players draw a worn item with its model -- the spawn
// record's look names the model's row -- while the owner's worn list keeps
// the item's true id beside the model.
func TestObserversDrawTheModel(t *testing.T) {
	ctx := context.Background()
	SetSpawnItemRefs(nil)
	inv := inventory.NewMemStore(nil)
	eq := equipment.NewMemStore(inv)
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Model")
	if err := inv.AddItemInstance(ctx, c.ID, 101, 1, inventory.Instance{OptLevel: 3, Model: 62515}); err != nil {
		t.Fatal(err)
	}
	slots, _ := inv.List(ctx, c.ID)
	if err := eq.Equip(ctx, c.ID, equipment.SlotWeapon, slots[0].Index); err != nil {
		t.Fatal(err)
	}
	invalidateLook(c.ID)
	t.Cleanup(func() { invalidateLook(c.ID) })
	worn := equippedItems(ctx, eq, c.ID)
	if len(worn) != 1 || worn[0].ItemID != 101 || worn[0].Model != 62515 {
		t.Fatalf("equippedItems %+v", worn)
	}
	lk := lookOf(ctx, viewDeps{ctx: ctx, eq: eq, chars: chars}, c.ID)
	if len(lk.items) != 1 || lk.items[0].RefItemID != 62515 {
		t.Fatalf("the look's items %+v, want the model row 62515", lk.items)
	}
	if displayRef(101, 0) != 101 || displayRef(101, 62515) != 62515 {
		t.Error("displayRef")
	}
}

func TestSwitchToolOf(t *testing.T) {
	for code, want := range map[string]switchKind{
		"ITEM_MALL_EQUIP_TRANSGENDER_4":  switchRetailGender,
		"ITEM_EVENT_EQUIP_TRANSGENDER_1": switchRetailGender,
		"ITEM_AVATAR_SWITCHER":           switchAvatarGender,
		"ITEM_EU_DARKSTAFF_SWITCHER":     switchWeaponType,
		"ITEM_CH_SHIELD_SWITCHER":        switchUnsupported,
		"ITEM_MODEL_16":                  switchModel,
		"ITEM_MODELSWITCHER_05":          switchUnsupported,
		"ITEM_WEAPON_UNLOCK":             switchUnsupported,
		"ITEM_UPGRADESTONE_SET":          switchUnsupported,
	} {
		if got := switchToolOf(code).kind; got != want {
			t.Errorf("%s: %d, want %d", code, got, want)
		}
	}
	if s := switchToolOf("ITEM_EU_DARKSTAFF_SWITCHER"); s.typeID4 != 10 || s.race != "EU" || s.weapon != "DARKSTAFF" {
		t.Errorf("dark staff: %+v", s)
	}
}
