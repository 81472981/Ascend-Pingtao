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

- 通过限制 HBM 中 KV Cache 容量（`--max-model-len` 或 `--gpu-memory-utilization`），迫使新请求的 KV Cache 被 swap 到 DRAM
- 后续相同 prefix 的请求命中 DRAM 中的 KV Cache，产生额外的数据搬运开销
- 对比 02 的 HBM 命中，量化 DRAM 命中的 TTFT 增幅

## 测试方案

### 方案 A：Mooncake Store（推荐尝试）

使用 Mooncake 的 CPU 内存 Store 作为 KV Cache 后端。

```bash
vllm serve <model> \
    --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_both"}' \
    --port 8000
```

### 方案 B：vLLM 内置 CPU Offload（兜底）

```bash
vllm serve <model> \
    --swap-space 16 \
    --cpu-offload-gb 8 \
    --max-model-len 32768 \
    --gpu-memory-utilization 0.85 \
    --port 8000
```

### 测试步骤

1. **启动服务**：按方案 A 或 B 启动 vLLM
2. **冷启动**：发送 1 次 prefix_repetition 请求（16K input），建立 KV Cache
3. **挤压 HBM**：发送大量不同 prefix 的请求，将 HBM 中的 KV Cache 挤压到 DRAM
4. **DRAM 命中测试**：使用 `vb-post` 脚本（同 02），发送相同 prefix 请求，记录 TTFT
5. **对比分析**：将 03 的 TTFT 与 02 的 HBM 基线对比

### 并发测试矩阵

| 并发 | 批次 | 说明 |
|------|------|------|
| 1 | 5 | 单请求，DRAM 命中 |
| 5 | 5 | 5 并发，DRAM 命中 |
| 10 | 5 | 10 并发，DRAM 命中 |
| 100 | 5 | 100 并发，DRAM 命中 |

## 预期结果

| 指标 | 02 HBM 基线 | 03 DRAM 命中 | 增幅 |
|------|------------|-------------|------|
| 并发 1 Avg TTFT | T₁ | T₁' | Δ% |
| 并发 5 Avg TTFT | T₅ | T₅' | Δ% |
| 并发 10 Avg TTFT | T₁₀ | T₁₀' | Δ% |
| 并发 100 Avg TTFT | T₁₀₀ | T₁₀₀' | Δ% |

## 输出物

- `result_c1.xlsx` / `result_batch.xlsx`：与 02 相同格式，含 TTFT 原始数据、汇总、请求明细
- 对比分析：03 与 02 的 TTFT 差异百分比

## 依赖

- 昇腾 910C + vLLM 0.23.0 (Ascend fork)
- Mooncake SDK（方案 A）或 vLLM 内置 swap（方案 B）
- 02 文件夹的 `vb-post` / `vb-post-batch` 脚本（可直接复用）
