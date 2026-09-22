# e2e lab entry points (see the README.md next to this file). The offline suite stays `uv run … pytest`.
#
#   make -C tests/e2e <target>   from the repo root
#   make <target>                from inside tests/e2e/
E2E  := $(patsubst %/,%,$(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(abspath $(E2E)/../..)

.PHONY: test e2e-static e2e-up e2e-check e2e-replay e2e-agent e2e-down

test:              ## the offline suite, from the repo root
	cd $(ROOT) && uv run --with pytest --with pyyaml pytest -q

e2e-static:        ## level 0 — greps only, no lab
	$(E2E)/replay.sh static

e2e-up:            ## create the GitHub lab (PLATFORM=github|gitlab|both)
	$(E2E)/lab-up.sh --platform $(or $(PLATFORM),github)

e2e-check:         ## prove BMM will fire the module hooks in the lab consumer
	$(E2E)/lab-up.sh --check

e2e-replay:        ## level 1 — literal RUN replays (≈35 min incl. Actions + seeding)
	$(E2E)/replay.sh all

e2e-agent:         ## level 2 — hooks via headless Claude, in dependency order
	$(E2E)/scenarios/A4.sh && $(E2E)/scenarios/A1.sh && $(E2E)/scenarios/A9.sh && $(E2E)/scenarios/A3.sh 2 && \
	$(E2E)/scenarios/A5.sh rows && $(E2E)/scenarios/A5.sh none && $(E2E)/scenarios/A7.sh && \
	$(E2E)/scenarios/A8.sh && $(E2E)/scenarios/A6.sh && $(E2E)/scenarios/A2.sh proxy

e2e-down:          ## delete the lab repo(s) and the consumer
	$(E2E)/lab-down.sh
