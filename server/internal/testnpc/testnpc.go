// Package testnpc is the Test Items NPC (round 783, OURS): an NPC that is not
// in the retail archives, standing in Jangan and selling every 11th degree
// alchemy item and every Seal of Nova item, for testing.
//
// The definition (test_items.json, embedded) names only rules -- a CodeName128
// prefix and suffix, a TypeID pattern, an ItemClass -- never an item row. The
// server resolves them at boot against the reference data it loaded from the
// operator's own archives (items.csv or the refdata database), so the goods
// are whatever the player's own item table holds. docs/protocol/
// test_items_npc.md has the design and the wire message.
//
// How the pieces map onto retail's (READ, docs/protocol/npc_gui.md and the
// client's ShopReader): a "line" is a talk-window store line -- one shop tab
// group (refshoptabgroup), its text the group's name -- and its "tabs" are the
// store window's tabs (refshoptab, at most four: the store builds them from
// x = 16 stepping 56 while x < 240), each a list of goods. The retail client
// reads all of that from its own Media.pk2; this NPC's are sent by the server
// in OpNpcShopDef (OURS), since the archives cannot carry them.
package testnpc

import (
	_ "embed"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

//go:embed test_items.json
var builtin []byte

// OpNpcShopDef is OpenSRO's own message (OURS, server -> client): an NPC's
// store lines, tabs and goods, for an NPC the client's archives do not
// describe. Sent just before the 0xB045 select reply of such an NPC, so the
// talk window the reply opens has its lines. 0x00BA was free in server/ and
// client/scripts (grep, 2026-10-12). Layout:
//
//	u32 NPC unique id
//	u16 n, n bytes   the greeting (UTF-8)
//	u8 lines
//	  u16 n, n bytes   the line's label (UTF-8; a text key or text)
//	  u8 tabs
//	    u16 n, n bytes   the tab's label
//	    u16 goods, goods x u32 item id
const OpNpcShopDef uint16 = 0x00ba

// OpNpcShopGoods is OpenSRO's own message too (OURS, server -> client, round
// 786): the item instance each of an NPC's goods is listed as -- the Test
// Items NPC's +12, full-variance, full-blue equipment -- so the store's slot
// and tooltip show the item exactly as it will be bought. Sent right after
// that NPC's OpNpcShopDef, once or more (each message adds to the last; a
// message stays inside one frame). 0x00BB was free in server/ and
// client/scripts (grep, 2026-10-13). Layout:
//
//	u32 NPC unique id
//	u16 n
//	  n x (u32 item id, the retail item record)
//
// The record is the one the bag, warehouse and worn lists already carry
// (session.AppendItemRecord, READ: the client's SOItem::FUN_008be4f0); the
// u32 before it is the good's item id where those lists put a slot, so the
// client reads the block with its existing decoder (ItemInstance.
// decode_block). Only equipment goods are listed.
//
// Why a message of its own and not more bytes on OpNpcShopDef: a client
// from before round 786 refuses an OpNpcShopDef with trailing bytes (its
// decoder, like Decode here, wants the payload exactly), and would lose the
// whole store; an unknown opcode it only logs and drops. So either side can
// update first.
//
// The retail client gets a good's plus and blue options from its own
// archive: a store's good is a package (refshopgoods ->
// refscrapofpackageitem), whose scrap row carries OptLevel, Variance, Data,
// MagParamNum and MagParam1..12 (READ, GlobalDataManager::
// RefParse_refscrapofpackageitem c:0x9824e0). c:0x8bf3a0 builds each
// package's SOItem from the OptLevel and the MagParams (READ) for the store
// to copy into its slots (c:0x6d2310 -> 0x6d1ff0); it never applies the
// Variance column, so a retail good reads as variance 0. This NPC's listing
// carries the variance its piece is bought with (OURS: the user's "100%
// white stats"). docs/protocol/test_items_npc.md.
const OpNpcShopGoods uint16 = 0x00bb

// MaxTabs is the store window's tab count (READ: CIFStoreForPackage builds
// tabs from x = 16 stepping 56 while x < 240, so four; hud_panels.gd
// SHOP_MAX_TABS).
const MaxTabs = 4

// MaxGoodsPerTab is what one tab shows: the store's 6 x 5 lattice
// (GDR_STORE_SLOT_100..129, READ). The client has no page spin yet, so a
// tab's goods past 30 would never be seen; Resolve keeps the first 30 and
// reports the rest.
const MaxGoodsPerTab = 30

// Rule picks items: every condition given must hold. Empty / zero means "any".
type Rule struct {
	Prefix string `json:"prefix"` // CodeName128 starts with
	Suffix string `json:"suffix"` // CodeName128 ends with
	// Code is a regular expression the whole CodeName128 must match (Go
	// syntax, anchored by the definition itself).
	Code string `json:"code"`
	code *regexp.Regexp
	// Type is "t1/t2/t3/t4" with "*" for any part, e.g. "3/1/6/*".
	Type string `json:"type"`
	// ItemClass is the item's ItemClass (31 is 11th degree, tier A: the
	// degree is (ItemClass-1)/3 + 1, alchemy.Target.Degree, READ).
	ItemClass int `json:"item_class"`
	// Gender is the item's ReqGender (itemdata column 58: 1 a man's, 0 a
	// woman's, 2 either; round 789, for the avatar tabs). Absent: any.
	Gender *int `json:"gender"`
}

// Tab is one store tab.
type Tab struct {
	Label string `json:"label"`
	Rules []Rule `json:"rules"`
}

// Line is one store line of the talk window.
type Line struct {
	Label string `json:"label"`
	Tabs  []Tab  `json:"tabs"`
}

// Definition is the whole NPC.
type Definition struct {
	Name     string  `json:"name"`
	Model    string  `json:"model"` // the characterdata CodeName128 whose body it wears
	Greeting string  `json:"greeting"`
	Region   int     `json:"region"`
	X        float32 `json:"x"`
	Y        float32 `json:"y"`
	Z        float32 `json:"z"`
	Angle    uint16  `json:"angle"` // wInitialDir: 0 east, 16384 north (npc_spawn.md)
	// Free: every good costs nothing at this NPC's store (round 783, the
	// user's choice for the Test Items NPC). The goods keep their own price
	// everywhere else.
	Free  bool   `json:"free"`
	Lines []Line `json:"lines"`
}

// Builtin is the embedded definition (test_items.json).
func Builtin() (*Definition, error) { return Parse(builtin) }

// Parse reads and checks a definition.
func Parse(b []byte) (*Definition, error) {
	var d Definition
	if err := json.Unmarshal(b, &d); err != nil {
		return nil, fmt.Errorf("testnpc: %w", err)
	}
	if d.Name == "" || d.Model == "" {
		return nil, errors.New("testnpc: a definition needs a name and a model")
	}
	if len(d.Lines) == 0 || len(d.Lines) > 255 {
		return nil, fmt.Errorf("testnpc: %d lines", len(d.Lines))
	}
	for i, l := range d.Lines {
		if len(l.Tabs) == 0 || len(l.Tabs) > MaxTabs {
			return nil, fmt.Errorf("testnpc: line %d has %d tabs (1..%d)", i, len(l.Tabs), MaxTabs)
		}
		for j, t := range l.Tabs {
			if len(t.Rules) == 0 {
				return nil, fmt.Errorf("testnpc: line %d tab %d has no rule", i, j)
			}
			for k, r := range t.Rules {
				if _, err := parseType(r.Type); err != nil {
					return nil, err
				}
				if r.Code != "" {
					re, err := regexp.Compile(r.Code)
					if err != nil {
						return nil, fmt.Errorf("testnpc: line %d tab %d: code %q: %w", i, j, r.Code, err)
					}
					d.Lines[i].Tabs[j].Rules[k].code = re
				}
			}
		}
	}
	return &d, nil
}

// parseType turns "3/1/6/*" into four values, -1 for "*" (or a missing part).
func parseType(s string) ([4]int, error) {
	out := [4]int{-1, -1, -1, -1}
	if s == "" {
		return out, nil
	}
	parts := strings.Split(s, "/")
	if len(parts) > 4 {
		return out, fmt.Errorf("testnpc: type %q", s)
	}
	for i, p := range parts {
		if p == "*" {
			continue
		}
		v, err := strconv.Atoi(p)
		if err != nil {
			return out, fmt.Errorf("testnpc: type %q", s)
		}
		out[i] = v
	}
	return out, nil
}

// Matches reports whether item satisfies r.
func (r Rule) Matches(it *refdata.Item) bool {
	if it == nil {
		return false
	}
	if r.Prefix != "" && !strings.HasPrefix(it.CodeName, r.Prefix) {
		return false
	}
	if r.Suffix != "" && !strings.HasSuffix(it.CodeName, r.Suffix) {
		return false
	}
	if r.Code != "" && (r.code == nil || !r.code.MatchString(it.CodeName)) {
		return false
	}
	if r.ItemClass != 0 && it.ItemClass != r.ItemClass {
		return false
	}
	if r.Gender != nil && it.ReqGender != *r.Gender {
		return false
	}
	t, _ := parseType(r.Type)
	have := [4]int{it.TypeID1, it.TypeID2, it.TypeID3, it.TypeID4}
	for i := range t {
		if t[i] >= 0 && have[i] != t[i] {
			return false
		}
	}
	return true
}

// ResolvedTab is a tab with its goods.
type ResolvedTab struct {
	Label   string
	ItemIDs []uint32
	// Dropped is how many matching goods did not fit (past MaxGoodsPerTab).
	Dropped int
}

// ResolvedLine is a store line with its tabs.
type ResolvedLine struct {
	Label string
	Tabs  []ResolvedTab
}

// Shop is a definition resolved against an item table.
type Shop struct {
	Name     string
	Greeting string
	Free     bool // not on the wire: the server prices the goods (OpShopList)
	Lines    []ResolvedLine
}

// Goods is every item id the shop sells (each once).
func (s *Shop) Goods() map[int64]bool {
	out := map[int64]bool{}
	if s == nil {
		return out
	}
	for _, l := range s.Lines {
		for _, t := range l.Tabs {
			for _, id := range t.ItemIDs {
				out[int64(id)] = true
			}
		}
	}
	return out
}

// Resolve applies the definition's rules to items: a tab's goods are the
// items its rules match, in rule order and, within a rule, by TypeID3,
// TypeID4 and then id (the retail vendors list a class's pieces head to foot,
// TypeID4 1..6). An item is listed once per tab. A tab keeps its first
// MaxGoodsPerTab goods and counts the rest in Dropped.
func (d *Definition) Resolve(items []*refdata.Item) *Shop {
	sorted := append([]*refdata.Item(nil), items...)
	sort.Slice(sorted, func(i, j int) bool {
		a, b := sorted[i], sorted[j]
		if a.TypeID3 != b.TypeID3 {
			return a.TypeID3 < b.TypeID3
		}
		if a.TypeID4 != b.TypeID4 {
			return a.TypeID4 < b.TypeID4
		}
		return a.ID < b.ID
	})
	shop := &Shop{Name: d.Name, Greeting: d.Greeting, Free: d.Free}
	for _, l := range d.Lines {
		rl := ResolvedLine{Label: l.Label}
		for _, t := range l.Tabs {
			rt := ResolvedTab{Label: t.Label}
			seen := map[int64]bool{}
			for _, r := range t.Rules {
				for _, it := range sorted {
					if seen[it.ID] || !r.Matches(it) {
						continue
					}
					seen[it.ID] = true
					if len(rt.ItemIDs) >= MaxGoodsPerTab {
						rt.Dropped++
						continue
					}
					rt.ItemIDs = append(rt.ItemIDs, uint32(it.ID))
				}
			}
			rl.Tabs = append(rl.Tabs, rt)
		}
		shop.Lines = append(shop.Lines, rl)
	}
	return shop
}

// Summary is one line per tab, for the boot log: "line/tab label=count".
func (s *Shop) Summary() string {
	var b strings.Builder
	for i, l := range s.Lines {
		for j, t := range l.Tabs {
			if b.Len() > 0 {
				b.WriteByte(' ')
			}
			fmt.Fprintf(&b, "%d/%d:%s=%d", i+1, j+1, t.Label, len(t.ItemIDs))
			if t.Dropped > 0 {
				fmt.Fprintf(&b, "(+%d dropped)", t.Dropped)
			}
		}
	}
	return b.String()
}

// Empty reports whether no tab resolved a single good (an item table with no
// code names, or one from another game version).
func (s *Shop) Empty() bool { return len(s.Goods()) == 0 }

// Encode is OpNpcShopDef's payload for the NPC with unique id uid.
func (s *Shop) Encode(uid uint32) []byte {
	out := binary.LittleEndian.AppendUint32(nil, uid)
	out = appendStr(out, s.Greeting)
	out = append(out, byte(len(s.Lines)))
	for _, l := range s.Lines {
		out = appendStr(out, l.Label)
		out = append(out, byte(len(l.Tabs)))
		for _, t := range l.Tabs {
			out = appendStr(out, t.Label)
			out = binary.LittleEndian.AppendUint16(out, uint16(len(t.ItemIDs)))
			for _, id := range t.ItemIDs {
				out = binary.LittleEndian.AppendUint32(out, id)
			}
		}
	}
	return out
}

func appendStr(out []byte, s string) []byte {
	if len(s) > 0xffff {
		s = s[:0xffff]
	}
	out = binary.LittleEndian.AppendUint16(out, uint16(len(s)))
	return append(out, s...)
}

// Decode reads an OpNpcShopDef payload (tests, and the client's mirror).
func Decode(b []byte) (uint32, *Shop, error) {
	r := &rd{b: b}
	uid := r.u32()
	s := &Shop{Greeting: r.str()}
	n := int(r.u8())
	for i := 0; i < n && r.err == nil; i++ {
		l := ResolvedLine{Label: r.str()}
		nt := int(r.u8())
		for j := 0; j < nt && r.err == nil; j++ {
			t := ResolvedTab{Label: r.str()}
			ng := int(r.u16())
			for k := 0; k < ng && r.err == nil; k++ {
				t.ItemIDs = append(t.ItemIDs, r.u32())
			}
			l.Tabs = append(l.Tabs, t)
		}
		s.Lines = append(s.Lines, l)
	}
	if r.err == nil && len(r.b) != 0 {
		r.err = fmt.Errorf("testnpc: %d trailing bytes", len(r.b))
	}
	return uid, s, r.err
}

type rd struct {
	b   []byte
	err error
}

func (r *rd) take(n int) []byte {
	if r.err != nil {
		return make([]byte, n)
	}
	if len(r.b) < n {
		r.err = errors.New("testnpc: truncated OpNpcShopDef")
		return make([]byte, n)
	}
	v := r.b[:n]
	r.b = r.b[n:]
	return v
}
func (r *rd) u8() byte    { return r.take(1)[0] }
func (r *rd) u16() uint16 { return binary.LittleEndian.Uint16(r.take(2)) }
func (r *rd) u32() uint32 { return binary.LittleEndian.Uint32(r.take(4)) }
func (r *rd) str() string { return string(r.take(int(r.u16()))) }

// NPC is the spawn of the definition: refID is the model's characterdata id
// (its body), uid its unique id. The record names it (flag bit 0, the
// record's own name field: CGObjNPC::SetCharName 0x4c3f20 sets it, READ) and
// offers only the store (interaction 1), at the definition's own spot and
// angle.
func (d *Definition) NPC(refID int64, uid uint32) npcspawn.NPC {
	return npcspawn.NPC{
		Record: npcspawn.Record{
			RefID: uint32(refID), UID: uid, Region: uint16(d.Region),
			X: d.X, Y: d.Y, Z: d.Z, Angle: d.Angle,
			Flags: npcspawn.FlagName | npcspawn.FlagInteractions,
			Name:  d.Name, Interact: []byte{1},
		},
		Code:   d.Model,
		Shop:   true,
		Source: npcspawn.FromDefinition,
	}
}

// ModelRefID is the characterdata id of the NPC table's row named code (its
// body), the smallest when several share it; 0 when none does.
func ModelRefID(table npcspawn.Table, code string) int64 {
	var refID int64
	for id, r := range table {
		if r.Code == code && (refID == 0 || id < refID) {
			refID = id
		}
	}
	return refID
}
