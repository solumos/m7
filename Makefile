.PHONY: deps test check integration

deps:
	forge install --no-git --shallow OpenZeppelin/openzeppelin-contracts@v5.4.0 foundry-rs/forge-std@v1.9.7

test:
	forge test
	python3 -m unittest discover -s test -p 'test_*.py' -v

check:
	forge fmt --check
	forge build --sizes
	$(MAKE) test

integration:
	python3 scripts/verify_base.py
