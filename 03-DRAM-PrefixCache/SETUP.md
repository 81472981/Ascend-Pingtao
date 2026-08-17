# Mooncake 环境搭建指南（昇腾 910C + vLLM 0.23.0）

## 适用环境

| 项目 | 版本/配置 |
|------|----------|
| 硬件 | 昇腾 910C (NPU) |
| 软件栈 | CANN + Ascend vLLM 0.23.0 |
| 网络 | 单卡，无 RDMA |
| 目标 | 将 KV Cache 卸载到 CPU 内存（DRAM），测试 Prefix Cache 命中时的 TTFT |

## 1. 安装 Mooncake SDK

```bash
# 克隆 Mooncake 仓库
git clone https://github.com/kvcache-ai/Mooncake.git
cd Mooncake

# 仅安装 Python 层（transfer engine 依赖 CUDA，昇腾无法编译）
pip install -e python/
```

## 2. 安装依赖

```bash
pip install mooncake-store
pip install uvloop
```

## 3. 验证安装

```bash
python3 -c "import mooncake; print('Mooncake version:', mooncake.__version__)"
python3 -c "import mooncake_store; print('Mooncake Store OK')"
```

## 4. Mooncake 组件说明

| 组件 | 作用 | 昇腾兼容 |
|------|------|---------|
| `mooncake` (Python SDK) | KV Cache 管理接口 | ✅ |
| `mooncake-store` | CPU 内存 KV Cache 存储后端 | ✅ |
| `mooncake-transfer-engine` | GPU RDMA 传输层 | ❌ 依赖 CUDA |

## 5. 启动 vLLM 服务

```bash
# 方案 A：使用 MooncakeConnector（需 Ascend fork 支持）
vllm serve <model> \
    --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_both"}' \
    --port 8000

# 方案 B：如果 MooncakeConnector 未注册，使用 vLLM 内置 CPU offload
vllm serve <model> \
    --swap-space 16 \
    --cpu-offload-gb 8 \
    --max-model-len 32768 \
    --port 8000
```

## 6. 常见问题

**Q: `Unknown kv_connector: MooncakeConnector`？**
Ascend fork 的 vLLM 0.23.0 可能未注册 Mooncake 插件。查看已注册插件：
```bash
VLLM_PLUGINS="" vllm serve --help 2>&1 | grep -i kv
```
若未注册，使用方案 B 的 `--cpu-offload-gb` + `--swap-space`。

**Q: 如何验证 KV Cache 在 DRAM？**
启动后查看 vLLM 日志，`--swap-space` 和 `--cpu-offload-gb` 生效时会打印 swap 配置。
