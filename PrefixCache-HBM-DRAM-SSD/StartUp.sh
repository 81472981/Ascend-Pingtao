#!/bin/bash
(
set -e

# 外层子 Shell 使完整脚本可以直接粘贴到登录终端；exit/trap 不会退出 SSH Shell。
STARTUP_PID="${BASHPID:-$$}"
STARTUP_START_TICKS=""
if [ -r "/proc/$STARTUP_PID/stat" ]; then
  STARTUP_START_TICKS=$(awk '{print $22}' "/proc/$STARTUP_PID/stat")
fi
STARTUP_VERSION="restart-preserve-ssd-v1"

SERVED_NAME="Qwen3-8B"
MODEL_PATH="/mnt/weight/${SERVED_NAME}"
PORT=8000
MOONCAKE_JSON=/tmp/mooncake.json
MASTER_PORT=50088
METRICS_PORT=9003
SSD_ROOT="${MOONCAKE_SSD_ROOT:-/mnt/mooncake-ssd-offload}"
# Qwen3-8B 的单条 16K BF16 KV 约 2.25GB；接收线程逐请求读取，默认 4GB
# 可覆盖单条 R4，同时避免为并发数重复预留 staging buffer。
SSD_BUFFER_MB="${MOONCAKE_SSD_BUFFER_MB:-4096}"
SSD_QUOTA_GB="${MOONCAKE_SSD_QUOTA_GB:-3072}"
# A3 未启用 Fabric Memory 时，vLLM-Ascend/Mooncake 官方建议使用 NPU 中转
# buffer。它会避免把超大的 DRAM 段和 SSD staging buffer 直接映射进 ADXL。
ASCEND_TRANSFER_BUFFER_POOL="${MOONCAKE_ASCEND_BUFFER_POOL:-4:8}"
# 当前评测容器的 overlay 位于 nvme3n1p1；其他环境仍可通过同名变量覆盖。
SSD_BLOCK_DEVICE_OVERRIDE="${MOONCAKE_SSD_BLOCK_DEVICE:-/dev/nvme3n1p1}"
SSD_PROBE_BYTES=$((256 * 1024 * 1024))
# Mooncake 为每个 rank 注册的主机 DRAM 段；要求按 1GB 对齐。
# 默认 256GB，也可在启动前用 MOONCAKE_SEGMENT_GB=... 覆盖。
MOONCAKE_SEGMENT_GB="${MOONCAKE_SEGMENT_GB:-256}"
# 保持与加入 SSD 前已经验证通过的 HBM/DRAM 基线一致。
VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-32768}"
VLLM_GPU_MEMORY_UTILIZATION="${VLLM_GPU_MEMORY_UTILIZATION:-0.9}"
# Mooncake 0.3.12.post1 移除了 16K SSD 回填触发的 kMaxSliceSize 断言。
# 正式评测固定使用该版本，避免 Python 元数据已升级但仍导入 CANN 内置旧库。
MOONCAKE_REQUIRED_VERSION="${MOONCAKE_REQUIRED_VERSION:-0.3.12.post1}"

for size_value in "$MOONCAKE_SEGMENT_GB" "$SSD_QUOTA_GB"; do
  case "$size_value" in
    ''|*[!0-9]*)
      echo "错误：MOONCAKE_SEGMENT_GB、MOONCAKE_SSD_QUOTA_GB 必须是整数 GB"
      exit 1
      ;;
  esac
  if [ "$size_value" -eq 0 ]; then
    echo "错误：DRAM、SSD buffer 和 SSD quota 必须大于 0GB"
    exit 1
  fi
done
case "$SSD_BUFFER_MB" in
  ''|*[!0-9]*) echo "错误：MOONCAKE_SSD_BUFFER_MB 必须是整数 MB"; exit 1 ;;
esac
if [ "$SSD_BUFFER_MB" -eq 0 ]; then
  echo "错误：MOONCAKE_SSD_BUFFER_MB 必须大于 0MB"
  exit 1
