package charlock

import (
	"context"
	"errors"
	"time"
)

// Code is a request's outcome on the wire (OURS, docs/protocol/pin.md).
type Code uint8

const (
	OK          Code = 0
	WrongPin    Code = 1 // the PIN did not match; the status says how many tries are left
	Locked      Code = 2 // too many wrong entries: the status says for how long
	PinExists   Code = 3 // create: the account has a PIN already
	NoPin       Code = 4 // verify, remove: the account has none
	BadFormat   Code = 5 // not PinLength digits, or a device token out of bounds
	NotLoggedIn Code = 6
	Failed      Code = 7 // the store failed
)

// Status is what the client is told about the account's lock.
type Status struct {
	HasPin   bool
	Required bool // the server requires a PIN (-require-pin)
	Unlocked bool // this session may start, delete and restore
	// AttemptsLeft before the lock; 0 while locked.
	AttemptsLeft int
	// LockedFor is how much of the lock is left; 0 when there is none.
	LockedFor time.Duration
}

// Service holds the rules over a Store. Required is the operator's
// -require-pin; Now is the clock (time.Now when nil).
type Service struct {
	Store    Store
	Required bool
	Now      func() time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// StatusOf is the status of an account for a session that has (unlocked) or
// has not passed the lock.
func (s *Service) StatusOf(rec Record, unlocked bool) Status {
	now := s.now()
	st := Status{HasPin: rec.HasPin(), Required: s.Required}
	st.Unlocked = s.passes(rec, unlocked)
	if rec.HasPin() {
		if rec.Locked(now) {
			st.LockedFor = rec.LockedUntil.Sub(now)
		} else {
			st.AttemptsLeft = max(MaxFailures-rec.Failures, 0)
		}
	}
	return st
}

// passes is the gate's rule: a session passes when it has unlocked the PIN,
// or when the account has none and the server does not require one.
func (s *Service) passes(rec Record, unlocked bool) bool {
	if rec.HasPin() {
		return unlocked
	}
	return !s.Required
}

// Allows reports whether a session (unlocked or not) may start, delete or
// restore a character on accountID. A store error does not allow (fails
// closed).
func (s *Service) Allows(ctx context.Context, accountID int64, unlocked bool) (bool, error) {
	rec, err := s.Store.Get(ctx, accountID)
	if err != nil {
		return false, err
	}
	return s.passes(rec, unlocked), nil
}

// Query answers the status request. A device token the account remembers
// unlocks the session (the returned bool) without the PIN -- even while the
// PIN is locked (OURS: the lock stops guessing, and a remembered PC guesses
// nothing; it also keeps a stranger's five wrong tries from shutting the
// owner out on their own PC).
func (s *Service) Query(ctx context.Context, accountID int64, token string, unlocked bool) (Status, bool, error) {
	rec, err := s.Store.Get(ctx, accountID)
	if err != nil {
		return Status{}, unlocked, err
	}
	if !unlocked && rec.HasPin() && ValidToken(token) && rec.Remembers(HashToken(token)) {
		unlocked = true
	}
	return s.StatusOf(rec, unlocked), unlocked, nil
}

// Create sets a PIN on an account with none. The session that set it is
// unlocked by it (the caller marks it).
func (s *Service) Create(ctx context.Context, accountID int64, pin string) (Code, error) {
	if !ValidPin(pin) {
		return BadFormat, nil
	}
	hash, err := HashPin(pin)
	if err != nil {
		return Failed, err
	}
	switch err := s.Store.SetPin(ctx, accountID, hash); {
	case errors.Is(err, ErrPinExists):
		return PinExists, nil
	case err != nil:
		return Failed, err
	}
	return OK, nil
}

// check is the PIN test both Verify and Remove make: locked, wrong (counted;
// the MaxFailures-th locks), or right (the count goes back to 0).
func (s *Service) check(ctx context.Context, accountID int64, pin string) (Code, error) {
	if !ValidPin(pin) {
		return BadFormat, nil
	}
	rec, err := s.Store.Get(ctx, accountID)
	if err != nil {
		return Failed, err
	}
	if !rec.HasPin() {
		return NoPin, nil
	}
	now := s.now()
	if rec.Locked(now) {
		return Locked, nil
	}
	if !PinMatches(rec.PinHash, pin) {
		_, until, err := s.Store.RecordFailure(ctx, accountID, MaxFailures, now.Add(LockFor))
		if err != nil {
			return Failed, err
		}
		if !until.IsZero() && now.Before(until) {
			return Locked, nil
		}
		return WrongPin, nil
	}
	if rec.Failures > 0 {
		if err := s.Store.ResetFailures(ctx, accountID); err != nil {
			return Failed, err
		}
	}
	return OK, nil
}

// Verify tests the PIN; on OK the caller unlocks the session, and with
// remember set the device token's hash is kept for the account.
func (s *Service) Verify(ctx context.Context, accountID int64, pin string, remember bool, token string) (Code, error) {
	if remember && (token == "" || !ValidToken(token)) {
		return BadFormat, nil
	}
	code, err := s.check(ctx, accountID, pin)
	if code != OK || err != nil {
		return code, err
	}
	if remember {
		if err := s.Store.RememberDevice(ctx, accountID, HashToken(token), s.now()); err != nil {
			return Failed, err
		}
	}
	return OK, nil
}

// Remove takes the PIN off the account, given the PIN (a wrong one counts as
// a wrong entry, the same counter as Verify's). Every remembered PC goes with
// it.
func (s *Service) Remove(ctx context.Context, accountID int64, pin string) (Code, error) {
	code, err := s.check(ctx, accountID, pin)
	if code != OK || err != nil {
		return code, err
	}
	switch err := s.Store.ClearPin(ctx, accountID); {
	case errors.Is(err, ErrNoPin):
		return NoPin, nil
	case err != nil:
		return Failed, err
	}
	return OK, nil
}
