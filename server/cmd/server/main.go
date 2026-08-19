package main

import (
	"flag"
	"log"
)

func main() {
	addr := flag.String("addr", ":15779", "listen address for the gateway service")
	flag.Parse()

	log.Printf("srrevamp server scaffold starting on %s (no protocol implemented yet)", *addr)
}
