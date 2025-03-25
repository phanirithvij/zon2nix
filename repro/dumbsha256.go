package main

import (
	"crypto/sha256"
	"fmt"
	"os"
)

func main() {
	path := os.Args[1]
	contents, _ := os.ReadFile(path)
	h := sha256.New()
	h.Write(contents)
	fmt.Printf("%x\n", h.Sum(nil))
}
