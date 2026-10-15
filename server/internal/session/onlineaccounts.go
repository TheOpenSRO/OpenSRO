package session

import (
	"net"
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
)

// OnlineAccounts is the server's table of logged-in accounts (round 788):
// one live session per account, with the address it came from. It is what
// GlobalManager's logged-in user table is to retail (READ, GlobalManager
// 0x401b70 -> 0x402220: a JID found there refuses the new login with error 1,
// 0xA102 [2,3]; the per-IP count behind MaxUserForNonePCBangIP is error 2,
// [2,8]). A session is entered when its login succeeds and leaves when it
// ends (LoginService.SessionEnded, from the gateway's OnDisconnect).
type OnlineAccounts struct {
	mu        sync.Mutex
	byAccount map[int64]onlineEntry
	bySession map[uint64]int64
}

type onlineEntry struct {
	sess *gateway.Session
	ip   string
}

// admitResult is what a login's admission found.
type admitResult int

const (
	admitted admitResult = iota
	admitDuplicate
	admitIPLimit
)

// NewOnlineAccounts returns an empty table.
func NewOnlineAccounts() *OnlineAccounts {
	return &OnlineAccounts{byAccount: map[int64]onlineEntry{}, bySession: map[uint64]int64{}}
}

// check reports whether accountID may come in from ip now: not already
// online, and fewer than maxPerIP sessions from ip (maxPerIP 0: no limit;
// an unknown ip "" is never limited). The order is GlobalManager's
// (0x401b70: the duplicate first, then the IP count).
func (o *OnlineAccounts) check(accountID int64, ip string, maxPerIP int) admitResult {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.checkLocked(accountID, ip, maxPerIP)
}

func (o *OnlineAccounts) checkLocked(accountID int64, ip string, maxPerIP int) admitResult {
	if _, on := o.byAccount[accountID]; on {
		return admitDuplicate
	}
	if maxPerIP > 0 && ip != "" {
		n := 0
		for _, e := range o.byAccount {
			if e.ip == ip {
				n++
			}
		}
		if n >= maxPerIP {
			return admitIPLimit
		}
	}
	return admitted
}

// admit checks as check does and, when the account may come in, enters it
// with sess in the same step, so two logins of one account racing cannot
// both pass. A nil sess is checked and not entered (a decision-only test).
func (o *OnlineAccounts) admit(accountID int64, sess *gateway.Session, ip string, maxPerIP int) admitResult {
	o.mu.Lock()
	defer o.mu.Unlock()
	if r := o.checkLocked(accountID, ip, maxPerIP); r != admitted || sess == nil {
		return r
	}
	o.byAccount[accountID] = onlineEntry{sess: sess, ip: ip}
	o.bySession[sess.ID()] = accountID
	return admitted
}

// Claim enters accountID as online on sess unless it already is, for a
// front door that admits a login outside LoginService.Login (the retail
// listener's agent connection). It reports whether it did.
func (o *OnlineAccounts) Claim(accountID int64, sess *gateway.Session, remote net.Addr) bool {
	return o.admit(accountID, sess, ipOf(remote), 0) == admitted
}

// Release takes sess's account off the table, if sess is the one holding
// it. Safe for a session that never logged in.
func (o *OnlineAccounts) Release(sess *gateway.Session) {
	if o == nil || sess == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	id, ok := o.bySession[sess.ID()]
	if !ok {
		return
	}
	delete(o.bySession, sess.ID())
	if e, held := o.byAccount[id]; held && e.sess.ID() == sess.ID() {
		delete(o.byAccount, id)
	}
}

// Session returns accountID's live session, if it is online.
func (o *OnlineAccounts) Session(accountID int64) (*gateway.Session, bool) {
	if o == nil {
		return nil, false
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	e, ok := o.byAccount[accountID]
	return e.sess, ok
}

// Count is how many accounts are online.
func (o *OnlineAccounts) Count() int {
	if o == nil {
		return 0
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	return len(o.byAccount)
}

// ipOf is addr's host part, "" when there is none.
func ipOf(addr net.Addr) string {
	if addr == nil {
		return ""
	}
	if tcp, ok := addr.(*net.TCPAddr); ok {
		return tcp.IP.String()
	}
	host, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		return addr.String()
	}
	return host
}
