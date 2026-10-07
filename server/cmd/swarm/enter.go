package main

// The steps every connection the tool makes goes through on its way into the
// world -- the login, the character (created through the retail lobby the
// first time), the Start -- shared by the crowd's bots (bot.go) and the
// latency probe (probe.go).

import (
	"context"
	"database/sql"
	"fmt"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/session"
)

// login sends the login and reads its result: errFull when the server is
// full.
func login(c *conn, name, pw string) error {
	if err := c.send(session.OpLogin, (&session.LoginRequest{Username: name, Password: pw}).Encode()); err != nil {
		return err
	}
	data, err := c.await(session.OpLoginResult, 15*time.Second)
	if err != nil {
		return fmt.Errorf("login: %w", err)
	}
	lr, err := session.DecodeLoginResult(data)
	if err != nil {
		return fmt.Errorf("login: %w", err)
	}
	if !lr.OK {
		if lr.Reason == session.LoginRefusedFull {
			return errFull
		}
		return fmt.Errorf("login refused: %s", lr.Reason)
	}
	return nil
}

// ensureCharacter is the bot account's character, created through the lobby
// (0x7007) as lk when it does not exist yet; created reports that it was.
func ensureCharacter(ctx context.Context, c *conn, db *sql.DB, prefix, name string, lk look) (ch botChar, created bool, err error) {
	ch, ok, err := botCharacter(ctx, db, prefix, name)
	if err != nil {
		return ch, false, fmt.Errorf("looking up the character: %w", err)
	}
	if ok {
		return ch, false, nil
	}
	if err := c.send(session.OpLobby, lk.createRequest(name).Encode()); err != nil {
		return ch, false, err
	}
	data, err := c.await(session.OpLobbyResult, 15*time.Second)
	if err != nil {
		return ch, false, fmt.Errorf("create: %w", err)
	}
	res, err := session.DecodeLobbyResult(data)
	if err != nil {
		return ch, false, fmt.Errorf("create: %w", err)
	}
	if !res.OK && res.Code != session.LobbyErrNameExists {
		return ch, false, fmt.Errorf("create refused: code 0x%x (is the server's -chargen-csv loaded?)", res.Code)
	}
	if ch, ok, err = botCharacter(ctx, db, prefix, name); err != nil || !ok {
		return ch, false, fmt.Errorf("the created character is not in the database: %v", err)
	}
	return ch, true, nil
}

// startWorld sends Start (0x7001) and reads the entry and the character's own
// world id (0x... SelfID).
func startWorld(c *conn, name string) (*session.EnterWorldResult, uint32, error) {
	if err := c.send(session.OpStart, (&session.StartRequest{Name: name}).Encode()); err != nil {
		return nil, 0, err
	}
	data, err := c.await(session.OpEnterWorldResult, 20*time.Second)
	if err != nil {
		return nil, 0, fmt.Errorf("start: %w", err)
	}
	er, err := session.DecodeEnterWorldResult(data)
	if err != nil {
		return nil, 0, fmt.Errorf("start: %w", err)
	}
	if !er.OK {
		return nil, 0, fmt.Errorf("enter world refused: %s", er.Reason)
	}
	data, err = c.await(session.OpSelfID, 15*time.Second)
	if err != nil {
		return nil, 0, err
	}
	self, err := session.DecodeSelfID(data)
	if err != nil {
		return nil, 0, err
	}
	return er, uint32(self.CharacterID), nil
}
