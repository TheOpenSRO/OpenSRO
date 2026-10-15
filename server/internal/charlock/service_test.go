package charlock

import (
	"context"
	"strings"
	"testing"
	"time"
)

// Round 788 (lane P): the PIN's rules, on an injectable clock.

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func newService(s Store, required bool) (*Service, *clock) {
	c := &clock{t: t0}
	return &Service{Store: s, Required: required, Now: c.now}, c
}

const devToken = "0123456789abcdef0123456789abcdef"

func TestValidPinAndToken(t *testing.T) {
	for pin, want := range map[string]bool{"1234": true, "0000": true, "123": false, "12345": false, "12a4": false, "": false, "１２３４": false} {
		if ValidPin(pin) != want {
			t.Errorf("ValidPin(%q) = %v", pin, !want)
		}
	}
	for tok, want := range map[string]bool{"": true, devToken: true, "short": false, strings.Repeat("a", MaxTokenLen+1): false, "0123456789abcdef 123": false} {
		if ValidToken(tok) != want {
			t.Errorf("ValidToken(%q) = %v", tok, !want)
		}
	}
}

func TestServiceCreateVerifyRemove(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		svc, _ := newService(s, false)
		if ok, _ := svc.Allows(ctx, 1, false); !ok {
			t.Fatal("no PIN, not required: refused")
		}
		if c, _ := svc.Verify(ctx, 1, "1234", false, ""); c != NoPin {
			t.Fatalf("verify with none: %d, want NoPin", c)
		}
		if c, _ := svc.Create(ctx, 1, "12a4"); c != BadFormat {
			t.Fatalf("create 12a4: %d, want BadFormat", c)
		}
		if c, _ := svc.Create(ctx, 1, "1234"); c != OK {
			t.Fatalf("create: %d", c)
		}
		if c, _ := svc.Create(ctx, 1, "5678"); c != PinExists {
			t.Fatalf("second create: %d, want PinExists", c)
		}
		if ok, _ := svc.Allows(ctx, 1, false); ok {
			t.Fatal("a PIN set, the session not unlocked: allowed")
		}
		if ok, _ := svc.Allows(ctx, 1, true); !ok {
			t.Fatal("unlocked session refused")
		}
		if c, _ := svc.Verify(ctx, 1, "1235", false, ""); c != WrongPin {
			t.Fatalf("wrong PIN: %d", c)
		}
		st, _, _ := svc.Query(ctx, 1, "", false)
		if !st.HasPin || st.Unlocked || st.AttemptsLeft != MaxFailures-1 || st.LockedFor != 0 {
			t.Fatalf("status after one wrong: %+v", st)
		}
		if c, _ := svc.Verify(ctx, 1, "1234", false, ""); c != OK {
			t.Fatalf("right PIN: %d", c)
		}
		if st, _, _ := svc.Query(ctx, 1, "", false); st.AttemptsLeft != MaxFailures {
			t.Fatalf("a right entry did not reset the count: %+v", st)
		}
		if c, _ := svc.Remove(ctx, 1, "9999"); c != WrongPin {
			t.Fatalf("remove with a wrong PIN: %d", c)
		}
		if c, _ := svc.Remove(ctx, 1, "1234"); c != OK {
			t.Fatalf("remove: %d", c)
		}
		if st, _, _ := svc.Query(ctx, 1, "", false); st.HasPin || !st.Unlocked {
			t.Fatalf("after remove: %+v", st)
		}
	})
}

func TestServiceRequired(t *testing.T) {
	ctx := context.Background()
	svc, _ := newService(NewMemStore(), true)
	if ok, _ := svc.Allows(ctx, 1, false); ok {
		t.Fatal("required and none set: allowed")
	}
	if ok, _ := svc.Allows(ctx, 1, true); ok {
		t.Fatal("required and none set: allowed even with the session flag")
	}
	st, _, _ := svc.Query(ctx, 1, "", false)
	if !st.Required || st.HasPin || st.Unlocked {
		t.Fatalf("status: %+v", st)
	}
	svc.Create(ctx, 1, "1111")
	if ok, _ := svc.Allows(ctx, 1, true); !ok {
		t.Fatal("required, set and unlocked: refused")
	}
}

