// Package friend implements this project's own friends list: persistent
// (unlike party/duel/trade -- a friendship should survive a relog or
// server restart) mutual relationships formed via request/accept, plus
// pending incoming requests. The request/accept SHAPE is own design; the list's
// size limit is not -- see MaxFriends.
//
// CORRECTED 2026-09-16: this said "Entirely own design; no real friends-list
// data to RE." The second half was an unchecked claim. The server has a friend
// system with its own error codes, and one of them gave up a number.
package friend

import (
	"context"
	"errors"
)

// MaxFriends is the most friends one character may have: **20**, RECOVERED.
//
// FUN_005d7620 handles a friend request and checks the list before growing it:
//
//	5d7734  mov ax,0x6409                   <- FRIENDERR_ALREADYFRIEND, just above
//	5d7746  cmp DWORD PTR [esi+0x14],0x14   <- the friend count, against 20
//	5d774a  jb  ok                          <- strictly fewer than 20 may add
//	5d775d  mov ax,0x6408                   <- else FRIENDERR_FULLLIST
//
// The code is named by the client (docs/protocol/error_codes.md), which is what
// ties `[esi+0x14]` to the friend list rather than to some other count: the
// comparison sits between an ALREADYFRIEND check and a FULLLIST refusal.
//
// A FRIENDSHIP IS MUTUAL, so accepting grows BOTH lists and both are checked
// here. The engine has a separate `0x640f FRIENDERR_TARGETLISTFULL` for the
// other side, but **the server never returns it** -- `0x640f` appears nowhere in
// its .text -- so where the engine enforces the target's limit is not
// established. OpenSRO checks both because it adds to both; that is the
// conservative reading rather than a claim about where the engine checks.
const MaxFriends = 20

// ErrListFull is returned when a friendship would push either character past
// MaxFriends. The engine's own refusal is UIIT_MSG_FRIENDERR_FULLLIST.
var ErrListFull = errors.New("friend: friend list is full")

// ErrCannotFriendSelf is returned by Store.SendRequest when fromID and
// toID are the same character.
var ErrCannotFriendSelf = errors.New("friend: cannot friend yourself")

// ErrAlreadyFriends is returned by Store.SendRequest when the two
// characters are already friends.
var ErrAlreadyFriends = errors.New("friend: already friends")

// ErrRequestAlreadySent is returned by Store.SendRequest when fromID
// already has a pending request to toID.
var ErrRequestAlreadySent = errors.New("friend: request already sent")

// ErrNoSuchRequest is returned by Store.AcceptRequest/DeclineRequest when
// there's no matching pending request.
var ErrNoSuchRequest = errors.New("friend: no such request")

// ErrNotFriends is returned by Store.RemoveFriend when the two characters
// aren't friends.
var ErrNotFriends = errors.New("friend: not friends")

// Friend is one entry in a character's friends list.
type Friend struct {
	CharacterID int64
	Name        string
}

// Request is one pending incoming friend request.
type Request struct {
	RequesterID   int64
	RequesterName string
}

// Store persists friend requests and friendships.
type Store interface {
	// SendRequest records that fromID (named fromName) wants to befriend
	// toID. Returns ErrCannotFriendSelf, ErrAlreadyFriends, or
	// ErrRequestAlreadySent as appropriate.
	SendRequest(ctx context.Context, fromID int64, fromName string, toID int64) error

	// AcceptRequest accepts the pending request from requesterID addressed
	// to characterID (named characterName, needed to store the reciprocal
	// friendship entry on the requester's side), forming a mutual
	// friendship. Returns ErrNoSuchRequest if there's nothing pending.
	AcceptRequest(ctx context.Context, characterID int64, characterName string, requesterID int64) error

	// DeclineRequest removes the pending request from requesterID
	// addressed to characterID without forming a friendship. Returns
	// ErrNoSuchRequest if there's nothing pending.
	DeclineRequest(ctx context.Context, characterID, requesterID int64) error

	// ListFriends returns characterID's full friends list.
	ListFriends(ctx context.Context, characterID int64) ([]Friend, error)

	// ListPendingRequests returns every incoming request addressed to
	// characterID that hasn't been accepted or declined yet.
	ListPendingRequests(ctx context.Context, characterID int64) ([]Request, error)

	// RemoveFriend ends the friendship between characterID and friendID
	// (both directions). Returns ErrNotFriends if they weren't friends.
	RemoveFriend(ctx context.Context, characterID, friendID int64) error
}
