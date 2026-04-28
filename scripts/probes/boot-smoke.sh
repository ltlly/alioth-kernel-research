#!/usr/bin/env bash
# Basic post-boot probe: kernel sanity, network, Android responsiveness.
# Returns 0 on pass.
set -uo pipefail

fail() { echo "PROBE FAIL: $*"; exit 1; }

# uname must show our kernel string (KBUILD_BUILD_USER=claude)
adb shell uname -a 2>/dev/null | grep -q "claude" || fail "uname does not show 'claude' (rebuild marker)"

# Basic adb features
adb shell id | grep -q "uid=0" || fail "adb not root"
adb shell getprop sys.boot_completed | grep -q "1" || fail "boot not completed"

# No kernel BUG/oops in dmesg
if adb shell 'dmesg 2>/dev/null | grep -iE "BUG:|Oops|kernel panic"' | grep -q .; then
  fail "dmesg shows kernel issues"
fi

echo "PROBE PASS: boot-smoke"
