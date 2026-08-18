# 03-DRAM-PrefixCache

## 目的

在昇腾 910C 单机单卡上，对同一个 16K Prefix（P1）比较：

- `R2-hbm-cache`：vLLM 本地 HBM Prefix Cache 命中；
- `R3-dram-cache`：本地 HBM 未命中，从 AscendStoreConnector + Mooncake DRAM 恢复。

默认请求形状为并发 `1/5/10`，每种并发 5 个批次。所有请求使用同一个由
`prefix_repetition`、`seed=0` 生成的 P1，避免并发度变化时实际测试不同 Prefix。

## 为什么不把压力请求作为默认挤压方式

压力请求产生的新 KV 也会写入 Mooncake。若 Mooncake DRAM 容量小于 HBM KV
容量，最老的 P1 可能先从 DRAM 淘汰；此时下一次 P1 会重算，而不是从 DRAM
恢复。`GPU cache usage`、`CPU cache usage` 或 `num_preemptions` 都只能描述系统
总体状态，不能证明指定的 P1 位于 DRAM。

R3 使用 vLLM 的 benchmark/debug cache API：

```text
POST /reset_prefix_cache?reset_running_requests=false&reset_connector=false
```

它清除本地 HBM Prefix Cache 索引，但保留 external connector 中的 Mooncake
对象。数据路径仍然是真实的 Mooncake DRAM -> HBM 加载，只把不可控的 LRU
压力淘汰换成确定性的本地淘汰。`R3-dram-cache` 会在每个小批次前调用一次，
避免首批 P1 被加载回 HBM 后污染后续样本。

## 自动判定规则

判定使用每个批次前后的 vLLM Prometheus token counter 增量，不使用累计命中率：

| 阶段 | 有效批次的硬条件 |
|---|---|
| R1-warmup | 请求成功；仅用于填充和观察，只有服务清空后的首个 P1 是真正冷请求 |
| R2-hbm-cache | `local prefix hit rate >= 95%` |
| R3-dram-cache | `local prefix hit rate <= 5%` 且 `external prefix hit rate >= 95%` |

另外，运行前必须满足：

1. Mooncake `Keys=0`，保证首次 P1 是冷请求；
2. `/metrics` 同时暴露 local/external Prefix Cache counter；
3. `mooncake.json` 没有启用 `enable_ssd_offload`；
4. R3 开始前 Mooncake `Keys>0`；
5. 每次清 HBM 前后 Mooncake external cache 被保留。

不满足命中判据的批次仍写入 `validation` sheet，但会从性能汇总排除。严格模式
默认开启，只要存在无效批次，脚本最终返回退出码 2。

## 执行

先参考 `doc/启动vllm&mk.sh` 启动干净的 vLLM + Mooncake。启动环境必须包含：

```bash
export VLLM_SERVER_DEV_MODE=1
```

三个脚本均为自包含 Bash heredoc，不 import 仓库文件。可以打开文件复制全文，
直接粘贴到目标机 Shell；默认共用 `vbench-results/dram-session`：

```bash
bash R1-warmup
bash R2-hbm-cache
bash R3-dram-cache
```

也可以使用可选入口顺序执行三个阶段：

```bash
bash run-all
```

如需为本次实验创建独立目录，应在三个脚本执行前设置同一个路径：

```bash
export VB_RUN_DIR="vbench-results/run-$(date +%Y%m%d-%H%M%S)"
```

`R3-dram-cache` 已包含清理 HBM、保留 Mooncake 和命中校验，不再需要额外的
`squeeze-hbm` 脚本。

## 输出

每个阶段立即写出自己的文件，因此中途失败也能保留已完成阶段的数据：

- `R1-warmup.xlsx` 和 `R1-warmup-summary.json`；
- `R2-hbm-cache.xlsx` 和 `R2-hbm-cache-summary.json`；
- `R3-dram-cache.xlsx` 和 `R3-dram-cache-summary.json`；
- `json/<stage>/`：vLLM 原始详细结果。

每个 Excel 含 `summary`、同名阶段页和 `validation`。R3 会读取同一目录下的
R2 summary，在 `vs_R2_change_percent` 中直接给出性能变化。

## 参数

```bash
VB_BATCHES=5
VB_CONCURRENCIES=1,5,10
VB_MIN_HIT_RATE=0.95
VB_MAX_LOCAL_HIT_RATE=0.05
VB_STORE_SETTLE_SECONDS=2
VB_STRICT=1
VB_RUN_DIR=vbench-results/dram-session
VB_MOONCAKE_METRICS_URL=http://127.0.0.1:9003/metrics/summary
MOONCAKE_CONFIG_PATH=/tmp/mooncake.json
```

单机单卡不需要跨机 RDMA 网络，但 AscendStoreConnector 的 Mooncake backend
仍需要与当前 vLLM-Ascend/CANN 版本匹配的 NPU transfer engine；不能用
`--swap-space` 或 `--cpu-offload-gb` 代替，二者不代表 external Prefix Cache DRAM 命中。
