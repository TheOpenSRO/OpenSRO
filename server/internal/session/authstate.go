package session

import "github.com/OpenSRO/OpenSRO/server/internal/gateway"

// accountIDKey is the gateway.Session value key this package stores the
// authenticated account's ID under. Unexported: other packages should go
// through AuthenticatedAccountID, not poke at the session's value bag
// directly.
const accountIDKey = "session.account_id"

// accountUsernameKey holds the authenticated account's username, exactly as
// the account store has it. The GM gate (gm.go) is a list of usernames, so
// the name has to be at hand when a command arrives, and the account Store
// interface has no by-id lookup to fetch it then.
const accountUsernameKey = "session.account_username"

// authenticate marks sess as belonging to the given account, for handlers
// further down the chain (e.g. character selection) to check.
func authenticate(sess *gateway.Session, accountID int64, username string) {
	sess.Set(accountIDKey, accountID)
	sess.Set(accountUsernameKey, username)
}

// AuthenticatedAccountID returns the account ID a previous OpLogin on this
// connection authenticated, if any.
func AuthenticatedAccountID(sess *gateway.Session) (int64, bool) {
	v, ok := sess.Get(accountIDKey)
	if !ok {
		return 0, false
	}
	id, ok := v.(int64)
	return id, ok
}

// AuthenticatedUsername returns the username a previous OpLogin on this
// connection authenticated, if any.
func AuthenticatedUsername(sess *gateway.Session) (string, bool) {
	v, ok := sess.Get(accountUsernameKey)
	if !ok {
		return "", false
	}
	name, ok := v.(string)
	return name, ok
}