fi
case "$ASCEND_TRANSFER_BUFFER_POOL" in
  *:*)
    buffer_pool_count="${ASCEND_TRANSFER_BUFFER_POOL%%:*}"
    buffer_pool_size_mb="${ASCEND_TRANSFER_BUFFER_POOL#*:}"
    ;;
  *)
    echo "错误：MOONCAKE_ASCEND_BUFFER_POOL 必须是 数量:大小MB，例如 4:8"
    exit 1
    ;;
esac
for buffer_pool_value in "$buffer_pool_count" "$buffer_pool_size_mb"; do
  case "$buffer_pool_value" in
    ''|*[!0-9]*)
      echo "错误：MOONCAKE_ASCEND_BUFFER_POOL 必须是正整数:正整数，例如 4:8"
      exit 1
      ;;
  esac
  if [ "$buffer_pool_value" -eq 0 ]; then
    echo "错误：MOONCAKE_ASCEND_BUFFER_POOL 不能关闭；A3 非 Fabric 模式需要中转 buffer"
    exit 1
  fi
done
case "$VLLM_MAX_MODEL_LEN" in
  ''|*[!0-9]*) echo "错误：VLLM_MAX_MODEL_LEN 必须是整数"; exit 1 ;;
esac
if [ "$VLLM_MAX_MODEL_LEN" -le 16384 ]; then
  echo "错误：VLLM_MAX_MODEL_LEN 必须大于默认测试输入 16384"
  exit 1
fi
if ! awk -v value="$VLLM_GPU_MEMORY_UTILIZATION" 'BEGIN { exit !(value > 0 && value < 1) }'; then
  echo "错误：VLLM_GPU_MEMORY_UTILIZATION 必须是 0 到 1 之间的小数"
  exit 1
fi

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
SSD_SESSION_PATH="$SSD_ROOT/session-$(date '+%Y%m%d-%H%M%S')-$STARTUP_PID"
mkdir -p "$SSD_SESSION_PATH"
MASTER_PID=""
VLLM_PID=""
VLLM_PATCH_DIR=""
VLLM_LOG=""
MASTER_LOG=""
RUNTIME_GENERATION=1
RESTART_REQUESTED=0
RUNTIME_REQUEST_PATH="/tmp/mooncake-benchmark-$STARTUP_PID.request"
RUNTIME_STATUS_PATH="/tmp/mooncake-benchmark-$STARTUP_PID.status"
VLLM_START_TIMEOUT_SECONDS="${VLLM_START_TIMEOUT_SECONDS:-1800}"

case "$VLLM_START_TIMEOUT_SECONDS" in
  ''|*[!0-9]*) echo "错误：VLLM_START_TIMEOUT_SECONDS 必须是整数秒"; exit 1 ;;
esac
if [ "$VLLM_START_TIMEOUT_SECONDS" -eq 0 ]; then
  echo "错误：VLLM_START_TIMEOUT_SECONDS 必须大于 0"
  exit 1
fi

umask 077
: > "$RUNTIME_REQUEST_PATH"

write_runtime_status() {
  local runtime_state="$1"
  local runtime_request_id="${2:-}"
  local runtime_message
  local runtime_status_tmp="$RUNTIME_STATUS_PATH.tmp"
  runtime_message=$(printf '%s' "${3:-}" | tr '\n=' '  ')
  cat > "$runtime_status_tmp" <<EOF
state=$runtime_state
generation=$RUNTIME_GENERATION
request_id=$runtime_request_id
startup_pid=$STARTUP_PID
startup_start_ticks=$STARTUP_START_TICKS
master_pid=$MASTER_PID
vllm_pid=$VLLM_PID
ssd_session_path=$SSD_SESSION_PATH
master_log=$MASTER_LOG
vllm_log=$VLLM_LOG
message=$runtime_message
EOF
  chmod 600 "$runtime_status_tmp"
  mv -f "$runtime_status_tmp" "$RUNTIME_STATUS_PATH"
}

