package session

import "github.com/OpenSRO/srrevamp/server/internal/gateway"

// accountIDKey is the gateway.Session value key this package stores the
// authenticated account's ID under. Unexported: other packages should go
// through AuthenticatedAccountID, not poke at the session's value bag
// directly.
const accountIDKey = "session.account_id"

// authenticate marks sess as belonging to the given account ID, for
// handlers further down the chain (e.g. character selection) to check.
func authenticate(sess *gateway.Session, accountID int64) {
	sess.Set(accountIDKey, accountID)
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
