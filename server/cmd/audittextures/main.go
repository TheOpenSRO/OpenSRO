// Command audittextures walks a real client's *entire* known object catalog
// (every real entry in navmesh\object.ifo -- not just objects actually
// placed somewhere, the full real list of everything that COULD be placed)
// and resolves each one's whole real asset chain -- .bsr -> .bms mesh(es) +
// .bmt material -> each layer's .ddj texture -- reporting every real
// failure found along the way with the exact real path involved.
//
// This is the static, exhaustive counterpart to this project's many
// live-render spot-checks: rather than sampling whichever regions happen to
// be visited, it checks literally every real object this client install
// knows about, without needing to render anything.
//
// Usage:
//
//	go run ./cmd/audittextures -data "C:\Silkroad\Data.pk2"
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/bms"
	"github.com/TheOpenSRO/OpenSRO/server/internal/bmt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/bsr"
	"github.com/TheOpenSRO/OpenSRO/server/internal/cpd"
	"github.com/TheOpenSRO/OpenSRO/server/internal/ddj"
	"github.com/TheOpenSRO/OpenSRO/server/internal/objidx"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pk2"
)

type failure struct {
	typeID int
	path   string
	reason string
}

func main() {
	dataPath := flag.String("data", "", "path to a real Data.pk2 (required)")
	verbose := flag.Bool("v", false, "print every real object checked, not just failures")
	flag.Parse()
	if *dataPath == "" {
		fmt.Fprintln(os.Stderr, "usage: audittextures -data <path to Data.pk2>")
		os.Exit(1)
	}

	archive, err := pk2.Open(*dataPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "opening Data.pk2:", err)
		os.Exit(1)
	}

	idxEntry, err := findFile(archive, `navmesh\object.ifo`)
	if err != nil {
		fmt.Fprintln(os.Stderr, "finding navmesh\\object.ifo:", err)
		os.Exit(1)
	}
	idxData, err := archive.ReadFile(*idxEntry)
	if err != nil {
		fmt.Fprintln(os.Stderr, "reading navmesh\\object.ifo:", err)
		os.Exit(1)
	}
	table, err := objidx.Parse(idxData)
	if err != nil {
		fmt.Fprintln(os.Stderr, "parsing navmesh\\object.ifo:", err)
		os.Exit(1)
	}

	var failures []failure
	checked := 0
	texCache := map[string]bool{} // real texture path -> already-checked-OK

	for id, entry := range table.Entries {
		if entry.Path == "" {
			continue // a real, empty-path entry -- not every real type ID names a real model
		}
		checked++
		if *verbose {
			fmt.Printf("[%d] %s\n", id, entry.Path)
		}
		checkObject(archive, id, entry.Path, &failures, texCache)
	}

	fmt.Printf("\nchecked %d real object type(s), %d real failure(s)\n", checked, len(failures))
	for _, f := range failures {
		fmt.Printf("  [%d] %s: %s\n", f.typeID, f.path, f.reason)
	}
	if len(failures) > 0 {
		os.Exit(1)
	}
}

