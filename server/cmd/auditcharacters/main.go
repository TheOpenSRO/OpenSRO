// Command auditcharacters walks the exact real character/equipment asset
// matrix World3D.gd loads at runtime (see GENDER_ASSET_PATHS,
// ARMOR_SET_NUMBERS, WEAPON_VARIANTS, SHIELD_VARIANTS in
// client/scripts/World3D.gd) and resolves every real chain: .bsk skeleton,
// each real body-part .bms, the body .bmt material + its .ddj textures,
// every real armor-set-number x equipment-part-suffix .bms + its .bmt
// material + textures, idle/walk .ban animations, and every weapon/shield
// variant's .bms + .bmt + textures.
//
// Unlike audittextures (which treats every catalog gap as a real failure),
// World3D.gd's own character-loading code already treats a missing armor
// set or body part as a normal, honestly-scoped gap (see ARMOR_SET_NUMBERS'
// doc comment) -- so this tool reports missing files as informational, and
// only real parse failures (a file that exists but doesn't parse) as
// failures, matching the client's own tolerance.
//
// Usage:
//
//	go run ./cmd/auditcharacters -data "C:\Silkroad\Data.pk2"
package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/ban"
	"github.com/OpenSRO/OpenSRO/server/internal/bms"
	"github.com/OpenSRO/OpenSRO/server/internal/bmt"
	"github.com/OpenSRO/OpenSRO/server/internal/bsk"
	"github.com/OpenSRO/OpenSRO/server/internal/ddj"
	"github.com/OpenSRO/OpenSRO/server/internal/pk2"
)

type genderPaths struct {
	skeleton              string
	meshDir               string
	bodyParts             []string
	material              string
	equipmentMeshDir      string
	equipmentMaterialDir  string
	equipmentPartSuffixes []string
	idleAnim              string
	walkAnim              string
}

var genders = map[string]genderPaths{
	"china_man": {
		skeleton:              `Prim\Skel\Char\China\chinaman_skel.bsk`,
		meshDir:               `Prim\Mesh\Char\China\man`,
		bodyParts:             []string{"man_pelvis", "man_torso_lower", "man_torso_upper", "man_thigh", "man_calf", "man_arm_upper", "man_arm_lower"},
		material:              `Prim\Mtrl\Char\China\man\chinaman_warrior.bmt`,
		equipmentMeshDir:      `Prim\Mesh\Item\China\man_item`,
		equipmentMaterialDir:  `Prim\Mtrl\Item\China\man_item`,
		equipmentPartSuffixes: []string{"aa", "ba", "fa", "ha", "la", "sa"},
		idleAnim:              `Prim\Ani\Char\China\man\chinaman_fighter_standcity.ban`,
		walkAnim:              `Prim\Ani\Char\China\man\chinaman_fighter_walkforward.ban`,
	},
	"china_woman": {
		skeleton:              `Prim\Skel\Char\China\chinawoman_skel.bsk`,
		meshDir:               `Prim\Mesh\Char\China\woman`,
		bodyParts:             []string{"woman_pelvis", "woman_torso_lower", "woman_torso_upper", "woman_thigh", "woman_calf", "woman_arm_upper", "woman_arm_fore"},
		material:              `Prim\Mtrl\Char\China\woman\chinawoman_warrior.bmt`,
		equipmentMeshDir:      `Prim\Mesh\Item\China\woman_item`,
		equipmentMaterialDir:  `Prim\Mtrl\Item\China\woman_item`,
		equipmentPartSuffixes: []string{"aa", "ba", "fa", "ha", "la", "sa"},
		idleAnim:              `Prim\Ani\Char\China\woman\chinawoman_fighter_standcity.ban`,
		walkAnim:              `Prim\Ani\Char\China\woman\chinawoman_fighter_walkforward.ban`,
	},
}

var armorSetNumbers = []string{"02", "03", "04", "05", "06", "07", "08", "09"}

type weaponVariant struct{ mesh, material string }

