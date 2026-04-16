# Gemma 4 Single-Request Performance Notes

Date: 2026-04-15

## Goal

Identify the best default runtime configuration for single-user chat/coding on this machine and fold that into the local scripts.

## Test Environment

- Machine: Apple M5 Pro, 64 GB unified memory
- Model alias: `gemma4-agent`
- Base model: `gemma4:26b`
- Model format: `gguf`
- Weight quantization: `Q4_K_M`
- Context setting in Modelfile during this benchmark: `65536`

The model weights are quantized, but KV cache format is configured independently at runtime. In Ollama/ggml, `type_k` and `type_v` are separate context parameters, so `Q4_K_M` model weights can still run with `f16` or `q8_0` KV cache.

## Runtime Variants

Two runtime families were benchmarked first:

1. Old stable path:
   - Homebrew Ollama `0.20.6`
   - `GGML_METAL_TENSOR_DISABLE=1`
   - `has tensor = false`
2. Patched full-tensor path:
   - local patched binary at `/tmp/ollama-tensor-fix/dist/darwin-arm64/ollama`
   - no tensor-disable workaround
   - `has tensor = true`

For long coding-agent prompts with a shared repo prefix and changing task suffix, the patched runtime improved TTFT by about 25% to 28% versus the old stable path.

## 2x2 Matrix On The Patched Runtime

All measurements below were taken on the patched full-tensor path with:

- `OLLAMA_FLASH_ATTENTION=1`
- long repo-context prompt, about `20.4k` prompt tokens
- output capped at about `220` tokens

### Single request

| Config | TTFT | Total Latency | TPOT | Throughput | Runner RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `NUM_PARALLEL=1`, `KV=q8_0` | `26.90s` | `30.39s` | `22.52 ms/token` | `44.41 tok/s` | `19.52 GiB` |
| `NUM_PARALLEL=2`, `KV=q8_0` | `28.15s` | `31.60s` | `22.22 ms/token` | `45.00 tok/s` | `20.90 GiB` |
| `NUM_PARALLEL=1`, `KV=f16` | `26.28s` | `29.39s` | `20.06 ms/token` | `49.86 tok/s` | `20.55 GiB` |
| `NUM_PARALLEL=2`, `KV=f16` | `26.29s` | `29.36s` | `19.82 ms/token` | `50.47 tok/s` | `22.68 GiB` |

### Two concurrent requests

| Config | Median TTFT | Median Total Latency | TPOT | Throughput | Batch Wall Time | Runner RSS |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `NUM_PARALLEL=1`, `KV=q8_0` | `44.26s` | `47.76s` | `22.42 ms/token` | `44.60 tok/s` | `63.58s` | `19.52 GiB` |
| `NUM_PARALLEL=2`, `KV=q8_0` | `58.50s` | `64.68s` | `41.10 ms/token` | `24.39 tok/s` | `64.70s` | `21.02 GiB` |
| `NUM_PARALLEL=1`, `KV=f16` | `41.34s` | `44.45s` | `20.11 ms/token` | `49.73 tok/s` | `59.27s` | `20.55 GiB` |
| `NUM_PARALLEL=2`, `KV=f16` | `51.96s` | `57.20s` | `35.20 ms/token` | `28.47 tok/s` | `57.22s` | `22.80 GiB` |

## Conclusion

For the default local workflow in this repo, the best single-request configuration is:

- patched Ollama binary
- `OLLAMA_FLASH_ATTENTION=1`
- `OLLAMA_KV_CACHE_TYPE=f16`
- `OLLAMA_NUM_PARALLEL=1`
- no `GGML_METAL_TENSOR_DISABLE`

Why:

- `f16` improved single-request TTFT and decode speed relative to `q8_0`
- `NUM_PARALLEL=1` kept the interactive path lower-latency and lower-memory than `2`
- the full-tensor patched runtime materially outperformed the older workaround-based runtime

## Script Defaults Updated

The repo scripts now prefer the patched binary by default:

- `/tmp/ollama-tensor-fix/dist/darwin-arm64/ollama`

Fallback order:

1. explicit `OLLAMA_BIN`
2. patched local binary
3. `ollama` on `PATH`
4. `/Applications/Ollama.app/Contents/Resources/ollama`

Runtime defaults were updated to:

- `OLLAMA_KV_CACHE_TYPE=f16`
- `OLLAMA_NUM_PARALLEL=1`
- `OLLAMA_FLASH_ATTENTION=1`

The old `GGML_METAL_TENSOR_DISABLE=1` workaround is no longer enabled by default. It remains available as an opt-in compatibility escape hatch if the user intentionally falls back to an older stock Ollama build.
