# Local AI Scripts

This repository contains two Bash scripts for running a local Ollama-based setup on macOS:

- `setup.sh`: one-time bootstrap for Ollama, a default Gemma model, and OpenCode.
- `ollama.sh`: daily control script for starting, stopping, checking status, and switching models.

The scripts are designed for a local workflow where Ollama is not configured as a login service. You start it when you need it, and stop it when you want to free memory.

When present, the scripts now prefer the patched local Ollama build at `/tmp/ollama-tensor-fix/dist/darwin-arm64/ollama`, which restores the full Metal tensor path on this machine. They fall back to the system `ollama` binary only if that patched build is unavailable.

## What Each Script Does

### `setup.sh`

Use this once on a new machine or a fresh local setup.

It does the following:

1. Checks that the machine is running macOS.
2. Installs Homebrew if missing.
3. Installs or upgrades Node.js.
4. Installs or upgrades `ollama`.
5. Ensures Ollama is not set to auto-start with `brew services`.
6. Writes Ollama performance environment variables to `~/.ollama_env`.
7. Optionally downloads the default base model: `gemma4:26b`.
8. Creates two local Ollama model aliases:
   - `gemma4-agent`: 256k context, intended for OpenCode
   - `gemma4-chat`: 256k context, intended for general chat
9. Installs or updates `opencode-ai`.
10. Writes OpenCode config to `~/.config/opencode/opencode.json`.

### `ollama.sh`

Use this script for normal day-to-day operation.

It provides these commands:

- `./ollama.sh start`
  Starts the Ollama server in the background, waits for it to become ready, then tries to warm the currently configured OpenCode model into memory.

- `./ollama.sh stop`
  Stops loaded models, terminates the Ollama server, and frees memory.

- `./ollama.sh status`
  Shows whether Ollama is running, the Ollama version, the current OpenCode model, loaded models, and downloaded local models.

- `./ollama.sh switch`
  Shows the built-in model catalog and lets you interactively choose a model alias.

- `./ollama.sh switch <alias>`
  Directly switches to a specific alias, downloading the exact base model if needed, registering a local Modelfile alias, and updating OpenCode config.

## Prerequisites

These scripts assume:

- macOS
- network access for Homebrew, npm, and model downloads
- enough disk space for local models
- enough RAM / unified memory for the model you choose

The default setup is centered around Ollama and OpenCode. If you do not use OpenCode, parts of the configuration may be unnecessary for your workflow.

The default runtime profile is optimized for single-user chat/coding:

- `OLLAMA_FLASH_ATTENTION=1`
- `OLLAMA_KV_CACHE_TYPE=f16`
- `OLLAMA_NUM_PARALLEL=1`
- `OPENCODE_ENABLE_EXA=1`

Benchmark notes and measurements for this choice are recorded in [docs/experiments/2026-04-15-gemma4-single-request-performance.md](docs/experiments/2026-04-15-gemma4-single-request-performance.md).

OpenCode is also configured for network-backed discovery by default:

- built-in `websearch`
- built-in `webfetch`
- `context7` MCP for docs search
- `gh_grep` MCP for public GitHub code search

For multimodal models such as `gemma4-agent`, OpenCode is also configured to accept image attachments. The generated model entries declare:

- `attachment: true`
- `modalities.input: ["text", "image"]`
- `modalities.output: ["text"]`

In practice, after starting `opencode`, you can attach an image or paste an image path into the prompt when using a model that supports vision.

## First-Time Setup

Make the scripts executable if needed:

```bash
chmod +x setup.sh ollama.sh
```

Run the one-time installer:

```bash
./setup.sh
```

During setup:

- you may be prompted to download the default Gemma base model
- the script writes shell config entries for `~/.ollama_env`
- OpenCode is configured to use `ollama/gemma4-agent`
- the generated `~/.ollama_env` defaults to the single-request performance profile

After setup, open a new shell or reload your shell config:

