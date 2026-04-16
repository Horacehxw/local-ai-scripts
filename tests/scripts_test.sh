#!/usr/bin/env bash

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT

failures=0

pass() {
  printf 'PASS: %s\n' "$1"
}

fail() {
  printf 'FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

assert_file_contains() {
  local file="$1"
  local expected="$2"
  local message="$3"
  if [[ -f "$file" ]] && grep -Fq -- "$expected" "$file"; then
    pass "$message"
  else
    fail "$message"
    [[ -f "$file" ]] && sed -n '1,120p' "$file"
  fi
}

assert_file_not_contains() {
  local file="$1"
  local unexpected="$2"
  local message="$3"
  if [[ ! -f "$file" ]] || ! grep -Fq -- "$unexpected" "$file"; then
    pass "$message"
  else
    fail "$message"
    sed -n '1,120p' "$file"
  fi
}

assert_file_not_has_line() {
  local file="$1"
  local unexpected="$2"
  local message="$3"
  if [[ ! -f "$file" ]] || ! grep -Fxq -- "$unexpected" "$file"; then
    pass "$message"
  else
    fail "$message"
    sed -n '1,120p' "$file"
  fi
}

assert_file_has_line() {
  local file="$1"
  local expected="$2"
  local message="$3"
  if [[ -f "$file" ]] && grep -Fxq -- "$expected" "$file"; then
    pass "$message"
  else
    fail "$message"
    [[ -f "$file" ]] && sed -n '1,120p' "$file"
  fi
}

new_env() {
  local name="$1"
  local dir="$TEST_ROOT/$name"
  mkdir -p "$dir/bin" "$dir/home"
  printf '%s\n' "$dir"
}

write_common_stubs() {
  local dir="$1"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"

  mkdir -p "$state_dir"

  cat > "$bin_dir/uname" <<'EOF'
#!/usr/bin/env bash
echo Darwin
EOF

  cat > "$bin_dir/brew" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "Homebrew 4.0.0"
fi
exit 0
EOF

  cat > "$bin_dir/node" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  echo "v20.0.0"
  exit 0
fi
exit 0
EOF

  cat > "$bin_dir/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  chmod +x "$bin_dir/uname" "$bin_dir/brew" "$bin_dir/node" "$bin_dir/npm"
}

test_help_runs_with_system_bash() {
  local dir
  dir="$(new_env help)"
  local out="$dir/out.txt"

  if bash "$REPO_DIR/ollama.sh" help >"$out" 2>&1; then
    pass "ollama.sh help runs on the system bash"
  else
    fail "ollama.sh help runs on the system bash"
    sed -n '1,80p' "$out"
  fi
}

test_status_prefers_path_ollama_over_app_bundle() {
  local dir
  dir="$(new_env status_prefers_path_bin)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$state_dir/path_calls.txt"
case "\${1:-}" in
  list)
    cat <<'LIST'
NAME                   ID              SIZE     MODIFIED
gemma4-agent:latest    123             17 GB    just now
LIST
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_PATCHED_BIN="$home_dir/missing-patched-ollama" bash "$REPO_DIR/ollama.sh" status >"$out" 2>&1; then
    assert_file_contains "$state_dir/path_calls.txt" "list" "ollama.sh status prefers a PATH ollama binary over the app bundle"
  else
    fail "ollama.sh status completes when both app and PATH binaries exist"
    sed -n '1,160p' "$out"
  fi
}

test_status_prefers_patched_binary_over_path_ollama() {
  local dir
  dir="$(new_env status_prefers_patched_bin)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local patched_bin="$dir/patched-ollama"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$state_dir/path_calls.txt"
exit 0
EOF

  cat > "$patched_bin" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$state_dir/patched_calls.txt"
case "\${1:-}" in
  list)
    cat <<'LIST'
