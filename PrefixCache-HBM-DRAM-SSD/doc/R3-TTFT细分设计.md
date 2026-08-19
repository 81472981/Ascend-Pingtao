# R3 TTFT 细分设计

## 1. 目标

当前评测只记录端到端 TTFT。R3 阶段要求在保持现有 TTFT 统计与 DRAM 来源校验不变的前提下，额外测量：

1. DRAM KV 缓存命中查询耗时；
2. 命中后的 DRAM KV 搬迁到 HBM 的耗时。

本设计仅覆盖 R3；R4 后续复用同一框架，替换为 SSD 查询和 SSD 到 HBM 的指标。

## 2. 适用环境

- 硬件：昇腾 910C 单机单卡；
- vLLM：`0.23.0+empty`，源码提交 `0fc695f`；
- vLLM-Ascend：`0.23.0rc1`，源码目录 `/vllm-workspace/vllm-ascend`；
- Mooncake：源码目录 `/root/Mooncake`，提交 `e9c6107`；
- KV connector：`AscendStoreConnector`，后端为 Mooncake，`load_async=true`。

## 3. 指标定义

| 指标 | Summary 列名 | 计时边界 |
|---|---|---|
| DRAM 查询耗时 | `R3-DRAM-Lookup(s)` | 发起外部 KV lookup 到获得命中 token 数的返回 |
| DRAM 到 HBM 搬迁耗时 | `R3-DRAM-to-HBM(s)` | 调用 Mooncake `get()` 前到 `get()` 返回 |
| R3 TTFT | `R3-DRAM-TTFT(s)` | 保持现有 vLLM benchmark 统计方式 |

`R3-DRAM-to-HBM(s)` 必须以 `get()` 返回为结束点，不能只测异步加载任务提交时间；接收线程在 `get()` 返回后才将请求标记为完成。

两个子耗时是 TTFT 的关键子路径，不能要求其相加必然等于 TTFT；TTFT 还包含排队、调度和首 token 计算等时间。

## 4. 埋点设计

### 4.1 DRAM KV 查询

修改文件：

```text
/vllm-workspace/vllm-ascend/vllm_ascend/distributed/kv_transfer/kv_pool/ascend_store/pool_scheduler.py
```

在 `get_num_new_matched_tokens()` 调用 `self.client.lookup(...)` 的前后使用 `time.perf_counter_ns()` 计时：

```text
lookup_start -> self.client.lookup(...) -> lookup_end
```

记录字段：`request_id`、`lookup_ms`、`hit_tokens`。

该计时包含 lookup IPC/RPC 与 Mooncake 的命中查询等待，是 R3 请求可观察到的 DRAM KV 查询耗时。

### 4.2 DRAM 到 HBM 搬迁

修改文件：

```text
/vllm-workspace/vllm-ascend/vllm_ascend/distributed/kv_transfer/kv_pool/ascend_store/kv_transfer.py
```

在 `KVCacheStoreRecvingThread._handle_request()` 中，围绕以下调用计时：

```python
self.m_store.get(key_list_c, addr_list_c, size_list_c)
```

计时边界：

```text
load_start -> m_store.get(...) -> load_end
```

记录字段：`req_id`、`load_ms`、`key_count`、`load_bytes`、`load_success`。

## 5. Trace 输出与关联

两个埋点写入同一个 benchmark 专用 CSV 或 JSONL 文件。建议 CSV 格式如下：

```text
event,request_id,elapsed_ms,hit_tokens,key_count,load_bytes,success
lookup,p1-c1-b1-r3-0,1.23,16256,,,1
load,p1-c1-b1-r3-0,8.45,,127,2415919104,1
```

要求：

- 使用现有 benchmark 的 `x-request-id`/vLLM `request_id` 关联；
- 仅收集 request ID 中 R3 前缀对应的记录；
- 每次服务启动前清空 trace 文件，避免旧运行污染；
- 仅将现有规则判定为“有效且纯 DRAM 命中”的 R3 请求计入汇总；缺失 trace、lookup 未命中或 load 失败的请求不计入子耗时平均值，并在 validation 中标明原因。

## 6. Run-all 与 Excel 改动

### 6.1 StartUp.sh

增加 benchmark trace 文件路径环境变量，并在启动 vLLM 前清空文件：

```text
VB_KV_TRACE_FILE=/tmp/vb-kv-timing.csv
```

### 6.2 Run-all

在每个阶段完成后读取新增 trace，以 `request_id` 合并到当前 R3 请求。

R3 原始 Sheet 每条请求新增：

```text
dram_lookup_seconds
dram_to_hbm_seconds
```

Summary 新增：

```text
R3-DRAM-Lookup(s)
R3-DRAM-to-HBM(s)
```

每个并发度的值为全部 batch 中有效 R3 请求子耗时的算术平均值，单位为秒。可选增加：

```text
R3-Other(s) = R3-DRAM-TTFT(s) - R3-DRAM-Lookup(s) - R3-DRAM-to-HBM(s)
```

## 7. 修改范围

| 文件 | 修改内容 |
|---|---|
| `vllm_ascend/.../pool_scheduler.py` | 记录 lookup 耗时并写 trace |
| `vllm_ascend/.../kv_transfer.py` | 记录 `m_store.get()` 耗时并写 trace |
| `PrefixCache-HBM-DRAM-SSD/StartUp.sh` | 配置、清空 trace 文件 |
| `PrefixCache-HBM-DRAM-SSD/Run-all` | 读取 trace，写入原始 Sheet、validation 和 Summary |

## 8. 验收标准

1. R3 仍满足现有 HBM 未命中、外部 Prefix Cache 命中、Mooncake 全部 DRAM 命中且无 SSD 命中的校验；
2. 每个纳入 R3 Summary 的有效请求都能关联到一条 lookup trace 和一条 load trace；
3. Summary 中新增两列有值且单位为秒；
4. TTFT 原始数据、TTFT 均值及既有 R3/R2 劣化计算保持不变；
5. trace 缺失、load 失败或来源非 DRAM 的请求不得混入 R3 子耗时结果。
