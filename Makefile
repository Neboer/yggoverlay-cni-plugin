# update app name. this is the name of binary
APP=yggoverlay-cni-plugin
APP_EXECUTABLE="./out/yggoverlay"
ALL_PACKAGES=$(shell go list ./... | grep -v /vendor)
SHELL := /bin/bash # Use bash syntax

# Optional if you need DB and migration commands
# DB_HOST=$(shell cat config/application.yml | grep -m 1 -i HOST | cut -d ":" -f2)
# DB_NAME=$(shell cat config/application.yml | grep -w -i NAME  | cut -d ":" -f2)
# DB_USER=$(shell cat config/application.yml | grep -i USERNAME | cut -d ":" -f2)

# Optional colors to beautify output
GREEN  := $(shell tput -Txterm setaf 2)
YELLOW := $(shell tput -Txterm setaf 3)
WHITE  := $(shell tput -Txterm setaf 7)
CYAN   := $(shell tput -Txterm setaf 6)
RESET  := $(shell tput -Txterm sgr0)

# Build metadata
VERSION ?= v0.1.1
LDFLAGS ?= -X github.com/containernetworking/plugins/pkg/utils/buildversion.BuildVersion=$(VERSION)

## All
all: ## runs setup, quality checks and builds
# 	make check-quality
# 	make test
	make build

## Quality
check-quality: ## runs code quality checks
	make lint
	make fmt
	make vet

# Append || true below if blocking local developement
lint: ## go linting. Update and use specific lint tool and options
	golangci-lint run --enable-all

vet: ## go vet
	go vet ./...

fmt: ## runs go formatter
	go fmt ./...

tidy: ## runs tidy to fix go.mod dependencies
	go mod tidy

## Test
test: ## runs tests and create generates coverage report
	make tidy
	make vendor
	go test -v -timeout 10m ./... -coverprofile=coverage.out -json > report.json

coverage: ## displays test coverage report in html mode
	make test
	go tool cover -html=coverage.out

## Build
build: ## build the go application
	mkdir -p out/
	go build -ldflags "$(LDFLAGS)" -o $(APP_EXECUTABLE)
	@echo "Build passed"

run: ## runs the go binary. use additional options if required.
	make build
	chmod +x $(APP_EXECUTABLE)
	$(APP_EXECUTABLE)

clean: ## cleans binary and other generated files
	go clean
	rm -rf out/
	rm -f coverage*.out

vendor: ## all packages required to support builds and tests in the /vendor directory
	go mod vendor


wire: ## for wiring dependencies (update if using some other DI tool)
	wire ./...

# [Optional] mock generation via go generate
# generate_mocks:
# 	go generate -x `go list ./... | grep - v wire`

# [Optional] Database commands
## Database
migrate: build
	${APP_EXECUTABLE} migrate --config=config/application.test.yml

rollback: build
	${APP_EXECUTABLE} migrate --config=config/application.test.yml

.PHONY: all test build vendor

.PHONY: help
## Help
help: ## Show this help.
	@echo ''
	@echo 'Usage:'
	@echo '  ${YELLOW}make${RESET} ${GREEN}<target>${RESET}'
	@echo ''
	@echo 'Targets:'
	@awk 'BEGIN {FS = ":.*?## "} { \
		if (/^[a-zA-Z_-]+:.*?##.*$$/) {printf "    ${YELLOW}%-20s${GREEN}%s${RESET}\n", $$1, $$2} \
		else if (/^## .*$$/) {printf "  ${CYAN}%s${RESET}\n", substr($$1,4)} \
		}' $(MAKEFILE_LIST)