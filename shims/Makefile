# Host tests for the shim layer. The shims themselves are compiled into the
# visionOS app; nothing here needs Darwin.
CC     ?= cc
CFLAGS := -O1 -g -Wall -Wextra -Wno-unused-parameter -D_GNU_SOURCE -pthread

.PHONY: test clean
test: build/t_shims
	@build/t_shims
	@../tools/metavision-gaps --check-shims

build/t_shims: mv_shims.c mv_shims.h mv_hands.c mv_hands.h tests/t_shims.c
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ mv_shims.c mv_hands.c tests/t_shims.c -lm

clean:
	rm -rf build
