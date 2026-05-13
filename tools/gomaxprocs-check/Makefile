BINARY := gomaxprocs-check
GOOS   ?= linux
GOARCH ?= amd64

.PHONY: build clean

build:
	CGO_ENABLED=0 GOOS=$(GOOS) GOARCH=$(GOARCH) go build -o $(BINARY) .

clean:
	rm -f $(BINARY)
