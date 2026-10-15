package session

// Retail's login request and reply (round 788): 0x6102 and 0xA102, the
// payloads byte for byte as GatewayServer.exe and sro_client.exe have them
// (docs/protocol/opcodes/login.md, "The login reply, READ (round 788)").
// They ride our framing on retail's own opcode numbers, as the lobby does
// (lobby.go), and the retail listener sends the same bytes in retail's
// framing. The Godot twin is client/scripts/net/login_ack.gd; the two are
// held to the same bytes by testdata/login_golden.json (TestLoginGolden here,
// login_ack_test.gd there).
//
// The older OpLogin 0x0001 / OpLoginResult 0x0002 pair (login.go) stays for
// clients that predate this round; both go through the same LoginService.

import (
	"encoding/binary"
	"errors"
	"fmt"
	"time"
)

// The opcodes (READ: GatewayServer registers 0x6102 -> 0x405910 and builds
// 0xA102; the client builds 0x6102 in CClientNet::vslot_004 0x4c9290 and reads
// 0xA102 in CClientProcess::vslot_017 0x4cf500).
const (
	OpGatewayLogin    uint16 = 0x6102 // client -> server
	OpGatewayLoginAck uint16 = 0xA102 // server -> client
)

// The result byte (READ): 1 success, 2 an error code follows.
const (
	loginAckOK   uint8 = 1
	loginAckFail uint8 = 2
)

// The error codes after result 2 (READ: the client's switch, jump table
// 0x86caf8 behind CPSTitle::vslot_006 0x86bfc0; what the gateway sends each
// for is RESEARCH's table, docs/protocol/opcodes/login.md). The client shows
// nothing for 0 and for 13 and above.
const (
	LoginErrPassword         uint8 = 1  // u32 max, u32 used follow: UIIT_STT_GLOBAL_PASSWORD_INPUT_ERROR
	LoginErrBlocked          uint8 = 2  // a block kind follows (LoginBlock*)
	LoginErrAlreadyConnected uint8 = 3  // UIO_MSG_ERROR_OVERLAP
	LoginErrNoShard          uint8 = 4  // "Failed to connect to server.(C5)"
	LoginErrFull             uint8 = 5  // UIO_MSG_ERROR_SERVER_BUSY_CONNECT_IMPOSSIBILE
	LoginErrFailed           uint8 = 6  // "...(C7)": the gateway's generic failure
	LoginErrShardMismatch    uint8 = 7  // "...(C8)"
	LoginErrIPLimit          uint8 = 8  // UIO_MSG_ERROR_CONTENT_FAIL_INSUFFICIENT_IP
	LoginErrBilling          uint8 = 9  // UIIO_CLIENT_START_CONTENT_FAIL_BILLING_RELATED
	LoginErrAdultOnly        uint8 = 10 // UIIO_SMERR_ADULT_ONLY_SERVER
	LoginErrTeenOverOnly     uint8 = 11 // UIIO_SMERR_TEENOVER_ONLY_SERVER
	LoginErrTeenServer       uint8 = 12 // UITT_TEENSERVER_ERRMGS_ADULT
)

// The block kinds after LoginErrBlocked (READ: GatewayServer's failure
// builder 0x40dc40; the client's cases).
const (
	LoginBlockPunished      uint8 = 1 // string reason + a 16-byte end time follow
	LoginBlockInspection    uint8 = 2 // UIO_MSG_ERROR_ACCOUNT_CONNECT_IMPOSSIBILE
	LoginBlockNoAccountInfo uint8 = 3 // UIO_MSG_ERROR_THERE_IS_NO_ACCOUNT_INFO
	LoginBlockFreeOver      uint8 = 4 // UIO_MSG_ERROR_GRATIS_USER_BLOCKED
)

// timestampSize is the punishment end time on the wire: an ODBC
// TIMESTAMP_STRUCT, u16 year, month, day, hour, minute, second and a u32
// fraction (READ: the 16 bytes at certparam+0x242 the gateway copies; the
// client reads the six u16 and ignores the fraction, 0x4cf350).
const timestampSize = 16

// GatewayLoginRequest is a 0x6102 payload (READ 0x4c9290): u8 content id,
// the ID and password as u16-length narrow strings, u16 shard id. The ID is
// sent as typed; the client lower-cases only its own copy for 0x6103.
type GatewayLoginRequest struct {
	ContentID uint8
	Username  string
	Password  string
	ShardID   uint16
}

// Encode serializes the request.
func (r *GatewayLoginRequest) Encode() []byte {
	out := []byte{r.ContentID}
	out = append(out, encodeStrings(r.Username, r.Password)...)
	return binary.LittleEndian.AppendUint16(out, r.ShardID)
}

// DecodeGatewayLoginRequest parses a 0x6102 payload. Bytes after the shard id
// are an error (OURS: strict).
func DecodeGatewayLoginRequest(data []byte) (*GatewayLoginRequest, error) {
	if len(data) < 1 {
		return nil, errors.New("session: 0x6102: empty")
	}
	fields, rest, err := decodeStringsPrefix(data[1:], 2)
	if err != nil {
		return nil, fmt.Errorf("session: 0x6102: %w", err)
	}
	if len(rest) != 2 {
		return nil, fmt.Errorf("session: 0x6102: %d bytes where the u16 shard id ends it", len(rest))
	}
	return &GatewayLoginRequest{ContentID: data[0], Username: fields[0], Password: fields[1],
		ShardID: binary.LittleEndian.Uint16(rest)}, nil
}

