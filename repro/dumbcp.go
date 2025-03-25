package main

import (
	"os"
)

func main() {
	path := os.Args[1]
	opath := os.Args[2]
	contents, _ := os.ReadFile(path)
	f, _ := os.Create(opath)
	defer f.Close()
	f.Write(contents)
}
