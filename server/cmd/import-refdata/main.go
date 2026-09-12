// Command import-refdata populates this project's own item reference-data
// database from a CSV export of a player's own legally-obtained game data —
// the same "bring your own data" approach this repo uses for pk2 client
// assets (see docs/LEGAL.md). It never ships with, embeds, or downloads any
// actual game data itself.
//
// To produce the input CSV from your own restored reference-data database,
// run (column order matters — see docs/protocol/refdata_schema.md):
//
//	SELECT ID,MaxStack,ReqStr,ReqInt,ItemClass,TwoHanded,
//	       Dur_L,Dur_U,PD_L,PD_U,MD_L,MD_U,
//	       PAttackMin_L,PAttackMax_U,MAttackMin_L,MAttackMax_U,
//	       HR_L,HR_U,CHR_L,CHR_U
//	FROM _RefObjItem ORDER BY ID
//
// and export the result as headerless CSV.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"

	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

func main() {
	itemsCSV := flag.String("items-csv", "", "path to a headerless CSV export of item reference data")
	skillsCSV := flag.String("skills-csv", "", "path to a headerless CSV export of skill reference data")
	dsn := flag.String("postgres-dsn", "postgres://postgres:postgres@localhost:5432/srrevamp?sslmode=disable",
		"PostgreSQL connection string to populate")
	flag.Parse()

	if *itemsCSV == "" && *skillsCSV == "" {
		fmt.Fprintln(os.Stderr, "usage: import-refdata [-items-csv <path>] [-skills-csv <path>] [-postgres-dsn <dsn>]")
		flag.PrintDefaults()
		os.Exit(2)
	}

	store, err := refdata.OpenSQLStore(*dsn)
	if err != nil {
		log.Fatalf("opening postgres store: %v", err)
	}
	defer store.Close()
	ctx := context.Background()

	if *itemsCSV != "" {
		f, err := os.Open(*itemsCSV)
		if err != nil {
			log.Fatalf("opening %s: %v", *itemsCSV, err)
		}
		items, err := refdata.LoadItemsCSV(f)
		f.Close()
		if err != nil {
			log.Fatalf("parsing %s: %v", *itemsCSV, err)
		}
		if err := store.ImportItems(ctx, items); err != nil {
			log.Fatalf("importing items: %v", err)
		}
		count, err := store.Count(ctx)
		if err != nil {
			log.Fatalf("verifying item import: %v", err)
		}
		log.Printf("imported %d items from %s; database now has %d", len(items), *itemsCSV, count)
	}

	if *skillsCSV != "" {
		f, err := os.Open(*skillsCSV)
		if err != nil {
			log.Fatalf("opening %s: %v", *skillsCSV, err)
		}
		skills, err := refdata.LoadSkillsCSV(f)
		f.Close()
		if err != nil {
			log.Fatalf("parsing %s: %v", *skillsCSV, err)
		}
		if err := store.ImportSkills(ctx, skills); err != nil {
			log.Fatalf("importing skills: %v", err)
		}
		count, err := store.CountSkills(ctx)
		if err != nil {
			log.Fatalf("verifying skill import: %v", err)
		}
		log.Printf("imported %d skills from %s; database now has %d", len(skills), *skillsCSV, count)
	}
}
