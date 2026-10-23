package main

import (
	"flag"
	"log/slog"
	"os"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charlock"
	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// The account PIN, "Character Lock" (round 788, lane P; OURS throughout --
// docs/protocol/pin.md). Kept out of main's long flag block so the lanes that
// touch main.go meet on two lines only.

var requirePinEnv, requirePinEnvErr = envBool("OPENSRO_REQUIRE_PIN")

var requirePin = flag.Bool("require-pin", requirePinEnv,
	"require an account PIN (env OPENSRO_REQUIRE_PIN): a player with none must set one at character "+
		"select before starting, deleting or restoring a character. Default OFF: the PIN is the "+
		"player's choice. A retail client has no PIN window, so with this on it cannot start a "+
		"character at all. See deploy/README.md, \"Account PIN (Character Lock)\".")

// characterLock opens the PIN's store beside the accounts -- the accounts'
// own database when they are on one, memory otherwise -- and returns the
// rules over it. The process exits when the database cannot be prepared.
func characterLock(accounts account.Store, logger *slog.Logger) *charlock.Service {
	if requirePinEnvErr != nil {
		logger.Warn("OPENSRO_REQUIRE_PIN is not a boolean; the PIN is optional unless -require-pin is given", "err", requirePinEnvErr)
	}
	var store charlock.Store
	if t, ok := accounts.(txn.TxDBer); ok && t.TxDB() != nil {
		s, err := charlock.NewSQLStore(t.TxDB())
		if err != nil {
			logger.Error("opening the account PIN store", "error", err)
			os.Exit(1)
		}
		store = s
	} else {
		store = charlock.NewMemStore()
	}
	logger.Info("account PIN (character lock)", "required", *requirePin,
		"lock_after", charlock.MaxFailures, "lock_for", charlock.LockFor)
	return &charlock.Service{Store: store, Required: *requirePin}
}
