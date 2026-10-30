RELEASE ?= limina
NAMESPACE ?= limina
VALUES ?=
TEMPLATE ?=
ARGS ?=

CI_VALUES := $(wildcard ci/*-values.yaml)
VALUES_FLAG := $(if $(VALUES),-f $(VALUES))
TEMPLATE_FLAG := $(if $(TEMPLATE),-s $(TEMPLATE))

.DEFAULT_GOAL := help

.PHONY: help lint template ci package

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "}; {printf "  %-10s %s\n", $$1, $$2}'

lint: ## Lint the chart (VALUES=file, ARGS=extra flags)
	helm lint . $(VALUES_FLAG) $(ARGS)

template: ## Render the chart (VALUES=file, TEMPLATE=templates/x.yaml, ARGS=extra flags)
	helm template $(RELEASE) . --namespace $(NAMESPACE) $(VALUES_FLAG) $(TEMPLATE_FLAG) $(ARGS)

ci: ## Lint with default values and every ci/*-values.yaml scenario
	@rc=0; \
	echo "==> helm lint (default values)"; \
	helm lint . || rc=1; \
	for f in $(CI_VALUES); do \
		echo "==> helm lint -f $$f"; \
		helm lint . -f "$$f" || rc=1; \
	done; \
	exit $$rc

package: ## Package the chart into limina-<version>.tgz
	helm package .
