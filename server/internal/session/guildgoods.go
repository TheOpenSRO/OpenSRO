package session

// Round 844 lane G (part 2): buying the guild store's goods, which cost gold
// AND the guild's GP (READ: CheckCurrencyRequirement s:0x617360 -- gold short
// 0x180f first, then no guild or not the master 0x18c4
// UIIT_MSG_GUILD_STORE_BUY_LIMIT, the guild short of GP 0x18c5
// UIIT_MSG_GUILD_LACK_GP; the payment s:0x618930 takes the gold, the job the
// GP; the GP history logs it as "Guild Item Purchases", kind 6, s:0x4e9bce).
// The goods' GP prices come from the mall catalogue's NPC store prices
// (mall/guildgoods.go; cmd/server's -mall-csv, re-exported).

import (
	"context"
	"errors"
	"log/slog"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/shop"
)

var guildGoods atomic.Pointer[mall.Catalogue]

// SetGuildGoodsCatalogue names the catalogue whose NPC GP prices the shop
// charges (nil: no good costs GP).
func SetGuildGoodsCatalogue(c *mall.Catalogue) { guildGoods.Store(c) }

// guildGoodsGP is an item's GP price at an NPC store (0 none).
func guildGoodsGP(itemID int64) int64 {
	return guildGoods.Load().GPPrice(itemID)
}

// The refusals' words: the client's own texts (UIIT_MSG_GUILD_STORE_BUY_LIMIT,
// UIIT_MSG_GUILD_LACK_GP; the client maps them back to the keys).
const (
	GuildStoreBuyLimitReason = "You are not qualified to purchase the item."
	GuildStoreLackGPReason   = "Item cannot be purchased due to lack of guild points."
)

// buyGuildGoods is a purchase of an item with a GP price: the gold test
// first, then the guild's (SpendPoints), the item bought inside it so a
// refused or failed buy spends no GP; then the members' GP (0x38F5 type 5
// mask 8, OURS: the ShardManager's echo is OPEN) and the GP history.
func buyGuildGoods(ctx context.Context, sess *gateway.Session, chars character.Store, svc *shop.Service,
	characterID, itemID int64, quantity int, gp int64) error {
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
	d := guildOps.Load()
	var spender guild.GPSpendStore
	if d != nil {
		spender, _ = d.guilds.(guild.GPSpendStore)
	}
	if spender == nil {
		return reply(&ShopBuyResult{Reason: GuildStoreBuyLimitReason})
	}
	total := gp * int64(quantity)
	g, err := spender.SpendPoints(ctx, characterID, total, func() error {
		return svc.Buy(ctx, characterID, itemID, quantity)
	})
	switch {
	case errors.Is(err, guild.ErrGuildStoreNotMaster):
		return reply(&ShopBuyResult{Reason: GuildStoreBuyLimitReason})
	case errors.Is(err, guild.ErrGuildStoreLackGP):
		return reply(&ShopBuyResult{Reason: GuildStoreLackGPReason})
	case errors.Is(err, character.ErrInsufficientGold):
		return reply(&ShopBuyResult{Reason: "insufficient gold"})
	case err != nil:
		slog.Warn("guild goods: purchase failed", "character_id", characterID, "item", itemID, "err", err)
		return reply(&ShopBuyResult{Reason: "purchase failed"})
	}
	if d != nil {
		d.toMembers(g, guild.OpUpdate, guild.EncodeGuildFields(guild.GuildFieldGP, g), 0)
	}
	logGPUse(ctx, d.guilds, g.ID, c.Name, total, guild.GPUseGuildItem)
	slog.Info("guild goods bought", "guild_id", g.ID, "character_id", characterID, "item", itemID, "quantity", quantity, "gp", total)
	return reply(&ShopBuyResult{OK: true})
}
