package main

import (
	"context"
	"log/slog"
	"os"
	"strconv"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/specialty"
)

// loadSpecialty reads the specialty trade's tables (round 801) and installs
// them (session.SetSpecialtyDeps), starting the quotations' ten-minute
// recovery. It returns the stores' goods, which the NPC set needs for id 0xc.
func loadSpecialty(ctx context.Context, logger *slog.Logger, shopsCSV, quotesCSV, scale string, specialGoods bool,
	items session.ItemLookup, chars character.Store) specialty.Shops {
	var shops specialty.Shops
	if shopsCSV != "" {
		s, err := specialty.LoadShops(shopsCSV)
		if err != nil {
			logger.Error("loading the specialty stores", "path", shopsCSV, "err", err)
			os.Exit(1)
		}
		shops = s
		goods := 0
		for _, l := range s {
			goods += len(l)
		}
		logger.Info("specialty stores loaded", "path", shopsCSV, "stores", len(s), "goods", goods)
	} else {
		logger.Info("no specialty stores (-specialty-shops-csv / OPENSRO_SPECIALTY_SHOPS_CSV): no good can be bought")
	}
	var board *specialty.Board
	if quotesCSV != "" {
		rows, err := specialty.LoadQuotes(quotesCSV)
		if err != nil {
			logger.Error("loading the quotations", "path", quotesCSV, "err", err)
			os.Exit(1)
		}
		board = specialty.NewBoard(rows, func(item int64) int64 {
			if items == nil {
				return 0
			}
			it, err := items.GetItem(context.Background(), item)
			if err != nil || it == nil {
				return 0
			}
			return it.Price
		})
		logger.Info("quotations loaded", "path", quotesCSV, "rows", len(rows), "npcs", len(board.NPCs()))
	} else {
		logger.Info("no quotations (-quotation-csv / OPENSRO_QUOTATION_CSV): goods sell at their SellPrice")
	}
	th, err := parseThresholds(scale)
	if err != nil {
		logger.Error("-trade-scale", "value", scale, "err", err)
		os.Exit(1)
	}
	session.SetSpecialtyDeps(session.SpecialtyDeps{Board: board, Shops: shops, Thresholds: th,
		SpecialGoods: specialGoods, Items: items, Chars: chars, Logger: logger})
	if board != nil {
		go session.RunQuotationTick(ctx)
	}
	return shops
}

// parseThresholds reads "T1,T2,T3,T4".
func parseThresholds(s string) (specialty.Thresholds, error) {
	parts := strings.Split(s, ",")
	if len(parts) != 4 {
		return specialty.Thresholds{}, errBadThresholds
	}
	var t specialty.Thresholds
	for i, p := range parts {
		v, err := strconv.ParseUint(strings.TrimSpace(p), 10, 32)
		if err != nil {
			return specialty.Thresholds{}, err
		}
		t[i+1] = uint32(v)
	}
	return t, nil
}

type thresholdsError string

func (e thresholdsError) Error() string { return string(e) }

const errBadThresholds = thresholdsError("want four comma-separated bounds")