NAME                   ID              SIZE     MODIFIED
gemma4-agent:latest    123             17 GB    just now
LIST
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama" "$patched_bin"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_PATCHED_BIN="$patched_bin" bash "$REPO_DIR/ollama.sh" status >"$out" 2>&1; then
    assert_file_contains "$state_dir/patched_calls.txt" "list" "ollama.sh status prefers the local patched Ollama binary by default"
    assert_file_not_contains "$state_dir/path_calls.txt" "list" "ollama.sh status does not fall back to PATH when the patched binary exists"
  else
    fail "ollama.sh status completes when the local patched binary is present"
    sed -n '1,160p' "$out"
  fi
}

test_setup_pulls_exact_model() {
  local dir
  dir="$(new_env setup_exact_pull)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  printf 'gemma4:e4b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  pull)
    echo "\$2" >> "\$STATE_DIR/models.txt"
    ;;
  create)
    file="\$4"
    base=\$(awk '/^FROM / {print \$2}' "\$file")
    if grep -Fxq "\$base" "\$STATE_DIR/models.txt"; then
      exit 0
    fi
    echo "missing base model: \$base" >&2
    exit 1
    ;;
  serve)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'Y'; then
    assert_file_has_line "$state_dir/models.txt" "gemma4:26b" "setup.sh pulls the exact Gemma base model"
  else
    fail "setup.sh completes when only another Gemma variant is preinstalled"
    sed -n '1,160p' "$out"
  fi
}

test_setup_writes_kv_cache_type() {
  local dir
  dir="$(new_env setup_kv_cache)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local env_file="$home_dir/.ollama_env"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create|serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_has_line "$env_file" 'export OLLAMA_KV_CACHE_TYPE=f16    # 单请求性能最优的 KV cache 配置' "setup.sh writes the single-request optimized KV cache type"
  else
    fail "setup.sh completes when writing the Ollama env file"
    sed -n '1,160p' "$out"
  fi
}

test_setup_writes_single_request_parallel_default() {
  local dir
  dir="$(new_env setup_num_parallel_default)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local env_file="$home_dir/.ollama_env"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create|serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_has_line "$env_file" 'export OLLAMA_NUM_PARALLEL=1       # 单用户 chat/coding 的最低延迟配置' "setup.sh writes the single-request optimized parallel default"
  else
    fail "setup.sh completes when writing the single-request parallel default"
    sed -n '1,160p' "$out"
  fi
}

test_setup_leaves_metal_tensor_workaround_opt_in() {
  local dir
  dir="$(new_env setup_tensor_workaround_opt_in)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local env_file="$home_dir/.ollama_env"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create|serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_has_line "$env_file" '# export GGML_METAL_TENSOR_DISABLE=1  # 仅在旧版 stock Ollama 上启用兼容绕过' "setup.sh leaves the Metal tensor workaround opt-in by default"
  else
    fail "setup.sh completes when leaving the Metal tensor workaround opt-in"
    sed -n '1,160p' "$out"
  fi
}

test_setup_omits_legacy_opencode_autoapprove_key() {
  local dir
  dir="$(new_env setup_opencode_schema)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local config_file="$home_dir/.config/opencode/opencode.json"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create|serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_not_contains "$config_file" '"autoapprove"' "setup.sh omits the legacy OpenCode autoapprove key"
  else
    fail "setup.sh completes when writing the OpenCode config"
    sed -n '1,200p' "$out"
  fi
}

test_setup_uses_256k_context_for_gemma4_agent() {
  local dir
  dir="$(new_env setup_gemma4_agent_256k)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local captured_modelfile="$state_dir/gemma4-agent.modelfile"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create)
    if [[ "\$2" == "gemma4-agent" ]]; then
      cp "\$4" "$captured_modelfile"
    fi
    exit 0
    ;;
  serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_has_line "$captured_modelfile" 'PARAMETER num_ctx 262144' "setup.sh creates gemma4-agent with a 256k context limit"
  else
    fail "setup.sh completes when generating the gemma4-agent Modelfile"
    sed -n '1,200p' "$out"
  fi
}

