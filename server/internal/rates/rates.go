// Package rates holds the server's configurable gain multipliers, recovered
// from the game server's own config loader rather than invented.
//
// CMainProcess::FUN_00427050 reads a block of named knobs at startup and turns
// each into a float multiplier. Every one follows the same three-step shape:
//
//	value = atol(configString) / 100.0     // the setting is a PERCENTAGE
//	if (value < 1.0)  value = 1.0          // "system default" branch
//	if (value >= cap) value = cap          // clamped at a per-knob ceiling
//
// so a setting of 100 means 1x, 250 means 2.5x, and anything below 100 is
// ignored in favour of 1x. The four gain globals are also statically
// initialised to 0x3f800000 (1.0f) before the config is read, which is an
// independent confirmation of the default. (HwanGainFactor is the exception,
// below.)
//
// **Rates below 1x are impossible.** The floor is not a clamp on bad input, it
// is the engine's design: the `< 1.0` branch is the one that logs
// "<knob>: system default". A server cannot be configured slower than retail.
//
// The knob names below are the game's own strings, and the caps are the
// constants each comparison loads (all `fld DWORD`, so float32):
//
//	ExpRatio            cap 2.5   (0xb45b90)   -> 0xc82518
//	ExpRatioParty       cap 2.5   (0xb45b90)   -> 0xc8251c
//	DropItemRatio       cap 3.0   (0xb45b84)   -> 0xc82520
//	DropGoldAmountCoef  cap 2.5   (0xb45b90)   -> 0xc82524
//	HwanGainFactor      cap 10.0  (0xb45b44)   -> 0xc82528
//
// The same loader reads three more (round 258): PCSpeedRatio (0xc8253c, cap
// 3.0, multiplies the player's speed params in GObjPC_InitStats when it is not
// 1), MONSTER_AGGRO_LINK_DECREASE_RATIO (0xc8252c, default 0.5 with no floor;
// ai.AggroLinkDecreaseRatio) and GiantMonster_SpawnRatio (0xc82538, u16, 0 ->
// 14), plus boolean switches.
//
// HwanGainFactor is a knob with no consumer. Its pre-config value is 100.0
// (0xb45e10), which the clamp turns into 10.0, and NO instruction outside the
// loader reads 0xc82528 -- the berserk earn (internal/berserk) never multiplies
// by it. It is kept here as the engine's own vocabulary; nothing applies it,
// and nothing should.
//
// OpenSRO reads them from the environment, since that is how this server is
// already configured (OPENSRO_LEVELDATA_CSV and friends), under the game's own
// names with an OPENSRO_ prefix.
package rates

import (
	"os"
	"strconv"
	"sync"
)

// The per-knob ceilings, each read out of the comparison in the config loader.
const (
	MaxExpRatio       = 2.5
	MaxPartyExpRatio  = 2.5
	MaxDropItemRatio  = 3.0
	MaxGoldRatio      = 2.5
	MaxHwanGainFactor = 10.0

	// MinRatio is the floor every knob shares. It is the "system default"
	// branch, not an input guard: a value below it is replaced by it.
	MinRatio = 1.0
)

// Rates is one resolved set of multipliers.
type Rates struct {
	// Exp multiplies a kill's experience for a character NOT in a party.
	Exp float64
	// PartyExp multiplies it for a character who IS in a party. The engine
	// picks one or the other -- `fVar1 = ExpRatio; if (pc[0x72e] != 0) fVar1 =
	// ExpRatioParty;` in GObjPC_ReceiveKillReward -- so they are alternatives
	// and are never multiplied together.
	PartyExp float64
	// DropItem multiplies drop chances. Carried for completeness; OpenSRO's
	// loot is still its own table, so nothing applies this yet.
	DropItem float64
	// Gold multiplies a kill's gold.
	Gold float64
	// HwanGain is the HwanGainFactor knob. The engine loads it and never
	// reads it (see the package comment), so nothing applies it here either.
	HwanGain float64
}

// Default is every knob at 1x -- what the engine uses before any config is
// read, and what it falls back to for an unset or too-small setting.
func Default() Rates {
	return Rates{Exp: 1, PartyExp: 1, DropItem: 1, Gold: 1, HwanGain: 1}
}

// resolve applies the engine's own three steps to one raw setting.
func resolve(raw string, cap float64) float64 {
	if raw == "" {
		return MinRatio
	}
	// The engine uses atol, which stops at the first non-digit and yields 0
	// for nonsense -- and 0/100 is below the floor, so nonsense lands on the
	// default. ParseInt's error path reaches the same place.
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil {
		return MinRatio
	}
	v := float64(n) / 100
	if v < MinRatio {
		return MinRatio
	}
	if v >= cap {
		return cap
	}
	return v
}

// FromEnv resolves every knob from the environment, under the game's own names
// with an OPENSRO_ prefix. Unset, malformed and too-small values all resolve to
// 1x, exactly as the engine's "system default" branch does.
func FromEnv() Rates {
	return Rates{
		Exp:      resolve(os.Getenv("OPENSRO_EXP_RATIO"), MaxExpRatio),
		PartyExp: resolve(os.Getenv("OPENSRO_EXP_RATIO_PARTY"), MaxPartyExpRatio),
		DropItem: resolve(os.Getenv("OPENSRO_DROP_ITEM_RATIO"), MaxDropItemRatio),
		Gold:     resolve(os.Getenv("OPENSRO_DROP_GOLD_AMOUNT_COEF"), MaxGoldRatio),
		HwanGain: resolve(os.Getenv("OPENSRO_HWAN_GAIN_FACTOR"), MaxHwanGainFactor),
	}
}

var (
	mu      sync.RWMutex
	current = Default()
)

// Current returns the live rates. Safe for concurrent use.
func Current() Rates {
	mu.RLock()
	defer mu.RUnlock()
	return current
}

// Set replaces the live rates. Called once at startup; exported so tests can
// drive a specific set without touching the environment.
func Set(r Rates) {
	mu.Lock()
	defer mu.Unlock()
	current = r
}

// ExpFor returns the multiplier a kill's experience takes, choosing between the
// solo and party knobs the way GObjPC_ReceiveKillReward does.
func (r Rates) ExpFor(inParty bool) float64 {
	if inParty {
		return r.PartyExp
	}
	return r.Exp
}
