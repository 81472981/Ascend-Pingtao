#!/usr/bin/env bash
set -euo pipefail

# Back up the two vLLM-Ascend source files needed for the R3 TTFT instrumentation.
# Usage:
#   bash Backup-vllm-ascend-r3-files.sh
# Optional:
#   VLLM_ASCEND_ROOT=/custom/vllm-ascend bash Backup-vllm-ascend-r3-files.sh

VLLM_ASCEND_ROOT="${VLLM_ASCEND_ROOT:-/vllm-workspace/vllm-ascend}"
BACKUP_ROOT="/root/vllm-bak"
STAMP="$(date '+%Y%m%d-%H%M%S')"
BACKUP_DIR="$BACKUP_ROOT/r3-ttft-$STAMP"
RELATIVE_DIR="vllm_ascend/distributed/kv_transfer/kv_pool/ascend_store"
FILES=(pool_scheduler.py kv_transfer.py)

for file in "${FILES[@]}"; do
  source_file="$VLLM_ASCEND_ROOT/$RELATIVE_DIR/$file"
  if [[ ! -f "$source_file" ]]; then
    echo "错误：未找到源码文件：$source_file" >&2
    exit 1
  fi
done

mkdir -p "$BACKUP_DIR"
for file in "${FILES[@]}"; do
  cp -p "$VLLM_ASCEND_ROOT/$RELATIVE_DIR/$file" "$BACKUP_DIR/$file"
done

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$BACKUP_DIR"/* > "$BACKUP_DIR/SHA256SUMS"
fi

echo "备份完成：$BACKUP_DIR"
ls -lh "$BACKUP_DIR"
