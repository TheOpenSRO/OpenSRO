// Package luabc reads a compiled Lua 5.1 chunk and runs the straight-line
// setup code in it against recording host functions.
//
// Why (round 785, READ): the retail game server SR_GameServer.exe embeds Lua
// 5.1 (docs/protocol/quest_scripting.md, rounds 427-434) and loads its quest
// definitions from ./Script/VIETNAM/{define,QuestList,Quest}.sct, which are
// Lua 5.1 bytecode (MEASURED: `file` reports "Lua bytecode, version 5.1"; the
// header below parses them). QuestList.sct's QUEST_LIST() calls
// LuaInsertQuest(TYPE_ID, "SN_<CODE>.lua", "<CODE>") once per scripted quest,
// and Quest.sct defines a global function <CODE>() per quest whose body is a
// sequence of calls to host functions the server registers (LuaSetStartCodition,
// LuaSetMissionData, LuaSetAchievedItem, ...; registration READ at
// 0x8706b0..0x870d2a: `mov eax,<fn>; mov edi,<name>; call`).
//
// This package does not ship any script. It parses the operator's own files at
// export time (cmd/export-refdata -mode quests) and calls each quest function
// with every host function replaced by a recorder, so the exporter sees the
// exact arguments the retail server's host functions would receive.
//
// Scope (OURS): the interpreter covers the Lua 5.1 opcode set enough for the
// setup functions -- moves, constants, globals, upvalues, tables, arithmetic,
// comparisons, jumps, calls, closures and varargs. Host functions return nil
// unless the caller supplies a value (LuaGetQuestID returns the quest's id).
// A step budget stops a runaway loop.
package luabc

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"strings"
)

// Kind is a Lua value's type.
type Kind byte

const (
	Nil Kind = iota
	Bool
	Number
	String
	Table
	Function
)

// Value is a Lua value. Tables and functions are pointers.
type Value struct {
	K   Kind
	B   bool
	N   float64
	S   string
	T   *LTable
	F   *Closure
	Nat string // a host function's global name, when F is nil and K is Function
}

// LTable is a Lua table (hash part only; enough for setup code).
type LTable struct {
	m map[string]Value
}

func (t *LTable) key(k Value) string {
	switch k.K {
	case Number:
		return fmt.Sprintf("n:%v", k.N)
	case String:
		return "s:" + k.S
	case Bool:
		return fmt.Sprintf("b:%v", k.B)
	}
	return fmt.Sprintf("p:%p%p", k.T, k.F)
}

// String renders v the way a CSV wants it: numbers without a trailing ".0".
func (v Value) String() string {
	switch v.K {
	case Nil:
		return "nil"
	case Bool:
		if v.B {
			return "true"
		}
		return "false"
	case Number:
		if v.N == math.Trunc(v.N) && math.Abs(v.N) < 1e15 {
			return fmt.Sprintf("%d", int64(v.N))
		}
		return fmt.Sprintf("%g", v.N)
	case String:
		return v.S
	case Table:
		return "table"
	}
	return "function"
}

func truthy(v Value) bool { return !(v.K == Nil || (v.K == Bool && !v.B)) }

// Proto is a function prototype.
type Proto struct {
	Source    string
	NumParams byte
	IsVararg  byte
	MaxStack  byte
	NumUps    byte
	Code      []uint32
	Consts    []Value
	Protos    []*Proto
}

// Closure is a Lua function with its upvalues.
type Closure struct {
	P   *Proto
	Ups []*Value
}

// ErrFormat is a chunk that is not Lua 5.1 bytecode of the expected shape.
var ErrFormat = errors.New("luabc: not a Lua 5.1 x86 chunk")

type reader struct {
	b   []byte
	off int
	err error
}

func (r *reader) need(n int) bool {
	if r.err != nil {
		return false
	}
	if r.off+n > len(r.b) {
		r.err = fmt.Errorf("luabc: truncated at %d (need %d)", r.off, n)
		return false
	}
	return true
}
func (r *reader) u8() byte {
	if !r.need(1) {
		return 0
	}
	v := r.b[r.off]
	r.off++
	return v
}
func (r *reader) u32() uint32 {
	if !r.need(4) {
		return 0
	}
	v := binary.LittleEndian.Uint32(r.b[r.off:])
	r.off += 4
	return v
}
func (r *reader) f64() float64 {
	if !r.need(8) {
		return 0
	}
	v := math.Float64frombits(binary.LittleEndian.Uint64(r.b[r.off:]))
	r.off += 8
	return v
}
func (r *reader) str() string {
	n := int(r.u32())
	if n == 0 || !r.need(n) {
		return ""
	}
	s := string(r.b[r.off : r.off+n-1]) // size counts the trailing NUL
	r.off += n
	return s
}

