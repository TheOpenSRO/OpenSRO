package main

import (
	"context"
	"log/slog"
	"os"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
)

// loadMall reads -mall-csv (round 837): the silk shop registry from the
// operator's own archive (cmd/export-refdata -mode mall). Without it no shop
// is registered and every buy is refused 2, as retail refuses a group it did
// not register.
func loadMall(logger *slog.Logger, path string) *mall.Catalogue {
	if path == "" {
		logger.Info("no item mall catalogue (-mall-csv / OPENSRO_MALL_CSV): every mall buy is refused")
		return nil
	}
	cat, err := mall.LoadCSV(path)
	if err != nil {
		logger.Error("loading the item mall catalogue", "path", path, "err", err)
		os.Exit(1)
	}
	n := cat.Count()
	logger.Info("item mall catalogue loaded", "path", path, "groups", n.Groups, "shops", n.Shops, "tabs", n.Tabs,
		"goods", n.Goods, "packages", n.Packages)
	return cat
}

// silkStoreOf is the account store's silk balances (round 837), with the
// starting grant set; nil when the store keeps none.
func silkStoreOf(logger *slog.Logger, accounts account.Store, starting int64) account.SilkStore {
	s, ok := accounts.(account.SilkStore)
	if !ok {
		logger.Warn("the account store keeps no silk: the item mall cannot sell")
		return nil
	}
	if g, ok := accounts.(interface{ SetStartingSilk(int64) }); ok && starting > 0 {
		g.SetStartingSilk(starting)
		logger.Info("starting silk on (OURS): each account is given it once", "silk", starting)
	}
	return s
}

// pruneTakeLog keeps the item chest's take log to mall.TakeLogDays (OURS).
func pruneTakeLog(ctx context.Context, logger *slog.Logger, st mall.Store) {
	if st == nil {
		return
	}
	t := time.NewTicker(time.Hour)
	defer t.Stop()
	for {
		before := time.Now().AddDate(0, 0, -mall.TakeLogDays)
		if n, err := st.PruneTakeLog(ctx, before); err != nil {
			logger.Warn("pruning the chest's take log", "err", err)
		} else if n > 0 {
			logger.Info("pruned the chest's take log", "rows", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