test_setup_uses_256k_context_for_gemma4_chat() {
  local dir
  dir="$(new_env setup_gemma4_chat_256k)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local captured_modelfile="$state_dir/gemma4-chat.modelfile"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create)
    if [[ "\$2" == "gemma4-chat" ]]; then
      cp "\$4" "$captured_modelfile"
    fi
    exit 0
    ;;
  serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_has_line "$captured_modelfile" 'PARAMETER num_ctx 262144' "setup.sh creates gemma4-chat with a 256k context limit"
  else
    fail "setup.sh completes when generating the gemma4-chat Modelfile"
    sed -n '1,200p' "$out"
  fi
}

test_setup_enables_opencode_websearch_env() {
  local dir
  dir="$(new_env setup_opencode_websearch_env)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local env_file="$home_dir/.ollama_env"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create|serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_has_line "$env_file" 'export OPENCODE_ENABLE_EXA=1       # 为 OpenCode 启用内置 websearch 工具' "setup.sh enables OpenCode websearch via OPENCODE_ENABLE_EXA"
  else
    fail "setup.sh completes when writing the OpenCode websearch env"
    sed -n '1,200p' "$out"
  fi
}

test_setup_configures_opencode_network_tools() {
  local dir
  dir="$(new_env setup_opencode_network_tools)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local config_file="$home_dir/.config/opencode/opencode.json"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create|serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_contains "$config_file" '"websearch": "allow"' "setup.sh allows the built-in websearch tool"
    assert_file_contains "$config_file" '"webfetch": "allow"' "setup.sh allows the built-in webfetch tool"
    assert_file_contains "$config_file" '"url": "https://mcp.context7.com/mcp"' "setup.sh configures the Context7 MCP server"
    assert_file_contains "$config_file" '"url": "https://mcp.grep.app"' "setup.sh configures the Grep MCP server"
  else
    fail "setup.sh completes when writing the OpenCode MCP configuration"
    sed -n '1,200p' "$out"
  fi
}

test_setup_configures_opencode_multimodal_models() {
  local dir
  dir="$(new_env setup_opencode_multimodal_models)"
  write_common_stubs "$dir"

  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local config_file="$home_dir/.config/opencode/opencode.json"

  printf 'gemma4:26b\n' > "$state_dir/models.txt"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
echo "unexpected curl args: $*" >&2
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  create|serve|pull)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'n'; then
    assert_file_contains "$config_file" '"attachment": true' "setup.sh marks gemma4 models as attachment-capable"
    assert_file_contains "$config_file" '"input": ["text", "image"]' "setup.sh configures image input modalities for gemma4 models"
    assert_file_contains "$config_file" '"output": ["text"]' "setup.sh configures text output modalities for gemma4 models"
  else
    fail "setup.sh completes when writing multimodal OpenCode model config"
    sed -n '1,200p' "$out"
  fi
}