// Load parses a Lua 5.1 chunk compiled for a little-endian 32-bit host
// (sizeof int/size_t/Instruction 4, lua_Number an 8-byte double) -- the
// layout of every .sct file MEASURED in a retail server.
func Load(b []byte) (*Proto, error) {
	if len(b) < 12 || string(b[:4]) != "\x1bLua" || b[4] != 0x51 || b[5] != 0 {
		return nil, ErrFormat
	}
	if b[6] != 1 || b[7] != 4 || b[8] != 4 || b[9] != 4 || b[10] != 8 || b[11] != 0 {
		return nil, fmt.Errorf("%w: header %x", ErrFormat, b[6:12])
	}
	r := &reader{b: b, off: 12}
	p := r.function()
	if r.err != nil {
		return nil, r.err
	}
	return p, nil
}

func (r *reader) function() *Proto {
	p := &Proto{}
	p.Source = r.str()
	r.u32() // linedefined
	r.u32() // lastlinedefined
	p.NumUps = r.u8()
	p.NumParams = r.u8()
	p.IsVararg = r.u8()
	p.MaxStack = r.u8()
	n := int(r.u32())
	if !r.need(4 * n) {
		return p
	}
	p.Code = make([]uint32, n)
	for i := range p.Code {
		p.Code[i] = r.u32()
	}
	n = int(r.u32())
	for i := 0; i < n && r.err == nil; i++ {
		switch t := r.u8(); t {
		case 0:
			p.Consts = append(p.Consts, Value{})
		case 1:
			p.Consts = append(p.Consts, Value{K: Bool, B: r.u8() != 0})
		case 3:
			p.Consts = append(p.Consts, Value{K: Number, N: r.f64()})
		case 4:
			p.Consts = append(p.Consts, Value{K: String, S: r.str()})
		default:
			r.err = fmt.Errorf("luabc: constant type %d", t)
		}
	}
	n = int(r.u32())
	for i := 0; i < n && r.err == nil; i++ {
		p.Protos = append(p.Protos, r.function())
	}
	// Debug information: line info, locals, upvalue names.
	n = int(r.u32())
	r.need(4 * n)
	r.off += 4 * n
	n = int(r.u32())
	for i := 0; i < n && r.err == nil; i++ {
		r.str()
		r.u32()
		r.u32()
	}
	n = int(r.u32())
	for i := 0; i < n && r.err == nil; i++ {
		r.str()
	}
	return p
}

// Host is the host function hook: name is the global the function was called
// through, args its arguments. It returns the function's results.
type Host func(name string, args []Value) []Value

// VM runs closures over one global table.
type VM struct {
	Globals map[string]Value
	Host    Host
	// Budget is the number of instructions any one Call may execute.
	Budget int
	steps  int
}

// NewVM returns a VM whose unknown globals are host functions.
func NewVM(host Host) *VM {
	return &VM{Globals: map[string]Value{}, Host: host, Budget: 1 << 20}
}

// Run executes a main chunk.
func (vm *VM) Run(p *Proto) error {
	_, err := vm.Call(Value{K: Function, F: &Closure{P: p}}, nil)
	return err
}

// CallGlobal calls the global function name with no arguments. A missing or
// non-function global is an error.
func (vm *VM) CallGlobal(name string) error {
	f, ok := vm.Globals[name]
	if !ok || f.K != Function || f.F == nil {
		return fmt.Errorf("luabc: no Lua function %q", name)
	}
	_, err := vm.Call(f, nil)
	return err
}

// Call calls f with args.
func (vm *VM) Call(f Value, args []Value) ([]Value, error) {
	vm.steps = 0
	return vm.call(f, args, 0)
}

