# The policy layer builds anywhere. The entry points need CompositorServices
# and are built inside the klepton runtime on the macOS host.
CFLAGS ?= -std=c11 -Wall -Wextra -Werror -O1

# When vrapi_abi_expect.h is present, every declared layout is asserted against
# the real library's DWARF at compile time.
ifneq ($(wildcard vrapi_abi_expect.h),)
CFLAGS += -DKL_VRAPI_HAVE_ABI_EXPECT -I.
endif

.PHONY: test clean
TESTS := build/test_policy build/test_frame build/test_swapchain build/test_pose

test: $(TESTS)
	@for t in $(TESTS); do ./$$t || exit 1; echo; done

build/test_policy: tests/test_policy.c kl_vrapi_policy.c kl_vrapi.h kl_vrapi_abi.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ tests/test_policy.c kl_vrapi_policy.c

build/test_frame: tests/test_frame.c kl_vrapi_frame.c kl_vrapi_policy.c kl_vrapi.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ tests/test_frame.c kl_vrapi_frame.c kl_vrapi_policy.c

build/test_swapchain: tests/test_swapchain.c kl_vrapi_swapchain.c kl_vrapi_exec.c kl_vrapi_policy.c kl_vrapi.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ tests/test_swapchain.c kl_vrapi_swapchain.c kl_vrapi_exec.c kl_vrapi_policy.c

build/test_pose: tests/test_pose.c kl_vrapi_pose.c kl_vrapi_mode.c kl_vrapi_clock.c kl_vrapi_policy.c kl_vrapi.h
	@mkdir -p build
	$(CC) $(CFLAGS) -o $@ tests/test_pose.c kl_vrapi_pose.c kl_vrapi_mode.c kl_vrapi_clock.c kl_vrapi_policy.c -lm

clean:
	rm -rf build
