ROOT := $(abspath $(CURDIR)/..)
API_OUTPUT := $(CURDIR)/static/api
DART ?= dart
HUGO ?= hugo

.PHONY: api build serve clean

api:
	cd "$(ROOT)" && $(DART) pub get --enforce-lockfile
	cd "$(ROOT)" && $(DART) doc --output "$(API_OUTPUT)" --validate-links

build: api
	$(HUGO) --source "$(CURDIR)" --gc --minify --panicOnWarning

serve: api
	$(HUGO) server --source "$(CURDIR)" --buildDrafts --disableFastRender

clean:
	rm -rf "$(API_OUTPUT)" "$(CURDIR)/public" "$(CURDIR)/resources"
