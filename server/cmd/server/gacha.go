package main

import (
	"log/slog"
	"os"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gacha"
)

// loadGacha reads -gacha-csv (round 838): the Magic POP tables from the
// operator's own archive (cmd/export-refdata -mode gacha). Without it no NPC is
// a machine (no interaction 0x11) and every draw is refused.
func loadGacha(logger *slog.Logger, path string) *gacha.Table {
	if path == "" {
		logger.Info("no Magic POP tables (-gacha-csv / OPENSRO_GACHA_CSV): no NPC offers the game")
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		logger.Error("opening the Magic POP tables", "path", path, "err", err)
		os.Exit(1)
	}
	defer f.Close()
	t, err := gacha.ReadCSV(f)
	if err != nil {
		logger.Error("loading the Magic POP tables", "path", path, "err", err)
		os.Exit(1)
	}
	rows, machines := t.Len()
	logger.Info("Magic POP tables loaded", "path", path, "rows", rows, "machines", machines)
	return t
}
