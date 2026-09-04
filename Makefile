SHELL := /bin/bash
SCRIPTS := install.sh bin/meilictl test/smoke.sh

.PHONY: lint test syntax

syntax:
	@for f in $(SCRIPTS); do bash -n $$f && echo "ok  $$f"; done

lint: syntax
	docker run --rm -v "$(CURDIR):/mnt:ro" koalaman/shellcheck:stable -x -S style $(SCRIPTS)

test:
	./test/smoke.sh