runtime_descendants() {
  local runtime_parent="$1"
  local runtime_child
  for runtime_child in $(pgrep -P "$runtime_parent" 2>/dev/null || true); do
    runtime_descendants "$runtime_child"
    printf '%s\n' "$runtime_child"
  done
}

process_is_running() {
  local process_pid="$1"
  local process_state
  if ! kill -0 "$process_pid" 2>/dev/null; then
    return 1
  fi
  if [ ! -r "/proc/$process_pid/stat" ]; then
    return 1
  fi
  process_state=$(sed 's/^.*) //' "/proc/$process_pid/stat" 2>/dev/null | awk '{print $1}')
  [ "$process_state" != "Z" ]
}

stop_process_tree() {
  local runtime_root="$1"
  local runtime_pids runtime_pid runtime_wait runtime_alive
  if [ -z "$runtime_root" ] || ! process_is_running "$runtime_root"; then
    if [ -n "$runtime_root" ]; then wait "$runtime_root" 2>/dev/null || true; fi
    return 0
  fi
  runtime_pids="$runtime_root $(runtime_descendants "$runtime_root")"
  for runtime_pid in $runtime_pids; do
    kill -TERM "$runtime_pid" 2>/dev/null || true
  done
  runtime_wait=0
  while [ "$runtime_wait" -lt 60 ]; do
    runtime_alive=false
    for runtime_pid in $runtime_pids; do
      if process_is_running "$runtime_pid"; then
        runtime_alive=true
        break
      fi
    done
    if [ "$runtime_alive" = false ]; then
      break
    fi
    sleep 1
    runtime_wait=$((runtime_wait + 1))
  done
  for runtime_pid in $runtime_pids; do
    kill -KILL "$runtime_pid" 2>/dev/null || true
  done
  wait "$runtime_root" 2>/dev/null || true
}

stop_runtime_processes() {
  stop_process_tree "$VLLM_PID"
  stop_process_tree "$MASTER_PID"
  VLLM_PID=""
  MASTER_PID=""
}

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
  trap - EXIT INT TERM USR1
  set +e
  echo ""
  echo "正在停止 vLLM/Mooncake 并释放本次 SSD KV Cache..."
  write_runtime_status stopping "" "final cleanup" 2>/dev/null || true
  stop_runtime_processes
  if [ -n "$VLLM_LOG" ] && [ -f "$VLLM_LOG" ]; then
    echo "vLLM 日志保留：$VLLM_LOG"
  fi
  case "$VLLM_PATCH_DIR" in
    /tmp/vllm-ssd-lazy-init.*)
      if [ -d "$VLLM_PATCH_DIR" ]; then
        find "$VLLM_PATCH_DIR" -xdev -depth -mindepth 1 -delete
        rmdir "$VLLM_PATCH_DIR"
      fi
      ;;
    '') ;;
    *) echo "拒绝清理非预期的临时补丁目录：$VLLM_PATCH_DIR" ;;
  esac
  if delete_ssd_session "$SSD_SESSION_PATH"; then
    echo "SSD KV Cache 已释放：${SSD_SESSION_PATH}；评测结果目录不受影响。"
  else
    echo "错误：SSD KV Cache 自动清理失败，请确认没有残留进程或子挂载：$SSD_SESSION_PATH"
    if [ "$cleanup_status" -eq 0 ]; then cleanup_status=1; fi
  fi
  rm -f "$RUNTIME_REQUEST_PATH" "$RUNTIME_STATUS_PATH" "$RUNTIME_STATUS_PATH.tmp"
  exit "$cleanup_status"
}
trap cleanup_runtime EXIT INT TERM
trap 'RESTART_REQUESTED=1' USR1

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
if [ -z "$SSD_BLOCK_SOURCE" ] || [ "${SSD_BLOCK_SOURCE#/dev/}" = "$SSD_BLOCK_SOURCE" ]; then
  echo "错误：SSD 后端设备名称无效：$SSD_BLOCK_SOURCE"
  exit 1
