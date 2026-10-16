package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/pcspawn"
)

// avatarGoldenPath is the vector file the client's avatar net tests read too
// (round 789): both sides encode the same fields to the same bytes and decode
// the same bytes to the same fields.
func avatarGoldenPath() string {
	return filepath.Join("..", "..", "..", "client", "scripts", "net", "testdata", "avatar_golden.json")
}

type goldenRecord struct {
	Slot      byte        `json:"slot"`
	Ref       uint32      `json:"ref"`
	OptLevel  uint8       `json:"opt_level"`
	Variance  uint64      `json:"variance"`
	Dur       uint32      `json:"durability"`
	MagParams [][2]uint32 `json:"mag_params"`
}

func (g goldenRecord) info() ItemInfo {
	ii := ItemInfo{RefItemID: g.Ref, OptLevel: g.OptLevel, Variance: g.Variance, Durability: g.Dur}
	for _, p := range g.MagParams {
		ii.MagParams = append(ii.MagParams, inventory.MagParam(uint16(p[0]), p[1]))
	}
	return ii
}

func recordOf(ii ItemInfo, slot byte) goldenRecord {
	g := goldenRecord{Slot: slot, Ref: ii.RefItemID, OptLevel: ii.OptLevel, Variance: ii.Variance, Dur: ii.Durability, MagParams: [][2]uint32{}}
	for _, p := range ii.MagParams {
		g.MagParams = append(g.MagParams, [2]uint32{uint32(inventory.MagParamOption(p)), inventory.MagParamValue(p)})
	}
	return g
}

type avatarGoldenFile struct {
	Opcodes      map[string]uint16 `json:"opcodes"`
	MoveRequests []struct {
		Name   string `json:"name"`
		Error  bool   `json:"error"`
		Hex    string `json:"hex"`
		Fields struct {
			Type, Src, Dst byte
		} `json:"fields"`
	} `json:"move_requests"`
	MoveAcks []struct {
		Name   string `json:"name"`
		Error  bool   `json:"error"`
		Hex    string `json:"hex"`
		Fields struct {
			OK   bool   `json:"ok"`
			Code uint16 `json:"code"`
			Type byte   `json:"type"`
			Src  byte   `json:"src"`
			Dst  byte   `json:"dst"`
			Qty  uint16 `json:"qty"`
			Subs []struct {
				Type, Src, Dst byte
				Qty            uint16
			} `json:"subs"`
		} `json:"fields"`
	} `json:"move_acks"`
	Broadcasts []struct {
		Name   string `json:"name"`
		Opcode uint16 `json:"opcode"`
		Hex    string `json:"hex"`
		Fields struct {
			UID  uint32 `json:"uid"`
			Slot byte   `json:"slot"`
			Ref  uint32 `json:"ref"`
			Plus *byte  `json:"plus"`
		} `json:"fields"`
	} `json:"broadcasts"`
	SpawnBlocks []struct {
		Name   string `json:"name"`
		Hex    string `json:"hex"`
		Fields struct {
			Size  byte `json:"size"`
			Items []struct {
				Ref  uint32 `json:"ref"`
				Plus byte   `json:"plus"`
			} `json:"items"`
		} `json:"fields"`
	} `json:"spawn_avatar_blocks"`
	Lists []struct {
		Name   string `json:"name"`
		Error  bool   `json:"error"`
		Hex    string `json:"hex"`
		Fields struct {
			Size  byte           `json:"size"`
			Items []goldenRecord `json:"items"`
		} `json:"fields"`
	} `json:"avatar_lists"`
	GrantRequests []struct {
		Name   string `json:"name"`
		Error  bool   `json:"error"`
		Hex    string `json:"hex"`
		Fields struct {
			Slot byte   `json:"slot"`
			Code string `json:"code"`
		} `json:"fields"`
	} `json:"grant_requests"`
	GrantAcks []struct {
		Name   string `json:"name"`
		Error  bool   `json:"error"`
		Hex    string `json:"hex"`
		Fields struct {
			OK   bool         `json:"ok"`
			Code uint16       `json:"code"`
			Flag byte         `json:"flag"`
			Slot byte         `json:"slot"`
			Item goldenRecord `json:"item"`
		} `json:"fields"`
	} `json:"grant_acks"`
}

