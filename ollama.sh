#!/usr/bin/env bash
# =============================================================================
# ollama.sh — 日常使用的唯一入口
#
# 用法:
#   ./ollama.sh start    启动 Ollama + 预热模型 + 打开 OpenCode
#   ./ollama.sh stop     关闭 Ollama（释放内存）
#   ./ollama.sh status   查看当前状态
#   ./ollama.sh switch   交互式切换模型
#   ./ollama.sh switch qwen-coder   直接切换到指定模型
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

MODELFILES_DIR="$HOME/.ollama_modelfiles"
OPENCODE_CONFIG="$HOME/.config/opencode/opencode.json"
OLLAMA_PID_FILE="$HOME/.ollama.pid"
OLLAMA_LOG_FILE="$HOME/.ollama.log"
if [[ -n "${OLLAMA_BIN:-}" ]]; then
  :
elif [[ -x "/Applications/Ollama.app/Contents/Resources/ollama" ]]; then
  OLLAMA_BIN="/Applications/Ollama.app/Contents/Resources/ollama"
else
  OLLAMA_BIN="ollama"
fi
MODEL_CATALOG=$(cat <<'EOF'
gemma4-moe|gemma4:26b|18GB|65536|Gemma 4 26B MoE · 默认 · 视觉支持
gemma4-dense|gemma4:31b-instruct-q4_K_M|20GB|65536|Gemma 4 31B Dense · 最高质量
gemma4-edge|gemma4:e4b|4GB|32768|Gemma 4 E4B · 极快 · 轻量任务
qwen-coder|qwen2.5-coder:32b|20GB|65536|Qwen2.5-Coder 32B · 最佳编码
qwen3|qwen3:32b|20GB|131072|Qwen3 32B · 最佳中文 · /think 模式
qwen3-fast|qwen3-coder-next|6GB|65536|Qwen3-Coder-Next MoE · 极快
deepseek-r1|deepseek-r1:32b|20GB|65536|DeepSeek R1 32B · 推理/调试
deepseek-r1-70b|deepseek-r1:70b|45GB|65536|DeepSeek R1 70B · 最强推理
llama3.3|llama3.3:70b|40GB|65536|Llama 3.3 70B · GPT-4 级
phi4|phi4:14b|9GB|16384|Phi-4 14B · STEM/数学
EOF
)

# ═══════════════════════════════════════════════════════════════════════════════
# 模型目录 — 添加新模型只需在这里加一行
# 格式: alias|base_model|大小|context_tokens|描述
# ═══════════════════════════════════════════════════════════════════════════════

# ═══════════════════════════════════════════════════════════════════════════════
# 辅助函数
# ═══════════════════════════════════════════════════════════════════════════════

is_running() {
  curl -s http://localhost:11434/api/version &>/dev/null
}

ollama_cmd() {
  "$OLLAMA_BIN" "$@"
}

model_installed_exact() {
  local model="$1"
  if [[ "$model" == *:* ]]; then
    ollama_cmd list 2>/dev/null | awk 'NR == 1 && $1 == "NAME" {next} NF {print $1}' | grep -Fxq "$model"
  else
    ollama_cmd list 2>/dev/null | awk 'NR == 1 && $1 == "NAME" {next} NF {print $1}' | grep -E -x -q "${model}(:latest)?"
  fi
}

model_aliases() {
  printf '%s\n' "$MODEL_CATALOG" | cut -d'|' -f1 | sort
}

get_model_spec() {
  local alias="$1"
  printf '%s\n' "$MODEL_CATALOG" | awk -F'|' -v alias="$alias" '$1 == alias {print; found=1} END {exit found ? 0 : 1}'
}

get_current_model() {
  if [[ -f "$OPENCODE_CONFIG" ]]; then
    python3 -c "import json; d=json.load(open('$OPENCODE_CONFIG')); print(d.get('model',''))" 2>/dev/null
  else
    return 1
  fi
}

start_server() {
  [[ -f "$HOME/.ollama_env" ]] && source "$HOME/.ollama_env"
  : "${OLLAMA_FLASH_ATTENTION:=1}"
  : "${OLLAMA_KV_CACHE_TYPE:=q8_0}"
  : "${GGML_METAL_TENSOR_DISABLE:=1}"
  export OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE GGML_METAL_TENSOR_DISABLE
  nohup "$OLLAMA_BIN" serve > "$OLLAMA_LOG_FILE" 2>&1 &
  echo $! > "$OLLAMA_PID_FILE"
}

