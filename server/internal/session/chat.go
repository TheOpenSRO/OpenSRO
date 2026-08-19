package session

import (
	"context"
	"fmt"

	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// Chat opcodes, our own protocol. All require the sender to already be in
// the world (see WorldNet.enter_world) -- chat identity/zone comes from
// world.Hub, not a separate character-name field, so there's nothing to
// resolve against character.Store here.
const (
	OpChatSay            uint16 = 0x00A0 // client -> server
	OpChatMessage        uint16 = 0x00A1 // server -> client, broadcast to sender's zone (incl. sender)
	OpChatWhisper        uint16 = 0x00A2 // client -> server
	OpChatWhisperResult  uint16 = 0x00A3 // server -> client, delivery ack for the sender
	OpChatWhisperMessage uint16 = 0x00A4 // server -> client, delivered to the whisper's target
)

// ChatSayRequest is the OpChatSay payload.
type ChatSayRequest struct {
	Message string
}

func (r *ChatSayRequest) Encode() []byte { return encodeStrings(r.Message) }

func DecodeChatSayRequest(data []byte) (*ChatSayRequest, error) {
	fields, err := decodeStrings(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatSayRequest: %w", err)
	}
	return &ChatSayRequest{Message: fields[0]}, nil
}

// ChatMessage is the OpChatMessage/OpChatWhisperMessage payload.
type ChatMessage struct {
	SenderName string
	Message    string
}

func (r *ChatMessage) Encode() []byte { return encodeStrings(r.SenderName, r.Message) }

func DecodeChatMessage(data []byte) (*ChatMessage, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatMessage: %w", err)
	}
	return &ChatMessage{SenderName: fields[0], Message: fields[1]}, nil
}

// ChatWhisperRequest is the OpChatWhisper payload.
type ChatWhisperRequest struct {
	TargetName string
	Message    string
}

func (r *ChatWhisperRequest) Encode() []byte { return encodeStrings(r.TargetName, r.Message) }

func DecodeChatWhisperRequest(data []byte) (*ChatWhisperRequest, error) {
	fields, err := decodeStrings(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatWhisperRequest: %w", err)
	}
	return &ChatWhisperRequest{TargetName: fields[0], Message: fields[1]}, nil
}

// ChatWhisperResult is the OpChatWhisperResult payload.
type ChatWhisperResult struct {
	OK     bool
	Reason string
}

func (r *ChatWhisperResult) Encode() []byte { return encodeOKReason(r.OK, r.Reason) }

func DecodeChatWhisperResult(data []byte) (*ChatWhisperResult, error) {
	ok, reason, err := decodeOKReason(data)
	if err != nil {
		return nil, fmt.Errorf("session: decoding ChatWhisperResult: %w", err)
	}
	return &ChatWhisperResult{OK: ok, Reason: reason}, nil
}

// ChatHandler returns a gateway.Handler implementing OpChatSay/OpChatWhisper
// against hub.
func ChatHandler(hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpChatSay:
			return handleChatSay(sess, p, hub)
		case OpChatWhisper:
			return handleChatWhisper(sess, p, hub)
		default:
			return nil
		}
	}
}

func handleChatSay(sess *gateway.Session, p *proto.Packet, hub *world.Hub) error {
	req, err := DecodeChatSayRequest(p.Data)
	if err != nil {
		// No response opcode for malformed say -- nothing meaningful to
		// tell a client that sent garbage for a fire-and-forget message.
		return nil
	}
	sender, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}

	msg := &ChatMessage{SenderName: sender.Name, Message: req.Message}
	data := msg.Encode()
	for _, e := range hub.EntitiesInZone(sender.Zone) {
		if err := e.Session.Send(&proto.Packet{Opcode: OpChatMessage, Data: data}); err != nil {
			return err
		}
	}
	return nil
}

func handleChatWhisper(sess *gateway.Session, p *proto.Packet, hub *world.Hub) error {
	req, err := DecodeChatWhisperRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpChatWhisperResult, Data: (&ChatWhisperResult{Reason: "malformed request"}).Encode()})
	}
	sender, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpChatWhisperResult, Data: (&ChatWhisperResult{Reason: "not in the world"}).Encode()})
	}
	target, ok := hub.FindByName(req.TargetName)
	if !ok {
		return sess.Send(&proto.Packet{Opcode: OpChatWhisperResult, Data: (&ChatWhisperResult{Reason: "player not found"}).Encode()})
	}

	msg := &ChatMessage{SenderName: sender.Name, Message: req.Message}
	if err := target.Session.Send(&proto.Packet{Opcode: OpChatWhisperMessage, Data: msg.Encode()}); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpChatWhisperResult, Data: (&ChatWhisperResult{Reason: "delivery failed"}).Encode()})
	}
	return sess.Send(&proto.Packet{Opcode: OpChatWhisperResult, Data: (&ChatWhisperResult{OK: true}).Encode()})
}