func TestAvatarGolden(t *testing.T) {
	raw, err := os.ReadFile(avatarGoldenPath())
	if err != nil {
		t.Fatal(err)
	}
	var f avatarGoldenFile
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]uint16{
		"item_move": OpItemMove, "item_move_ack": OpItemMoveResult,
		"equip_broadcast": OpEquipBroadcast, "unequip_broadcast": OpUnequipBroadcast,
		"avatar_grant": OpAvatarGrant, "avatar_grant_ack": OpAvatarGrantResult,
		"avatar_list_request": OpAvatarList, "avatar_list": OpAvatarListResult,
	} {
		if f.Opcodes[name] != want {
			t.Errorf("opcode %s: golden 0x%04x, server 0x%04x", name, f.Opcodes[name], want)
		}
	}
	if len(f.MoveRequests) == 0 || len(f.MoveAcks) == 0 || len(f.Broadcasts) == 0 || len(f.SpawnBlocks) == 0 ||
		len(f.Lists) == 0 || len(f.GrantRequests) == 0 || len(f.GrantAcks) == 0 {
		t.Fatal("a section of the golden file is missing")
	}

	for _, v := range f.MoveRequests {
		b := goldenBytes(t, v.Hex)
		got, err := DecodeAvatarMove(b)
		if v.Error {
			if err == nil {
				t.Errorf("%s: decoded %+v, want an error", v.Name, got)
			}
			continue
		}
		want := &AvatarMove{Type: v.Fields.Type, Src: v.Fields.Src, Dst: v.Fields.Dst}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: decode = %+v, %v; want %+v", v.Name, got, err, want)
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
	}

	for _, v := range f.MoveAcks {
		b := goldenBytes(t, v.Hex)
		got, err := DecodeAvatarMoveResult(b)
		if v.Error {
			if err == nil {
				t.Errorf("%s: decoded %+v, want an error", v.Name, got)
			}
			continue
		}
		want := &AvatarMoveResult{OK: v.Fields.OK, Code: v.Fields.Code}
		if want.OK {
			want.Type, want.Src, want.Dst, want.Qty = v.Fields.Type, v.Fields.Src, v.Fields.Dst, v.Fields.Qty
			want.Subs = []AvatarSubOp{}
			for _, s := range v.Fields.Subs {
				want.Subs = append(want.Subs, AvatarSubOp{Type: s.Type, Src: s.Src, Dst: s.Dst, Qty: s.Qty})
			}
		}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: decode = %+v, %v; want %+v", v.Name, got, err, want)
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
	}

	for _, v := range f.Broadcasts {
		b := goldenBytes(t, v.Hex)
		want := &EquipBroadcast{UID: v.Fields.UID, Slot: v.Fields.Slot, RefItemID: v.Fields.Ref}
		if v.Fields.Plus != nil {
			want.Plus, want.HasPlus = *v.Fields.Plus, true
		}
		if (v.Opcode == OpEquipBroadcast) != want.HasPlus {
			t.Errorf("%s: a 0x3038 carries the plus, a 0x3039 does not", v.Name)
		}
		got, err := DecodeEquipBroadcast(b)
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: decode = %+v, %v; want %+v", v.Name, got, err, want)
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
	}

	for _, v := range f.SpawnBlocks {
		b := goldenBytes(t, v.Hex)
		var items []pcspawn.Item
		for _, it := range v.Fields.Items {
			items = append(items, pcspawn.Item{RefItemID: it.Ref, Plus: it.Plus, HasPlus: true})
		}
		if enc := pcspawn.AppendAvatarBlock(nil, v.Fields.Size, items); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
		size, got, rest, err := pcspawn.ReadAvatarBlock(b)
		if err != nil || len(rest) != 0 || size != v.Fields.Size || !reflect.DeepEqual(got, items) {
			t.Errorf("%s: decode = %d %+v (%d left), %v", v.Name, size, got, len(rest), err)
		}
	}

	for _, v := range f.Lists {
		b := goldenBytes(t, v.Hex)
		got, err := DecodeAvatarList(b)
		if v.Error {
			if err == nil {
				t.Errorf("%s: decoded %+v, want an error", v.Name, got)
			}
			continue
		}
		want := &AvatarList{Size: v.Fields.Size, Items: []AvatarListItem{}}
		for _, it := range v.Fields.Items {
			want.Items = append(want.Items, AvatarListItem{Slot: it.Slot, Info: it.info()})
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
		if err != nil {
			t.Errorf("%s: decode: %v", v.Name, err)
			continue
		}
		var gotFields []goldenRecord
		for _, it := range got.Items {
			gotFields = append(gotFields, recordOf(it.Info, it.Slot))
		}
		var wantFields []goldenRecord
		for _, it := range v.Fields.Items {
			if it.MagParams == nil {
				it.MagParams = [][2]uint32{}
			}
			wantFields = append(wantFields, it)
		}
		if got.Size != v.Fields.Size || !reflect.DeepEqual(gotFields, wantFields) {
			t.Errorf("%s: decode = %d %+v, want %d %+v", v.Name, got.Size, gotFields, v.Fields.Size, wantFields)
		}
	}

	for _, v := range f.GrantRequests {
		b := goldenBytes(t, v.Hex)
		got, err := DecodeAvatarGrantRequest(b)
		if v.Error {
			if err == nil {
				t.Errorf("%s: decoded %+v, want an error", v.Name, got)
			}
			continue
		}
		want := &AvatarGrantRequest{Slot: v.Fields.Slot, Code: v.Fields.Code}
		if err != nil || !reflect.DeepEqual(got, want) {
			t.Errorf("%s: decode = %+v, %v; want %+v", v.Name, got, err, want)
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
	}

	for _, v := range f.GrantAcks {
		b := goldenBytes(t, v.Hex)
		got, err := DecodeAvatarGrantResult(b)
		if v.Error {
			if err == nil {
				t.Errorf("%s: decoded %+v, want an error", v.Name, got)
			}
			continue
		}
		want := &AvatarGrantResult{OK: v.Fields.OK, Code: v.Fields.Code}
		if want.OK {
			want.Flag, want.Slot, want.Item = v.Fields.Flag, v.Fields.Slot, v.Fields.Item.info()
		}
		if enc := want.Encode(); !reflect.DeepEqual(enc, b) {
			t.Errorf("%s: encode = %x, want %x", v.Name, enc, b)
		}
		if err != nil || got.OK != want.OK || got.Code != want.Code || got.Flag != want.Flag || got.Slot != want.Slot ||
			!reflect.DeepEqual(recordOf(got.Item, 0), recordOf(want.Item, 0)) {
			t.Errorf("%s: decode = %+v, %v; want %+v", v.Name, got, err, want)
		}
	}
}
