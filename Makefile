.PHONY: build test demo bench clean
build:
	dune build
test:
	dune runtest
demo:
	dune exec axiom -- replay examples/demo.commands
bench:
	dune exec --profile release axiom -- bench 100000 42
clean:
	dune clean
