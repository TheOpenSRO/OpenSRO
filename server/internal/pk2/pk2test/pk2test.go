// Package pk2test writes small, unencrypted, synthetic pk2 archives for
// tests (never real game data): the on-disk layout of
// docs/protocol/PK2_FORMAT.md, with folders, chained directory blocks and
// duplicate names when a test asks for them.
package pk2test

import (
	"encoding/binary"
	"os"
)

const (
	headerSize       = 256
	entrySize        = 128
	entriesPerBlock  = 20
	blockSize        = entrySize * entriesPerBlock
	entryTypeFolder  = 1
	entryTypeFile    = 2
	entryOffName     = 0x01
	entryOffPosition = 0x6A
	entryOffSize     = 0x72
	entryOffNext     = 0x76
)

// Node is a file (Data) or a folder (Dir, Children) in a synthetic archive.
// Names are written byte for byte, so two siblings may share a name.
type Node struct {
	Name     string
	Dir      bool
	Data     []byte
	Children []Node
}

// File is a file Node.
func File(name string, data string) Node { return Node{Name: name, Data: []byte(data)} }

// Folder is a folder Node.
func Folder(name string, children ...Node) Node {
	return Node{Name: name, Dir: true, Children: children}
}

type dirPlan struct {
	node   *Node
	self   uint32 // offset of the first block
	parent uint32
	blocks int
}

type rawEntry struct {
	typ       byte
	name      string
	pos, size uint32
}

// Write writes an archive holding root's children at path.
func Write(path string, root ...Node) error {
	top := Node{Dir: true, Children: root}
	var plans []*dirPlan
	off := uint32(headerSize)
	var plan func(n *Node, parent uint32)
	plan = func(n *Node, parent uint32) {
		// "." (and ".." below the root) plus the children, in chained blocks
		// of 20 slots.
		count := len(n.Children) + 1
		if parent != 0 {
			count++
		}
		blocks := (count + entriesPerBlock - 1) / entriesPerBlock
		p := &dirPlan{node: n, self: off, parent: parent, blocks: blocks}
		plans = append(plans, p)
		off += uint32(blocks * blockSize)
		for i := range n.Children {
			if n.Children[i].Dir {
				plan(&n.Children[i], p.self)
			}
		}
	}
	plan(&top, 0)

	// Folder offsets by node, file data after every block.
	dirOff := map[*Node]uint32{}
	for _, p := range plans {
		dirOff[p.node] = p.self
	}
	dataOff := map[*Node]uint32{}
	var data []byte
	dataStart := off
	var place func(n *Node)
	place = func(n *Node) {
		for i := range n.Children {
			c := &n.Children[i]
			if c.Dir {
				place(c)
				continue
			}
			dataOff[c] = dataStart + uint32(len(data))
			data = append(data, c.Data...)
		}
	}
	place(&top)

	out := make([]byte, off)
	copy(out, "JoyMax File Manager!\n")
	for _, p := range plans {
		var es []rawEntry
		es = append(es, rawEntry{typ: entryTypeFolder, name: ".", pos: p.self})
		if p.parent != 0 {
			es = append(es, rawEntry{typ: entryTypeFolder, name: "..", pos: p.parent})
		}
		for i := range p.node.Children {
			c := &p.node.Children[i]
			if c.Dir {
				es = append(es, rawEntry{typ: entryTypeFolder, name: c.Name, pos: dirOff[c]})
			} else {
				es = append(es, rawEntry{typ: entryTypeFile, name: c.Name, pos: dataOff[c], size: uint32(len(c.Data))})
			}
		}
		for b := 0; b < p.blocks; b++ {
			base := p.self + uint32(b*blockSize)
			for s := 0; s < entriesPerBlock; s++ {
				i := b*entriesPerBlock + s
				if i >= len(es) {
					break
				}
				e := out[base+uint32(s*entrySize):]
				e[0] = es[i].typ
				copy(e[entryOffName:entryOffName+89], es[i].name)
				binary.LittleEndian.PutUint32(e[entryOffPosition:], es[i].pos)
				binary.LittleEndian.PutUint32(e[entryOffSize:], es[i].size)
			}
			if b+1 < p.blocks {
				last := out[base+uint32((entriesPerBlock-1)*entrySize):]
				binary.LittleEndian.PutUint32(last[entryOffNext:], base+blockSize)
			}
		}
	}
	return os.WriteFile(path, append(out, data...), 0o644)
}
