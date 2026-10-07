# Everything verifiable without a Mac. The visionOS build is the only step that
# needs Xcode; see .github/workflows/build.yml.
.PHONY: test clean

test:
	@echo "== vrapi =="
	@$(MAKE) --no-print-directory -C vrapi test
	@echo "== shims =="
	@$(MAKE) --no-print-directory -C shims test
	@echo "== manifest schema =="
	@tools/metavision-manifest --check triage/manifest.sample.json
	@echo "== tool syntax =="
	@for t in tools/metavision-*; do \
	    case "$$(head -1 "$$t")" in \
	      *python*) python3 -c "import ast,sys; ast.parse(open('$$t').read())" || exit 1 ;; \
	      *bash*|*sh)  bash -n "$$t" || exit 1 ;; \
	      *) echo "no shebang: $$t" && exit 1 ;; \
	    esac; \
	done
	@echo "all checks passed"

clean:
	@$(MAKE) --no-print-directory -C vrapi clean
