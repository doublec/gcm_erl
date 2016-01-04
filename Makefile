.PHONY: all compile doc clean test ct dialyzer dialyzer-build-plt typer \
		shell distclean update-deps clean-common-test-data clean-doc-data \
		rebuild stashdoc

ERLFLAGS= -pa $(CURDIR)/.eunit \
		  -pa $(CURDIR)/ebin \
		  -pa $(CURDIR)/deps/*/ebin \
		  -pa $(CURDIR)/test

INCLUDES := ./deps $(wildcard ./deps/*/include)
SOURCES := $(wildcard ./src/*.erl)

#
# Check for required packages
#
REQUIRED_PKGS := \
	erl \
	dialyzer

_ := $(foreach pkg,$(REQUIRED_PACKAGES),\
		$(if $(shell which $(pkg)),\
			$(error Missing required package $(pkg)),))

ERLANG_VER=$(shell erl -noinput -eval 'io:put_chars(erlang:system_info(system_version)),halt().')

APP := gcm_erl
README_URL := https://code.silentcircle.org/projects/SCPS/repos/$(APP)
DEPS_PLT=$(CURDIR)/.deps_plt
DIALYZER_WARNINGS = -Wunmatched_returns -Werror_handling -Wrace_conditions
DIALYZER_APPS = erts kernel stdlib sasl crypto public_key ssl inets mnesia

# Prefer local rebar, if present

ifneq (,$(wildcard ./rebar))
    REBAR_PGM = `pwd`/rebar
else
    REBAR_PGM = rebar
endif

REBAR = $(REBAR_PGM)
REBAR_VSN := $(shell $(REBAR) --version)

all: deps compile test

info:
	@echo 'Erlang/OTP system version: $(ERLANG_VER)'
	@echo '$(REBAR_VSN)'

compile: deps
	$(REBAR) compile

doc: clean-doc-data compile
	$(REBAR) skip_deps=true doc

stashdoc: clean-doc-data compile
	EDOWN_TARGET=stash EDOWN_TOP_LEVEL_README_URL=$(README_URL) $(REBAR) skip_deps=true doc

deps: info
	$(REBAR) get-deps

update-deps: info
	$(REBAR) update-deps

ct:
	@echo Some tests may be misleading because valid GCM API keys
	@echo and registration IDs are needed, but they should run.
	$(REBAR) skip_deps=true ct

dialyzer: compile $(DEPS_PLT)
	dialyzer \
		--fullpath \
		--plt $(DEPS_PLT) \
		$(DIALYZER_WARNINGS) \
		-r ./ebin

$(DEPS_PLT):
	@echo Building local plt at $(DEPS_PLT)
	@echo
	dialyzer \
		--build_plt \
		--output_plt $(DEPS_PLT) \
		--apps $(DIALYZER_APPS) \
		-r deps

dialyzer-add-to-plt: $(DEPS_PLT)
	@echo Adding to local plt at $(DEPS_PLT)
	@echo
	dialyzer \
		--add_to_plt \
		--plt $(DEPS_PLT) \
		--output_plt $(DEPS_PLT) \
		--apps $(DIALYZER_APPS) \
		-r deps

test: dialyzer ct

shell: deps
	@erl $(ERLFLAGS)

typer:
	typer --plt $(DEPS_PLT) $(patsubst %, -I %, $(INCLUDES)) -r ./src

xref: all
	$(REBAR) xref skip_deps=true

clean-common-test-data:
	- rm -rf $(CURDIR)/test/*.beam
	- rm -rf $(CURDIR)/logs

clean-doc-data:
	- rm -f $(CURDIR)/doc/*.html
	- rm -f $(CURDIR)/doc/edoc-info

clean: clean-common-test-data
	- rm -rf $(CURDIR)/ebin
	$(REBAR) skip_deps=true clean

distclean: clean clean-doc-data
	- rm -rf $(DEPS_PLT)
	- rm -rf .rebar/
	- rm -rvf $(CURDIR)/deps

# ex: ts=4 sts=4 sw=4 noet
