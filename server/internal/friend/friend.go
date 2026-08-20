// Package friend implements this project's own friends list: persistent
// (unlike party/duel/trade -- a friendship should survive a relog or
// server restart) mutual relationships formed via request/accept, plus
// pending incoming requests. Entirely own design; no real friends-list
// data to RE.
package friend

import (
	"context"
	"errors"
)

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
