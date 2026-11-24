.PHONY: all fmt vet test prod bench ci clean

all: fmt vet test prod

fmt:
	v fmt -verify .

vet:
	v vet .
	v vet scripts/

test:
	v test .

prod:
	v -prod -o trash ./cmd/trash

bench:
	v run bench/bench.v 1000

ci: fmt vet test
	v -prod test .
	v run scripts/update_sqlite.vsh --check
	v -prod -o /tmp/trash ./cmd/trash
	v run scripts/concurrency_test.vsh /tmp/trash
	v run scripts/stress_test.vsh /tmp/trash
	v run scripts/cross_device_test.vsh /tmp/trash

clean:
	rm -f trash /tmp/trash /tmp/trashbin /tmp/trashbin_prod
