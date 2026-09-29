.PHONY: deps test check ui-check integration native rehearse

deps:
	forge install --no-git --shallow OpenZeppelin/openzeppelin-contracts@v5.4.0 foundry-rs/forge-std@v1.9.7

test:
	forge test
	python3 -m unittest discover -s test -p 'test_*.py' -v

check:
	forge fmt --check
	forge build --sizes
	$(MAKE) test

ui-check:
	npm --prefix ui test
	npm --prefix ui run build

integration:
	python3 -m scripts.verify_base

# Native B20 fork tests; needs Base's Foundry build (docs/DEPLOYMENT.md). FOUNDRY_BASE=beryl before Cobalt.
native:
	BASE_FORK_TEST=true FOUNDRY_BASE=$${FOUNDRY_BASE:-cobalt} "$${BASE_FORGE:?set BASE_FORGE}" test --match-contract BaseForkTest -vv

# Rehearse the mainnet runbook on a local base-anvil fork.
rehearse:
	scripts/rehearse.sh
