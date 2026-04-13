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

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" bash "$REPO_DIR/setup.sh" >"$out" 2>&1 <<<'Y'; then
    assert_file_has_line "$state_dir/models.txt" "gemma4:26b" "setup.sh pulls the exact Gemma base model"
  else
    fail "setup.sh completes when only another Gemma variant is preinstalled"
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

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" bash "$REPO_DIR/ollama.sh" switch deepseek-r1-70b >"$out" 2>&1 <<<'Y'; then
    assert_file_contains "$state_dir/models.txt" "deepseek-r1:70b" "ollama.sh switch pulls the exact base model tag"
  else
    fail "ollama.sh switch succeeds when only another DeepSeek variant is present"
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

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" bash "$REPO_DIR/ollama.sh" start >"$out" 2>&1; then
    assert_file_not_contains "$state_dir/run_calls.txt" "run" "ollama.sh start does not warm an invalid or missing model"
  else
    fail "ollama.sh start handles a missing config without crashing"
    sed -n '1,160p' "$out"
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

  if PATH="$bin_dir:/usr/bin:/bin" HOME="$home_dir" bash "$REPO_DIR/ollama.sh" stop >"$out" 2>&1; then
    assert_file_not_has_line "$state_dir/pkill_calls.txt" "-9 -f ollama" "ollama.sh stop avoids force-killing every Ollama process"
  else
    fail "ollama.sh stop completes with a stale pid file"
    sed -n '1,160p' "$out"
  fi
}

test_help_runs_with_system_bash
test_setup_pulls_exact_model
test_switch_pulls_exact_model
test_start_skips_invalid_model_warmup
test_stop_avoids_generic_force_kill

if [[ "$failures" -gt 0 ]]; then
  printf '\n%s test(s) failed.\n' "$failures"
  exit 1
fi

printf '\nAll tests passed.\n'
