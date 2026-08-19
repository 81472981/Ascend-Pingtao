#!/bin/bash
set -e

SERVED_NAME="Qwen3-8B"
MODEL_PATH="/mnt/weight/${SERVED_NAME}"
PORT=8000
MOONCAKE_JSON=/tmp/mooncake.json
MASTER_PORT=50088
METRICS_PORT=9003
SSD_ROOT="${MOONCAKE_SSD_ROOT:-/mnt/mooncake-ssd-offload}"
SSD_BUFFER_GB="${MOONCAKE_SSD_BUFFER_GB:-8}"
SSD_QUOTA_GB="${MOONCAKE_SSD_QUOTA_GB:-3072}"
SSD_BLOCK_DEVICE_OVERRIDE="${MOONCAKE_SSD_BLOCK_DEVICE:-}"
SSD_PROBE_BYTES=$((256 * 1024 * 1024))
# Mooncake 为每个 rank 注册的主机 DRAM 段；要求按 1GB 对齐。
# 默认 256GB，也可在启动前用 MOONCAKE_SEGMENT_GB=... 覆盖。
MOONCAKE_SEGMENT_GB="${MOONCAKE_SEGMENT_GB:-256}"

for size_value in "$MOONCAKE_SEGMENT_GB" "$SSD_BUFFER_GB" "$SSD_QUOTA_GB"; do
  case "$size_value" in
    ''|*[!0-9]*)
      echo "错误：MOONCAKE_SEGMENT_GB、MOONCAKE_SSD_BUFFER_GB、MOONCAKE_SSD_QUOTA_GB 必须是整数 GB"
      exit 1
      ;;
  esac
  if [ "$size_value" -eq 0 ]; then
    echo "错误：DRAM、SSD buffer 和 SSD quota 必须大于 0GB"
    exit 1
  fi
done

while [ "$SSD_ROOT" != "/" ] && [ "${SSD_ROOT%/}" != "$SSD_ROOT" ]; do
  SSD_ROOT="${SSD_ROOT%/}"
done

