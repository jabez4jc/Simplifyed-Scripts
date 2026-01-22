#!/bin/bash

# === CONFIG ===
BASE_DIR="/var/python/openalgo-flask"
DAILY_RESTART_LOG="/var/log/openalgo-daily-restart.log"

echo "🧹 OpenAlgo Log Cleanup"

if [ "$(id -u)" -ne 0 ]; then
    echo "❌ This script must be run with sudo"
    echo "   Usage: sudo ./oa-clear-logs.sh"
    exit 1
fi

if [ ! -d "$BASE_DIR" ]; then
    echo "❌ No instances found in $BASE_DIR"
    exit 1
fi

read -p "This will delete all per-instance log files. Continue? (y/N): " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "❌ Cancelled."
    exit 0
fi

INSTANCES=($(ls -1 "$BASE_DIR" 2>/dev/null))
if [ ${#INSTANCES[@]} -eq 0 ]; then
    echo "❌ No OpenAlgo instances installed."
    exit 1
fi

total_deleted=0
for inst in "${INSTANCES[@]}"; do
    for log_dir in "$BASE_DIR/$inst/log" "$BASE_DIR/$inst/logs"; do
        if [ -d "$log_dir" ]; then
            count=$(find "$log_dir" -type f 2>/dev/null | wc -l | tr -d ' ')
            if [ "$count" -gt 0 ]; then
                find "$log_dir" -type f -delete 2>/dev/null
                echo "✅ Cleared $count log file(s) in $log_dir"
                total_deleted=$((total_deleted + count))
            fi
        fi
    done
done

if [ -f "$DAILY_RESTART_LOG" ]; then
    rm -f "$DAILY_RESTART_LOG"
    echo "✅ Removed daily restart log: $DAILY_RESTART_LOG"
fi

if [ "$total_deleted" -eq 0 ]; then
    echo "ℹ️  No per-instance log files found to delete."
else
    echo "✅ Cleanup complete. Deleted $total_deleted file(s)."
fi
