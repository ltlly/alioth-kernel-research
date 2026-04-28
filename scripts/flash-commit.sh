#!/usr/bin/env bash
# Permanently flash a validated boot.img to slot _b and switch active.
# Refuses to run unless a green LAST_TEST exists (i.e., flash-test.sh passed).
# Usage: flash-commit.sh <boot.img>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
img="${1:?img required}"

LAST_TEST="$ROOT/runs/LAST_TEST"
test -f "$LAST_TEST" || { echo "Refusing: no green flash-test run on record"; exit 21; }

log() { echo "[$(date +%T)] $*"; }

state=$(adb get-state 2>/dev/null || echo unknown)
if [[ "$state" == "device" ]]; then
  log "rebooting to bootloader"
  adb reboot bootloader
  sleep 5
fi

deadline=$((SECONDS+90))
until fastboot devices | grep -q .; do
  if (( SECONDS > deadline )); then echo "no fastboot"; exit 22; fi
  sleep 2
done

log "current slots:"
fastboot getvar all 2>&1 | grep -E "current-slot|has-slot|slot-count" || true

# Defensive: never touch slot _a — only flash boot_b
log "flashing $img to boot_b"
fastboot flash boot_b "$img"

log "setting active=b"
fastboot --set-active=b

log "rebooting"
fastboot reboot

# Wait for adb back
deadline=$((SECONDS+180))
until adb get-state 2>/dev/null | grep -q '^device$'; do
  if (( SECONDS > deadline )); then
    log "device did not return — invoking recover.sh"
    "$ROOT/scripts/recover.sh" --reason "flash-commit boot timeout"
    exit 23
  fi
  sleep 3
done

log "=== flash-commit done; on slot b. Run soak monitor next. ==="
