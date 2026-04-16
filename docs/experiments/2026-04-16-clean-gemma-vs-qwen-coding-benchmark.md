# Clean Gemma vs Qwen Coding Benchmark

Date: 2026-04-16

## Goal

Run a clean, reproducible comparison between the current default `gemma4-agent` setup and `qwen3.5:35b-a3b` on this machine for a coding-agent style workload.

The main objective was not just to compare raw latency, but to avoid the two failure modes that had already polluted earlier measurements:

1. another model already resident in memory
2. leaked runtime env from the parent shell, especially:
   - `GGML_METAL_TENSOR_DISABLE=1`
   - `OLLAMA_KV_CACHE_TYPE=q8_0`
   - `OLLAMA_NUM_PARALLEL=2`

This document records the clean rerun only.

## Machine And Runtime

- Machine: Apple M5 Pro, 64 GB unified memory
- Runtime: local patched Ollama binary
- GPU path: Metal, full tensor path enabled
- Expected log checks:
  - `has tensor = true`
  - `has bfloat = true`
  - all layers offloaded to GPU

## Test Configuration

All runs used the same runtime settings:

- `OLLAMA_FLASH_ATTENTION=1`
- `OLLAMA_KV_CACHE_TYPE=f16`
- `OLLAMA_NUM_PARALLEL=1`
- `OLLAMA_KEEP_ALIVE=-1`
- no `GGML_METAL_TENSOR_DISABLE`

Models:

- `gemma4-agent`
- `qwen3.5:35b-a3b`

Both were run with a `256K` context limit in the benchmark environment.

## Workload

The prompt was a single coding-agent style repo review request built from this repository:

- `README.md`
- `setup.sh`
- `ollama.sh`
- the first `900` lines of `tests/scripts_test.sh`

The task prompt asked the model to:

- read the repository snapshot
- identify the 3 highest-risk implementation issues
- propose concrete shell-level fixes

This produced a long prompt similar to a real coding-agent turn:

- prompt text length: `51,382` characters
- Gemma prompt tokens: `19,800`
- Qwen prompt tokens: `18,449`

The tokenizer counts differ by model, but the input text itself was identical.

## Reproduction Method

To keep the comparison clean, each model was measured in isolation.

### Procedure

1. Stop any existing Ollama service and unload any already-loaded models.
2. Ensure no `serve` or `runner` processes remain.
3. Start a fresh `serve` process with a clean env:
   - explicitly remove leaked `GGML_*` and `OLLAMA_*` benchmark-overriding vars
   - then set the intended benchmark vars
4. For each model:
   - start a fresh `serve`
   - run one cold request
   - run one warm request with the exact same prompt
   - terminate `serve`
5. Parse the service log for:
   - `has tensor`
   - `has bfloat`
   - offloaded layer count
   - model weight memory
   - KV cache size
   - compute graph size
   - total memory
6. Sample runner RSS during each request to estimate peak process memory.

### Why This Matters

The earlier contaminated run was invalid because it inherited:

- `GGML_METAL_TENSOR_DISABLE=1`
- `OLLAMA_KV_CACHE_TYPE=q8_0`
- `OLLAMA_NUM_PARALLEL=2`

That accidentally benchmarked the fallback path instead of the intended performance-default path. A clean run must verify `has tensor = true` in the fresh per-model log before trusting any TTFT/TPOT number.

## Results

### Cold request

| Model | TTFT | Total Latency | TPOT | Throughput | Peak Runner RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `gemma4-agent` | `22.46s` | `26.50s` | `18.30 ms/token` | `54.64 tok/s` | `24.6 GiB` |
| `qwen3.5:35b-a3b` | `31.05s` | `37.34s` | `28.00 ms/token` | `35.71 tok/s` | `31.2 GiB` |

### Warm request

| Model | TTFT | Total Latency | TPOT | Throughput | Peak Runner RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| `gemma4-agent` | `0.25s` | `4.30s` | `18.30 ms/token` | `54.65 tok/s` | `24.5 GiB` |
| `qwen3.5:35b-a3b` | `2.73s` | `8.98s` | `27.91 ms/token` | `35.82 tok/s` | `31.6 GiB` |

Important note:

- Gemma's warm TTFT is heavily helped by exact prompt cache reuse.
- For cross-model comparison, the more trustworthy comparison points are:
  - cold TTFT
  - TPOT
  - total memory

## Memory Breakdown

### `gemma4-agent`

- GPU model weights: `16.6 GiB`
- CPU model weights: `667.5 MiB`
- KV cache: `5.9 GiB`
- GPU compute graph: `827.8 MiB`
- Total memory: `24.0 GiB`
- GPU offload: `31/31`

### `qwen3.5:35b-a3b`

- GPU model weights: `21.9 GiB`
- CPU model weights: `277.3 MiB`
- KV cache: `6.5 GiB`
- GPU compute graph: `3.3 GiB`
- Total memory: `32.0 GiB`
- GPU offload: `41/41`

## Interpretation

### Main finding

On this M5 Pro / 64 GB machine, `gemma4-agent` remains the better default coding-agent model.

Compared with `qwen3.5:35b-a3b`, Gemma is:

- about `27.7%` faster on cold TTFT
- about `53%` faster on decode throughput
- about `8 GiB` lighter in total memory

### Why Qwen is slower here

The gap is not primarily about KV cache.

The more important differences are:

- heavier model weights
- much larger compute graph
- slower prompt eval
- slower decode

Memory comparison:

- Gemma total memory: `24.0 GiB`
- Qwen total memory: `32.0 GiB`

Compute graph comparison:

- Gemma: `827.8 MiB`
- Qwen: `3.3 GiB`

So even though both models fit and fully offload to GPU, Qwen pays a visibly larger graph and execution cost on this workload.

## Recommendation

Keep `gemma4-agent` as the default local coding / agent model for this repository.

Use `qwen3.5:35b-a3b` as a secondary model when you specifically want:

- Qwen-family style
- stronger Chinese preference
- tool-calling style comparison
- a second opinion model rather than the default interactive path

## Practical Takeaways

For future local-model experiments on this machine:

1. Always benchmark one model at a time with a fresh `serve`.
2. Always confirm `has tensor = true` before trusting results.
3. Record the exact env; leaked shell vars can silently invalidate the run.
4. For coding-agent evaluation, cold TTFT and TPOT matter more than exact-prompt warm-cache TTFT.
5. On this machine, the most practical model class is still roughly:
   - `25B` to `35B`
   - `Q4_K_M` or similar quantized MoE/dense models

70B-class models may still load, but they are unlikely to be good defaults for day-to-day coding-agent work because TTFT, memory pressure, and model coexistence all degrade sharply.
