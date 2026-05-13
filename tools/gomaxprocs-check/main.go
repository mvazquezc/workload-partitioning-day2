package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	fmt.Printf("GOMAXPROCS:      %d\n", runtime.GOMAXPROCS(0))
	fmt.Printf("NumCPU:          %d\n", runtime.NumCPU())
	fmt.Printf("GOMAXPROCS env:  %s\n", envOrDefault("GOMAXPROCS", "<not set>"))
}

func envOrDefault(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return fallback
}
