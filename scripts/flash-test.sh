#!/usr/bin/env bash
# RAM-only fastboot boot of a candidate boot.img + smoke probe.
# Does NOT write to flash. On success, exits 0. On failure, calls recover.sh.
# Usage: flash-test.sh <path/to/boot.img> [--probe <probe-script>]
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:?img required}"
probe=""
if [[ "${2:-}" == "--probe" ]]; then probe="$3"; fi

ts=$(date +%Y%m%d-%H%M%S)
RUN_DIR="$ROOT/runs/$ts-flash-test"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/flash-test.log"
log() { echo "[$(date +%T)] $*" | tee -a "$LOG"; }

trap 'log "trap fired; running recover.sh"; "$ROOT/scripts/recover.sh" --reason "flash-test trap" || true' ERR

log "=== flash-test start: $img ==="

# Reboot to bootloader if needed
state=$(adb get-state 2>/dev/null || echo unknown)
if [[ "$state" == "device" ]]; then
  log "rebooting device to bootloader"
  adb reboot bootloader
  sleep 5
fi

# Wait for fastboot
deadline=$((SECONDS+90))
until fastboot devices | grep -q .; do
  if (( SECONDS > deadline )); then log "device never reached fastboot"; exit 11; fi
  sleep 2
done

log "issuing 'fastboot boot $img'"
fastboot boot "$img" 2>&1 | tee -a "$LOG"

# Wait for adb
log "waiting for adb (up to 120s)"
deadline=$((SECONDS+120))
until adb get-state 2>/dev/null | grep -q '^device$'; do
  if (( SECONDS > deadline )); then
    log "ABORT: adb never came back; running recover"
    "$ROOT/scripts/recover.sh" --reason "boot timed out"
    exit 12
  fi
  sleep 3
done
adb root >/dev/null 2>&1 || true
sleep 2

# Smoke checks
log "--- uname ---"
adb shell uname -a 2>&1 | tee -a "$LOG"
log "--- dmesg panic/oops/bug ---"
if adb shell 'dmesg 2>/dev/null | grep -iE "panic|oops|BUG:|Unable to handle"' 2>&1 | tee -a "$LOG" | grep -q .; then
  log "WARN: dmesg shows trouble — review $LOG"
fi
log "--- sys.boot_completed ---"
deadline=$((SECONDS+60))
while [[ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" != "1" ]]; do
  if (( SECONDS > deadline )); then
    log "WARN: boot_completed never reached 1 (still functional but degraded)"
    break
  fi
  sleep 3
done
adb shell getprop sys.boot_completed 2>&1 | tee -a "$LOG"

# Run probe if specified
if [[ -n "$probe" ]]; then
  log "--- running probe: $probe ---"
  if ! bash "$probe" 2>&1 | tee "$RUN_DIR/probe.log"; then
    log "PROBE FAILED"
    exit 13
  fi
fi

log "=== flash-test PASS ==="
echo "RUN_DIR=$RUN_DIR" > "$ROOT/runs/LAST_TEST"
