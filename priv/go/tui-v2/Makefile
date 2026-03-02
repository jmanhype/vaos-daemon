.PHONY: build clean vet test all install

BIN := osagent

build:
	go build -o $(BIN) .

clean:
	rm -f $(BIN) osa

vet:
	go vet ./...

test:
	go test ./...

install: build
	cp $(BIN) $(HOME)/bin/$(BIN)
	chmod +x $(HOME)/bin/$(BIN)

all: vet test build