wait_for_server() {
  local attempt
  for attempt in $(seq 1 20); do
    if is_running; then
      return 0
    fi
    sleep 1
  done
  return 1
}

diagnose_start_failure() {
  [[ -f "$OLLAMA_LOG_FILE" ]] || return 1

  if grep -Fq 'failure during GPU discovery' "$OLLAMA_LOG_FILE" && grep -Fq 'failed to finish discovery before timeout' "$OLLAMA_LOG_FILE"; then
    cat <<EOF
GPU 探测超时，Ollama 回退到了 CPU，随后当前大模型加载失败。
建议先修复本机 Ollama 运行时，再重试当前模型：
  brew reinstall ollama mlx-c
  ./ollama.sh stop
  ./ollama.sh start
若仍失败，请先切换到较小模型验证运行时：
  ./ollama.sh switch gemma4-edge
EOF
    return 0
  fi

  if grep -Fq 'llama runner terminated' "$OLLAMA_LOG_FILE"; then
    cat <<EOF
当前模型加载失败，Ollama runner 已异常退出。
请检查日志：cat ~/.ollama.log
EOF
    return 0
  fi

  return 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# start — 启动服务 + 预热 + 进入 OpenCode
# ═══════════════════════════════════════════════════════════════════════════════
cmd_start() {
  echo -e "\n${BOLD}${CYAN}━━━ 启动 Ollama ━━━${NC}\n"

  # 加载环境变量
  [[ -f "$HOME/.ollama_env" ]] && source "$HOME/.ollama_env"

  if is_running; then
    log "Ollama 已在运行"
  else
    info "启动 Ollama 服务（后台）..."
    start_server

    info "等待服务就绪..."
    wait_for_server || err "服务启动超时，查看日志: cat ~/.ollama.log"
    log "Ollama 服务已启动 (PID: $(cat "$OLLAMA_PID_FILE"))"
  fi

  # 显示当前配置的模型
  CURRENT_MODEL=""
  if CURRENT_MODEL=$(get_current_model); then
    :
  elif [[ -f "$OPENCODE_CONFIG" ]]; then
    warn "OpenCode 配置无法解析，跳过模型预热"
  else
    warn "OpenCode 配置不存在，请先运行 setup.sh"
  fi
  echo ""
  echo -e "当前模型: ${CYAN}${CURRENT_MODEL:-未设置}${NC}"

  # 预热模型（发一个空请求让模型加载进内存）
  MODEL_SHORT=""
  if [[ "$CURRENT_MODEL" == ollama/* ]]; then
    MODEL_SHORT="${CURRENT_MODEL#ollama/}"
  fi
  if [[ -n "$MODEL_SHORT" ]]; then
    if ! model_installed_exact "$MODEL_SHORT"; then
      warn "当前模型 ${MODEL_SHORT} 未安装，跳过预热"
    else
      info "预热模型 ${MODEL_SHORT}（首次加载需要几秒）..."
      if ollama_cmd run "$MODEL_SHORT" "" --nowordwrap >/dev/null 2>&1; then
        log "模型已加载到内存"
      else
        echo ""
        if diagnose_start_failure; then
          err "模型预热失败，服务未就绪。"
        fi
        err "模型预热失败，请手动检查: $OLLAMA_BIN run ${MODEL_SHORT}"
      fi
    fi
  else
    warn "当前未配置有效的 Ollama 模型，跳过预热"
  fi

  # 提示用户下一步
  echo ""
  echo -e "${BOLD}Ollama 已就绪。现在可以:${NC}"
  echo -e "  ${CYAN}cd ~/your-project && opencode${NC}   # 启动编码 agent"
  if [[ -n "$MODEL_SHORT" ]]; then
    echo -e "  ${CYAN}ollama run $MODEL_SHORT${NC}         # 直接终端对话"
  fi
  echo -e "  ${CYAN}./ollama.sh stop${NC}                # 关闭服务"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# stop — 关闭服务，释放内存
# ═══════════════════════════════════════════════════════════════════════════════
cmd_stop() {
  echo -e "\n${BOLD}${CYAN}━━━ 关闭 Ollama ━━━${NC}\n"

  if ! is_running; then
    warn "Ollama 服务未在运行"
    return
  fi

  # 先卸载所有模型（释放内存）
  info "卸载已加载的模型..."
  ollama_cmd ps 2>/dev/null | tail -n +2 | awk '{print $1}' | while read -r model; do
    [[ -n "$model" ]] && ollama_cmd stop "$model" 2>/dev/null && echo "  已卸载: $model" || true
  done

  # 停止服务进程
  if [[ -f "$OLLAMA_PID_FILE" ]]; then
    PID=$(cat "$OLLAMA_PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
      kill "$PID"
      rm -f "$OLLAMA_PID_FILE"
      log "Ollama 进程已终止 (PID: $PID)"
    else
      rm -f "$OLLAMA_PID_FILE"
      warn "PID 文件过期，尝试 pkill..."
      pkill -f "ollama serve" 2>/dev/null || true
    fi
  else
    # 没有 pid 文件时用 pkill
    pkill -f "ollama serve" 2>/dev/null && log "Ollama 进程已终止" || warn "未找到 ollama 进程"
  fi

  # 验证已停止
  sleep 1
  if is_running; then
    warn "服务仍在运行，强制终止..."
    pkill -9 -f "ollama serve" 2>/dev/null || true
    sleep 1
  fi

  if is_running; then
    warn "Ollama 服务仍在运行，请检查: cat ~/.ollama.log"
  else
    log "Ollama 已完全停止，内存已释放"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# status — 查看当前状态
# ═══════════════════════════════════════════════════════════════════════════════
cmd_status() {
  echo -e "\n${BOLD}${CYAN}━━━ 当前状态 ━━━${NC}\n"

  # 服务状态
  if is_running; then
    echo -e "服务状态:   ${GREEN}● 运行中${NC}"
    OLLAMA_VER=$(curl -s http://localhost:11434/api/version | python3 -c "import json,sys; print(json.load(sys.stdin).get('version','?'))" 2>/dev/null || echo "?")
    echo -e "Ollama 版本: $OLLAMA_VER"
  else
    echo -e "服务状态:   ${RED}● 未运行${NC}"
  fi

  # 当前 OpenCode 模型
  echo -e "OpenCode 模型: ${CYAN}$(get_current_model)${NC}"

  # 已加载的模型
  if is_running; then
    echo ""
    LOADED=$(ollama_cmd ps 2>/dev/null | tail -n +2)
    if [[ -n "$LOADED" ]]; then
      echo -e "${BOLD}已加载到内存的模型:${NC}"
      ollama_cmd ps 2>/dev/null
    else
      echo -e "已加载模型: ${YELLOW}无（模型未预热）${NC}"
    fi
  fi

  # 本地已下载的模型
  echo ""
  echo -e "${BOLD}本地已下载模型:${NC}"
  if command -v "$OLLAMA_BIN" &>/dev/null || [[ -x "$OLLAMA_BIN" ]]; then
    ollama_cmd list 2>/dev/null || echo "  (服务未运行，无法获取列表)"
  fi
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# switch — 切换模型（下载 + 注册 Modelfile + 更新 OpenCode 配置）
# ═══════════════════════════════════════════════════════════════════════════════
cmd_switch() {
  echo -e "\n${BOLD}${CYAN}━━━ 切换模型 ━━━${NC}\n"
  echo -e "当前模型: ${CYAN}$(get_current_model)${NC}\n"

  # 展示模型目录
  echo -e "${BOLD}可用模型:${NC}"
  echo ""
  printf "  %-16s %-8s %-10s  %s\n" "别名" "大小" "Context" "描述"
  echo "  ────────────────────────────────────────────────────────────────"

  while IFS='|' read -r alias base size ctx desc; do
    # 标记已安装
    if model_installed_exact "$base"; then
      STATUS="${GREEN}[已下载]${NC}"
    else
      STATUS="${YELLOW}[未下载]${NC}"
    fi
    printf "  ${CYAN}%-16s${NC} %-8s %-10s  %s %b\n" "$alias" "$size" "${ctx}t" "$desc" "$STATUS"
  done << EOF
$MODEL_CATALOG
EOF
  echo ""

  # 接收输入
  if [[ $# -gt 0 ]]; then
    CHOSEN="$1"
  else
    read -r -p "$(echo -e ${BLUE}[→]${NC}) 输入别名 (q 退出): " CHOSEN
    [[ "$CHOSEN" == "q" || -z "$CHOSEN" ]] && return 0
  fi

  # 验证
  if ! SPEC=$(get_model_spec "$CHOSEN"); then
    err "未知别名: $CHOSEN。请从上方列表选择。"
  fi

  IFS='|' read -r _ BASE_MODEL SIZE CTX DESC <<< "$SPEC"

  echo ""
  echo -e "切换到: ${BOLD}$CHOSEN${NC}  ($DESC)"
  echo -e "  基础模型: ${CYAN}$BASE_MODEL${NC}  |  大小: ${YELLOW}$SIZE${NC}  |  Context: ${CYAN}${CTX}t${NC}"
  echo ""

  # 确保服务在运行（下载和注册需要）
  if ! is_running; then
    info "需要启动 Ollama 服务来注册模型..."
    start_server
    wait_for_server || err "服务启动超时，查看日志: cat ~/.ollama.log"
    STOP_AFTER=true
  else
    STOP_AFTER=false
  fi

  # 下载（若未下载）
  if ! model_installed_exact "$BASE_MODEL"; then
    warn "模型 $BASE_MODEL 未下载 (~$SIZE)"
    read -r -p "$(echo -e ${YELLOW}[?]${NC}) 现在下载？[Y/n] " dl
    dl=${dl:-Y}
    if [[ "$dl" =~ ^[Yy]$ ]]; then
      info "下载中..."
      ollama_cmd pull "$BASE_MODEL"
      log "下载完成"
    else
      warn "已跳过下载，切换可能失败"
    fi
  else
    log "模型已在本地"
  fi

  # 创建 Modelfile
  mkdir -p "$MODELFILES_DIR"
  cat > "$MODELFILES_DIR/$CHOSEN" << EOF
FROM $BASE_MODEL
PARAMETER num_ctx $CTX
PARAMETER num_predict 8192
PARAMETER temperature 1.0
PARAMETER top_p 0.95
PARAMETER top_k 64
PARAMETER repeat_penalty 1.0
EOF

  info "注册模型 $CHOSEN 到 Ollama..."
  ollama_cmd create "$CHOSEN" -f "$MODELFILES_DIR/$CHOSEN"
  log "Ollama 模型 $CHOSEN 已注册"

  # 更新 OpenCode 配置
  if [[ -f "$OPENCODE_CONFIG" ]]; then
    python3 - << PYEOF
import json

path = "$OPENCODE_CONFIG"
alias = "$CHOSEN"
ctx = $CTX

with open(path) as f:
    cfg = json.load(f)

cfg["model"] = f"ollama/{alias}"
cfg.setdefault("provider", {}).setdefault("ollama", {}).setdefault("models", {})[alias] = {
    "name": alias,
    "contextLength": ctx
}

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
PYEOF
    log "OpenCode 默认模型已更新为: ollama/$CHOSEN"
  else
    warn "OpenCode 配置不存在，请先运行 setup.sh"
  fi

  # 模型特定提示
  echo ""
  case "$CHOSEN" in
    qwen3*)
      echo -e "${CYAN}提示: Qwen3 输入 /think 开启深度推理模式${NC}" ;;
    deepseek*)
      echo -e "${CYAN}提示: DeepSeek R1 会先输出 <think>...</think> 思维链，属正常现象，响应较慢${NC}" ;;
    llama3.3|deepseek-r1-70b)
      echo -e "${CYAN}提示: 70B 模型速度约 8-12 tok/s，适合复杂任务${NC}" ;;
  esac

  # 如果是本脚本临时启动的服务，停掉
  if [[ "${STOP_AFTER:-false}" == "true" ]]; then
    info "注册完成，停止临时服务..."
    pkill -f "ollama serve" 2>/dev/null || true
  fi

  echo ""
  log "切换完成！下次 ./ollama.sh start 将使用: $CHOSEN"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# 帮助
# ═══════════════════════════════════════════════════════════════════════════════
cmd_help() {
  echo ""
  echo -e "${BOLD}用法: ./ollama.sh <命令>${NC}"
  echo ""
  echo -e "  ${CYAN}start${NC}              启动 Ollama 服务 + 预热当前模型"
  echo -e "  ${CYAN}stop${NC}               关闭 Ollama，释放内存"
  echo -e "  ${CYAN}status${NC}             查看服务状态 + 已加载模型"
  echo -e "  ${CYAN}switch${NC}             交互式切换模型"
  echo -e "  ${CYAN}switch <别名>${NC}      直接切换到指定模型"
  echo ""
  echo -e "  可用模型别名: $(model_aliases | tr '\n' ' ')"
  echo ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# 入口
# ═══════════════════════════════════════════════════════════════════════════════
CMD="${1:-help}"
shift || true

case "$CMD" in
  start)  cmd_start "$@" ;;
  stop)   cmd_stop  "$@" ;;
  status) cmd_status "$@" ;;
  switch) cmd_switch "$@" ;;
  help|--help|-h) cmd_help ;;
  *) echo -e "${RED}[✗]${NC} 未知命令: $CMD"; cmd_help; exit 1 ;;
esac
