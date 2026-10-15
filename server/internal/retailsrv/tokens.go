package retailsrv

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/binary"
	"strings"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
)

// DefaultTokenTTL is how long a login the gateway admitted waits for the
// client's 0x6103 on the agent: 10 s, AgentServer's own (READ: a token
// expires once more than 10000 ms old, "Token Timeout!", 0x409fc9; its sweep
// runs every 3 s, 0x4017cc, so retail's lasts 10-13 s). The client connects
// at once on 0xA102 (READ 0x4cf500).
const DefaultTokenTTL = 10 * time.Second

// pending is one admitted login waiting for the agent: the account and the
// credentials the 0x6102 carried, which the 0x6103 must repeat (READ:
// AgentServer answers [2, 1] when they do not match the queued login).
type pending struct {
	acc       *account.Account
	id, pw    string
	contentID byte
	expires   time.Time
}

// Tokens holds the gateway's admitted logins by token, each usable once.
type Tokens struct {
	TTL time.Duration
	Now func() time.Time

	mu sync.Mutex
	m  map[uint32]*pending
}

func (t *Tokens) now() time.Time {
	if t.Now != nil {
		return t.Now()
	}
	return time.Now()
}

func (t *Tokens) ttl() time.Duration {
	if t.TTL > 0 {
		return t.TTL
	}
	return DefaultTokenTTL
}

// Issue queues an admitted login and returns its token: a random non-zero
// u32 not in use (OURS: AgentServer hands out small sequential ids from a
// pool of 500, 0x409a40 / 0x40a510, which anyone could guess; the client
// only echoes the value).
func (t *Tokens) Issue(acc *account.Account, id, pw string, contentID byte) uint32 {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.m == nil {
		t.m = make(map[uint32]*pending)
	}
	now := t.now()
	for k, p := range t.m {
		if now.After(p.expires) {
			delete(t.m, k)
		}
	}
	var b [4]byte
	for {
		_, _ = rand.Read(b[:])
		tok := binary.LittleEndian.Uint32(b[:])
		if tok == 0 {
			continue
		}
		if _, used := t.m[tok]; used {
			continue
		}
		t.m[tok] = &pending{acc: acc, id: id, pw: pw, contentID: contentID, expires: now.Add(t.ttl())}
		return tok
	}
}

// Take removes token's login and returns it, or false for a token never
// issued, already used or expired. A token is spent by any 0x6103 that
// names it, whether its credentials match or not (OURS).
func (t *Tokens) Take(token uint32) (*pending, bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	p, ok := t.m[token]
	if !ok {
		return nil, false
	}
	delete(t.m, token)
	if t.now().After(p.expires) {
		return nil, false
	}
	return p, true
}

// Len is the number of logins waiting (tests).
func (t *Tokens) Len() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.m)
}

// matches reports whether the agent's credentials are the queued login's.
// The client sends its LOWER-CASED copy of the ID in 0x6103 (READ,
// _strlwr_s at 0x4c9374) while 0x6102 carried it as typed, so the ID is
// compared without case; the password exactly, in constant time.
func (p *pending) matches(id, pw string) bool {
	idOK := strings.EqualFold(p.id, id)
	pwOK := subtle.ConstantTimeCompare([]byte(p.pw), []byte(pw)) == 1
	return idOK && pwOK
}
