// Package friend keeps the friends list: persistent (unlike
// party/duel/trade -- a friendship survives a relog or a server restart)
// mutual friendships. Round 834 put the request on retail's wire and rules
// (session/friend.go, docs/protocol/friends.md); before it the request
// was OpenSRO's own, stored until answered.
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
// A FRIENDSHIP IS MUTUAL, so accepting grows BOTH lists and both are checked.
// CORRECTED in round 834: this said the server never returns `0x640f
// FRIENDERR_TARGETLISTFULL`. True of the GameServer alone; the ShardManager
// returns it for the target's full list (sm:0x447770), and checks both lists
// again at the accept (sm:0x447320). docs/protocol/friends.md, 2 and 3.2.
const MaxFriends = 20

// ErrListFull is returned when a friendship would push either character past
// MaxFriends. The engine's own refusal is UIIT_MSG_FRIENDERR_FULLLIST.
var ErrListFull = errors.New("friend: friend list is full")

// ErrCannotFriendSelf is returned by Store.AddFriendship when both ids are
// the same character.
var ErrCannotFriendSelf = errors.New("friend: cannot friend yourself")

// ErrAlreadyFriends is returned by Store.AddFriendship when the two
// characters are already friends.
var ErrAlreadyFriends = errors.New("friend: already friends")

// ErrNotFriends is returned by Store.RemoveFriend when the two characters
// aren't friends.
var ErrNotFriends = errors.New("friend: not friends")

// Friend is one entry in a character's friends list.
type Friend struct {
	CharacterID int64
	Name        string
}

// Store persists friendships. Round 834: the request is retail's, a live
// 30-second wait the session holds (session/friend.go,
// docs/protocol/friends.md 3.2), not a stored row, so the store keeps only
// the friendships -- retail's `_Friend` table, written by `_Friend_Add` /
// `_Friend_Remove` for both sides at once.
type Store interface {
	// AddFriendship makes a and b friends, both ways, in one step:
	// ErrCannotFriendSelf, ErrAlreadyFriends when either already lists the
	// other, ErrListFull when either list holds MaxFriends.
	AddFriendship(ctx context.Context, aID int64, aName string, bID int64, bName string) error

	// ListFriends returns characterID's full friends list.
	ListFriends(ctx context.Context, characterID int64) ([]Friend, error)

	// RemoveFriend ends the friendship between characterID and friendID
	// (both directions). Returns ErrNotFriends if they weren't friends.
	RemoveFriend(ctx context.Context, characterID, friendID int64) error
}
