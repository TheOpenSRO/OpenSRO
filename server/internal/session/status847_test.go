package session

import (
	"context"
	"testing"
	"time"
)

// Round 847 lane B: "status effects ... linger even after it's been removed
// naturally or through pills". Every way a state ends tells the owner AND
// an observer at once, with the same empty mask: the expiry (one status
// pass past the state's time, never before), the universal pill, the
// purification pill, a death by the state's own tick, and a state renewed
// before its end (overwritten), which ends at the renewal's time and not the
// first one's. The clients end the looks from that one message (World3D
// _on_object_status -> SkillEffects._end_kept); a message that never came,
// or came late, would be what lingers. Aria is afflicted, Bram watches.

// endSeen reads c's packets for up to d and reports whether it was told
// owner's mask went to 0.
func endSeen(t *testing.T, c *strikeClient, owner int64, d time.Duration) bool {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		pkts, p := c.readUntil(t, OpObjectStatus, time.Until(deadline))
		if p == nil {
			return false
		}
		for _, st := range statusesIn(t, pkts) {
			if st.OwnerKind == OwnerCharacter && st.OwnerID == owner && st.Mask == 0 {
				return true
			}
		}
	}
	return false
}

// noEndYet reports whether c holds no end of owner's states up to a barrier.
func noEndYet(t *testing.T, c *strikeClient, owner int64) bool {
	t.Helper()
	for _, st := range statusesIn(t, c.barrier(t)) {
		if st.OwnerKind == OwnerCharacter && st.OwnerID == owner && st.Mask == 0 {
			return false
		}
	}
	return true
}

// afflict847 lands a state on Aria (the GM tool's path, /afflict) and drains
// both clients' copies of the new mask.
func afflict847(t *testing.T, z *strikeZone, a gmAfflict, code string, values ...int) {
	t.Helper()
	mask, err := a.Afflict(z.ariaChar, code, values)
	if err != nil || mask == 0 {
		t.Fatalf("/afflict %s %v: mask %#x, %v", code, values, mask, err)
	}
	for _, c := range []*strikeClient{z.aria, z.bram} {
		if _, p := c.readUntil(t, OpObjectStatus, time.Second); p == nil {
			t.Fatalf("%s was not told Aria's %s", c.name, code)
		}
	}
}

func startStatusEnds847(t *testing.T) (*statusRuntime, *strikeZone, gmAfflict) {
	t.Helper()
	fx := statusFXForTest(t)
	z := startStrikeZone(t)
	deps := strikeDeps{chars: z.chars, eq: z.eq, items: z.items, hub: z.hub}
	fx.mu.Lock()
	fx.sdeps = deps
	fx.mu.Unlock()
	return fx, z, gmAfflict{hub: z.hub, deps: deps}
}

func TestRound847ExpiryEndsForOwnerAndObserver(t *testing.T) {
	fx, z, a := startStatusEnds847(t)
	ctx := context.Background()
	t0 := time.Now()
	afflict847(t, z, a, "ps", 8, 100, 5) // poison for 8 x 1000 ms
	fx.step(ctx, t0.Add(7*time.Second))
	if !noEndYet(t, z.aria, z.ariaChar) || !noEndYet(t, z.bram, z.ariaChar) {
		t.Fatal("the poison was ended before its time")
	}
	fx.step(ctx, t0.Add(8200*time.Millisecond))
	if !endSeen(t, z.aria, z.ariaChar, time.Second) {
		t.Error("the owner was not told her poison expired")
	}
	if !endSeen(t, z.bram, z.ariaChar, time.Second) {
		t.Error("the observer was not told Aria's poison expired")
	}
}

func TestRound847UniversalPillEndsForOwnerAndObserver(t *testing.T) {
	fx, z, a := startStatusEnds847(t)
	afflict847(t, z, a, "bu", 30, 100, 5) // burn, 30 x 750 = 22.5 s
	rows := curePillRows()
	rule, _, _ := curePillRule(&rows[0]) // ITEM_ETC_CURE_ALL_01: 36 x 750 ms back
	fx.cureCharacter(z.hub, z.ariaChar, rule)
	if !endSeen(t, z.aria, z.ariaChar, time.Second) {
		t.Error("the owner was not told the universal pill ended her burn")
	}
	if !endSeen(t, z.bram, z.ariaChar, time.Second) {
		t.Error("the observer was not told the universal pill ended Aria's burn")
	}
}

func TestRound847PurificationPillEndsForOwnerAndObserver(t *testing.T) {
	fx, z, a := startStatusEnds847(t)
	afflict847(t, z, a, "dn", 30000, 100, 3) // dark, level 3, 30 s
	rows := curePillRows()
	rule, _, _ := curePillRule(&rows[1]) // ITEM_ETC_CURE_RANDOM_01: cap 3, chance 100
	fx.cureCharacter(z.hub, z.ariaChar, rule)
	if !endSeen(t, z.aria, z.ariaChar, time.Second) {
		t.Error("the owner was not told the purification pill ended her darkness")
	}
	if !endSeen(t, z.bram, z.ariaChar, time.Second) {
		t.Error("the observer was not told the purification pill ended Aria's darkness")
	}
}

func TestRound847DeathEndsForOwnerAndObserver(t *testing.T) {
	fx, z, a := startStatusEnds847(t)
	ctx := context.Background()
	c, _ := z.chars.GetByID(ctx, z.ariaChar)
	if _, _, err := z.chars.ApplyDamage(ctx, z.ariaChar, c.HP-1); err != nil {
		t.Fatal(err)
	}
	afflict847(t, z, a, "bl", 30000, 100, 1, 50, 0) // a bleeding tick of 50 on 1 HP: her death
	fx.step(ctx, time.Now().Add(2100*time.Millisecond))
	if !endSeen(t, z.aria, z.ariaChar, time.Second) {
		t.Error("the owner was not told her death ended her bleeding")
	}
	// It was her death (finishKill's end of her states, then the blow that
	// killed her, flagged as a status tick; flag off she is back up at once).
	if _, p := z.aria.readUntil(t, OpMonsterAttacked, time.Second); p == nil {
		t.Fatal("the bleeding tick did not kill Aria")
	}
	if !endSeen(t, z.bram, z.ariaChar, time.Second) {
		t.Error("the observer was not told Aria's death ended her bleeding")
	}
}

func TestRound847OverwrittenStateEndsAtTheRenewal(t *testing.T) {
	fx, z, a := startStatusEnds847(t)
	ctx := context.Background()
	t0 := time.Now()
	afflict847(t, z, a, "ps", 2, 100, 5)  // 2 s ...
	afflict847(t, z, a, "ps", 30, 100, 5) // ... renewed at once for 30 s
	fx.step(ctx, t0.Add(2500*time.Millisecond))
	if !noEndYet(t, z.aria, z.ariaChar) || !noEndYet(t, z.bram, z.ariaChar) {
		t.Fatal("the renewed poison ended at the first one's time")
	}
	fx.step(ctx, t0.Add(30500*time.Millisecond))
	if !endSeen(t, z.aria, z.ariaChar, time.Second) || !endSeen(t, z.bram, z.ariaChar, time.Second) {
		t.Error("the renewed poison's end did not reach the owner and the observer")
	}
}
