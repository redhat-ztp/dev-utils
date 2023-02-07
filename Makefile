SHELL := /bin/bash
ENGINE ?= podman
TAG ?= latest
REPO ?= optv

all: check
.PHONY: all

check: | check-shellcheck check-bashate check-markdownlint
.PHONY: check

ifeq ($(shell which shellcheck 2>/dev/null),)
check-shellcheck:
	@echo "Skipping shellcheck: Not installed"
else
check-shellcheck:
	find . -name '*.sh' -not -path './vendor/*' -not -path './git/*' -print0 \
		| xargs -0 --no-run-if-empty shellcheck
endif
.PHONY: check-shellcheck

ifeq ($(shell which bashate 2>/dev/null),)
check-bashate:
	@echo "Skipping bashate: Not installed"
else
# Ignored bashate errors/warnings:
#   E006 Line too long
check-bashate:
	find . -name '*.sh' -not -path './vendor/*' -not -path './git/*' -print0 \
		| xargs -0 --no-run-if-empty bashate -e 'E*' -i E006
endif
.PHONY: check-bashate

ifeq ($(shell which markdownlint 2>/dev/null),)
check-markdownlint:
	@echo "Skipping markdownlint: Not installed"
else
check-markdownlint:
	find . -name '*.md' -not -path './vendor/*' -not -path './git/*' -print0 \
		| xargs -0 --no-run-if-empty markdownlint
endif
.PHONY: check-markdownlint

check_var_defined = \
	$(if $(value $1),, \
		$(error $1 must be set))

check_optv_defined = \
	$(call check_var_defined,OPTV_HOST) \
	$(call check_var_defined,OPTV_REGPORT)

optv-build: check
	$(call check_optv_defined)
	podman build -t $(OPTV_HOST):$(OPTV_REGPORT)/$(REPO)/builder:$(TAG) optv-build

optv-push: optv-build
	$(call check_optv_defined)
	podman push $(OPTV_HOST):$(OPTV_REGPORT)/$(REPO)/builder:$(TAG)
