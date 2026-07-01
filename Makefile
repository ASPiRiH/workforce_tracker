REBAR3 := ./rebar3

## OTP 26: enable the experimental maybe feature at runtime so compiled beams load
ERL_FLAGS ?= -enable-feature maybe_expr
export ERL_FLAGS

.PHONY: all compile clean shell release ct ct-%

all: compile

compile:
	$(REBAR3) compile

clean:
	$(REBAR3) clean --all
	@rm -rf logs/ct/*

shell: compile
	$(REBAR3) shell

release:
	$(REBAR3) as prod release

## make ct               — run all suites (docker-up first)
## make ct-cards         — run one suite
## make ct-cards c=card_lifecycle  — run one test case
ct: compile
	$(REBAR3) ct

ct-%: compile
	@if [ -n "$(c)" ]; then \
	    $(REBAR3) ct --suite test/wt_$*_SUITE --case $(c); \
	else \
	    $(REBAR3) ct --suite test/wt_$*_SUITE; \
	fi

docker-up:
	docker compose up -d --wait broker db

docker-down:
	docker compose down -v