```bash
source ~/.zshrc
```

If you use Bash instead of Zsh:

```bash
source ~/.bashrc
```

## Daily Usage

Start Ollama and warm the currently configured model:

```bash
./ollama.sh start
```

Check status:

```bash
./ollama.sh status
```

Stop Ollama and release memory:

```bash
./ollama.sh stop
```

If you use OpenCode, a typical flow is:

```bash
./ollama.sh start
cd ~/your-project
opencode
```

When you are done:

```bash
./ollama.sh stop
```

## Switching Models

Show the interactive chooser:

```bash
./ollama.sh switch
```

Switch directly to a known alias:

```bash
./ollama.sh switch qwen-coder
```

When you switch models, the script:

1. Ensures the Ollama server is running.
2. Checks whether the exact base model tag is already downloaded.
3. Downloads it if needed.
4. Writes a Modelfile into `~/.ollama_modelfiles/`.
5. Registers the alias with `ollama create`.
6. Updates `~/.config/opencode/opencode.json` so OpenCode uses `ollama/<alias>`.

## Built-In Model Aliases

The current built-in aliases are:

- `gemma4-moe`
- `gemma4-dense`
- `gemma4-edge`
- `qwen-coder`
- `qwen3`
- `qwen3-fast`
- `deepseek-r1`
- `deepseek-r1-70b`
- `llama3.3`
- `phi4`

To see the latest list from the script itself:

```bash
./ollama.sh help
```

## Files Created or Modified

These scripts touch files outside the repository:

- `~/.ollama_env`
  Stores Ollama environment variables such as keep-alive and parallelism settings.

- `~/.zshrc` or `~/.bashrc`
  Adds a line to source `~/.ollama_env` if the file exists and does not already include it.

- `~/.ollama_modelfiles/`
  Stores generated Modelfiles for local aliases like `gemma4-agent` or `qwen-coder`.

- `~/.config/opencode/opencode.json`
  Stores the OpenCode configuration and current default model.

- `~/.ollama.pid`
  Stores the PID of the background Ollama server started by `ollama.sh`.

- `~/.ollama.log`
  Receives background server logs when `ollama.sh start` launches `ollama serve`.

- `/tmp/ollama_setup.log`
  Temporary setup-time Ollama server log.

## Important Behavior Notes

- `setup.sh` is intended as a bootstrap script, not something you run every day.
- `ollama.sh start` does not use `brew services`; it starts `ollama serve` in the background directly.
- `ollama.sh stop` tries to unload models before stopping the server.
- `ollama.sh start` only warms a model if OpenCode is configured with a valid `ollama/<alias>` model string.
- `ollama.sh switch` updates OpenCode config, so your next `start` uses the newly selected model.

## Troubleshooting

### Ollama fails to start

Check the background log:

```bash
cat ~/.ollama.log
```

Then verify status:

```bash
./ollama.sh status
```

### The script says a model is missing

List local models:

```bash
ollama list
```

If needed, switch again and allow the script to download the missing exact model tag.

### OpenCode is not using the model you expect

Inspect the OpenCode config:

```bash
cat ~/.config/opencode/opencode.json
```

Look for:

```json
"model": "ollama/<alias>"
```

### Environment changes are not taking effect

Reload your shell config or open a new terminal session:

```bash
source ~/.zshrc
```

Then confirm:

```bash
cat ~/.ollama_env
```

If you intentionally fall back to an older stock Ollama runtime and need the old Metal compatibility workaround, uncomment this line in `~/.ollama_env`:

```bash
export GGML_METAL_TENSOR_DISABLE=1
```

## Repo Verification

This repo includes a regression harness for the scripts:

```bash
bash tests/scripts_test.sh
```

That test checks:

- `ollama.sh` runs on macOS's default Bash
- exact model tag detection works
- invalid model warmup is skipped safely
- shutdown avoids the overly broad kill behavior that was fixed