test_start_uses_single_request_defaults_without_env_file() {
  local dir
  dir="$(new_env start_single_request_defaults)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local patched_bin="$dir/patched-ollama"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir/.config/opencode"
  printf '{"model":"ollama/gemma4-agent"}\n' > "$home_dir/.config/opencode/opencode.json"

  cat > "$bin_dir/curl" <<EOF
#!/usr/bin/env bash
if [[ "\${*: -1}" == "http://localhost:11434/api/version" && -f "$state_dir/server_ready" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$patched_bin" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  serve)
    touch "\$STATE_DIR/server_ready"
    {
      printf 'OLLAMA_FLASH_ATTENTION=%s\n' "\${OLLAMA_FLASH_ATTENTION:-}"
      printf 'OLLAMA_KV_CACHE_TYPE=%s\n' "\${OLLAMA_KV_CACHE_TYPE:-}"
      printf 'OLLAMA_NUM_PARALLEL=%s\n' "\${OLLAMA_NUM_PARALLEL:-}"
      printf 'GGML_METAL_TENSOR_DISABLE=%s\n' "\${GGML_METAL_TENSOR_DISABLE:-}"
    } > "\$STATE_DIR/serve_env.txt"
    exit 0
    ;;
  list)
    cat <<'LIST'
NAME                   ID              SIZE     MODIFIED
gemma4-agent:latest    123             17 GB    just now
LIST
    ;;
  run|ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$patched_bin"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_PATCHED_BIN="$patched_bin" OLLAMA_FLASH_ATTENTION= OLLAMA_KV_CACHE_TYPE= OLLAMA_NUM_PARALLEL= GGML_METAL_TENSOR_DISABLE=1 bash "$REPO_DIR/ollama.sh" start >"$out" 2>&1; then
    assert_file_has_line "$state_dir/serve_env.txt" 'OLLAMA_FLASH_ATTENTION=1' "ollama.sh start enables flash attention by default"
    assert_file_has_line "$state_dir/serve_env.txt" 'OLLAMA_KV_CACHE_TYPE=f16' "ollama.sh start defaults to the single-request optimized KV cache type"
    assert_file_has_line "$state_dir/serve_env.txt" 'OLLAMA_NUM_PARALLEL=1' "ollama.sh start defaults to the single-request optimized parallel setting"
    assert_file_has_line "$state_dir/serve_env.txt" 'GGML_METAL_TENSOR_DISABLE=' "ollama.sh start does not force-disable Metal tensor support on the patched runtime path"
  else
    fail "ollama.sh start completes when using the patched runtime defaults"
    sed -n '1,160p' "$out"
  fi
}

test_switch_pulls_exact_model() {
  local dir
  dir="$(new_env switch_exact_pull)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir/.config/opencode"
  printf 'deepseek-r1:32b\n' > "$state_dir/models.txt"
  printf '{"model":"ollama/deepseek-r1"}\n' > "$home_dir/.config/opencode/opencode.json"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  pull)
    echo "\$2" >> "\$STATE_DIR/models.txt"
    ;;
  create)
    file="\$4"
    base=\$(awk '/^FROM / {print \$2}' "\$file")
    if grep -Fxq "\$base" "\$STATE_DIR/models.txt"; then
      exit 0
    fi
    echo "missing base model: \$base" >&2
    exit 1
    ;;
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" switch deepseek-r1-70b >"$out" 2>&1 <<<'Y'; then
    assert_file_contains "$state_dir/models.txt" "deepseek-r1:70b" "ollama.sh switch pulls the exact base model tag"
  else
    fail "ollama.sh switch succeeds when only another DeepSeek variant is present"
    sed -n '1,160p' "$out"
  fi
}

test_switch_pulls_exact_qwen35_a3b_model() {
  local dir
  dir="$(new_env switch_qwen35_a3b_exact_pull)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir/.config/opencode"
  printf 'qwen3:32b\n' > "$state_dir/models.txt"
  printf '{"model":"ollama/qwen3"}\n' > "$home_dir/.config/opencode/opencode.json"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  pull)
    echo "\$2" >> "\$STATE_DIR/models.txt"
    ;;
  create)
    file="\$4"
    base=\$(awk '/^FROM / {print \$2}' "\$file")
    if grep -Fxq "\$base" "\$STATE_DIR/models.txt"; then
      exit 0
    fi
    echo "missing base model: \$base" >&2
    exit 1
    ;;
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" switch qwen35-a3b >"$out" 2>&1 <<<'Y'; then
    assert_file_contains "$state_dir/models.txt" "qwen3.5:35b-a3b" "ollama.sh switch pulls the exact Qwen3.5 35B-A3B base model tag"
  else
    fail "ollama.sh switch succeeds when only another Qwen variant is present"
    sed -n '1,160p' "$out"
  fi
}

