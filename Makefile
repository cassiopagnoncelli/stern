.PHONY: all release build check clean docs test lint style stats

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

all: build clean

release: lint test docs check build

build: clean docs

check: build

clean:
	@rm -f logs/*.log

docs:

tests: test

test:
	bundle exec rspec

lint:
	bundle exec rubocop

style:
	bundle exec rubocop --auto-correct

stats:
	@current_rails_loc=$$(find $(RAILS_LOC_DIRS) -type f $(RAILS_LOC_FIND_TYPES) -print0 | xargs -0 cat | wc -l | tr -d ' ') && \
	printf "LOC\n  Current: %s\n" "$$current_rails_loc"
	@historical_rails_loc=$$(git log --numstat --format=tformat: -- $(RAILS_LOC_GIT_PATHS) | \
		awk '($$1 ~ /^[0-9]+$$/ && $$2 ~ /^[0-9]+$$/) { total += $$1 + $$2 } END { print total + 0 }') && \
	printf "  Historical: %s\n" "$$historical_rails_loc"
