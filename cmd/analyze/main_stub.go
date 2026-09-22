//go:build !darwin

package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "analyze 仅支持在 macOS 上运行")
	os.Exit(1)
}
