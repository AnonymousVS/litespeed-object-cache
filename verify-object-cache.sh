#!/bin/bash

LOG_FILE="/var/log/lscwp-verify.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-verify-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=30

log() {
    local DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

cleanup() {
    wait
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR"

START_TIME=$(date +%s)

if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI"
    exit 1
fi

CPU_CORES=$(nproc)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
MAX_JOBS_BY_RAM=$(( TOTAL_RAM_MB / RAM_PER_JOB_MB ))

if [ "$CPU_CORES" -lt "$MAX_JOBS_BY_RAM" ]; then
    MAX_JOBS=$CPU_CORES
else
    MAX_JOBS=$MAX_JOBS_BY_RAM
fi

[ "$MAX_JOBS" -lt 1 ] && MAX_JOBS=1
[ "$MAX_JOBS" -gt 20 ] && MAX_JOBS=20

log "======================================"
log " LITESPEED OBJECT CACHE VERIFY"
log " เริ่มเวลา      : $(date '+%Y-%m-%d %H:%M:%S')"
log " CPU Cores     : $CPU_CORES Core"
log " Total RAM     : $TOTAL_RAM_MB MB"
log " Auto MAX_JOBS : $MAX_JOBS"
log "======================================"

DIRS=()
for dir in /home/*/public_html/*/; do
    if [ -f "${dir}wp-config.php" ]; then
        DIRS+=("$dir")
    fi
done

TOTAL=${#DIRS[@]}
log "พบ WordPress ทั้งหมด: $TOTAL เว็บ"
log "======================================"

verify_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local SITE=$(echo "$dir" | awk -F'/' '{print $5"/"$7}')
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    if [ ! -d "$RESULT_DIR" ]; then return; fi

    if ! _wp plugin is-installed litespeed-cache; then
        _log "⏭  NO LITESPEED: $SITE"
        touch "${RESULT_DIR}/skipped_${UNIQUE}" 2>/dev/null
        return
    fi

    if ! _wp plugin is-active litespeed-cache; then
        _log "⏭  INACTIVE: $SITE"
        touch "${RESULT_DIR}/skipped_${UNIQUE}" 2>/dev/null
        return
    fi

    local OBJ=$(_wp litespeed-option get object | tr -d '[:space:]')
    local KIND=$(_wp litespeed-option get object-kind | tr -d '[:space:]')
    local HOST=$(_wp litespeed-option get object-host | tr -d '[:space:]')
    local PORT=$(_wp litespeed-option get object-port | tr -d "'\"\`[:space:]")
    [ -z "$PORT" ] && PORT="0"

    if [ "$OBJ" = "1" ] && [ "$KIND" = "1" ] && \
       [ "$HOST" = "/var/run/redis/redis.sock" ] && [ "$PORT" = "0" ]; then
        _log "✅ PASS: $SITE"
        touch "${RESULT_DIR}/pass_${UNIQUE}" 2>/dev/null
    else
        _log "❌ FAIL: $SITE"
        _log "   object=$OBJ | kind=$KIND | host=$HOST | port=$PORT"
        ( flock 200; echo "$dir" >> "$RESULT_DIR/failed_sites.txt" ) 200>"$LOCK_FILE"
        touch "${RESULT_DIR}/fail_${UNIQUE}" 2>/dev/null
    fi
}

export -f verify_site

declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    verify_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

PASS=$(find "$RESULT_DIR" -name "pass_*" 2>/dev/null | wc -l)
FAIL=$(find "$RESULT_DIR" -name "fail_*" 2>/dev/null | wc -l)
SKIPPED=$(find "$RESULT_DIR" -name "skipped_*" 2>/dev/null | wc -l)

log "======================================"
log " สรุปผล Verify"
log " รวมทั้งหมด   : $TOTAL เว็บ"
log " ✅ PASS      : $PASS เว็บ"
log " ❌ FAIL      : $FAIL เว็บ"
log " ⏭  Skipped   : $SKIPPED เว็บ"
log " เวลาที่ใช้    : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log " Log อยู่ที่   : $LOG_FILE"
log "======================================"

if [ "$FAIL" -gt 0 ] && [ -f "$RESULT_DIR/failed_sites.txt" ]; then
    log " เว็บที่ FAIL ทั้งหมด:"
    while IFS= read -r dir; do
        SITE=$(echo "$dir" | awk -F'/' '{print $5"/"$7}')
        log " ❌ $SITE"
    done < "$RESULT_DIR/failed_sites.txt"
    log "======================================"
    log " รัน setup อีกครั้ง: setup-object-cache.sh"
    log "======================================"
fi
```

---

## Step by Step

---

## STEP 1: เข้า GitHub แก้ไขไฟล์
```
https://github.com/ufavision/server-scripts/blob/main/verify-object-cache.sh