// Five wrong entries lock for 30 minutes; the lock refuses even the right
// PIN, keeps across sessions (it is in the store, not the session), and ends
// at 30 minutes, with five fresh tries.
func TestServiceLockoutAndExpiry(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		svc, clk := newService(s, false)
		svc.Create(ctx, 1, "1234")
		for i := 1; i < MaxFailures; i++ {
			if c, _ := svc.Verify(ctx, 1, "0000", false, ""); c != WrongPin {
				t.Fatalf("wrong %d: %d", i, c)
			}
		}
		if c, _ := svc.Verify(ctx, 1, "0000", false, ""); c != Locked {
			t.Fatalf("wrong %d: %d, want Locked", MaxFailures, c)
		}
		clk.t = t0.Add(10 * time.Minute)
		if c, _ := svc.Verify(ctx, 1, "1234", false, ""); c != Locked {
			t.Fatalf("right PIN while locked: %d, want Locked", c)
		}
		if c, _ := svc.Remove(ctx, 1, "1234"); c != Locked {
			t.Fatalf("remove while locked: %d, want Locked", c)
		}
		// A second server process on the same store (a reconnect, a restart).
		other := &Service{Store: s, Now: clk.now}
		st, _, _ := other.Query(ctx, 1, "", false)
		if st.LockedFor != 20*time.Minute || st.AttemptsLeft != 0 {
			t.Fatalf("status 10 min in: %+v, want 20 min left", st)
		}
		clk.t = t0.Add(LockFor - time.Second)
		if c, _ := other.Verify(ctx, 1, "1234", false, ""); c != Locked {
			t.Fatalf("1 s before the end: %d, want Locked", c)
		}
		clk.t = t0.Add(LockFor)
		st, _, _ = other.Query(ctx, 1, "", false)
		if st.LockedFor != 0 || st.AttemptsLeft != MaxFailures {
			t.Fatalf("status at the end: %+v", st)
		}
		if c, _ := other.Verify(ctx, 1, "1234", false, ""); c != OK {
			t.Fatalf("after the lock: %d, want OK", c)
		}
	})
}

// A wrong remove counts on the same counter as a wrong verify.
func TestServiceRemoveCountsTowardTheLock(t *testing.T) {
	ctx := context.Background()
	svc, _ := newService(NewMemStore(), false)
	svc.Create(ctx, 1, "1234")
	for i := 0; i < MaxFailures-1; i++ {
		svc.Verify(ctx, 1, "0000", false, "")
	}
	if c, _ := svc.Remove(ctx, 1, "0000"); c != Locked {
		t.Fatalf("5th wrong entry by remove: %d, want Locked", c)
	}
}

func TestServiceRememberedDevice(t *testing.T) {
	eachStore(t, func(t *testing.T, s Store) {
		ctx := context.Background()
		svc, _ := newService(s, false)
		svc.Create(ctx, 1, "1234")
		if c, _ := svc.Verify(ctx, 1, "1234", true, ""); c != BadFormat {
			t.Fatalf("remember without a token: %d, want BadFormat", c)
		}
		if c, _ := svc.Verify(ctx, 1, "1234", true, devToken); c != OK {
			t.Fatalf("verify + remember: %d", c)
		}
		// The next login: the token unlocks without the PIN; another does not.
		st, unlocked, _ := svc.Query(ctx, 1, devToken, false)
		if !unlocked || !st.Unlocked {
			t.Fatalf("remembered PC not unlocked: %+v", st)
		}
		if _, unlocked, _ := svc.Query(ctx, 1, "fedcba9876543210fedcba9876543210", false); unlocked {
			t.Fatal("an unknown PC was unlocked")
		}
		// The stored value is the hash, not the token.
		rec, _ := s.Get(ctx, 1)
		for _, d := range rec.Devices {
			if string(d) == devToken {
				t.Fatal("the token itself is stored")
			}
		}
		// Removing the PIN, then setting one again, forgets the PC.
		svc.Remove(ctx, 1, "1234")
		svc.Create(ctx, 1, "5678")
		if _, unlocked, _ := svc.Query(ctx, 1, devToken, false); unlocked {
			t.Fatal("the PC is remembered after the PIN changed")
		}
	})
}