// LoginAck is a 0xA102 payload.
//
// Success: [1, u32 token, string agent host, u16 agent port] (READ). On
// OpenSRO's own connection the session is already logged in when this
// arrives, and the agent fields are empty and 0, meaning "stay on this
// connection" (OURS); the retail listener names its agent listener there.
//
// Failure: [2, u8 code] and, by code: 1 -> u32 max, u32 used; 2 -> u8 block
// kind, and for kind 1 a string reason and the 16-byte end time.
type LoginAck struct {
	OK        bool
	Token     uint32
	AgentHost string
	AgentPort uint16

	Code         uint8
	MaxAttempts  uint32 // Code 1
	UsedAttempts uint32 // Code 1
	BlockKind    uint8  // Code 2
	BlockReason  string // Code 2, kind 1
	BlockEnd     time.Time
}

// Encode serializes the reply. BlockEnd is written in its own location's
// wall time (the caller passes the server's local time, as the gateway sends
// the DB's datetime as stored).
func (a *LoginAck) Encode() []byte {
	if a.OK {
		out := binary.LittleEndian.AppendUint32([]byte{loginAckOK}, a.Token)
		out = append(out, encodeStrings(a.AgentHost)...)
		return binary.LittleEndian.AppendUint16(out, a.AgentPort)
	}
	out := []byte{loginAckFail, a.Code}
	switch a.Code {
	case LoginErrPassword:
		out = binary.LittleEndian.AppendUint32(out, a.MaxAttempts)
		out = binary.LittleEndian.AppendUint32(out, a.UsedAttempts)
	case LoginErrBlocked:
		out = append(out, a.BlockKind)
		if a.BlockKind == LoginBlockPunished {
			out = append(out, encodeStrings(a.BlockReason)...)
			out = append(out, encodeTimestamp(a.BlockEnd)...)
		}
	}
	return out
}

// DecodeLoginAck parses a 0xA102 payload. Trailing bytes are an error
// (OURS: strict); an unknown error code carries nothing after it, as the
// client reads nothing more for one.
func DecodeLoginAck(data []byte) (*LoginAck, error) {
	if len(data) < 1 {
		return nil, errors.New("session: 0xA102: empty")
	}
	a := &LoginAck{}
	switch data[0] {
	case loginAckOK:
		if len(data) < 5 {
			return nil, errors.New("session: 0xA102: short token")
		}
		a.OK = true
		a.Token = binary.LittleEndian.Uint32(data[1:])
		fields, rest, err := decodeStringsPrefix(data[5:], 1)
		if err != nil {
			return nil, fmt.Errorf("session: 0xA102: agent host: %w", err)
		}
		if len(rest) != 2 {
			return nil, fmt.Errorf("session: 0xA102: %d bytes where the u16 port ends it", len(rest))
		}
		a.AgentHost = fields[0]
		a.AgentPort = binary.LittleEndian.Uint16(rest)
		return a, nil
	case loginAckFail:
	default:
		return nil, fmt.Errorf("session: 0xA102: result %d", data[0])
	}
	if len(data) < 2 {
		return nil, errors.New("session: 0xA102: no error code")
	}
	a.Code = data[1]
	rest := data[2:]
	switch a.Code {
	case LoginErrPassword:
		if len(rest) != 8 {
			return nil, fmt.Errorf("session: 0xA102 code 1: %d bytes, want 8", len(rest))
		}
		a.MaxAttempts = binary.LittleEndian.Uint32(rest)
		a.UsedAttempts = binary.LittleEndian.Uint32(rest[4:])
		rest = nil
	case LoginErrBlocked:
		if len(rest) < 1 {
			return nil, errors.New("session: 0xA102 code 2: no block kind")
		}
		a.BlockKind = rest[0]
		rest = rest[1:]
		if a.BlockKind == LoginBlockPunished {
			fields, after, err := decodeStringsPrefix(rest, 1)
			if err != nil {
				return nil, fmt.Errorf("session: 0xA102 block reason: %w", err)
			}
			if len(after) != timestampSize {
				return nil, fmt.Errorf("session: 0xA102 block end: %d bytes, want %d", len(after), timestampSize)
			}
			a.BlockReason = fields[0]
			a.BlockEnd = decodeTimestamp(after)
			rest = nil
		}
	}
	if len(rest) != 0 {
		return nil, fmt.Errorf("session: 0xA102 code %d: %d trailing bytes", a.Code, len(rest))
	}
	return a, nil
}

// encodeTimestamp writes t's wall-clock fields as a TIMESTAMP_STRUCT with a
// zero fraction (the client ignores it).
func encodeTimestamp(t time.Time) []byte {
	out := make([]byte, 0, timestampSize)
	for _, v := range []int{t.Year(), int(t.Month()), t.Day(), t.Hour(), t.Minute(), t.Second()} {
		out = binary.LittleEndian.AppendUint16(out, uint16(v))
	}
	return binary.LittleEndian.AppendUint32(out, 0)
}

// decodeTimestamp reads a TIMESTAMP_STRUCT as a time in UTC holding the same
// wall-clock fields (the wire carries no zone).
func decodeTimestamp(b []byte) time.Time {
	f := func(i int) int { return int(binary.LittleEndian.Uint16(b[i*2:])) }
	return time.Date(f(0), time.Month(f(1)), f(2), f(3), f(4), f(5), 0, time.UTC)
}
