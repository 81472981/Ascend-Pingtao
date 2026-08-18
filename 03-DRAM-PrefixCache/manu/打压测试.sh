#!/bin/bash
set +m

MODEL="Qwen3-8B"
ENDPOINT="http://127.0.0.1:8000/v1/chat/completions"
HBM_TOTAL=65536

echo "========================================"
echo "  持续打压开始 (Ctrl+C 停止)"
echo "========================================"

BASE_PROMPT=$(python3 -c "print('人工智能在各领域的应用与影响。' * 1500)")

print_status() {
  # HBM：直接匹配 "/ 65536" 前面的数字，total 写死
  HBM_USED=$(npu-smi info 2>/dev/null | grep -oP '\d+(?=\s*/\s*65536)' | head -1)
  if [ -n "$HBM_USED" ]; then
    HBM_PCT=$(awk "BEGIN {printf \"%.1f\", $HBM_USED/$HBM_TOTAL*100}")
  else
    HBM_USED="N/A"; HBM_PCT=""
  fi

  # DRAM
  MC=$(curl -s -m 2 http://127.0.0.1:9003/metrics/summary 2>/dev/null)
  if [ -n "$MC" ]; then
    MC_STORAGE=$(echo "$MC" | grep -o "Mem Storage: [^|]*" | head -1 | sed 's/Mem Storage: //')
    MC_KEYS=$(echo "$MC" | grep -o "Keys: [0-9]*" | head -1 | sed 's/Keys: //')
  else
    MC_STORAGE="busy"; MC_KEYS="?"
  fi

  echo ""
  echo "[$(date +%H:%M:%S)] 已发送: $i"
  echo "  [HBM ]  ${HBM_USED} / ${HBM_TOTAL} MB  (${HBM_PCT}%)"
  echo "  [DRAM]  ${MC_STORAGE} | Keys: ${MC_KEYS}"
}

auto_monitor() {
  while true; do
    print_status
    sleep 5
  done
}
auto_monitor &
MON_PID=$!

i=0
while true; do
  i=$((i+1))
  PROMPT="REQ-$i-$RANDOM-$RANDOM。$BASE_PROMPT"

  ( curl -s -m 30 $ENDPOINT \
      -H "Content-Type: application/json" \
      -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT\"}],\"max_tokens\":5,\"temperature\":0}" \
      > /dev/null 2>&1 & )

  if [ $((i % 20)) -eq 0 ]; then
    echo ">> 已发送 $i 个请求"
  fi

  sleep 0.8
done

trap "kill $MON_PID 2>/dev/null; pkill -f 'curl.*8000' 2>/dev/null; echo ''; echo '========================================'; echo '  打压结束'; echo '========================================'" EXIT