func checkObject(archive *pk2.Archive, typeID int, objPath string, failures *[]failure, texCache map[string]bool) {
	if strings.HasSuffix(strings.ToLower(objPath), ".cpd") {
		checkCompound(archive, typeID, objPath, failures, texCache)
		return
	}

	entry, err := findFile(archive, objPath)
	if err != nil {
		*failures = append(*failures, failure{typeID, objPath, "bsr not found: " + err.Error()})
		return
	}
	data, err := archive.ReadFile(*entry)
	if err != nil {
		*failures = append(*failures, failure{typeID, objPath, "bsr read failed: " + err.Error()})
		return
	}
	obj, err := bsr.Parse(data)
	if err != nil {
		*failures = append(*failures, failure{typeID, objPath, "bsr parse failed: " + err.Error()})
		return
	}

	meshPaths := append([]string{obj.MeshPath}, obj.SubMeshPaths...)
	anyMeshOK := false
	for _, mp := range meshPaths {
		if mp == "" {
			continue
		}
		mEntry, err := findFile(archive, mp)
		if err != nil {
			*failures = append(*failures, failure{typeID, mp, "mesh (.bms) not found: " + err.Error()})
			continue
		}
		mData, err := archive.ReadFile(*mEntry)
		if err != nil {
			*failures = append(*failures, failure{typeID, mp, "mesh (.bms) read failed: " + err.Error()})
			continue
		}
		if _, err := bms.Parse(mData); err != nil {
			*failures = append(*failures, failure{typeID, mp, "mesh (.bms) parse failed: " + err.Error()})
			continue
		}
		anyMeshOK = true
	}
	hasRealMeshPath := false
	for _, mp := range meshPaths {
		if mp != "" {
			hasRealMeshPath = true
			break
		}
	}
	// A real object with no mesh path at all (obj.MeshPath == "" and no
	// real sub-mesh paths) is a real, genuine particle-effect-only marker
	// (see bsr.Parse's own doc comment) -- only flag a real failure when
	// there WERE real mesh paths to try and every one of them failed.
	if hasRealMeshPath && !anyMeshOK {
		*failures = append(*failures, failure{typeID, objPath, "no mesh piece resolved at all"})
	}

	if obj.MaterialPath == "" {
		return // a real object can genuinely have no material (renders flat/default) -- not itself a failure
	}
	matEntry, err := findFile(archive, obj.MaterialPath)
	if err != nil {
		*failures = append(*failures, failure{typeID, obj.MaterialPath, "material (.bmt) not found: " + err.Error()})
		return
	}
	matData, err := archive.ReadFile(*matEntry)
	if err != nil {
		*failures = append(*failures, failure{typeID, obj.MaterialPath, "material (.bmt) read failed: " + err.Error()})
		return
	}
	mat, err := bmt.Parse(matData)
	if err != nil {
		*failures = append(*failures, failure{typeID, obj.MaterialPath, "material (.bmt) parse failed: " + err.Error()})
		return
	}

	dir := dirOf(obj.MaterialPath)
	for _, layer := range mat.Layers {
		if layer.TexturePath == "" {
			continue
		}
		texPath := layer.TexturePath
		if !strings.ContainsAny(texPath, `\/`) {
			texPath = dir + `\` + texPath
		}
		checkTexture(archive, typeID, texPath, failures, texCache)
	}
}

func checkCompound(archive *pk2.Archive, typeID int, cpdPath string, failures *[]failure, texCache map[string]bool) {
	entry, err := findFile(archive, cpdPath)
	if err != nil {
		*failures = append(*failures, failure{typeID, cpdPath, "cpd not found: " + err.Error()})
		return
	}
	data, err := archive.ReadFile(*entry)
	if err != nil {
		*failures = append(*failures, failure{typeID, cpdPath, "cpd read failed: " + err.Error()})
		return
	}
	compound, err := cpd.Parse(data)
	if err != nil {
		*failures = append(*failures, failure{typeID, cpdPath, "cpd parse failed: " + err.Error()})
		return
	}
	for _, subPath := range compound.BsrPaths {
		checkObject(archive, typeID, subPath, failures, texCache)
	}
}

func checkTexture(archive *pk2.Archive, typeID int, texPath string, failures *[]failure, texCache map[string]bool) {
	key := strings.ToLower(texPath)
	if ok, seen := texCache[key]; seen {
		if !ok {
			*failures = append(*failures, failure{typeID, texPath, "texture (.ddj) previously failed (cached)"})
		}
		return
	}

	entry, err := findFile(archive, texPath)
	if err != nil {
		*failures = append(*failures, failure{typeID, texPath, "texture (.ddj) not found: " + err.Error()})
		texCache[key] = false
		return
	}
	data, err := archive.ReadFile(*entry)
	if err != nil {
		*failures = append(*failures, failure{typeID, texPath, "texture (.ddj) read failed: " + err.Error()})
		texCache[key] = false
		return
	}
	tex, err := ddj.Parse(data)
	if err != nil {
		*failures = append(*failures, failure{typeID, texPath, "texture (.ddj) parse failed: " + err.Error()})
		texCache[key] = false
		return
	}
	switch tex.FourCC {
	case "", "DXT1", "DXT2", "DXT3", "DXT5":
		texCache[key] = true
	default:
		*failures = append(*failures, failure{typeID, texPath, "texture (.ddj) has unhandled real FourCC: " + tex.FourCC})
		texCache[key] = false
	}
}

func dirOf(p string) string {
	idx := strings.LastIndexAny(p, `\/`)
	if idx == -1 {
		return ""
	}
	return p[:idx]
}

// findFile resolves path with the pk2 package's shared lookup (Find:
// case-insensitive, `\` and `/` alike; round 789).
func findFile(archive *pk2.Archive, path string) (*pk2.Entry, error) {
	e, err := archive.Find(path)
	if err != nil {
		return nil, err
	}
	return &e, nil
}
