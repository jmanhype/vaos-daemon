.PHONY: build clean check test run

build:
	cargo build --release

clean:
	cargo clean

check:
	cargo check && cargo clippy -- -D warnings

test:
	cargo test

run:
	cargo run
