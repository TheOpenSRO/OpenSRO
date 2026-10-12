package main

import (
	"context"
	"log/slog"

	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/testnpc"
)

// testItemsNPCSpec is the Test Items NPC resolved against the loaded item
// reference data (round 783, OURS; internal/testnpc).
type testItemsNPCSpec struct {
	def  *testnpc.Definition
	shop *testnpc.Shop
}

// resolveTestItemsNPC resolves the embedded definition's rules against every
// item the server loaded (items.csv or the refdata database). nil, with an
// ERROR line, when it cannot: the rest of the server runs without the NPC.
func resolveTestItemsNPC(ctx context.Context, logger *slog.Logger, items interface {
	ListAll(ctx context.Context) ([]*refdata.Item, error)
}) *testItemsNPCSpec {
	def, err := testnpc.Builtin()
	if err != nil {
		logger.Error("-test-items-npc: the definition does not parse; no Test Items NPC", "err", err)
		return nil
	}
	all, err := items.ListAll(ctx)
	if err != nil {
		logger.Error("-test-items-npc: listing the item reference data failed; no Test Items NPC", "err", err)
		return nil
	}
	shop := def.Resolve(all)
	if shop.Empty() {
		logger.Error("-test-items-npc: no item matches the definition's rules (no item reference data, or one "+
			"exported before the CodeName column, round 497); no Test Items NPC", "items", len(all))
		return nil
	}
	logger.Info("Test Items NPC resolved (round 783, OURS): line/tab label=goods", "items", len(all),
		"goods", len(shop.Goods()), "tabs", shop.Summary())
	return &testItemsNPCSpec{def: def, shop: shop}
}

// appendTestItemsNPC adds the Test Items NPC to npcs -- its body the NPC
// table's row for the definition's model code, its unique id the next after
// the placed NPCs' -- and installs its shop definition (OpNpcShopDef).
func appendTestItemsNPC(logger *slog.Logger, npcs []npcspawn.NPC, table npcspawn.Table, spec *testItemsNPCSpec) []npcspawn.NPC {
	if spec == nil {
		session.InstallNPCShopDefs(nil)
		return npcs
	}
	refID := testnpc.ModelRefID(table, spec.def.Model)
	if refID == 0 {
		logger.Error("-test-items-npc: the NPC table names no " + spec.def.Model + " (its body); no Test Items NPC")
		session.InstallNPCShopDefs(nil)
		return npcs
	}
	uid := npcspawn.UIDBase + uint32(len(npcs))
	npcs = append(npcs, spec.def.NPC(refID, uid))
	session.InstallNPCShopDefs(map[uint32]session.NPCShopDef{uid: {
		Payload: spec.shop.Encode(uid), Goods: spec.shop.Goods(), Free: spec.shop.Free}})
	logger.Info("Test Items NPC spawned (round 783, OURS)", "name", spec.def.Name, "uid", uid, "body", spec.def.Model,
		"ref", refID, "region", spec.def.Region, "x", spec.def.X, "y", spec.def.Y, "z", spec.def.Z, "angle", spec.def.Angle, "free", spec.shop.Free)
	return npcs
}
