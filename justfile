build:
    make

build-graphs:
    make bench-graphs

bench:
    make bench-run

all: build build-graphs bench
