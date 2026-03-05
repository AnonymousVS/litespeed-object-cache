#!/bin/bash

LOG_FILE="/var/log/lscwp-setup.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-setup-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=30

log() {
    local DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

cleanup() {
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR"
mkdir -p "$RESULT_DIR/check"
mkdir -p "$RESULT_DIR/fix"

START_TIME=$(date +%s)

# ====================================
# เช็ค WP-CLI
# ====================================
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI กรุณาติดตั้งก่อน"
    exit 1
fi

# ====================================
# เช็ค Redis
# ====================================
if [ ! -S "/var/run/redis/redis.sock" ]; then
    log "❌ ERROR: ไม่พบ Redis Socket ที่ /var/run/redis/redis.sock"
    exit 1
fi

REDIS_PING=$(redis-cli -s /var/run/redis/redis.sock ping 2>/dev/null)
if [ "$REDIS_PING" != "PONG" ]; then
    log "❌ ERROR: Redis ไม่ตอบสนอง (ping ได้ = ${REDIS_PING:-ไม่มีผล})"
    exit 1
fi

# ====================================
# สแกน cPanel Accounts
# ====================================
log "======================================"
log " PRE-SCAN: กำลังสแกน cPanel Accounts..."
log "======================================"

CPANEL_USERS_HOME1=()
CPANEL_USERS_HOME2=()
CPANEL_USERS_BOTH=()    # มีทั้ง /home และ /home2
CPANEL_USERS_ALL=()     # รวมทุก account

# ดึง list จาก /etc/trueuserdomains หรือ /etc/passwd (เฉพาะ cPanel users)
# วิธีที่แม่นที่สุดคืออ่านจาก /var/cpanel/users/ หรือ /etc/trueuserdomains
if [ -d "/var/cpanel/users" ]; then
    CPANEL_SOURCE="cpanel_dir"
    RAW_USERS=$(ls /var/cpanel/users/ 2>/dev/null | grep -v "^root$")
elif [ -f "/etc/trueuserdomains" ]; then
    CPANEL_SOURCE="trueuserdomains"
    RAW_USERS=$(awk '{print $NF}' /etc/trueuserdomains 2>/dev/null | sort -u | grep -v "^root$")
else
    CPANEL_SOURCE="passwd"
    RAW_USERS=$(awk -F: '$3 >= 500 && $3 < 65534 && $1 != "nobody" {print $1}' /etc/passwd 2>/dev/null | grep -v "^root$")
fi

log " แหล่งข้อมูล cPanel : $CPANEL_SOURCE"

for user in $RAW_USERS; do
    IN_HOME1=false
    IN_HOME2=false

    [ -d "/home/${user}" ]  && IN_HOME1=true
    [ -d "/home2/${user}" ] && IN_HOME2=true

    if $IN_HOME1 || $IN_HOME2; then
        CPANEL_USERS_ALL+=("$user")
    fi

    if $IN_HOME1 && $IN_HOME2; then
        CPANEL_USERS_BOTH+=("$user")
    elif $IN_HOME1; then
        CPANEL_USERS_HOME1+=("$user")
    elif $IN_HOME2; then
        CPANEL_USERS_HOME2+=("$user")
    fi
done

TOTAL_ACCOUNTS=${#CPANEL_USERS_ALL[@]}
COUNT_HOME1=${#CPANEL_USERS_HOME1[@]}
COUNT_HOME2=${#CPANEL_USERS_HOME2[@]}
COUNT_BOTH=${#CPANEL_USERS_BOTH[@]}

log "--------------------------------------"
log " ผลสแกน cPanel Accounts"
log "--------------------------------------"
log " 👥 รวม cPanel Accounts ทั้งหมด : $TOTAL_ACCOUNTS accounts"
log " 📁 อยู่ใน /home เท่านั้น        : $COUNT_HOME1 accounts"
log " 📁 อยู่ใน /home2 เท่านั้น       : $COUNT_HOME2 accounts"
log " 📁 อยู่ทั้ง /home และ /home2    : $COUNT_BOTH accounts"
log "--------------------------------------"

if [ "$COUNT_HOME1" -gt 0 ]; then
    log " 📂 Accounts ใน /home:"
    for u in "${CPANEL_USERS_HOME1[@]}"; do
        log "    - $u"
    done
fi

if [ "$COUNT_HOME2" -gt 0 ]; then
    log " 📂 Accounts ใน /home2:"
    for u in "${CPANEL_USERS_HOME2[@]}"; do
        log "    - $u"
    done
fi

if [ "$COUNT_BOTH" -gt 0 ]; then
    log " 📂 Accounts ที่อยู่ทั้ง /home และ /home2:"
    for u in "${CPANEL_USERS_BOTH[@]}"; do
        log "    - $u"
    done
fi

log "======================================"

if [ "$TOTAL_ACCOUNTS" -eq 0 ]; then
    log "⚠️  WARNING: ไม่พบ cPanel accounts ใน /home หรือ /home2"
    log "   กรุณาตรวจสอบว่าเซิร์ฟเวอร์นี้ใช้ cPanel จริงหรือไม่"
fi

# ====================================
# คำนวณ MAX_JOBS อัตโนมัติ
# ====================================
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
log " LITESPEED OBJECT CACHE SETUP"
log " เริ่มเวลา      : $(date '+%Y-%m-%d %H:%M:%S')"
log " CPU Cores     : $CPU_CORES Core"
log " Total RAM     : $TOTAL_RAM_MB MB"
log " Auto MAX_JOBS : $MAX_JOBS"
log " Redis Status  : ✅ PONG"
log " WP-CLI        : ✅ $(wp --version --allow-root 2>/dev/null)"
log "======================================"

# ====================================
# หา WordPress ทั้งหมด (รองรับ /home และ /home2)
# ====================================
DIRS=()

# สแกนจาก /home
for dir in /home/*/public_html/*/; do
    if [ -f "${dir}wp-config.php" ]; then
        DIRS+=("$dir")
    fi
done

# สแกนจาก /home2 (ถ้ามี)
if [ -d "/home2" ]; then
    for dir in /home2/*/public_html/*/; do
        if [ -f "${dir}wp-config.php" ]; then
            DIRS+=("$dir")
        fi
    done
fi

TOTAL=${#DIRS[@]}
log "พบ WordPress ทั้งหมด: $TOTAL เว็บ (จาก $TOTAL_ACCOUNTS cPanel accounts)"
log "======================================"

# ====================================
# PHASE 1: Check
# ====================================
log " PHASE 1: กำลังตรวจสอบค่าปัจจุบัน..."
log "======================================"

check_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"

    # รองรับทั้ง /home และ /home2 (field 3 หรือ 4 ของ path)
    local BASE=$(echo "$dir" | cut -d'/' -f2)   # home หรือ home2
    if [ "$BASE" = "home2" ]; then
        local SITE=$(echo "$dir" | awk -F'/' '{print $3"/"$5}')
    else
        local SITE=$(echo "$dir" | awk -F'/' '{print $3"/"$5}')
    fi
    SITE="[$BASE] $SITE"

    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    if ! _wp plugin is-installed litespeed-cache; then
        _log "⏭  NO LITESPEED: $SITE"
        touch "${RESULT_DIR}/check/noplugin_${UNIQUE}"
        return
    fi

    if ! _wp plugin is-active litespeed-cache; then
        _log "⏭  INACTIVE: $SITE"
        touch "${RESULT_DIR}/check/inactive_${UNIQUE}"
        return
    fi

    local CUR_OBJ=$(_wp litespeed-option get object | tr -d '[:space:]')
    local CUR_KIND=$(_wp litespeed-option get object-kind | tr -d '[:space:]')
    local CUR_HOST=$(_wp litespeed-option get object-host | tr -d '[:space:]')
    local CUR_PORT=$(_wp litespeed-option get object-port | tr -d '[:space:]')

    if [ "$CUR_OBJ" = "1" ] && [ "$CUR_KIND" = "1" ] && \
       [ "$CUR_HOST" = "/var/run/redis/redis.sock" ] && [ "$CUR_PORT" = "0" ]; then
        _log "✅ CORRECT: $SITE"
        touch "${RESULT_DIR}/check/correct_${UNIQUE}"
    else
        _log "⚠️  NEEDS FIX: $SITE"
        _log "   object=$CUR_OBJ | kind=$CUR_KIND | host=$CUR_HOST | port=$CUR_PORT"
        ( flock 200; echo "$dir" >> "$RESULT_DIR/needs_fix.txt" ) 200>"$LOCK_FILE"
        touch "${RESULT_DIR}/check/needsfix_${UNIQUE}"
    fi
}

export -f check_site

declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    check_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

CORRECT=$(find "$RESULT_DIR/check" -name "correct_*" 2>/dev/null | wc -l)
NEEDSFIX=$(find "$RESULT_DIR/check" -name "needsfix_*" 2>/dev/null | wc -l)
NOPLUGIN=$(find "$RESULT_DIR/check" -name "noplugin_*" 2>/dev/null | wc -l)
INACTIVE=$(find "$RESULT_DIR/check" -name "inactive_*" 2>/dev/null | wc -l)
SKIPPED=$(( NOPLUGIN + INACTIVE ))

log "======================================"
log " สรุปผล PHASE 1"
log " รวมทั้งหมด         : $TOTAL เว็บ"
log " ✅ ถูกต้องแล้ว      : $CORRECT เว็บ"
log " ⚠️  ต้องแก้ไข       : $NEEDSFIX เว็บ"
log " ⏭  ข้าม (No Plugin) : $NOPLUGIN เว็บ"
log " ⏭  ข้าม (Inactive)  : $INACTIVE เว็บ"
log "======================================"

if [ "$NEEDSFIX" -eq 0 ]; then
    log "✅ ทุกเว็บถูกต้องแล้ว ไม่ต้องแก้ไขอะไร"
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    log " เวลาที่ใช้ : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
    log "======================================"
    exit 0
fi

# ====================================
# PHASE 2: Setup
# ====================================
log " PHASE 2: กำลังแก้ไข $NEEDSFIX เว็บ..."
log "======================================"

fix_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"

    local BASE=$(echo "$dir" | cut -d'/' -f2)
    local SITE=$(echo "$dir" | awk -F'/' '{print $3"/"$5}')
    SITE="[$BASE] $SITE"

    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    local FAILED=0

    _wp litespeed-option set object 1 || FAILED=1
    _wp litespeed-option set object-kind 1 || FAILED=1
    _wp litespeed-option set object-host "/var/run/redis/redis.sock" || FAILED=1
    _wp litespeed-option set object-port "0" || FAILED=1
    _wp litespeed-option set object-user "" || \
    _wp litespeed-option set object-user " " || FAILED=1
    _wp litespeed-option set object-pswd "" || \
    _wp litespeed-option set object-pswd " " || FAILED=1

    if [ "$FAILED" -eq 1 ]; then
        _log "❌ FAILED (Set Error): $SITE"
        touch "${RESULT_DIR}/fix/failed_${UNIQUE}"
        return
    fi

    _log "✅ SET DONE: $SITE"
    touch "${RESULT_DIR}/fix/success_${UNIQUE}"
}

export -f fix_site

declare -a PIDS=()
while IFS= read -r dir; do
    fix_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done < "$RESULT_DIR/needs_fix.txt"
for pid in "${PIDS[@]}"; do wait "$pid"; done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

SUCCESS=$(find "$RESULT_DIR/fix" -name "success_*" 2>/dev/null | wc -l)
FAILED=$(find "$RESULT_DIR/fix" -name "failed_*" 2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " 👥 cPanel Accounts    : $TOTAL_ACCOUNTS accounts"
log "    /home              : $COUNT_HOME1 | /home2: $COUNT_HOME2 | ทั้งคู่: $COUNT_BOTH"
log " รวมทั้งหมด            : $TOTAL เว็บ"
log " ✅ ถูกต้องอยู่แล้ว   : $CORRECT เว็บ"
log " ✅ Set สำเร็จ          : $SUCCESS เว็บ"
log " ❌ Set ไม่สำเร็จ       : $FAILED เว็บ"
log " ⏭  ข้ามทั้งหมด         : $SKIPPED เว็บ"
log " เวลาที่ใช้             : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log " ✅ รัน verify ต่อด้วย  : verify-object-cache.sh"
log "======================================"
