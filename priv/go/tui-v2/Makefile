.PHONY: build clean vet test all

BIN := osa

build:
	go build -o $(BIN) .

clean:
	rm -f $(BIN)

vet:
	go vet ./...

test:
	go test ./...

all: vet test build