var weaponVariants = []weaponVariant{
	{`Prim\Mesh\Item\China\weapon\blade_01.bms`, `Prim\Mtrl\Item\China\weapon\blade1_5.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_02.bms`, `Prim\Mtrl\Item\China\weapon\blade1_5.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_03.bms`, `Prim\Mtrl\Item\China\weapon\blade1_5.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_04.bms`, `Prim\Mtrl\Item\China\weapon\blade1_5.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_05.bms`, `Prim\Mtrl\Item\China\weapon\blade1_5.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_06.bms`, `Prim\Mtrl\Item\China\weapon\blade1_5.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_07.bms`, `Prim\Mtrl\Item\China\weapon\blade6_10.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_08.bms`, `Prim\Mtrl\Item\China\weapon\blade6_10.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_09.bms`, `Prim\Mtrl\Item\China\weapon\blade6_10.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_10.bms`, `Prim\Mtrl\Item\China\weapon\blade_10_12.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_11.bms`, `Prim\Mtrl\Item\China\weapon\blade_11.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_12.bms`, `Prim\Mtrl\Item\China\weapon\blade_12.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_13.bms`, `Prim\Mtrl\Item\China\weapon\blade_13.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_14.bms`, `Prim\Mtrl\Item\China\weapon\blade_14.bmt`},
	{`Prim\Mesh\Item\China\weapon\blade_15.bms`, `Prim\Mtrl\Item\China\weapon\blade_15.bmt`},
}

var shieldVariants = []weaponVariant{
	{`Prim\Mesh\Item\China\weapon\shield_11.bms`, `Prim\Mtrl\Item\China\weapon\shield_11.bmt`},
	{`Prim\Mesh\Item\China\weapon\shield_15.bms`, `Prim\Mtrl\Item\China\weapon\shield_15.bmt`},
	{`Prim\Mesh\Item\China\weapon\shield_16.bms`, `Prim\Mtrl\Item\China\weapon\shield_16.bmt`},
	{`Prim\Mesh\Item\China\weapon\shield_90.bms`, `Prim\Mtrl\Item\China\weapon\shield_90.bmt`},
	{`Prim\Mesh\Item\China\weapon\shield_91.bms`, `Prim\Mtrl\Item\China\weapon\shield_11.bmt`},
}

type failure struct {
	path   string
	reason string
}

var (
	failures []failure
	missing  []string
	verbose  bool
)