fi
SSD_KNAME="${SSD_BLOCK_SOURCE##*/}"
case "$SSD_KNAME" in
  ''|*[!A-Za-z0-9._-]*) echo "错误：SSD kernel device name 非法：$SSD_KNAME"; exit 1 ;;
esac
# 容器可能只暴露 sysfs 而没有 /dev/nvme* 节点；从 lsblk 全量输出按 KNAME 查询。
SSD_DEVICE_INFO=$(lsblk -bnr -o KNAME,ROTA,SIZE | awk -v kname="$SSD_KNAME" '$1 == kname {print $2, $3; exit}')
read -r SSD_ROTA SSD_DEVICE_SIZE_BYTES <<EOF
$SSD_DEVICE_INFO
EOF
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
pkill -9 -f 'VLLM::EngineCore|VLLMEngineCore' 2>/dev/null || true
pkill -9 -f mooncake_master 2>/dev/null || true
# 清理可能残留的旧测试 curl
pkill -9 -f "curl.*8000" 2>/dev/null || true
sleep 3

# 确认进程杀干净
if pgrep -f "vllm serve|VLLM::EngineCore|VLLMEngineCore|mooncake_master" > /dev/null 2>&1; then
  echo "警告：仍有残留进程，再等 3 秒..."
  sleep 3
fi
if pgrep -f "vllm serve|VLLM::EngineCore|VLLMEngineCore|mooncake_master" > /dev/null 2>&1; then
  echo "错误：旧 vLLM/Mooncake 进程仍未退出，拒绝删除其 SSD 缓存"
  pgrep -af "vllm serve|VLLM::EngineCore|VLLMEngineCore|mooncake_master" || true
  exit 1
fi

# 进程退出后给 NPU runtime 留出释放物理页的时间，并输出启动前占用，便于识别
# 同容器或同设备上的非本评测进程。
sleep 5
if command -v npu-smi >/dev/null 2>&1; then
  echo "NPU 启动前状态:"
  npu-smi info || true
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
  SSD_PROBE_PATH="$SSD_SESSION_PATH/.ssd-device-probe-$STARTUP_PID"
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
echo "启动脚本版本：$STARTUP_VERSION"
PYTHON_REAL_BIN=$(readlink -f "$(command -v python3)")
PYTHON_BIN_DIR=$(dirname "$PYTHON_REAL_BIN")
MOONCAKE_PYTHON_SITE=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')
MOONCAKE_PACKAGE_DIR="$MOONCAKE_PYTHON_SITE/mooncake"
MOONCAKE_MASTER_BIN="$PYTHON_BIN_DIR/mooncake_master"
if [ ! -f "$MOONCAKE_PACKAGE_DIR/store.so" ] || \
   [ ! -f "$MOONCAKE_PACKAGE_DIR/libmooncake_store.so" ] || \
   [ ! -x "$MOONCAKE_MASTER_BIN" ]; then
  echo "错误：未找到完整的新版 Mooncake NPU wheel：$MOONCAKE_PACKAGE_DIR"
  echo "请安装 mooncake-transfer-engine-npu==$MOONCAKE_REQUIRED_VERSION"
  exit 1
fi

# 新 wheel 自带 Ascend transport 和全部 Mooncake 动态库。必须放在 /usr/local/lib
# 及 CANN 内置旧 Mooncake 之前，防止新 Python 模块链接到旧 libmooncake_store.so。
export PATH="$PYTHON_BIN_DIR:$PATH"
export PYTHONPATH="$MOONCAKE_PYTHON_SITE${PYTHONPATH:+:$PYTHONPATH}"
export LD_LIBRARY_PATH="$MOONCAKE_PACKAGE_DIR:/usr/local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

