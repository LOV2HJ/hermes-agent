#!/usr/bin/env bash
# Configure Hermes Agent on Termux/Android for a local OpenAI-compatible LLM.
#
# Supported modes:
#   lmstudio   -> provider=lmstudio, default URL http://127.0.0.1:1234/v1
#   ollama     -> provider=custom,   default URL http://127.0.0.1:11434/v1
#   llamacpp   -> provider=custom,   default URL http://127.0.0.1:8080/v1
#
# Usage:
#   scripts/termux-local-llm.sh lmstudio qwen3.5-9b-deepseek-v4-flash
#   scripts/termux-local-llm.sh ollama qwen3.5:9b
#   scripts/termux-local-llm.sh llamacpp local-model http://127.0.0.1:8080/v1

set -euo pipefail

MODE="${1:-lmstudio}"
MODEL="${2:-}"
BASE_URL="${3:-}"
HERMES_HOME_DIR="${HERMES_HOME:-$HOME/.hermes}"
CONFIG_FILE="$HERMES_HOME_DIR/config.yaml"
ENV_FILE="$HERMES_HOME_DIR/.env"
PYTHON_BIN="${PYTHON_BIN:-}"

usage() {
  cat <<'EOF'
Usage:
  scripts/termux-local-llm.sh <lmstudio|ollama|llamacpp> <model> [base_url]

Examples:
  scripts/termux-local-llm.sh lmstudio qwen3.5-9b-deepseek-v4-flash
  scripts/termux-local-llm.sh ollama qwen3.5:9b
  scripts/termux-local-llm.sh llamacpp local-model http://127.0.0.1:8080/v1

Notes:
  - Run this after installing Hermes.
  - The local server must expose an OpenAI-compatible /v1 endpoint.
  - If your server runs on another device, pass its LAN URL as base_url.
EOF
}

if [[ "$MODE" == "-h" || "$MODE" == "--help" ]]; then
  usage
  exit 0
fi

if [[ -z "$MODEL" ]]; then
  echo "error: model is required." >&2
  usage >&2
  exit 2
fi

case "$MODE" in
  lmstudio)
    PROVIDER="lmstudio"
    BASE_URL="${BASE_URL:-http://127.0.0.1:1234/v1}"
    API_KEY_ENV="LM_API_KEY"
    BASE_URL_ENV="LM_BASE_URL"
    API_KEY_VALUE="${LM_API_KEY:-lm-studio}"
    ;;
  ollama)
    PROVIDER="custom"
    BASE_URL="${BASE_URL:-http://127.0.0.1:11434/v1}"
    API_KEY_ENV="OPENAI_API_KEY"
    BASE_URL_ENV="OPENAI_BASE_URL"
    API_KEY_VALUE="${OPENAI_API_KEY:-ollama}"
    ;;
  llamacpp|llama.cpp|llama-cpp)
    PROVIDER="custom"
    BASE_URL="${BASE_URL:-http://127.0.0.1:8080/v1}"
    API_KEY_ENV="OPENAI_API_KEY"
    BASE_URL_ENV="OPENAI_BASE_URL"
    API_KEY_VALUE="${OPENAI_API_KEY:-local}"
    ;;
  *)
    echo "error: unknown mode '$MODE'." >&2
    usage >&2
    exit 2
    ;;
esac

mkdir -p "$HERMES_HOME_DIR"
touch "$ENV_FILE"
chmod 600 "$ENV_FILE" 2>/dev/null || true

if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python)"
  elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  else
    echo "error: python or python3 is required." >&2
    exit 1
  fi
fi

upsert_env() {
  local key="$1"
  local value="$2"
  local tmp
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$ENV_FILE"; then
    sed "s|^${key}=.*|${key}=${value}|" "$ENV_FILE" > "$tmp"
  else
    cat "$ENV_FILE" > "$tmp"
    printf '%s=%s\n' "$key" "$value" >> "$tmp"
  fi
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE" 2>/dev/null || true
}

upsert_env "$API_KEY_ENV" "$API_KEY_VALUE"
upsert_env "$BASE_URL_ENV" "$BASE_URL"

"$PYTHON_BIN" - "$CONFIG_FILE" "$PROVIDER" "$MODEL" "$BASE_URL" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider, model, base_url = sys.argv[2], sys.argv[3], sys.argv[4]

try:
    import yaml
except Exception:
    yaml = None

if yaml and path.exists():
    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
elif yaml:
    data = {}
else:
    data = {}

model_cfg = data.get("model")
if not isinstance(model_cfg, dict):
    model_cfg = {}

model_cfg.update({
    "provider": provider,
    "default": model,
    "model": model,
    "base_url": base_url,
    "context_length": int(model_cfg.get("context_length") or 32768),
    "max_tokens": int(model_cfg.get("max_tokens") or 8192),
})
if provider == "custom":
    model_cfg.setdefault("api_mode", "chat_completions")

data["model"] = model_cfg
data.setdefault("terminal", {})["backend"] = data.get("terminal", {}).get("backend") or "local"
data.setdefault("agent", {})["api_max_retries"] = int(data.get("agent", {}).get("api_max_retries") or 1)
data["agent"]["gateway_timeout"] = int(data["agent"].get("gateway_timeout") or 0)
data["agent"]["gateway_timeout_warning"] = int(data["agent"].get("gateway_timeout_warning") or 0)

for key in ("vision", "web_extract", "compression", "skills_hub", "curator"):
    aux = data.setdefault("auxiliary", {}).setdefault(key, {})
    if isinstance(aux, dict):
      aux.setdefault("provider", provider)
      aux.setdefault("model", model)
      aux.setdefault("base_url", base_url)
      aux.setdefault("timeout", 900)

path.parent.mkdir(parents=True, exist_ok=True)
if yaml:
    path.write_text(yaml.safe_dump(data, allow_unicode=True, sort_keys=False), encoding="utf-8")
else:
    # Minimal fallback when PyYAML is unavailable. This is enough for a fresh
    # Termux install; later Hermes config writes will normalize the file.
    path.write_text(
        "model:\n"
        f"  provider: {provider}\n"
        f"  default: {model}\n"
        f"  model: {model}\n"
        f"  base_url: {base_url}\n"
        "  context_length: 32768\n"
        "  max_tokens: 8192\n"
        "terminal:\n"
        "  backend: local\n"
        "agent:\n"
        "  api_max_retries: 1\n"
        "  gateway_timeout: 0\n"
        "  gateway_timeout_warning: 0\n",
        encoding="utf-8",
    )
PY

cat <<EOF
Configured Hermes for local LLM on Termux.

Provider: $PROVIDER
Model:    $MODEL
Base URL: $BASE_URL

Files updated:
  $CONFIG_FILE
  $ENV_FILE

Next:
  hermes doctor
  hermes
EOF
