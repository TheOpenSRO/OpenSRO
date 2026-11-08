package session

// Round 865 stage 2: buying the honor stores' goods, which cost gold AND the
// buyer's academy honor points (READ: CheckCurrencyRequirement s:0x617360 --
// gold short first, then the honor price above the member's HonorPoint
// 0x18d4 UIIT_MSG_TC_LACK_HONOR_POINT, s:0x617629 reading the member's +0x54
// through s:0x4ea600; the database takes the points, PaymentDevice bit 32).
// The new total goes to the camp as 0x3C80 {05, id, 03, u32 honor} (the
// honor refresh s:0x4e9ae0). The goods' honor prices come from the mall
// catalogue's NPC store prices (mall/honorgoods.go; cmd/server's -mall-csv,
// re-exported with its "npchonor" rows).

import (
	"context"
	"errors"
	"log/slog"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/shop"
)

// HonorLackReason is the honor refusal's words: the client's own text for
// UIIT_MSG_TC_LACK_HONOR_POINT, which it maps back to the key.
const HonorLackReason = "Selected item cannot be purchased due to insufficient amount of honor points."

// honorGoodsPrice is an item's honor price at an NPC store (0 none).
func honorGoodsPrice(itemID int64) int64 {
	return guildGoods.Load().HonorPrice(itemID)
}

// buyHonorGoods is a purchase of an item with an honor price: the gold test
// first, then the honor points (SpendHonor), the item bought inside it so a
// refused or failed buy spends none; then the camp's 0x3C80 05 field 3.
func buyHonorGoods(ctx context.Context, sess *gateway.Session, chars character.Store, svc *shop.Service,
	characterID, itemID int64, quantity int, honor int64) error {
	reply := func(r *ShopBuyResult) error {
		return sess.Send(&proto.Packet{Opcode: OpShopBuyResult, Data: r.Encode()})
	}
	item, err := svc.Items.GetItem(ctx, itemID)
	if err != nil {
		return reply(&ShopBuyResult{Reason: "no such item"})
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		return reply(&ShopBuyResult{Reason: "purchase failed"})
	}
	if c.Gold < shop.Price(item)*int64(quantity) {
		return reply(&ShopBuyResult{Reason: "insufficient gold"})
	}
	rt := academyRT.Load()
	if rt == nil {
		return reply(&ShopBuyResult{Reason: HonorLackReason})
	}
	total := int(honor) * quantity
	left, err := rt.Store.SpendHonor(ctx, characterID, total, func() error {
		return svc.Buy(ctx, characterID, itemID, quantity)
	})
	switch {
	case errors.Is(err, academy.ErrNotInCamp), errors.Is(err, academy.ErrHonorShort):
		return reply(&ShopBuyResult{Reason: HonorLackReason})
	case errors.Is(err, character.ErrInsufficientGold):
		return reply(&ShopBuyResult{Reason: "insufficient gold"})
	case err != nil:
		slog.Warn("honor goods: purchase failed", "character_id", characterID, "item", itemID, "err", err)
		return reply(&ShopBuyResult{Reason: "purchase failed"})
	}
	if camp := rt.campOf(ctx, characterID); camp != nil {
		rt.push(camp.ID, academy.EncodeFieldU32(characterID, academy.FieldHonor, uint32(left)), 0)
	}
	slog.Info("honor goods bought", "character_id", characterID, "item", itemID, "quantity", quantity, "honor", total)
	return reply(&ShopBuyResult{OK: true})
}
