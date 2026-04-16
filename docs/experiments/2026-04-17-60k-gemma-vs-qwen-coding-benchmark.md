# 60K-Input Gemma vs Qwen Coding Benchmark

Date: 2026-04-17

## Goal

Measure `gemma4:26b` versus `qwen3.5:35b-a3b` on this machine with a long coding-agent style prompt at roughly `60K` input tokens.

This run was intended to answer a different question from the earlier `~20K` benchmark:

- how both models behave when prompt prefill dominates
- how much memory each model needs at this longer context length
- whether the relative Gemma versus Qwen ranking changes at `~60K`

## Machine And Runtime

- Machine: Apple M5 Pro
- Unified memory: `64 GB`
- Runtime: patched local Ollama build at `/tmp/ollama-tensor-fix/dist/darwin-arm64/ollama`
- GPU backend: Metal
- Tensor path: enabled

Required log checks for a valid run:

- `has tensor = true`
- `has bfloat = true`
- all model layers offloaded to GPU

## Test Configuration

All runs used the same runtime configuration:

- `OLLAMA_FLASH_ATTENTION=1`
- `OLLAMA_KV_CACHE_TYPE=f16`
- `OLLAMA_NUM_PARALLEL=1`
- `OLLAMA_MAX_LOADED_MODELS=1`
- `OLLAMA_KEEP_ALIVE=-1`
- no `GGML_METAL_TENSOR_DISABLE`

Per-request options:

- `stream=true`
- `temperature=0`
- `num_predict=220`
- `num_ctx=262144`
- `think=false`

## Workload

The prompt was a repo-context coding task assembled from:

- `README.md`
- `setup.sh`
- `ollama.sh`
- `tests/scripts_test.sh`

The file set was repeated until the prompt reached about `170K` characters. The task asked the model to:

- read the repository snapshot
- identify the 3 highest-risk implementation issues for a coding-agent workflow
- propose concrete shell-level or config-level remediations

Prompt characteristics:

- raw prompt length: `170,037` characters
- `gemma4:26b` prompt tokens: `65,313`
- `qwen3.5:35b-a3b` prompt tokens: `60,685`

The text itself was identical across both runs. The token counts differ because the tokenizers differ.

## Reproduction Method

To keep the comparison clean, each model was measured in isolation.

### Procedure

1. Stop any existing Ollama service and unload any already-loaded models.
2. Ensure no stale `serve` or `runner` processes remain.
3. Start a fresh `serve` with the exact env listed above.
4. Send one cold streaming chat request for the target model.
5. Record:
   - TTFT from request start to the first streamed token
   - TPOT from `eval_duration / eval_count`
   - peak runner RSS sampled during the request
   - `kv cache`, `compute graph`, and `total memory` from the server log
6. Terminate that `serve`.
7. Repeat the same steps for the second model.

### Why Fresh `serve` Matters

This machine can keep large models resident in memory. If another model is already loaded, measured RSS and prefill time stop being trustworthy.

For this benchmark, correctness depended on:

- one model at a time
- fresh `serve` per model
- confirming `has tensor = true` in the per-model log before accepting the result

## Results

| Model | Prompt Tokens | TTFT | Total Latency | TPOT | Throughput | Peak Runner RSS | Total Memory | KV Cache |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `gemma4:26b` | `65,313` | `132.99s` | `139.13s` | `28.01 ms/token` | `35.70 tok/s` | `25.3 GiB` | `24.0 GiB` | `5.9 GiB` |
| `qwen3.5:35b-a3b` | `60,685` | `146.44s` | `154.23s` | `35.02 ms/token` | `28.55 tok/s` | `33.67 GiB` | `32.0 GiB` | `6.5 GiB` |

## Memory Breakdown

### `gemma4:26b`

- GPU model weights: `16.6 GiB`
- CPU model weights: `667.5 MiB`
- KV cache: `5.9 GiB`
- GPU compute graph: `827.8 MiB`
- CPU compute graph: `5.5 MiB`
- Total memory: `24.0 GiB`
- GPU offload: `31/31`

### `qwen3.5:35b-a3b`

- GPU model weights: `21.9 GiB`
- CPU model weights: `277.3 MiB`
- KV cache: `6.5 GiB`
- GPU compute graph: `3.3 GiB`
- CPU compute graph: `27.1 MiB`
- Total memory: `32.0 GiB`
- GPU offload: `41/41`

## Interpretation

At roughly `60K` input tokens, `gemma4:26b` remains the stronger default model on this machine for long coding-agent prompts.

Compared with `qwen3.5:35b-a3b`, Gemma is:

- about `9.2%` faster on TTFT
- about `20%` faster on TPOT
- about `8.4 GiB` lighter on peak runner RSS
- about `8 GiB` lighter on total memory

The KV cache difference is small:

- Gemma: `5.9 GiB`
- Qwen: `6.5 GiB`

The larger gap comes from:

- heavier model weights on Qwen
- a much larger compute graph on Qwen

At this context length, the ranking does not flip:

- Gemma is still faster
- Gemma is still lighter
- Qwen is still viable, but it is the more expensive choice

## Practical Takeaways

1. For long-context local coding-agent work on this M5 Pro / 64 GB machine, `gemma4:26b` is still the better default.
2. `qwen3.5:35b-a3b` remains usable, but it pays a clear memory and latency penalty.
3. At `~60K`, prompt prefill dominates. TTFT becomes much larger than it was in the earlier `~20K` benchmark.
4. When comparing long-context models on Ollama, the most useful memory breakdown is:
   - model weights
   - KV cache
   - compute graph
   - peak runner RSS

## Reproducing This Benchmark

The exact local run used a temporary harness outside the repository, but the benchmark is straightforward to reproduce if you keep the same discipline:

1. Install or reuse the patched Ollama binary that enables the full Metal tensor path on this machine.
2. Stop any existing Ollama service.
3. Start a fresh `serve` with:
   - `OLLAMA_FLASH_ATTENTION=1`
   - `OLLAMA_KV_CACHE_TYPE=f16`
   - `OLLAMA_NUM_PARALLEL=1`
   - `OLLAMA_MAX_LOADED_MODELS=1`
   - no `GGML_METAL_TENSOR_DISABLE`
4. Build one shared long repo-context prompt and reuse the exact same text for both models.
5. Run one cold request per model with:
   - `stream=true`
   - `temperature=0`
   - `num_predict=220`
   - `num_ctx=262144`
   - `think=false`
6. Record:
   - `prompt_eval_count`
   - `prompt_eval_duration`
   - `eval_count`
   - `eval_duration`
   - TTFT from the first streamed token
   - peak runner RSS from `ps`
   - `kv cache`, `compute graph`, and `total memory` from the server log
7. Reject the run if the log does not show:
   - `has tensor = true`
   - full layer offload to GPU

## Notes

- These numbers are for cold, clean, single-model runs only.
- They should not be compared directly with a reused-prompt warm-cache measurement.
- If a future run changes `KV cache`, `num_ctx`, or `NUM_PARALLEL`, treat it as a different benchmark rather than a direct continuation of this one.
