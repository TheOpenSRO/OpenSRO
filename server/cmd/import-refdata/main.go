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
	itemsCSV := flag.String("items-csv", "", "path to a headerless CSV export of item reference data (required)")
	db := flag.String("db", "refdata.db", "path to the SQLite database to populate")
	flag.Parse()

	if *itemsCSV == "" {
		fmt.Fprintln(os.Stderr, "usage: import-refdata -items-csv <path> [-db <path>]")
		flag.PrintDefaults()
		os.Exit(2)
	}

	f, err := os.Open(*itemsCSV)
	if err != nil {
		log.Fatalf("opening %s: %v", *itemsCSV, err)
	}
	defer f.Close()

	items, err := refdata.LoadItemsCSV(f)
	if err != nil {
		log.Fatalf("parsing %s: %v", *itemsCSV, err)
	}
	log.Printf("parsed %d items from %s", len(items), *itemsCSV)

	store, err := refdata.OpenSQLStore(*db)
	if err != nil {
		log.Fatalf("opening %s: %v", *db, err)
	}
	defer store.Close()

	ctx := context.Background()
	if err := store.ImportItems(ctx, items); err != nil {
		log.Fatalf("importing items: %v", err)
	}

	count, err := store.Count(ctx)
	if err != nil {
		log.Fatalf("verifying import: %v", err)
	}
	log.Printf("import complete: %s now has %d items", *db, count)
}
