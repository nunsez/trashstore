.PHONY: all fmt vet test prod bench ci clean

all: fmt vet test prod

fmt:
	v fmt -verify .

vet:
	v vet .

test:
	v test .

prod:
	v -prod -o trash ./cmd/trash

bench:
	v run bench/bench.v 1000

ci: fmt vet test
	v -prod test .
	v -prod -o /tmp/trash ./cmd/trash
	./scripts/concurrency_test.sh /tmp/trash
	./scripts/stress_test.sh /tmp/trash
	./scripts/cross_device_test.sh /tmp/trash

clean:
	rm -f trash /tmp/trash /tmp/trashbin /tmp/trashbin_prod