func main() {
	dataPath := flag.String("data", "", "path to a real Data.pk2 (required)")
	flag.BoolVar(&verbose, "v", false, "print every real path checked, not just failures")
	flag.Parse()
	if *dataPath == "" {
		fmt.Fprintln(os.Stderr, "usage: auditcharacters -data <path to Data.pk2>")
		os.Exit(1)
	}

	archive, err := pk2.Open(*dataPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "opening Data.pk2:", err)
		os.Exit(1)
	}

	texCache := map[string]bool{}

	for gender, paths := range genders {
		fmt.Printf("=== %s ===\n", gender)

		skelData, ok := readFile(archive, paths.skeleton)
		if !ok {
			note("missing", paths.skeleton)
		} else if _, err := bsk.Parse(skelData); err != nil {
			fail(paths.skeleton, "bsk parse failed: "+err.Error())
		}

		for _, part := range paths.bodyParts {
			p := paths.meshDir + `\` + part + ".bms"
			data, ok := readFile(archive, p)
			if !ok {
				note("missing", p)
				continue
			}
			if _, err := bms.Parse(data); err != nil {
				fail(p, "bms parse failed: "+err.Error())
			}
		}

		checkMaterial(archive, paths.material, texCache)

		for _, setNumber := range armorSetNumbers {
			anyPart := false
			for _, suffix := range paths.equipmentPartSuffixes {
				p := paths.equipmentMeshDir + `\clothes_` + setNumber + "_" + suffix + ".bms"
				data, ok := readFile(archive, p)
				if !ok {
					note("missing", p)
					continue
				}
				anyPart = true
				if _, err := bms.Parse(data); err != nil {
					fail(p, "bms parse failed: "+err.Error())
				}
			}
			if anyPart {
				checkMaterial(archive, paths.equipmentMaterialDir+`\clothes_`+setNumber+".bmt", texCache)
			}
		}

		checkAnim(archive, paths.idleAnim)
		checkAnim(archive, paths.walkAnim)
	}

	fmt.Println("=== weapons ===")
	for _, w := range weaponVariants {
		checkMeshAndMaterial(archive, w.mesh, w.material, texCache)
	}

	fmt.Println("=== shields ===")
	for _, s := range shieldVariants {
		checkMeshAndMaterial(archive, s.mesh, s.material, texCache)
	}

	fmt.Printf("\n%d real failure(s), %d real missing file(s) (informational -- the client already treats these as normal gaps)\n", len(failures), len(missing))
	for _, f := range failures {
		fmt.Printf("  FAIL %s: %s\n", f.path, f.reason)
	}
	if verbose {
		for _, m := range missing {
			fmt.Printf("  missing %s\n", m)
		}
	}
	if len(failures) > 0 {
		os.Exit(1)
	}
}

func checkMeshAndMaterial(archive *pk2.Archive, meshPath, matPath string, texCache map[string]bool) {
	data, ok := readFile(archive, meshPath)
	if !ok {
		note("missing", meshPath)
	} else if _, err := bms.Parse(data); err != nil {
		fail(meshPath, "bms parse failed: "+err.Error())
	}
	checkMaterial(archive, matPath, texCache)
}

func checkMaterial(archive *pk2.Archive, matPath string, texCache map[string]bool) {
	data, ok := readFile(archive, matPath)
	if !ok {
		note("missing", matPath)
		return
	}
	mat, err := bmt.Parse(data)
	if err != nil {
		fail(matPath, "bmt parse failed: "+err.Error())
		return
	}
	dir := dirOf(matPath)
	for _, layer := range mat.Layers {
		if layer.TexturePath == "" {
			continue
		}
		texPath := layer.TexturePath
		if !strings.ContainsAny(texPath, `\/`) {
			texPath = dir + `\` + texPath
		}
		checkTexture(archive, texPath, texCache)
	}
}

func checkTexture(archive *pk2.Archive, texPath string, texCache map[string]bool) {
	key := strings.ToLower(texPath)
	if ok, seen := texCache[key]; seen {
		if !ok {
			fail(texPath, "texture (.ddj) previously failed (cached)")
		}
		return
	}
	data, ok := readFile(archive, texPath)
	if !ok {
		note("missing", texPath)
		texCache[key] = false
		return
	}
	tex, err := ddj.Parse(data)
	if err != nil {
		fail(texPath, "ddj parse failed: "+err.Error())
		texCache[key] = false
		return
	}
	switch tex.FourCC {
	case "", "DXT1", "DXT2", "DXT3", "DXT5":
		texCache[key] = true
	default:
		fail(texPath, "unhandled real FourCC: "+tex.FourCC)
		texCache[key] = false
	}
}

func checkAnim(archive *pk2.Archive, animPath string) {
	data, ok := readFile(archive, animPath)
	if !ok {
		note("missing", animPath)
		return
	}
	if _, err := ban.Parse(data); err != nil {
		fail(animPath, "ban parse failed: "+err.Error())
	}
}

func fail(path, reason string) {
	failures = append(failures, failure{path, reason})
}

func note(kind, path string) {
	missing = append(missing, path)
	if verbose {
		fmt.Printf("  %s %s\n", kind, path)
	}
}

func dirOf(p string) string {
	idx := strings.LastIndexAny(p, `\/`)
	if idx == -1 {
		return ""
	}
	return p[:idx]
}

func readFile(archive *pk2.Archive, path string) ([]byte, bool) {
	entry, err := findFile(archive, path)
	if err != nil {
		return nil, false
	}
	data, err := archive.ReadFile(*entry)
	if err != nil {
		return nil, false
	}
	return data, true
}

func findFile(archive *pk2.Archive, path string) (*pk2.Entry, error) {
	parts := splitPath(path)
	entries, err := archive.ReadDir()
	if err != nil {
		return nil, err
	}
	for i, part := range parts {
		var found *pk2.Entry
		for j := range entries {
			if strings.EqualFold(entries[j].Name, part) {
				found = &entries[j]
				break
			}
		}
		if found == nil {
			return nil, fmt.Errorf("%s not found", path)
		}
		if i == len(parts)-1 {
			return found, nil
		}
		if !found.IsDir {
			return nil, fmt.Errorf("%s is not a directory", strings.Join(parts[:i+1], `\`))
		}
		entries, err = archive.ReadDirAt(*found)
		if err != nil {
			return nil, err
		}
	}
	return nil, fmt.Errorf("%s not found", path)
}

func splitPath(p string) []string {
	var out []string
	cur := ""
	for _, c := range p {
		if c == '\\' || c == '/' {
			if cur != "" {
				out = append(out, cur)
				cur = ""
			}
			continue
		}
		cur += string(c)
	}
	if cur != "" {
		out = append(out, cur)
	}
	return out
}
