# 03-DRAM-PrefixCache：KV Cache 挤压至 DRAM 的性能测试

## 任务目的

02 测试了 HBM Prefix Cache 命中的性能基线。03 的任务是**将 KV Cache 挤压到 CPU 内存（DRAM）**，测试同样 Prefix Cache 命中场景下的 TTFT，对比 02 的 HBM 基线，量化 DRAM 卸载带来的性能下降。

## 核心原理

```
┌─────────────────────────────────────────────────┐
│                   HBM (NPU 显存)                  │
│  ┌──────────┐  ┌──────────────────────────────┐  │
│  │ 模型权重  │  │       KV Cache (限量)         │  │
│  └──────────┘  └──────────────┬───────────────┘  │
│                               │ swap out          │
└───────────────────────────────┼───────────────────┘
                                ▼
┌─────────────────────────────────────────────────┐
│                   DRAM (CPU 内存)                 │
│  ┌──────────────────────────────────────────────┐│
│  │       KV Cache (溢出部分)      ← 测试命中这里  ││
│  └──────────────────────────────────────────────┘│
└─────────────────────────────────────────────────┘
```

## 脚本说明

测试拆分为两个独立脚本，分步执行：

| 脚本 | 作用 | 执行顺序 |
|------|------|---------|
| `squeeze-hbm` | 挤压 HBM，将 KV Cache 换出到 DRAM | 先执行 |
| `bench-dram` | 在 DRAM 命中场景下跑 TTFT 基准测试 | 后执行 |

### Step 1: squeeze-hbm

```bash
bash squeeze-hbm
```

**流程**：
1. 发送 1 次 warmup 请求（prefix P，16K），建立 KV Cache 在 HBM
2. 分批发送挤压请求（不同 prefix），每批 10 个，实时监控：
   - `preemptions`：preemption 次数，>0 表示 KV Cache 开始被换出
   - `gpu_cache_usage`：HBM 使用率
3. 检测到 swap 后继续发送剩余请求确保 DRAM 驻留

**输出示例**：
```
Batch   Sent      Preemptions     GPU Cache     Status
--------------------------------------------------------------
  1      10       0 -> 0          45.2%         filling...
  2      20       0 -> 0          68.7%         filling...
  3      30       0 -> 12         89.3%         SWAPPED!
  KV cache swap detected. Sending 70 more to ensure DRAM residence...
```

**可调参数**（环境变量）：
- `VB_SQUEEZE`：挤压请求总数，默认 100
- `VB_SQUEEZE_BATCH`：每批请求数，默认 10
- `VB_SQUEEZE_CONC`：挤压并发数，默认 10

### Step 2: bench-dram

```bash
bash bench-dram
```

**前提**：`squeeze-hbm` 已执行完成，KV Cache 在 DRAM。

**流程**：直接跑并发 1/5/10/100 的 TTFT 基准测试，输出 Excel。

## 预期结果

| 指标 | 02 HBM 基线 | 03 DRAM 命中 | 增幅 |
|------|------------|-------------|------|
| 并发 1 Avg TTFT | T₁ | T₁' | Δ% |
| 并发 5 Avg TTFT | T₅ | T₅' | Δ% |
| 并发 10 Avg TTFT | T₁₀ | T₁₀' | Δ% |
| 并发 100 Avg TTFT | T₁₀₀ | T₁₀₀' | Δ% |

## 输出物

- `bench-dram` 输出：`vbench-results/YYYYMMDD-HHMMSS/result_batch_dram_YYYYMMDD-HHMMSS.xlsx`
- 含 `summary`、各并发 `raw` sheet、`request_details`

## 依赖

- 昇腾 910C + vLLM 0.23.0 (Ascend fork)
- vLLM 启动时需配置 swap 空间：`--swap-space 16 --cpu-offload-gb 8`
