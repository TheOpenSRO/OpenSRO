package session

// Login notices (round 837, OURS; the user's request): a large notice shown
// to one account when it enters the world. OPENSRO_LOGIN_NOTICES lists them
// as "account=text;account=text" (account names match case-insensitively).
// The client draws it as a big centred banner (HudBigNotice).
//
//	S->C 0x00D8 {u16 len, text}   OURS, sent once per world entry

import (
	"strings"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// OpBigNotice is the OURS big-notice message.
const OpBigNotice uint16 = 0x00D8

var loginNotices atomic.Pointer[map[string]string]

// SetLoginNotices installs the notices from OPENSRO_LOGIN_NOTICES' format.
func SetLoginNotices(spec string) int {
	m := ParseLoginNotices(spec)
	loginNotices.Store(&m)
	return len(m)
}

// ParseLoginNotices reads "account=text;account=text"; blank or malformed
// parts are skipped.
func ParseLoginNotices(spec string) map[string]string {
	out := map[string]string{}
	for _, part := range strings.Split(spec, ";") {
		name, text, ok := strings.Cut(part, "=")
		name = strings.ToLower(strings.TrimSpace(name))
		text = strings.TrimSpace(text)
		if !ok || name == "" || text == "" {
			continue
		}
		out[name] = text
	}
	return out
}

// EncodeBigNotice is 0x00D8's body.
func EncodeBigNotice(text string) []byte {
	b := []byte(text)
	out := []byte{byte(len(b)), byte(len(b) >> 8)}
	return append(out, b...)
}

// loginNoticeAfterEnter sends the arriving account its notice, if it has one.
func loginNoticeAfterEnter(sess *gateway.Session) {
	m := loginNotices.Load()
	if m == nil || len(*m) == 0 {
		return
	}
	name, ok := AuthenticatedUsername(sess)
	if !ok {
		return
	}
	if text, ok := (*m)[strings.ToLower(name)]; ok {
		sendToPeer(sess, &proto.Packet{Opcode: OpBigNotice, Data: EncodeBigNotice(text)})
	}
}
