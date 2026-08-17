# Mooncake 单卡测试环境搭建指南

## 适用环境

- 昇腾 910C (NPU)
- vLLM 0.23.0 (Ascend fork)
- 单卡、无 RDMA

## 安装步骤

### 1. 安装 Mooncake SDK（Python 层）

```bash
git clone https://github.com/kvcache-ai/Mooncake.git
cd Mooncake
pip install -e python/
```

### 2. 安装 mooncake-store

```bash
pip install mooncake-store
```

### 3. 验证

```bash
python3 -c "import mooncake; print(mooncake.__version__)"
```

## 启动 vLLM + Mooncake Store

```bash
vllm serve <model> \
    --kv-transfer-config '{"kv_connector":"MooncakeConnector","kv_role":"kv_both"}' \
    --port 8000
```

## 测试对比

| 场景 | 说明 |
|------|------|
| HBM 命中 | 冷启动后直接发请求，KV cache 在 HBM |
| DRAM 命中（Mooncake） | 通过 Mooncake Store 将 KV cache 换出到 CPU 内存，再发请求 |

## 注意事项

1. MooncakeConnector 在 vLLM Ascend fork 上可能未注册，如报 `Unknown kv_connector` 需确认 plugin 列表
2. Mooncake transfer engine 依赖 CUDA/RDMA，昇腾环境无法编译，仅使用 Python 层和 Store