MOONCAKE_RUNTIME_INFO=$(python3 - <<'PY'
import mooncake
from importlib.metadata import version

print(version("mooncake-transfer-engine-npu"))
print(mooncake.__file__)
PY
)
MOONCAKE_RUNTIME_VERSION=$(printf '%s\n' "$MOONCAKE_RUNTIME_INFO" | sed -n '1p')
MOONCAKE_RUNTIME_PATH=$(printf '%s\n' "$MOONCAKE_RUNTIME_INFO" | sed -n '2p')
if [ "$MOONCAKE_RUNTIME_VERSION" != "$MOONCAKE_REQUIRED_VERSION" ]; then
  echo "错误：Mooncake 版本为 $MOONCAKE_RUNTIME_VERSION，要求 $MOONCAKE_REQUIRED_VERSION"
  exit 1
fi
case "$MOONCAKE_RUNTIME_PATH" in
  "$MOONCAKE_PACKAGE_DIR"/*) ;;
  *)
    echo "错误：仍在加载旧 Mooncake：$MOONCAKE_RUNTIME_PATH"
    exit 1
    ;;
esac
MOONCAKE_STORE_LINKS=$(ldd "$MOONCAKE_PACKAGE_DIR/store.so")
if printf '%s\n' "$MOONCAKE_STORE_LINKS" | grep -q 'not found'; then
  echo "错误：新版 Mooncake 存在未解析动态库："
  printf '%s\n' "$MOONCAKE_STORE_LINKS" | grep 'not found'
  exit 1
fi
MOONCAKE_STORE_LIBRARY=$(printf '%s\n' "$MOONCAKE_STORE_LINKS" | awk '$1 == "libmooncake_store.so" && $2 == "=>" {print $3; exit}')
if [ -z "$MOONCAKE_STORE_LIBRARY" ] || \
   [ "$(readlink -f "$MOONCAKE_STORE_LIBRARY")" != "$(readlink -f "$MOONCAKE_PACKAGE_DIR/libmooncake_store.so")" ]; then
  echo "错误：store.so 未链接新版 libmooncake_store.so：${MOONCAKE_STORE_LIBRARY:-未找到}"
  exit 1
fi
echo "Mooncake校验：版本=$MOONCAKE_RUNTIME_VERSION，Python/动态库=新版wheel"
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
# 当前容器沿用加入 SSD 前的非 Fabric 路径。开启官方推荐的 4×8MB NPU
# 中转池后，Mooncake 日志应出现 "Set adxl.BufferPool to:4:8"，并对 Host
# 段打印 "Ignore register host mem ... when buffer pool is enabled"。
export ASCEND_BUFFER_POOL="$ASCEND_TRANSFER_BUFFER_POOL"
# Mooncake 只按变量是否存在判断异步传输；即使值为 0 也会启用，而异步模式
# 与 ASCEND_BUFFER_POOL 不兼容，因此必须显式清除可能继承的环境变量。
unset ASCEND_USE_ASYNC_TRANSFER
export MOONCAKE_REQUESTER_LOCAL_HOSTNAME=192.168.243.40

# vLLM-Ascend 0.23.0rc1 默认在 NPU KV tensor 分配前初始化 embedded
# Mooncake。日志显示 SSD 模式额外执行 aclrtMallocHost 后，本机驱动曾在第一个大 KV
# tensor 的 aclrtMallocPhysical 返回 507899。临时 import hook 仅将
# contribute-memory worker 的 SSD store 延迟到 KV tensor 已分配并注册之后；
# scheduler client、非 SSD 模式以及已安装源码都不改变。
VLLM_PATCH_DIR=$(mktemp -d /tmp/vllm-ssd-lazy-init.XXXXXX)
cat > "$VLLM_PATCH_DIR/sitecustomize.py" <<'PY'
import importlib.abc
import importlib.machinery
import os
import sys
import threading


_TARGET = (
    "vllm_ascend.distributed.kv_transfer.kv_pool.ascend_store."
    "backend.mooncake_backend"
)


class _MooncakeBackendPatchLoader(importlib.abc.Loader):
    def __init__(self, wrapped_loader):
        self._wrapped_loader = wrapped_loader

    def create_module(self, spec):
        create_module = getattr(self._wrapped_loader, "create_module", None)
        return create_module(spec) if create_module is not None else None

    def exec_module(self, module):
        self._wrapped_loader.exec_module(module)
        backend = module.MooncakeBackend
        if getattr(backend, "_benchmark_ssd_init_order_patch", False):
            return

        original_register_buffer = backend.register_buffer

        def patched_init(
            self,
            parallel_config,
            lazy_init=False,
            contribute_memory=True,
        ):
            self.parallel_config = parallel_config
            self.config = module.MooncakeStoreConfig.load_from_env()
            if self.config.protocol != "ascend":
                raise NotImplementedError(
                    "MooncakeBackend does not support protocol "
                    f"{self.config.protocol!r}."
                )

            self.store = None
            self.local_seg = None
            self._use_fabric_mem = (
                os.getenv("ASCEND_ENABLE_USE_FABRIC_MEM", "0") == "1"
            )
            # Preserve the upstream compress/Fabric behavior, and additionally
            # defer only the SSD worker that contributes DRAM/SSD capacity.
            self._lazy_init = (
                lazy_init and self._use_fabric_mem
            ) or (
                contribute_memory and self.config.enable_ssd_offload
            )
            self._contribute_memory = contribute_memory
            self._store_initialized = False
            self._store_init_lock = threading.Lock()

            if self._lazy_init and self.config.enable_ssd_offload:
                module.logger.info(
                    "SSD startup ordering patch active: defer Mooncake worker "
                    "store until NPU KV cache allocation completes."
                )
            if not self._lazy_init:
                self.store = self._setup_store()
                self._store_initialized = True

        def patched_register_buffer(self, ptrs, lengths):
            # This callback is reached only after vLLM has successfully created
            # all NPU KV cache tensors. Register them first, then allocate the
            # Mooncake DRAM segment and SSD staging buffer.
            original_register_buffer(self, ptrs, lengths)
            if (
                self._lazy_init
                and not self._store_initialized
                and self._contribute_memory
                and self.config.enable_ssd_offload
            ):
                module.logger.info(
                    "NPU KV cache allocated; initializing Mooncake DRAM/SSD now."
                )
                self.ensure_initialized()

        backend.__init__ = patched_init
        backend.register_buffer = patched_register_buffer
        backend._benchmark_ssd_init_order_patch = True


class _MooncakeBackendPatchFinder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname != _TARGET:
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        if spec is None or spec.loader is None or not hasattr(spec.loader, "exec_module"):
            raise ImportError(f"Cannot install SSD startup ordering patch for {fullname}")
        spec.loader = _MooncakeBackendPatchLoader(spec.loader)
        return spec


sys.meta_path.insert(0, _MooncakeBackendPatchFinder())
PY
python3 -m py_compile "$VLLM_PATCH_DIR/sitecustomize.py"
export PYTHONPATH="$VLLM_PATCH_DIR${PYTHONPATH:+:$PYTHONPATH}"

# Mooncake SSD offload：每次启动使用新的空目录，避免上次会话的数据污染冷启动。
export MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES=$((SSD_BUFFER_MB * 1024 * 1024))
export MOONCAKE_OFFLOAD_BUCKET_MAX_TOTAL_SIZE=$((SSD_QUOTA_GB * 1024 * 1024 * 1024))
export MOONCAKE_OFFLOAD_TOTAL_SIZE_LIMIT_BYTES=$((SSD_QUOTA_GB * 1024 * 1024 * 1024))
export MOONCAKE_OFFLOAD_BUCKET_EVICTION_POLICY=none
# 当前 Ascend 驱动在 io_uring_register_buffers(aclrtMallocHost buffer) 返回 EFAULT
# 后会进入 507899 错误状态，Mooncake 的 fallback 无法恢复。因此显式使用稳定的
# POSIX pread/pwrite 路径。Run-all 在每次 R4 前 fsync + POSIX_FADV_DONTNEED，并要求
# 评测进程 read_bytes 覆盖完整 batch 且 NVMe read sectors 覆盖该读量，页缓存不能冒充 SSD。
export MOONCAKE_OFFLOAD_USE_URING=0

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
  "benchmark_ssd_direct_io": false,
  "benchmark_ssd_page_cache_drop": true,
  "benchmark_ssd_io_mode": "posix-fadvise-dontneed",
  "benchmark_ssd_overlay_verified": $SSD_OVERLAY_MODE,
  "benchmark_cleanup_managed": true,
  "benchmark_startup_version": "$STARTUP_VERSION",
  "benchmark_startup_pid": $STARTUP_PID,
  "benchmark_startup_start_ticks": "$STARTUP_START_TICKS",
  "benchmark_runtime_control": "signal-request-v1",
  "benchmark_runtime_request_path": "$RUNTIME_REQUEST_PATH",
  "benchmark_runtime_status_path": "$RUNTIME_STATUS_PATH"
}
EOF
cat $MOONCAKE_JSON

wait_master_ready() {
  master_wait=0
  while [ "$master_wait" -lt 60 ]; do
    if ! kill -0 "$MASTER_PID" 2>/dev/null; then
      echo "错误：mooncake_master 启动失败，查看日志：$MASTER_LOG"
      tail -20 "$MASTER_LOG" || true
      return 1
    fi
    if curl -s -m 2 "http://127.0.0.1:$METRICS_PORT/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    master_wait=$((master_wait + 1))
  done
  echo "错误：mooncake_master 60 秒内未就绪，查看日志：$MASTER_LOG"
  tail -20 "$MASTER_LOG" || true
  return 1
}

wait_vllm_ready() {
  vllm_wait=0
  while [ "$vllm_wait" -lt "$VLLM_START_TIMEOUT_SECONDS" ]; do
    if ! kill -0 "$VLLM_PID" 2>/dev/null; then
      echo "错误：vLLM 启动失败，查看日志：$VLLM_LOG"
      tail -40 "$VLLM_LOG" || true
      return 1
    fi
    if curl -s -f -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    vllm_wait=$((vllm_wait + 1))
  done
  echo "错误：vLLM ${VLLM_START_TIMEOUT_SECONDS} 秒内未就绪，查看日志：$VLLM_LOG"
  tail -40 "$VLLM_LOG" || true
  return 1
}

start_runtime() {
  MASTER_LOG="/tmp/mooncake-master-$STARTUP_PID-g$RUNTIME_GENERATION.log"
  VLLM_LOG="/tmp/vllm-ssd-$STARTUP_PID-g$RUNTIME_GENERATION.log"
  write_runtime_status starting "${1:-}" "starting generation $RUNTIME_GENERATION"

  echo ""
  echo "===== [4/5] 启动 mooncake_master（第${RUNTIME_GENERATION}代）====="
  "$MOONCAKE_MASTER_BIN" --port "$MASTER_PORT" \
    --eviction_high_watermark_ratio 0.9 \
    --eviction_ratio 0.1 \
    --default_kv_lease_ttl 11000 \
    --enable_offload=true \
    --offload_on_evict=false \
    --promotion_on_hit=false \
    --enable_metric_reporting=true \
    --client_ttl=120 \
    > "$MASTER_LOG" 2>&1 &
  MASTER_PID=$!
  wait_master_ready
  echo "mooncake_master 已就绪"

  echo ""
  echo "===== [5/5] 启动 vLLM（第${RUNTIME_GENERATION}代）====="
  echo "配置: SSD staging buffer=${SSD_BUFFER_MB}MB；SSD I/O=POSIX；Ascend中转池=$ASCEND_BUFFER_POOL；max-model-len=$VLLM_MAX_MODEL_LEN"
  echo "vLLM 日志: $VLLM_LOG"
  vllm serve "$MODEL_PATH" \
    --port "$PORT" \
    --trust-remote-code \
    --served-model-name "$SERVED_NAME" \
    --block-size 128 \
    --enable-prefix-caching \
    --tensor-parallel-size 1 \
    --max-model-len "$VLLM_MAX_MODEL_LEN" \
    --gpu-memory-utilization "$VLLM_GPU_MEMORY_UTILIZATION" \
    --kv-transfer-config '{
      "kv_connector": "AscendStoreConnector",
      "kv_role": "kv_both",
      "kv_load_failure_policy": "recompute",
      "kv_connector_extra_config": {
        "backend": "mooncake",
        "lookup_rpc_port": "0",
        "load_async": false
      }
    }' > >(tee "$VLLM_LOG") 2>&1 &
  VLLM_PID=$!
  wait_vllm_ready
  write_runtime_status ready "${1:-}" "generation $RUNTIME_GENERATION ready"
  echo "运行时已就绪：第${RUNTIME_GENERATION}代；SSD目录保持为 $SSD_SESSION_PATH"
}

read_request_value() {
  local request_key="$1"
  awk -F= -v key="$request_key" '$1 == key {sub(/^[^=]*=/, ""); print; exit}' "$RUNTIME_REQUEST_PATH"
}

handle_restart_request() {
  local restart_command restart_expected_generation restart_request_id
  RESTART_REQUESTED=0
  if [ ! -f "$RUNTIME_REQUEST_PATH" ] || [ -L "$RUNTIME_REQUEST_PATH" ]; then
    write_runtime_status failed "" "invalid restart request file"
    return 0
  fi
  restart_command=$(read_request_value command)
  restart_expected_generation=$(read_request_value expected_generation)
  restart_request_id=$(read_request_value request_id)
  case "$restart_request_id" in
    ''|*[!A-Za-z0-9._-]*)
      write_runtime_status failed "" "invalid request id"
      return 0
      ;;
  esac
  if [ "$restart_command" != "restart" ] || [ "$restart_expected_generation" != "$RUNTIME_GENERATION" ]; then
    write_runtime_status failed "$restart_request_id" "restart request generation mismatch"
    return 0
  fi

  echo ""
  echo "收到 SSD 保留重启请求：第${RUNTIME_GENERATION}代 -> 第$((RUNTIME_GENERATION + 1))代"
  write_runtime_status restarting "$restart_request_id" "preserving SSD; clearing HBM and DRAM"
  stop_runtime_processes
  sleep 5
  RUNTIME_GENERATION=$((RUNTIME_GENERATION + 1))
  start_runtime "$restart_request_id"
}

start_runtime "initial"
echo "初始状态: $(curl -s "http://127.0.0.1:$METRICS_PORT/metrics/summary" | grep -o 'Mem Storage: [^|]*| SSD Storage: [^|]*| Keys: [0-9]*' | head -1)"
echo "可靠性校验: 重启清空HBM/DRAM且保留SSD；R4校验外部命中、进程读盘和NVMe读盘"
echo "启动窗口请保持打开；Run-all 会自动请求受控重启，无需手工操作。"

while true; do
  if [ "$RESTART_REQUESTED" -eq 1 ]; then
    handle_restart_request
  fi
  if [ -z "$MASTER_PID" ] || ! kill -0 "$MASTER_PID" 2>/dev/null; then
    echo "错误：mooncake_master 意外退出：$MASTER_LOG"
    exit 1
  fi
  if [ -z "$VLLM_PID" ] || ! kill -0 "$VLLM_PID" 2>/dev/null; then
    echo "错误：vLLM 意外退出：$VLLM_LOG"
    exit 1
  fi
  sleep 1 || true
done
)
