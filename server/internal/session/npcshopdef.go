package session

import (
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/testnpc"
)

// The shop definitions of NPCs the client's archives do not describe (round
// 783, OURS; internal/testnpc): uid -> OpNpcShopDef's payload. The retail
// client reads every NPC's store lines and tabs from its own Media.pk2
// (refshopgroup .. refshopgoods, the client's ShopReader); an NPC of
// OpenSRO's own has none there, so the server sends its lines, tabs and
// goods just before the select reply (handleNPCSelect).
var npcShopDefs atomic.Pointer[map[uint32]NPCShopDef]

// NPCShopDef is one such NPC's definition as the session uses it.
type NPCShopDef struct {
	// Payload is OpNpcShopDef's bytes (testnpc.Shop.Encode).
	Payload []byte
	// GoodsPayloads are OpNpcShopGoods' messages (round 786,
	// TestShopGoodsPayloads): the instance each equipment good is listed as,
	// sent right after Payload. None: the goods list as reference items.
	GoodsPayloads [][]byte
	// Goods is every item id its store lists.
	Goods map[int64]bool
	// Free: its goods cost nothing while its store is the open interaction
	// (round 783, the user's choice for the Test Items NPC; OURS). The same
	// items bought anywhere else keep their own price.
	Free bool
	// ActionsPayload is OpNpcActionDef's bytes (round 872,
	// testnpc.Shop.EncodeActions), sent after the goods; nil for none.
	ActionsPayload []byte
	// Actions is what each of its action ids runs (testnpc.Action.Do).
	Actions map[uint8]string
}

// InstallNPCShopDefs installs the definitions (nil or empty: none).
func InstallNPCShopDefs(defs map[uint32]NPCShopDef) {
	if len(defs) == 0 {
		npcShopDefs.Store(nil)
		return
	}
	m := make(map[uint32]NPCShopDef, len(defs))
	for k, v := range defs {
		m[k] = v
	}
	npcShopDefs.Store(&m)
}

// freeAtOpenStore reports whether itemID is free for session id: the session's
// open interaction is the store (INTERACTMODE 6, set by the 0x7046 open of id
// 1) of an NPC whose definition gives its goods away, and itemID is one of
// them. Every other buy -- any retail NPC, or no store open -- pays the
// item's own price.
func freeAtOpenStore(id uint64, itemID int64) bool {
	p := npcShopDefs.Load()
	if p == nil {
		return false
	}
	entity, mode := NPCInteractionMode(id)
	if mode != 6 {
		return false
	}
	d, ok := (*p)[entity]
	return ok && d.Free && d.Goods[itemID]
}

// sendNPCShopDef sends uid's definition, if it has one, and then the
// instances its goods are listed as (OpNpcShopGoods, round 786).
func sendNPCShopDef(sess *gateway.Session, uid uint32) {
	p := npcShopDefs.Load()
	if p == nil {
		return
	}
	if d, ok := (*p)[uid]; ok {
		sess.Send(&proto.Packet{Opcode: testnpc.OpNpcShopDef, Data: d.Payload})
		for _, g := range d.GoodsPayloads {
			sess.Send(&proto.Packet{Opcode: testnpc.OpNpcShopGoods, Data: g})
		}
		// Round 872: its action lines, after the store's (OpNpcActionDef).
		if len(d.ActionsPayload) > 0 {
			sess.Send(&proto.Packet{Opcode: testnpc.OpNpcActionDef, Data: d.ActionsPayload})
		}
	}
}

// npcActionOf is what action id of the NPC with unique id uid runs ("" for
// none: a retail NPC, or an id its definition lacks).
func npcActionOf(uid uint32, id uint8) string {
	p := npcShopDefs.Load()
	if p == nil {
		return ""
	}
	return (*p)[uid].Actions[id]
}
