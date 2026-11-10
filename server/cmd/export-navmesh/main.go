// Command export-navmesh copies the game's walkable surface out of a
// client's own archives into the directory the server's -navmesh-dir names
// (round 812): Data.pk2's navmesh\nv_*.nvm files as they are, and every
// object index entry's navigation mesh (internal/navmesh, the client's
// NavObjectSource rule) in objects.gob, and (round 879, with -media) every
// characterdata STRUCTURE_* row's model's navigation mesh by its codename in
// structures.gob -- the trigger doors, which no region lists. The archives are
// the user's; the output is never committed.
//
// Usage:
//
//	export-navmesh -data Data.pk2 [-map Map.pk2] [-media Media.pk2] -out DIR
package main

import (
	"encoding/gob"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"unicode/utf16"

	"github.com/TheOpenSRO/OpenSRO/server/internal/assetfs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/TheOpenSRO/OpenSRO/server/internal/objidx"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pk2"
)

func main() {
	dataPath := flag.String("data", "", "the client's Data.pk2")
	mapPath := flag.String("map", "", "the client's Map.pk2 (its object.ifo is the index the client resolves navmesh objects with; Data.pk2's navmesh\\object.ifo without it)")
	mediaPath := flag.String("media", "", "the client's Media.pk2 (its characterdata names the runtime structures' models: structures.gob)")
	out := flag.String("out", "", "the directory to write (created)")
	flag.Parse()
	if *dataPath == "" || *out == "" {
		flag.Usage()
		os.Exit(2)
	}
	data, err := pk2.Open(*dataPath)
	if err != nil {
		log.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(*out, navmesh.NvmSubdir), 0o755); err != nil {
		log.Fatal(err)
	}

	// The terrain navigation meshes, copied as they are.
	nvm, bytes := 0, int64(0)
	err = data.Walk(func(path string, e pk2.Entry) error {
		if e.IsDir {
			return nil
		}
		low := strings.ToLower(path)
		if !strings.HasPrefix(low, `navmesh\nv_`) || !strings.HasSuffix(low, ".nvm") {
			return nil
		}
		b, err := data.ReadFile(e)
		if err != nil {
			return fmt.Errorf("%s: %w", path, err)
		}
		name := strings.ToLower(path[strings.LastIndex(path, `\`)+1:])
		if err := os.WriteFile(filepath.Join(*out, navmesh.NvmSubdir, name), b, 0o644); err != nil {
			return err
		}
		nvm++
		bytes += int64(len(b))
		return nil
	})
	if err != nil {
		log.Fatal(err)
	}

	// The object index: Map.pk2's own, as the client prefers it.
	var ifo []byte
	source := ""
	if *mapPath != "" {
		m, err := pk2.Open(*mapPath)
		if err != nil {
			log.Fatal(err)
		}
		if ifo, err = m.ReadPath("object.ifo"); err == nil {
			source = "Map.pk2 object.ifo"
		}
	}
	if ifo == nil {
		if ifo, err = data.ReadPath(`navmesh\object.ifo`); err != nil {
			log.Fatal("no object index: ", err)
		}
		source = `Data.pk2 navmesh\object.ifo`
	}
	table, err := objidx.Parse(ifo)
	if err != nil {
		log.Fatal(err)
	}
	read := func(p string) []byte {
		b, err := data.ReadPath(p)
		if err != nil {
			return nil
		}
		return b
	}
	objs := map[uint32]*navmesh.CollisionMesh{}
	none, bad := 0, 0
	for _, e := range table.Entries {
		mp := navmesh.CollisionPath(e.Path, read)
		if mp == "" {
			none++
			continue
		}
		b := read(mp)
		if b == nil {
			none++
			continue
		}
		c, err := navmesh.ParseCollision(b)
		if err != nil {
			bad++
			log.Printf("object %d %s (%s): %v", e.TypeID, e.Path, mp, err)
			continue
		}
		if c == nil || len(c.Cells) == 0 {
			none++
			continue
		}
		objs[e.TypeID] = c
	}
	f, err := os.Create(filepath.Join(*out, navmesh.ObjectsFile))
	if err != nil {
		log.Fatal(err)
	}
	if err := gob.NewEncoder(f).Encode(objs); err != nil {
		log.Fatal(err)
	}
	if err := f.Close(); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("export-navmesh: %d .nvm files (%d MB), %d of %d objects with a navigation mesh from %s (%d without, %d unreadable) -> %s\n",
		nvm, bytes>>20, len(objs), len(table.Entries), source, none, bad, *out)
	if *mediaPath != "" {
		exportStructures(*mediaPath, read, *out)
	}
}

// characterDataIndex is the client's characterdata part list (Media.pk2).
const characterDataIndex = `server_dep\silkroad\textdata\characterdata.txt`

// characterdata's columns (0-based): the codename and the model's .bsr
// (MEASURED: column 52, "Dun\Property\wreck\event\wreck_event_door.bsr" for
// STRUCTURE_GOD_BIG_GATE_WRECK_B1_1; the client's StructureWorld reads it).
const (
	charColCode  = 2
	charColModel = 52
)

// exportStructures writes structures.gob: each STRUCTURE_* row's model's
// navigation mesh (navmesh.CollisionPath of "res\" + the model) by codename.
func exportStructures(mediaPath string, read func(string) []byte, out string) {
	media, err := pk2.Open(mediaPath)
	if err != nil {
		log.Fatal(err)
	}
	idx, err := media.ReadPath(characterDataIndex)
	if err != nil {
		log.Fatal(err)
	}
	st := map[string]*navmesh.CollisionMesh{}
	rows := 0
	for _, part := range assetfs.IndexNames(idx) {
		raw, err := media.ReadPath(`server_dep\silkroad\textdata\` + part)
		if err != nil {
			continue
		}
		for _, line := range strings.Split(decodeText(raw), "\n") {
			cols := strings.Split(strings.TrimRight(line, "\r"), "\t")
			if len(cols) <= charColModel || !strings.HasPrefix(strings.ToUpper(cols[charColCode]), "STRUCTURE_") {
				continue
			}
			rows++
			model := strings.TrimSpace(cols[charColModel])
			if model == "" {
				continue
			}
			mp := navmesh.CollisionPath(`res\`+model, read)
			if mp == "" {
				continue
			}
			b := read(mp)
			if b == nil {
				continue
			}
			if c, err := navmesh.ParseCollision(b); err == nil && c != nil && len(c.Cells) > 0 {
				st[strings.ToUpper(strings.TrimSpace(cols[charColCode]))] = c
			}
		}
	}
	f, err := os.Create(filepath.Join(out, navmesh.StructuresFile))
	if err != nil {
		log.Fatal(err)
	}
	if err := gob.NewEncoder(f).Encode(st); err != nil {
		log.Fatal(err)
	}
	if err := f.Close(); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("export-navmesh: %d of %d structure rows with a navigation mesh -> %s\n", len(st), rows, navmesh.StructuresFile)
}

// decodeText is a client text table: UTF-16LE behind a BOM, else as it is.
func decodeText(raw []byte) string {
	if len(raw) >= 2 && raw[0] == 0xFF && raw[1] == 0xFE {
		u := make([]uint16, 0, len(raw)/2)
		for i := 2; i+1 < len(raw); i += 2 {
			u = append(u, uint16(raw[i])|uint16(raw[i+1])<<8)
		}
		return string(utf16.Decode(u))
	}
	return string(raw)
}
