.DEFAULT_GOAL := help

help: ## show this help
	@grep -hE '^[a-z0-9%_-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "%-10s %s\n", $$1, $$2}'

up: ## start both PostgreSQL instances
	docker compose up -d --wait

down: ## stop instances and drop their data
	docker compose down -v

test: up ## run all scenarios
	./tests/run_all.sh

test-%: up ## run one scenario by number, e.g. make test-04
	./tests/$*_*.sh

.PHONY: help up down test
