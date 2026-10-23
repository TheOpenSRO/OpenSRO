// Command export-navmesh copies the game's walkable surface out of a
// client's own archives into the directory the server's -navmesh-dir names
// (round 812): Data.pk2's navmesh\nv_*.nvm files as they are, and every
// object index entry's navigation mesh (internal/navmesh, the client's
// NavObjectSource rule) in objects.gob. The archives are the user's; the
// output is never committed.
//
// Usage:
//
//	export-navmesh -data Data.pk2 [-map Map.pk2] -out DIR
package main

import (
	"encoding/gob"
	"flag"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/navmesh"
	"github.com/OpenSRO/OpenSRO/server/internal/objidx"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

func main() {
	dataPath := flag.String("data", "", "the client's Data.pk2")
	mapPath := flag.String("map", "", "the client's Map.pk2 (its object.ifo is the index the client resolves navmesh objects with; Data.pk2's navmesh\\object.ifo without it)")
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
}