func (vm *VM) global(name string) Value {
	if v, ok := vm.Globals[name]; ok {
		return v
	}
	// An undefined global read as a function is a host function.
	return Value{K: Function, Nat: name}
}

func (vm *VM) call(f Value, args []Value, depth int) ([]Value, error) {
	if f.K != Function {
		return nil, fmt.Errorf("luabc: call of a %v", f.K)
	}
	if f.F == nil {
		if vm.Host == nil {
			return nil, nil
		}
		return vm.Host(f.Nat, args), nil
	}
	if depth > 64 {
		return nil, errors.New("luabc: call depth")
	}
	cl := f.F
	p := cl.P
	reg := make([]Value, int(p.MaxStack)+8)
	for i := 0; i < int(p.NumParams) && i < len(args); i++ {
		reg[i] = args[i]
	}
	var varargs []Value
	if len(args) > int(p.NumParams) {
		varargs = args[p.NumParams:]
	}
	top := 0 // the top set by a call with C == 0 or a vararg with B == 0
	ensure := func(n int) {
		for len(reg) < n {
			reg = append(reg, Value{})
		}
	}
	rk := func(x int) Value {
		if x >= 256 {
			return p.Consts[x-256]
		}
		return reg[x]
	}
	pc := 0
	for {
		if pc < 0 || pc >= len(p.Code) {
			return nil, fmt.Errorf("luabc: pc %d out of range", pc)
		}
		vm.steps++
		if vm.steps > vm.Budget {
			return nil, errors.New("luabc: step budget exhausted")
		}
		ins := p.Code[pc]
		pc++
		op := ins & 0x3f
		a := int(ins >> 6 & 0xff)
		c := int(ins >> 14 & 0x1ff)
		b := int(ins >> 23 & 0x1ff)
		bx := int(ins >> 14)
		sbx := bx - 131071
		ensure(a + 2)
		switch op {
		case 0: // MOVE
			reg[a] = reg[b]
		case 1: // LOADK
			reg[a] = p.Consts[bx]
		case 2: // LOADBOOL
			reg[a] = Value{K: Bool, B: b != 0}
			if c != 0 {
				pc++
			}
		case 3: // LOADNIL
			for i := a; i <= b; i++ {
				ensure(i + 1)
				reg[i] = Value{}
			}
		case 4: // GETUPVAL
			if b < len(cl.Ups) && cl.Ups[b] != nil {
				reg[a] = *cl.Ups[b]
			} else {
				reg[a] = Value{}
			}
		case 5: // GETGLOBAL
			reg[a] = vm.global(p.Consts[bx].S)
		case 6: // GETTABLE
			t := reg[b]
			if t.K == Table {
				reg[a] = t.T.m[t.T.key(rk(c))]
			} else {
				reg[a] = Value{}
			}
		case 7: // SETGLOBAL
			vm.Globals[p.Consts[bx].S] = reg[a]
		case 8: // SETUPVAL
			if b < len(cl.Ups) && cl.Ups[b] != nil {
				*cl.Ups[b] = reg[a]
			}
		case 9: // SETTABLE
			if t := reg[a]; t.K == Table {
				t.T.m[t.T.key(rk(b))] = rk(c)
			}
		case 10: // NEWTABLE
			reg[a] = Value{K: Table, T: &LTable{m: map[string]Value{}}}
		case 11: // SELF
			t := reg[b]
			reg[a+1] = t
			if t.K == Table {
				reg[a] = t.T.m[t.T.key(rk(c))]
			} else {
				reg[a] = Value{}
			}
		case 12, 13, 14, 15, 16, 17: // ADD SUB MUL DIV MOD POW
			x, y := rk(b), rk(c)
			var r float64
			switch op {
			case 12:
				r = x.N + y.N
			case 13:
				r = x.N - y.N
			case 14:
				r = x.N * y.N
			case 15:
				r = x.N / y.N
			case 16:
				r = x.N - math.Floor(x.N/y.N)*y.N
			case 17:
				r = math.Pow(x.N, y.N)
			}
			reg[a] = Value{K: Number, N: r}
		case 18: // UNM
			reg[a] = Value{K: Number, N: -reg[b].N}
		case 19: // NOT
			reg[a] = Value{K: Bool, B: !truthy(reg[b])}
		case 20: // LEN
			reg[a] = Value{K: Number, N: float64(len(reg[b].S))}
		case 21: // CONCAT
			var sb strings.Builder
			for i := b; i <= c; i++ {
				sb.WriteString(reg[i].String())
			}
			reg[a] = Value{K: String, S: sb.String()}
		case 22: // JMP
			pc += sbx
		case 23, 24, 25: // EQ LT LE
			x, y := rk(b), rk(c)
			var r bool
			switch op {
			case 23:
				r = x.K == y.K && x.N == y.N && x.S == y.S && x.B == y.B && x.T == y.T && x.F == y.F && x.Nat == y.Nat
			case 24:
				if x.K == String {
					r = x.S < y.S
				} else {
					r = x.N < y.N
				}
			case 25:
				if x.K == String {
					r = x.S <= y.S
				} else {
					r = x.N <= y.N
				}
			}
			if r != (a != 0) {
				pc++
			}
		case 26: // TEST
			if truthy(reg[a]) != (c != 0) {
				pc++
			}
		case 27: // TESTSET
			if truthy(reg[b]) == (c != 0) {
				reg[a] = reg[b]
			} else {
				pc++
			}
		case 28, 29: // CALL TAILCALL
			n := b - 1
			if b == 0 {
				n = top - a - 1
			}
			ensure(a + 1 + n)
			args := append([]Value(nil), reg[a+1:a+1+n]...)
			res, err := vm.call(reg[a], args, depth+1)
			if err != nil {
				return nil, err
			}
			if op == 29 {
				return res, nil
			}
			if c == 0 {
				ensure(a + len(res) + 1)
				copy(reg[a:], res)
				top = a + len(res)
			} else {
				for i := 0; i < c-1; i++ {
					ensure(a + i + 1)
					if i < len(res) {
						reg[a+i] = res[i]
					} else {
						reg[a+i] = Value{}
					}
				}
			}
		case 30: // RETURN
			if b == 0 {
				return append([]Value(nil), reg[a:top]...), nil
			}
			ensure(a + b)
			return append([]Value(nil), reg[a:a+b-1]...), nil
		case 31: // FORLOOP
			reg[a].N += reg[a+2].N
			if (reg[a+2].N > 0 && reg[a].N <= reg[a+1].N) || (reg[a+2].N <= 0 && reg[a].N >= reg[a+1].N) {
				pc += sbx
				ensure(a + 4)
				reg[a+3] = reg[a]
			}
		case 32: // FORPREP
			reg[a].N -= reg[a+2].N
			pc += sbx
		case 33: // TFORLOOP: generic for over host iterators is not in setup code
			return nil, errors.New("luabc: TFORLOOP not supported")
		case 34: // SETLIST
			n := b
			if n == 0 {
				n = top - a - 1
			}
			if c == 0 {
				c = int(p.Code[pc])
				pc++
			}
			if t := reg[a]; t.K == Table {
				for i := 1; i <= n; i++ {
					t.T.m[t.T.key(Value{K: Number, N: float64((c-1)*50 + i)})] = reg[a+i]
				}
			}
		case 35: // CLOSE
		case 36: // CLOSURE
			np := p.Protos[bx]
			ncl := &Closure{P: np}
			for i := 0; i < int(np.NumUps); i++ {
				pi := p.Code[pc]
				pc++
				pb := int(pi >> 23 & 0x1ff)
				if pi&0x3f == 0 { // MOVE: a local of this function
					ensure(pb + 1)
					v := reg[pb]
					ncl.Ups = append(ncl.Ups, &v)
				} else if pb < len(cl.Ups) { // GETUPVAL
					ncl.Ups = append(ncl.Ups, cl.Ups[pb])
				} else {
					ncl.Ups = append(ncl.Ups, &Value{})
				}
			}
			reg[a] = Value{K: Function, F: ncl}
		case 37: // VARARG
			n := b - 1
			if b == 0 {
				n = len(varargs)
				top = a + n
			}
			ensure(a + n + 1)
			for i := 0; i < n; i++ {
				if i < len(varargs) {
					reg[a+i] = varargs[i]
				} else {
					reg[a+i] = Value{}
				}
			}
		default:
			return nil, fmt.Errorf("luabc: opcode %d", op)
		}
	}
}
