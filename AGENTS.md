# Repository Guidelines

## Project Structure & Module Organization

- `setup.sh` is the one-time macOS bootstrap script for Homebrew, Node.js, Ollama, and OpenCode.
- `ollama.sh` is the daily control entrypoint for `start`, `stop`, `status`, `switch`, and `help`.
- `tests/scripts_test.sh` is the regression harness; keep new tests close to the behavior they cover.
- `README.md` is the user-facing setup and usage document. Update it when commands, defaults, or generated files change.

## Build, Test, and Development Commands

- `chmod +x setup.sh ollama.sh` makes the scripts executable on a fresh clone.
- `./setup.sh` performs first-time local setup and writes config under `$HOME`.
- `./ollama.sh help` is the quickest smoke test for CLI compatibility.
- `./ollama.sh start|status|switch|stop` exercises the main operational paths locally.
- `bash tests/scripts_test.sh` runs the automated regression suite with stubbed dependencies; run it before every PR.

## Coding Style & Naming Conventions

- Write portable Bash with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Preserve macOS default Bash compatibility; avoid Bash-4-only features such as associative arrays.
- Use quoted expansions, `[[ ... ]]` conditionals, and 2-space indentation inside functions.
- Keep shared config variables uppercase (`OLLAMA_BIN`, `OPENCODE_CONFIG`) and functions lowercase with underscores (`model_installed_exact`).
- Follow the existing script style: small helper functions, section banners, and concise comments only where behavior is non-obvious.

## Testing Guidelines

- Add or extend `test_*` functions in `tests/scripts_test.sh` for every behavior change.
- Cover both success and guardrail paths, especially model detection, startup diagnostics, and shutdown behavior.
- When fixing a bug, include a regression test in the same change when practical.

## Commit & Pull Request Guidelines

- Follow the existing Conventional Commit style seen in history: `fix: ...`, `chore: ...`.
- Keep subjects imperative and narrow, for example `fix: avoid warming missing model aliases`.
- PRs should summarize the behavior change, list the verification command(s), and note any `README.md` updates.
- If a change affects files written under `$HOME`, call out those paths explicitly in the PR description.

## Configuration & Safety Notes

- These scripts modify user-scoped files such as `~/.ollama_env`, `~/.ollama_modelfiles/`, and `~/.config/opencode/opencode.json`.
- Never commit local logs, generated config, or machine-specific paths and secrets.
- Prefer additive, reversible changes when touching shell rc files or generated config.
