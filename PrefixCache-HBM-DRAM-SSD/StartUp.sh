#!/bin/bash
set -e

SERVED_NAME="Qwen3-8B"
MODEL_PATH="/mnt/weight/${SERVED_NAME}"
PORT=8000
MOONCAKE_JSON=/tmp/mooncake.json
MASTER_PORT=50088
METRICS_PORT=9003
# Mooncake 为每个 rank 注册的主机 DRAM 段；要求按 1GB 对齐。
# 默认 512GB，也可在启动前用 MOONCAKE_SEGMENT_GB=... 覆盖。
MOONCAKE_SEGMENT_GB="${MOONCAKE_SEGMENT_GB:-512}"

case "$MOONCAKE_SEGMENT_GB" in
  ''|*[!0-9]*)
    echo "错误：MOONCAKE_SEGMENT_GB 必须是整数 GB，当前值: $MOONCAKE_SEGMENT_GB"
    exit 1
    ;;
esac

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

# 确认端口释放
while netstat -tlnp 2>/dev/null | grep -qE ":$PORT |:$MASTER_PORT "; do
  echo "等待端口释放..."
  sleep 1
done

echo "HBM 和 Mooncake DRAM 已清理（进程退出，内存自动释放）"

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
# Enable the benchmark-only /reset_prefix_cache endpoint. 03 uses it with
# reset_connector=false, so only HBM is cleared and Mooncake DRAM is retained.
export VLLM_SERVER_DEV_MODE=1
unset ASCEND_ENABLE_USE_FABRIC_MEM
export MOONCAKE_REQUESTER_LOCAL_HOSTNAME=192.168.243.40

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
  "prefer_alloc_in_same_node": true
}
EOF
cat $MOONCAKE_JSON

echo ""
echo "===== [4/5] 启动 mooncake_master ====="
mooncake_master --port $MASTER_PORT \
  --eviction_high_watermark_ratio 0.9 \
  --eviction_ratio 0.1 \
  --default_kv_lease_ttl 11000 \
  > /tmp/mooncake_master.log 2>&1 &
sleep 3

# 验证 mooncake_master 启动成功且数据为空
if curl -s -m 2 http://127.0.0.1:$METRICS_PORT/health > /dev/null 2>&1; then
  echo "mooncake_master 启动成功"
  echo "初始状态: $(curl -s http://127.0.0.1:$METRICS_PORT/metrics/summary | grep -o 'Mem Storage: [^|]*| Keys: [0-9]*' | head -1)"
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
  }'
