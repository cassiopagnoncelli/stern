.PHONY: all release build check clean dev docs tests test lint style stats benchmark benchmark-list help
.DEFAULT_GOAL := help

BENCHMARK_OP         ?= charge_pix
BENCHMARK_THREADS    ?= 8
BENCHMARK_ITERATIONS ?= 2000
BENCHMARK_WARMUP     ?= 200
BENCHMARK_MERCHANTS  ?= 16

RAILS_LOC_DIRS = app config db lib spec
RAILS_LOC_FIND_TYPES = \( -name '*.rb' -o -name '*.erb' -o -name '*.js' -o -name '*.rake' -o -name '*.ru' \)
RAILS_LOC_GIT_PATHS = \
	':(glob)app/**/*.rb' \
	':(glob)app/**/*.erb' \
	':(glob)app/**/*.js' \
	':(glob)config/**/*.rb' \
	':(glob)config/**/*.ru' \
	':(glob)db/**/*.rb' \
	':(glob)lib/**/*.rb' \
	':(glob)lib/**/*.rake' \
	':(glob)spec/**/*.rb' \
	Rakefile \
	config.ru

all: build clean ## Build and clean temporary artifacts

release: lint test docs check build ## Run full release pipeline

build: clean docs ## Run build steps

check: build ## Verify build can run

clean: ## Remove generated log files
	@rm -f logs/*.log

dev: ## Run the Rails server locally (web + css watcher)
	bin/dev

docs: ## Generate documentation (currently no-op)

tests: test ## Alias for test

test: ## Run test suite
	bundle exec rspec

lint: ## Run static analysis
	bundle exec rubocop

style: ## Auto-correct style issues
	bundle exec rubocop --auto-correct

benchmark: ## Benchmark a Stern operation (override BENCHMARK_OP/THREADS/ITERATIONS/WARMUP/MERCHANTS)
	@RAILS_MAX_THREADS=$(BENCHMARK_THREADS) bundle exec ruby scripts/benchmark/run.rb \
		--op=$(BENCHMARK_OP) \
		--threads=$(BENCHMARK_THREADS) \
		--iterations=$(BENCHMARK_ITERATIONS) \
		--warmup=$(BENCHMARK_WARMUP) \
		--merchants=$(BENCHMARK_MERCHANTS)

benchmark-list: ## List available benchmark scenarios
	@bundle exec ruby scripts/benchmark/run.rb --list

stats: ## Show current and historical LOC stats
	@current_rails_loc=$$(find $(RAILS_LOC_DIRS) -type f $(RAILS_LOC_FIND_TYPES) -print0 | xargs -0 cat | wc -l | tr -d ' ') && \
	printf "LOC\n  Current: %s\n" "$$current_rails_loc"
	@historical_rails_loc=$$(git log --numstat --format=tformat: -- $(RAILS_LOC_GIT_PATHS) | \
		awk '($$1 ~ /^[0-9]+$$/ && $$2 ~ /^[0-9]+$$/) { total += $$1 + $$2 } END { print total + 0 }') && \
	printf "  Historical: %s\n" "$$historical_rails_loc"

help: ## Show available make targets
	@awk 'BEGIN {FS = ":.*##"; printf "Usage: make <target>\n\nTargets:\n"} /^[a-zA-Z0-9_.-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