test_switch_marks_qwen35_a3b_as_multimodal() {
  local dir
  dir="$(new_env switch_qwen35_a3b_multimodal)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local config_file="$home_dir/.config/opencode/opencode.json"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir/.config/opencode"
  printf 'qwen3:32b\n' > "$state_dir/models.txt"
  printf '{\n  "model": "ollama/qwen3",\n  "provider": {"ollama": {"models": {}}}\n}\n' > "$config_file"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  pull)
    echo "\$2" >> "\$STATE_DIR/models.txt"
    ;;
  create)
    file="\$4"
    base=\$(awk '/^FROM / {print \$2}' "\$file")
    if grep -Fxq "\$base" "\$STATE_DIR/models.txt"; then
      exit 0
    fi
    echo "missing base model: \$base" >&2
    exit 1
    ;;
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" switch qwen35-a3b >"$out" 2>&1 <<<'Y'; then
    assert_file_contains "$config_file" '"attachment": true' "ollama.sh switch marks qwen35-a3b as attachment-capable"
    assert_file_contains "$config_file" '"modalities": {' "ollama.sh switch writes multimodal metadata for qwen35-a3b"
    assert_file_contains "$config_file" '"image"' "ollama.sh switch configures image input modalities for qwen35-a3b"
  else
    fail "ollama.sh switch writes multimodal config for qwen35-a3b"
    sed -n '1,160p' "$out"
  fi
}

test_switch_uses_native_context_for_qwen35_a3b() {
  local dir
  dir="$(new_env switch_qwen35_a3b_native_context)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"
  local config_file="$home_dir/.config/opencode/opencode.json"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir/.config/opencode"
  printf 'qwen3:32b\n' > "$state_dir/models.txt"
  printf '{\n  "model": "ollama/qwen3",\n  "provider": {"ollama": {"models": {}}}\n}\n' > "$config_file"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat "\$STATE_DIR/models.txt"
    ;;
  pull)
    echo "\$2" >> "\$STATE_DIR/models.txt"
    ;;
  create)
    exit 0
    ;;
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" switch qwen35-a3b >"$out" 2>&1 <<<'Y'; then
    assert_file_contains "$config_file" '"contextLength": 262144' "ollama.sh switch uses the native maximum context for qwen35-a3b"
  else
    fail "ollama.sh switch writes the native qwen35-a3b context"
    sed -n '1,160p' "$out"
  fi
}

test_start_skips_invalid_model_warmup() {
  local dir
  dir="$(new_env start_invalid_warmup)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  run)
    printf '%s\n' "\$*" >> "\$STATE_DIR/run_calls.txt"
    exit 1
    ;;
  ps|list)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" start >"$out" 2>&1; then
    assert_file_not_contains "$state_dir/run_calls.txt" "run" "ollama.sh start does not warm an invalid or missing model"
  else
    fail "ollama.sh start handles a missing config without crashing"
    sed -n '1,160p' "$out"
  fi
}

test_start_warms_latest_model_alias() {
  local dir
  dir="$(new_env start_latest_alias)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir/.config/opencode"
  printf '{"model":"ollama/gemma4-agent"}\n' > "$home_dir/.config/opencode/opencode.json"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
STATE_DIR="$state_dir"
case "\${1:-}" in
  list)
    cat <<'LIST'
NAME                   ID              SIZE     MODIFIED
gemma4-agent:latest    123             17 GB    just now
LIST
    ;;
  run)
    printf '%s\n' "\$*" >> "\$STATE_DIR/run_calls.txt"
    exit 0
    ;;
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" start >"$out" 2>&1; then
    assert_file_contains "$state_dir/run_calls.txt" "run gemma4-agent  --nowordwrap" "ollama.sh start warms an installed alias even when Ollama reports :latest"
  else
    fail "ollama.sh start warms an installed alias reported with :latest"
    sed -n '1,160p' "$out"
  fi
}

