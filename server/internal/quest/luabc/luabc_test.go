package luabc

import (
	"encoding/binary"
	"math"
	"testing"
)

// A tiny Lua 5.1 assembler for the tests: no retail script is ever a fixture
// (AGENTS.md); the chunks below are written by hand in the shape the retail
// Quest.sct uses (a wrapper closure defining a global quest function).

type kst struct {
	t byte
	n float64
	s string
}

type fn struct {
	nups, params, vararg, stack byte
	code                        []uint32
	k                           []kst
	protos                      []fn
}

func abc(op, a, b, c int) uint32 { return uint32(op) | uint32(a)<<6 | uint32(c)<<14 | uint32(b)<<23 }
func abx(op, a, bx int) uint32   { return uint32(op) | uint32(a)<<6 | uint32(bx)<<14 }

func putStr(out []byte, s string) []byte {
	if s == "" {
		return binary.LittleEndian.AppendUint32(out, 0)
	}
	out = binary.LittleEndian.AppendUint32(out, uint32(len(s)+1))
	out = append(out, s...)
	return append(out, 0)
}

func (f fn) bytes(out []byte) []byte {
	out = putStr(out, "@test")
	out = binary.LittleEndian.AppendUint32(out, 0)
	out = binary.LittleEndian.AppendUint32(out, 0)
	out = append(out, f.nups, f.params, f.vararg, f.stack)
	out = binary.LittleEndian.AppendUint32(out, uint32(len(f.code)))
	for _, c := range f.code {
		out = binary.LittleEndian.AppendUint32(out, c)
	}
	out = binary.LittleEndian.AppendUint32(out, uint32(len(f.k)))
	for _, k := range f.k {
		out = append(out, k.t)
		switch k.t {
		case 3:
			out = binary.LittleEndian.AppendUint64(out, math.Float64bits(k.n))
		case 4:
			out = putStr(out, k.s)
		}
	}
	out = binary.LittleEndian.AppendUint32(out, uint32(len(f.protos)))
	for _, p := range f.protos {
		out = p.bytes(out)
	}
	for i := 0; i < 3; i++ { // no debug info
		out = binary.LittleEndian.AppendUint32(out, 0)
	}
	return out
}

func chunk(main fn) []byte {
	out := []byte{0x1b, 'L', 'u', 'a', 0x51, 0, 1, 4, 4, 4, 8, 0}
	return main.bytes(out)
}

func TestQuestShapedChunk(t *testing.T) {
	quest := fn{stack: 6, k: []kst{
		{t: 4, s: "QUESTID"}, {t: 4, s: "LuaGetQuestID"}, {t: 4, s: "QNO_TEST"},
		{t: 4, s: "LuaSetStartCodition"}, {t: 3, n: 2}, {t: 4, s: "QSC_QUEST"}, {t: 3, n: 4}, {t: 3, n: 1},
	}, code: []uint32{
		abx(5, 0, 1),         // GETGLOBAL r0 LuaGetQuestID
		abx(1, 1, 2),         // LOADK r1 "QNO_TEST"
		abc(28, 0, 2, 2),     // CALL r0 1 arg 1 result
		abx(7, 0, 0),         // SETGLOBAL QUESTID
		abx(5, 0, 3),         // GETGLOBAL r0 LuaSetStartCodition
		abx(1, 1, 4),         // LOADK r1 2
		abx(5, 2, 5),         // GETGLOBAL r2 QSC_QUEST (defined by define.sct)
		abx(1, 3, 6),         // LOADK r3 4
		abc(0, 4, 3, 0),      // MOVE r4 r3
		abc(12, 4, 4, 256+7), // ADD r4 r4 K(1) -> 5
		abx(5, 5, 0),         // GETGLOBAL r5 QUESTID
		abc(28, 0, 6, 1),     // CALL r0 5 args
		abc(30, 0, 1, 0),     // RETURN
	}}
	wrapper := fn{stack: 2, vararg: 2, k: []kst{{t: 4, s: "QNO_TEST"}}, protos: []fn{quest}, code: []uint32{
		abx(36, 0, 0),    // CLOSURE r0 quest
		abx(7, 0, 0),     // SETGLOBAL QNO_TEST
		abc(30, 0, 1, 0), // RETURN
	}}
	main := fn{stack: 2, vararg: 2, protos: []fn{wrapper}, code: []uint32{
		abx(36, 0, 0),    // CLOSURE r0 wrapper
		abc(28, 0, 1, 1), // CALL r0
		abc(30, 0, 1, 0), // RETURN
	}}
	p, err := Load(chunk(main))
	if err != nil {
		t.Fatal(err)
	}
	type call struct {
		name string
		args []Value
	}
	var calls []call
	vm := NewVM(func(name string, args []Value) []Value {
		calls = append(calls, call{name, args})
		if name == "LuaGetQuestID" {
			return []Value{{K: Number, N: 42}}
		}
		return nil
	})
	vm.Globals["QSC_QUEST"] = Value{K: Number, N: 2}
	if err := vm.Run(p); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 0 {
		t.Fatalf("the main chunk must only define the quest, got %v", calls)
	}
	if err := vm.CallGlobal("QNO_TEST"); err != nil {
		t.Fatal(err)
	}
	if len(calls) != 2 || calls[0].name != "LuaGetQuestID" || calls[1].name != "LuaSetStartCodition" {
		t.Fatalf("calls %v", calls)
	}
	got := ""
	for _, a := range calls[1].args {
		got += a.String() + ","
	}
	if got != "2,2,4,5,42," {
		t.Fatalf("args %q", got)
	}
	if err := vm.CallGlobal("QNO_MISSING"); err == nil {
		t.Fatal("a missing quest function must be an error")
	}
}

func TestLoadRejectsOtherFormats(t *testing.T) {
	if _, err := Load([]byte("not lua")); err == nil {
		t.Fatal("expected an error")
	}
	bad := chunk(fn{code: []uint32{abc(30, 0, 1, 0)}})
	bad[10] = 4 // float lua_Number
	if _, err := Load(bad); err == nil {
		t.Fatal("expected a header error")
	}
}
