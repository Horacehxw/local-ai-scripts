#!/usr/bin/env bash
# =============================================================================
# setup.sh — 一次性安装脚本
# 安装 Ollama + Gemma 4 26B MoE + OpenCode，不设置开机自启
# 用法: chmod +x setup.sh && ./setup.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
step() { echo -e "\n${BOLD}${CYAN}━━━ $* ━━━${NC}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_BASE="gemma4:26b"
MODELFILES_DIR="$HOME/.ollama_modelfiles"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
OLLAMA_PATCHED_BIN="${OLLAMA_PATCHED_BIN:-/tmp/ollama-tensor-fix/dist/darwin-arm64/ollama}"
OLLAMA_APP_BIN="${OLLAMA_APP_BIN:-/Applications/Ollama.app/Contents/Resources/ollama}"

resolve_ollama_bin() {
  if [[ -n "${OLLAMA_BIN:-}" ]]; then
    printf '%s\n' "$OLLAMA_BIN"
  elif [[ -x "$OLLAMA_PATCHED_BIN" ]]; then
    printf '%s\n' "$OLLAMA_PATCHED_BIN"
  elif command -v ollama &>/dev/null; then
    command -v ollama
  elif [[ -x "$OLLAMA_APP_BIN" ]]; then
    printf '%s\n' "$OLLAMA_APP_BIN"
  else
    printf '%s\n' "ollama"
  fi
}

OLLAMA_BIN="$(resolve_ollama_bin)"
STARTED_TEMP=false
OLLAMA_PID=""

cleanup_temp_ollama() {
  if [[ "$STARTED_TEMP" == "true" && -n "$OLLAMA_PID" ]]; then
    kill "$OLLAMA_PID" 2>/dev/null || true
    wait "$OLLAMA_PID" 2>/dev/null || true
    STARTED_TEMP=false
  fi
}

model_installed_exact() {
  local model="$1"
  "$OLLAMA_BIN" list 2>/dev/null | awk 'NR == 1 && $1 == "NAME" {next} NF {print $1}' | grep -Fxq "$model"
}

trap cleanup_temp_ollama EXIT INT TERM

echo -e "${BOLD}"
cat << 'BANNER'
  ╔══════════════════════════════════════════════════╗
  ║   Setup: Ollama + Gemma 4 26B MoE + OpenCode    ║
  ║   一次性安装，不设开机自启                        ║
  ╚══════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

# ── Step 1: 依赖检查 ──────────────────────────────────────────────────────────
step "1/6 检查依赖"

[[ "$(uname)" == "Darwin" ]] || err "仅支持 macOS"

if ! command -v brew &>/dev/null; then
  info "安装 Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/homebrew/install/HEAD/install.sh)"
else
  log "Homebrew: $(brew --version | head -1)"
fi

if ! command -v node &>/dev/null; then
  info "安装 Node.js..."
  brew install node
else
  NODE_MAJOR=$(node --version | sed 's/v//' | cut -d. -f1)
  if [[ "$NODE_MAJOR" -lt 18 ]]; then
    info "Node.js 版本过低，升级中..."
    brew upgrade node
  fi
  log "Node.js: $(node --version)"
fi

# ── Step 2: 安装 Ollama（不设自启）──────────────────────────────────────────
step "2/6 安装 Ollama"

if command -v ollama &>/dev/null; then
  log "Ollama 已安装，检查更新..."
  brew upgrade ollama 2>/dev/null || true
else
  brew install ollama
  log "Ollama 安装完成"
fi

# 确保 Ollama 没有被设置为自启（清理旧配置）
brew services stop ollama 2>/dev/null || true
brew services disable ollama 2>/dev/null || true
log "Ollama 开机自启已禁用（按需手动启动）"

# ── Step 3: 写入环境变量（仅性能参数，不含自启）────────────────────────────
step "3/6 配置环境变量"

OLLAMA_ENV="$HOME/.ollama_env"
cat > "$OLLAMA_ENV" << 'EOF'
# Ollama 性能配置 (Apple Silicon)
export OLLAMA_KEEP_ALIVE=-1        # 模型常驻内存，避免重复加载
export OLLAMA_FLASH_ATTENTION=1    # Metal Flash Attention 加速
export OLLAMA_KV_CACHE_TYPE=f16    # 单请求性能最优的 KV cache 配置
export OLLAMA_NUM_PARALLEL=1       # 单用户 chat/coding 的最低延迟配置
export OLLAMA_MAX_LOADED_MODELS=3  # 最多同时加载 3 个模型
export OPENCODE_ENABLE_EXA=1       # 为 OpenCode 启用内置 websearch 工具
# export GGML_METAL_TENSOR_DISABLE=1  # 仅在旧版 stock Ollama 上启用兼容绕过
EOF

# 写入 shell rc（避免重复）
for RC in "$HOME/.zshrc" "$HOME/.bashrc"; do
  if [[ -f "$RC" ]] && ! grep -q "ollama_env" "$RC" 2>/dev/null; then
    echo "" >> "$RC"
    echo "# Ollama 环境变量" >> "$RC"
    echo "[ -f \"\$HOME/.ollama_env\" ] && source \"\$HOME/.ollama_env\"" >> "$RC"
    log "已写入 $RC"
  fi
done
source "$OLLAMA_ENV"

# ── Step 4: 下载模型 ──────────────────────────────────────────────────────────
step "4/6 下载 Gemma 4 26B MoE (~18GB)"

# 启动临时服务用于下载
if ! curl -s http://localhost:11434/api/version &>/dev/null; then
  info "临时启动 Ollama 服务用于下载..."
  "$OLLAMA_BIN" serve &>/tmp/ollama_setup.log &
  OLLAMA_PID=$!
  sleep 3
  STARTED_TEMP=true
else
  STARTED_TEMP=false
fi

if model_installed_exact "$MODEL_BASE"; then
  log "Gemma 4 模型已存在，跳过下载"
else
  warn "即将下载 ~18GB，请确保网络和磁盘空间充足"
  read -r -p "$(echo -e ${YELLOW}[?]${NC}) 开始下载？[Y/n] " confirm
  confirm=${confirm:-Y}
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    "$OLLAMA_BIN" pull "$MODEL_BASE"
    log "下载完成"
  else
    warn "已跳过。之后可手动运行: ollama pull $MODEL_BASE"
  fi
fi

# ── Step 5: 创建 Modelfile（Gemma 4 26B 使用 256k context）───────────────────
step "5/6 创建优化 Modelfile"

mkdir -p "$MODELFILES_DIR"

# gemma4-agent：给 OpenCode 用（256k context，上限拉满）
cat > "$MODELFILES_DIR/gemma4-agent" << EOF
FROM $MODEL_BASE
PARAMETER num_ctx 262144
PARAMETER num_predict 8192
PARAMETER temperature 1.0
PARAMETER top_p 0.95
PARAMETER top_k 64
PARAMETER repeat_penalty 1.0
EOF

# gemma4-chat：日常聊天（32k context，速度更快）
cat > "$MODELFILES_DIR/gemma4-chat" << EOF
FROM $MODEL_BASE
PARAMETER num_ctx 32768
PARAMETER num_predict 4096
PARAMETER temperature 1.0
PARAMETER top_p 0.95
PARAMETER top_k 64
PARAMETER repeat_penalty 1.0
EOF

"$OLLAMA_BIN" create gemma4-agent -f "$MODELFILES_DIR/gemma4-agent"
"$OLLAMA_BIN" create gemma4-chat  -f "$MODELFILES_DIR/gemma4-chat"
log "gemma4-agent (256k ctx) 和 gemma4-chat (32k ctx) 已创建"

# 停止临时服务
if [[ "${STARTED_TEMP:-false}" == "true" ]]; then
  cleanup_temp_ollama
  info "临时 Ollama 服务已停止"
fi

# ── Step 6: 安装并配置 OpenCode ───────────────────────────────────────────────
step "6/6 安装 OpenCode"

if command -v opencode &>/dev/null; then
  log "OpenCode 已安装，更新中..."
  npm update -g opencode-ai 2>/dev/null || true
else
  npm install -g opencode-ai
  log "OpenCode 安装完成"
fi

mkdir -p "$(dirname "$OPENCODE_CONFIG")"
[[ -f "$OPENCODE_CONFIG" ]] && cp "$OPENCODE_CONFIG" "$OPENCODE_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"

cat > "$OPENCODE_CONFIG" << 'EOF'
{
  "$schema": "https://opencode.ai/config.json",
  "model": "ollama/gemma4-agent",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Local",
      "options": {
        "baseURL": "http://localhost:11434/v1"
      },
      "models": {
        "gemma4-agent": {
          "name": "gemma4-agent",
          "contextLength": 262144,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          }
        },
        "gemma4-chat": {
          "name": "gemma4-chat",
          "contextLength": 32768,
          "attachment": true,
          "modalities": {
            "input": ["text", "image"],
            "output": ["text"]
          }
        }
      }
    }
  },
  "autoshare": false,
  "permission": {
    "websearch": "allow",
    "webfetch": "allow"
  },
  "mcp": {
    "context7": {
      "type": "remote",
      "url": "https://mcp.context7.com/mcp",
      "enabled": true
    },
    "gh_grep": {
      "type": "remote",
      "url": "https://mcp.grep.app",
      "enabled": true
    }
  }
}
EOF

log "OpenCode 配置完成，默认模型: gemma4-agent"

# ── 完成 ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}━━━ 安装完成！━━━${NC}"
echo ""
echo -e "下一步，使用 ${CYAN}ollama.sh${NC} 来启动/关闭服务和切换模型："
echo ""
echo -e "  ${CYAN}./ollama.sh start${NC}   # 启动 Ollama + 预加载模型"
echo -e "  ${CYAN}./ollama.sh stop${NC}    # 关闭 Ollama"
echo -e "  ${CYAN}./ollama.sh switch${NC}  # 切换模型"
echo ""