test_start_fails_on_gpu_discovery_timeout() {
  local dir
  dir="$(new_env start_gpu_timeout)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir/.config/opencode"
  printf '{"model":"ollama/gemma4-agent"}\n' > "$home_dir/.config/opencode/opencode.json"
  cat > "$home_dir/.ollama.log" <<'EOF'
time=2026-04-13T23:56:31.034+08:00 level=INFO source=runner.go:464 msg="failure during GPU discovery" error="failed to finish discovery before timeout"
time=2026-04-13T23:56:31.034+08:00 level=INFO source=types.go:60 msg="inference compute" id=cpu library=cpu
time=2026-04-13T23:56:32.000+08:00 level=ERROR source=server.go:316 msg="llama runner terminated" error="exit status 2"
EOF

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  list)
    cat <<'LIST'
NAME                   ID              SIZE     MODIFIED
gemma4-agent:latest    123             17 GB    just now
LIST
    ;;
  run)
    exit 1
    ;;
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" start >"$out" 2>&1; then
    fail "ollama.sh start stops when GPU discovery times out and warmup fails"
    sed -n '1,160p' "$out"
  else
    assert_file_contains "$out" "GPU 探测超时" "ollama.sh start reports the GPU discovery timeout explicitly"
    assert_file_contains "$out" "brew reinstall ollama mlx-c" "ollama.sh start suggests repairing the local Ollama runtime"
  fi
}

test_stop_avoids_generic_force_kill() {
  local dir
  dir="$(new_env stop_force_kill)"
  local bin_dir="$dir/bin"
  local state_dir="$dir/state"
  local home_dir="$dir/home"
  local out="$dir/out.txt"

  mkdir -p "$bin_dir" "$state_dir" "$home_dir"
  printf '999999\n' > "$home_dir/.ollama.pid"

  cat > "$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "${*: -1}" == "http://localhost:11434/api/version" ]]; then
  echo '{"version":"test"}'
  exit 0
fi
exit 1
EOF

  cat > "$bin_dir/ollama" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  ps)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

  cat > "$bin_dir/pkill" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$state_dir/pkill_calls.txt"
exit 0
EOF

  chmod +x "$bin_dir/curl" "$bin_dir/ollama" "$bin_dir/pkill"

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" OLLAMA_BIN=ollama bash "$REPO_DIR/ollama.sh" stop >"$out" 2>&1; then
    assert_file_not_has_line "$state_dir/pkill_calls.txt" "-9 -f ollama" "ollama.sh stop avoids force-killing every Ollama process"
  else
    fail "ollama.sh stop completes with a stale pid file"
    sed -n '1,160p' "$out"
  fi
}

test_help_runs_with_system_bash
test_status_prefers_path_ollama_over_app_bundle
test_status_prefers_patched_binary_over_path_ollama
test_setup_pulls_exact_model
test_setup_writes_kv_cache_type
test_setup_writes_single_request_parallel_default
test_setup_leaves_metal_tensor_workaround_opt_in
test_setup_omits_legacy_opencode_autoapprove_key
test_setup_uses_256k_context_for_gemma4_agent
test_setup_uses_256k_context_for_gemma4_chat
test_setup_enables_opencode_websearch_env
test_setup_configures_opencode_network_tools
test_setup_configures_opencode_multimodal_models
test_switch_pulls_exact_model
test_switch_pulls_exact_qwen35_a3b_model
test_switch_marks_qwen35_a3b_as_multimodal
test_switch_uses_native_context_for_qwen35_a3b
test_start_uses_single_request_defaults_without_env_file
test_start_skips_invalid_model_warmup
test_start_warms_latest_model_alias
test_start_fails_on_gpu_discovery_timeout
test_stop_avoids_generic_force_kill

if [[ "$failures" -gt 0 ]]; then
  printf '\n%s test(s) failed.\n' "$failures"
  exit 1
fi

printf '\nAll tests passed.\n'
