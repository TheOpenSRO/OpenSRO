// Package charlock is the account PIN, "Character Lock" (round 788, lane P).
//
// The whole feature is OURS. The retail game has no PIN of any kind (READ,
// round 788's research: no layout, art, text key or opcode in the client, and
// nothing in Gateway, Agent, Shard or Game server); this one is modelled on a
// private server's addon the user showed (a window titled "Character Lock", 4
// digits on a 3x4 keypad, "Remove Pin", "Remember this PC and don't ask for
// pin"). docs/protocol/pin.md has the rules and the wire.
//
// The user's decisions (2026-10-15), which this package implements:
//   - per ACCOUNT, asked at character select once per login, the first time
//     the player starts, deletes or restores a character;
//   - optional; an operator flag can require it;
//   - 4 digits;
//   - after MaxFailures wrong entries the account's PIN is locked for LockFor,
//     across every login, persisted;
//   - "Remember this PC": a random device token the client keeps; the server
//     keeps a hash of it per account; changing or removing the PIN forgets
//     every remembered PC.
package charlock

import (
	"context"
	"crypto/sha256"
	"errors"
	"time"

	"golang.org/x/crypto/bcrypt"
)

// The rules (OURS, the user's decisions).
const (
	// PinLength is the PIN's digit count.
	PinLength = 4
	// MaxFailures wrong entries in a row lock the PIN.
	MaxFailures = 5
	// LockFor is how long the lock lasts.
	LockFor = 30 * time.Minute
	// MaxDevices is how many remembered PCs an account keeps; remembering
	// one more forgets the oldest (OURS: a bound, so a client cannot grow
	// the list without end).
	MaxDevices = 16
	// MinTokenLen and MaxTokenLen bound a device token in bytes (OURS). Our
	// client sends 64 hex characters (32 random bytes).
	MinTokenLen = 16
	MaxTokenLen = 128
)

// ErrPinExists is SetPin's answer for an account that already has a PIN.
var ErrPinExists = errors.New("charlock: the account already has a PIN")

// ErrNoPin is ClearPin's answer for an account with none.
var ErrNoPin = errors.New("charlock: the account has no PIN")

// Record is one account's lock state. The zero Record is an account with no
// PIN.
type Record struct {
	// PinHash is the bcrypt hash of the PIN; nil when there is none.
	PinHash []byte
	// Failures counts wrong entries since the last right one or the last
	// lock.
	Failures int
	// LockedUntil is when the lock ends; zero when there is none. A time in
	// the past is no lock.
	LockedUntil time.Time
	// Devices are the SHA-256 hashes of the remembered PCs' tokens.
	Devices [][]byte
}

// HasPin reports whether the account has a PIN.
func (r Record) HasPin() bool { return len(r.PinHash) > 0 }

// Locked reports whether the PIN is locked at now.
func (r Record) Locked(now time.Time) bool {
	return !r.LockedUntil.IsZero() && now.Before(r.LockedUntil)
}

// Remembers reports whether a token's hash is on the account's list.
func (r Record) Remembers(tokenHash []byte) bool {
	if len(tokenHash) == 0 {
		return false
	}
	for _, d := range r.Devices {
		if string(d) == string(tokenHash) {
			return true
		}
	}
	return false
}

// Store keeps the lock state per account. MemStore and SQLStore are both.
type Store interface {
	// Get returns accountID's record; the zero Record when it has none.
	Get(ctx context.Context, accountID int64) (Record, error)
	// SetPin stores a PIN hash for an account with none, clearing failures,
	// the lock and the remembered PCs. ErrPinExists when it has one.
	SetPin(ctx context.Context, accountID int64, hash []byte) error
	// ClearPin removes the PIN, failures, the lock and every remembered PC.
	// ErrNoPin when there is none.
	ClearPin(ctx context.Context, accountID int64) error
	// RecordFailure counts one wrong entry as one atomic step: the count
	// grows by one, and when it reaches max it goes back to 0 and the PIN is
	// locked until `until`. It returns the count and the lock end after it;
	// ErrNoPin when the account has no PIN.
	RecordFailure(ctx context.Context, accountID int64, max int, until time.Time) (int, time.Time, error)
	// ResetFailures sets the count back to 0 (a right entry).
	ResetFailures(ctx context.Context, accountID int64) error
	// RememberDevice adds a token hash to the account's list (a no-op when
	// it is there), keeping at most MaxDevices, the newest.
	RememberDevice(ctx context.Context, accountID int64, tokenHash []byte, now time.Time) error
}

// HashPin hashes a PIN for storage (bcrypt, the account password's own
// scheme). OURS, and worth saying plainly: a 4-digit PIN has 10,000 values,
// so a stolen hash falls to an offline search whatever the hash; the PIN's
// strength is the online lockout, not the hash.
func HashPin(pin string) ([]byte, error) {
	return bcrypt.GenerateFromPassword([]byte(pin), bcrypt.DefaultCost)
}

// PinMatches reports whether pin is the one hash was made from.
func PinMatches(hash []byte, pin string) bool {
	return len(hash) > 0 && bcrypt.CompareHashAndPassword(hash, []byte(pin)) == nil
}

// HashToken is what is stored for a device token: SHA-256 (OURS). The token
// is 32 random bytes, so a fast hash is enough: there is nothing to search.
func HashToken(token string) []byte {
	if token == "" {
		return nil
	}
	h := sha256.Sum256([]byte(token))
	return h[:]
}

// ValidPin reports whether s is exactly PinLength ASCII digits.
func ValidPin(s string) bool {
	if len(s) != PinLength {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// ValidToken reports whether a device token is one the server keeps: empty
// (none) or MinTokenLen..MaxTokenLen printable ASCII bytes.
func ValidToken(s string) bool {
	if s == "" {
		return true
	}
	if len(s) < MinTokenLen || len(s) > MaxTokenLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x21 || s[i] > 0x7e {
			return false
		}
	}
	return true
}