case "$SSD_ROOT" in
  /*) ;;
  *) echo "错误：MOONCAKE_SSD_ROOT 必须是绝对路径，当前值: $SSD_ROOT"; exit 1 ;;
esac
if [ "$SSD_ROOT" = "/" ] || [ -L "$SSD_ROOT" ]; then
  echo "错误：SSD 根目录不能是 / 或符号链接：$SSD_ROOT"
  exit 1
fi
mkdir -p "$SSD_ROOT"
SSD_SESSION_PATH="$SSD_ROOT/session-$(date '+%Y%m%d-%H%M%S')-$$"
mkdir -p "$SSD_SESSION_PATH"
MASTER_PID=""
VLLM_PID=""

delete_ssd_session() {
  session_dir="$1"
  case "$session_dir" in
    "$SSD_ROOT"/session-*) ;;
    *) echo "拒绝清理非会话目录：$session_dir"; return 1 ;;
  esac
  if [ -d "$session_dir" ]; then
    find "$session_dir" -xdev -depth -mindepth 1 -delete
    rmdir "$session_dir"
  fi
}

cleanup_runtime() {
  cleanup_status=$?
  trap - EXIT INT TERM
  set +e
  echo ""
  echo "正在停止 vLLM/Mooncake 并释放本次 SSD KV Cache..."
  if [ -n "$VLLM_PID" ] && kill -0 "$VLLM_PID" 2>/dev/null; then
    kill -TERM "$VLLM_PID" 2>/dev/null
  fi
  pkill -TERM -f VLLMEngineCore 2>/dev/null
  if [ -n "$MASTER_PID" ] && kill -0 "$MASTER_PID" 2>/dev/null; then
    kill -TERM "$MASTER_PID" 2>/dev/null
  fi
  cleanup_wait=0
  while [ "$cleanup_wait" -lt 30 ] && { { [ -n "$VLLM_PID" ] && kill -0 "$VLLM_PID" 2>/dev/null; } || { [ -n "$MASTER_PID" ] && kill -0 "$MASTER_PID" 2>/dev/null; }; }; do
    sleep 1
    cleanup_wait=$((cleanup_wait + 1))
  done
  if [ -n "$VLLM_PID" ]; then kill -KILL "$VLLM_PID" 2>/dev/null; fi
  pkill -KILL -f VLLMEngineCore 2>/dev/null
  if [ -n "$MASTER_PID" ]; then kill -KILL "$MASTER_PID" 2>/dev/null; fi
  if [ -n "$VLLM_PID" ]; then wait "$VLLM_PID" 2>/dev/null; fi
  if [ -n "$MASTER_PID" ]; then wait "$MASTER_PID" 2>/dev/null; fi
  if delete_ssd_session "$SSD_SESSION_PATH"; then
    echo "SSD KV Cache 已释放：${SSD_SESSION_PATH}；评测结果目录不受影响。"
  else
    echo "错误：SSD KV Cache 自动清理失败，请确认没有残留进程或子挂载：$SSD_SESSION_PATH"
    if [ "$cleanup_status" -eq 0 ]; then cleanup_status=1; fi
  fi
  exit "$cleanup_status"
}
trap cleanup_runtime EXIT INT TERM

if ! command -v findmnt >/dev/null 2>&1 || ! command -v lsblk >/dev/null 2>&1; then
  echo "错误：需要 findmnt 和 lsblk 来证明 SSD 路径位于非旋转块设备上"
  exit 1
fi
SSD_SOURCE=$(findmnt -n -o SOURCE -T "$SSD_SESSION_PATH" | head -1)
SSD_FSTYPE=$(findmnt -n -o FSTYPE -T "$SSD_SESSION_PATH" | head -1)
case "$SSD_FSTYPE" in
  tmpfs|ramfs|devtmpfs)
    echo "错误：SSD 路径位于 ${SSD_FSTYPE}，不是真实 SSD：$SSD_SESSION_PATH"
    exit 1
    ;;
  overlay)
    if [ -z "$SSD_BLOCK_DEVICE_OVERRIDE" ]; then
      echo "错误：SSD 路径位于容器 overlay；必须显式设置 MOONCAKE_SSD_BLOCK_DEVICE，并通过 O_DIRECT 映射探针"
      exit 1
    fi
    SSD_BLOCK_SOURCE="$SSD_BLOCK_DEVICE_OVERRIDE"
    SSD_OVERLAY_MODE=true
    ;;
  *)
    if [ -z "$SSD_SOURCE" ] || [ "${SSD_SOURCE#/dev/}" = "$SSD_SOURCE" ]; then
      echo "错误：无法把 SSD 路径解析为本地块设备：source=$SSD_SOURCE path=$SSD_SESSION_PATH"
      exit 1
    fi
    # bind mount 的 SOURCE 可能是 /dev/nvmeXnYpZ[/host/subdir]。
    SSD_BLOCK_SOURCE="${SSD_SOURCE%%\[*}"
    SSD_OVERLAY_MODE=false
    ;;
esac
if [ -z "$SSD_BLOCK_SOURCE" ] || [ "${SSD_BLOCK_SOURCE#/dev/}" = "$SSD_BLOCK_SOURCE" ] || [ ! -b "$SSD_BLOCK_SOURCE" ]; then
  echo "错误：SSD 后端不是容器内可见的块设备：$SSD_BLOCK_SOURCE"
  exit 1
fi
SSD_ROTA=$(lsblk -ndo ROTA "$SSD_BLOCK_SOURCE" 2>/dev/null | head -1 | tr -d '[:space:]')
SSD_KNAME=$(lsblk -ndo KNAME "$SSD_BLOCK_SOURCE" 2>/dev/null | head -1 | tr -d '[:space:]')
SSD_DEVICE_SIZE_BYTES=$(lsblk -bndo SIZE "$SSD_BLOCK_SOURCE" 2>/dev/null | head -1 | tr -d '[:space:]')
if [ "$SSD_ROTA" != "0" ]; then
  echo "错误：${SSD_BLOCK_SOURCE} 未被识别为非旋转 SSD（ROTA=$SSD_ROTA）"
  exit 1
fi
if [ -z "$SSD_KNAME" ] || [ ! -r "/sys/class/block/$SSD_KNAME/stat" ]; then
  echo "错误：无法读取 SSD 块设备统计：source=$SSD_BLOCK_SOURCE kname=$SSD_KNAME"
  exit 1
fi
if [ -z "$SSD_DEVICE_SIZE_BYTES" ] || [ "$SSD_DEVICE_SIZE_BYTES" -lt $((SSD_QUOTA_GB * 1024 * 1024 * 1024)) ]; then
  echo "错误：SSD 块设备容量小于配置 quota：device=$SSD_BLOCK_SOURCE size=$SSD_DEVICE_SIZE_BYTES"
  exit 1
fi
echo "SSD 设备已验证：path=$SSD_SESSION_PATH filesystem=$SSD_FSTYPE block=$SSD_BLOCK_SOURCE ROTA=$SSD_ROTA"

if [ -r /proc/meminfo ]; then
  AVAILABLE_GB=$(awk '/MemAvailable:/ {printf "%d", $2 / 1024 / 1024}' /proc/meminfo)
  echo "Mooncake 计划注册: ${MOONCAKE_SEGMENT_GB}GB；当前主机可用内存: 约 ${AVAILABLE_GB}GB"
  if [ "$AVAILABLE_GB" -lt $((MOONCAKE_SEGMENT_GB + 32)) ]; then
    echo "警告：建议主机可用内存至少为 Mooncake 段 + 32GB，否则 vLLM/Mooncake 可能启动失败或被 OOM。"
  fi
fi

echo "===== [1/5] 清理旧进程 ====="
# 强杀 vLLM（含子进程 EngineCore）和 mooncake_master
pkill -9 -f "vllm serve" 2>/dev/null || true
pkill -9 -f "VLLMEngineCore" 2>/dev/null || true
pkill -9 -f mooncake_master 2>/dev/null || true
# 清理残留 curl（打压脚本可能还在跑）
pkill -9 -f "curl.*8000" 2>/dev/null || true
sleep 3

# 确认进程杀干净
if pgrep -f "vllm serve|mooncake_master" > /dev/null 2>&1; then
  echo "警告：仍有残留进程，再等 3 秒..."
  sleep 3
fi
if pgrep -f "vllm serve|mooncake_master" > /dev/null 2>&1; then
  echo "错误：旧 vLLM/Mooncake 进程仍未退出，拒绝删除其 SSD 缓存"
  exit 1
fi

# 确认端口释放
while netstat -tlnp 2>/dev/null | grep -qE ":$PORT |:$MASTER_PORT "; do
  echo "等待端口释放..."
  sleep 1
done

echo "HBM 和 Mooncake DRAM 已清理（进程退出，内存自动释放）"

# 旧版本可能留下 session-* 缓存目录。此时旧服务已停止，可以安全回收。
while IFS= read -r -d '' stale_session; do
  if [ "$stale_session" != "$SSD_SESSION_PATH" ]; then
    echo "清理旧 SSD KV Cache：$stale_session"
    if ! delete_ssd_session "$stale_session" && [ -d "$stale_session" ]; then
      echo "错误：旧 SSD KV Cache 未能完全删除：$stale_session"
      exit 1
    fi
  fi
done < <(find "$SSD_ROOT" -xdev -mindepth 1 -maxdepth 1 -type d -name 'session-*' -print0)

if [ "$SSD_OVERLAY_MODE" = true ]; then
  if ! command -v dd >/dev/null 2>&1; then
    echo "错误：容器 overlay 验证需要 dd 的 O_DIRECT 支持"
    exit 1
  fi
  SSD_PROBE_PATH="$SSD_SESSION_PATH/.ssd-device-probe-$$"
  read -r probe_read_before probe_write_before < <(awk '{printf "%.0f %.0f\n", $3 * 512, $7 * 512}' "/sys/class/block/$SSD_KNAME/stat")
  if ! dd if=/dev/zero of="$SSD_PROBE_PATH" bs=4M count=64 oflag=direct conv=fsync status=none; then
    echo "错误：overlay 路径不支持 O_DIRECT 写入，不能可靠用作 SSD offload"
    exit 1
  fi
  read -r probe_read_after probe_write_after < <(awk '{printf "%.0f %.0f\n", $3 * 512, $7 * 512}' "/sys/class/block/$SSD_KNAME/stat")
  probe_write_delta=$((probe_write_after - probe_write_before))
  if [ "$probe_write_delta" -lt "$SSD_PROBE_BYTES" ]; then
    echo "错误：overlay 写入未映射到指定块设备：device=$SSD_BLOCK_SOURCE delta=$probe_write_delta expected>=$SSD_PROBE_BYTES"
    exit 1
  fi
  probe_read_before="$probe_read_after"
  if ! dd if="$SSD_PROBE_PATH" of=/dev/null bs=4M iflag=direct status=none; then
    echo "错误：overlay 路径不支持 O_DIRECT 读取，不能可靠用作 SSD offload"
    exit 1
  fi
  probe_read_after=$(awk '{printf "%.0f\n", $3 * 512}' "/sys/class/block/$SSD_KNAME/stat")
  probe_read_delta=$((probe_read_after - probe_read_before))
  rm -f "$SSD_PROBE_PATH"
  if [ "$probe_read_delta" -lt "$SSD_PROBE_BYTES" ]; then
    echo "错误：overlay 读取未映射到指定块设备：device=$SSD_BLOCK_SOURCE delta=$probe_read_delta expected>=$SSD_PROBE_BYTES"
    exit 1
  fi
  echo "容器 overlay 已通过 O_DIRECT 映射探针：block=$SSD_BLOCK_SOURCE write=$probe_write_delta read=$probe_read_delta bytes"
fi
SSD_AVAILABLE_GB=$(df -Pk "$SSD_SESSION_PATH" | awk 'NR==2 {printf "%d", $4 / 1024 / 1024}')
if [ "$SSD_AVAILABLE_GB" -lt "$SSD_QUOTA_GB" ]; then
  echo "错误：清理旧缓存后 SSD 可用空间约 ${SSD_AVAILABLE_GB}GB，仍小于配置 quota ${SSD_QUOTA_GB}GB"
  exit 1
fi

echo ""
echo "===== [2/5] 环境变量 ====="
export LD_LIBRARY_PATH=/usr/local/lib:/usr/local/Ascend/cann-9.0.1/python/site-packages/mooncake:$LD_LIBRARY_PATH
export PYTHONHASHSEED=0
export ASCEND_RT_VISIBLE_DEVICES=0
export TASK_QUEUE_ENABLE=1
export MOONCAKE_CONFIG_PATH=$MOONCAKE_JSON
export HCCL_IF_IP=192.168.243.40
export HCCL_SOCKET_IFNAME=eth0
export GLOO_SOCKET_IFNAME=eth0
export TP_SOCKET_IFNAME=eth0
export OMP_PROC_BIND=false
export OMP_NUM_THREADS=10
# Enable the benchmark-only /reset_prefix_cache endpoint. Run-all uses it with
# reset_connector=false, so only HBM is cleared and Mooncake DRAM is retained.
export VLLM_SERVER_DEV_MODE=1
unset ASCEND_ENABLE_USE_FABRIC_MEM
export MOONCAKE_REQUESTER_LOCAL_HOSTNAME=192.168.243.40
# Mooncake SSD offload：每次启动使用新的空目录，避免上次会话的数据污染冷启动。
export MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES=$((SSD_BUFFER_GB * 1024 * 1024 * 1024))
export MOONCAKE_OFFLOAD_BUCKET_MAX_TOTAL_SIZE=$((SSD_QUOTA_GB * 1024 * 1024 * 1024))
export MOONCAKE_OFFLOAD_TOTAL_SIZE_LIMIT_BYTES=$((SSD_QUOTA_GB * 1024 * 1024 * 1024))
export MOONCAKE_OFFLOAD_BUCKET_EVICTION_POLICY=none
# io_uring read path 使用 O_DIRECT；R4 还会核对块设备 read-sector 增量，避免页缓存冒充 SSD。
export MOONCAKE_OFFLOAD_USE_URING=1

echo ""
echo "===== [3/5] 生成 mooncake.json ====="
cat > $MOONCAKE_JSON <<EOF
{
  "metadata_server": "P2PHANDSHAKE",
  "protocol": "ascend",
  "device_name": "",
  "master_server_address": "127.0.0.1:$MASTER_PORT",
  "global_segment_size": "${MOONCAKE_SEGMENT_GB}GB",
  "preferred_segment": false,
  "prefer_alloc_in_same_node": true,
  "enable_ssd_offload": true,
  "ssd_offload_path": "$SSD_SESSION_PATH",
  "benchmark_ssd_verified": true,
  "benchmark_ssd_source": "$SSD_SOURCE",
  "benchmark_ssd_block_source": "$SSD_BLOCK_SOURCE",
  "benchmark_ssd_fstype": "$SSD_FSTYPE",
  "benchmark_ssd_kname": "$SSD_KNAME",
  "benchmark_ssd_direct_io": true,
  "benchmark_ssd_overlay_verified": $SSD_OVERLAY_MODE,
  "benchmark_cleanup_managed": true,
  "benchmark_startup_pid": $$
}
EOF
cat $MOONCAKE_JSON

echo ""
echo "===== [4/5] 启动 mooncake_master ====="
mooncake_master --port $MASTER_PORT \
  --eviction_high_watermark_ratio 0.9 \
  --eviction_ratio 0.1 \
  --default_kv_lease_ttl 11000 \
  --enable_offload=true \
  --offload_on_evict=false \
  --promotion_on_hit=false \
  --client_ttl=120 \
  > /tmp/mooncake_master.log 2>&1 &
MASTER_PID=$!
sleep 3

# 验证 mooncake_master 启动成功且数据为空
if curl -s -m 2 http://127.0.0.1:$METRICS_PORT/health > /dev/null 2>&1; then
  echo "mooncake_master 启动成功"
  echo "初始状态: $(curl -s http://127.0.0.1:$METRICS_PORT/metrics/summary | grep -o 'Mem Storage: [^|]*| SSD Storage: [^|]*| Keys: [0-9]*' | head -1)"
  MASTER_METRICS=$(curl -s http://127.0.0.1:$METRICS_PORT/metrics)
  for metric in mem_cache_hit_nums_ file_cache_hit_nums_ mem_cache_hit_bytes_total file_cache_hit_bytes_total mem_cache_nums_ file_cache_nums_ valid_get_nums_ master_evicted_key_count_mem; do
    if ! printf '%s\n' "$MASTER_METRICS" | grep -q "^${metric}[{ ]"; then
      echo "错误：Mooncake 缺少 SSD 可靠性校验指标 ${metric}；不能运行正式 SSD 评测"
      exit 1
    fi
  done
else
  echo "错误：mooncake_master 启动失败，查看日志："
  tail -20 /tmp/mooncake_master.log
  exit 1
fi

echo ""
echo "===== [5/5] 启动 vLLM ====="
vllm serve "$MODEL_PATH" \
  --port "$PORT" \
  --trust-remote-code \
  --served-model-name "$SERVED_NAME" \
  --block-size 128 \
  --enable-prefix-caching \
  --tensor-parallel-size 1 \
  --max-model-len 32768 \
  --gpu-memory-utilization 0.9 \
  --kv-transfer-config '{
    "kv_connector": "AscendStoreConnector",
    "kv_role": "kv_both",
    "kv_load_failure_policy": "recompute",
    "kv_connector_extra_config": {
      "backend": "mooncake",
      "lookup_rpc_port": "0",
      "load_async": true
    }
  }' &
VLLM_PID=$!
wait "$VLLM_PID"
