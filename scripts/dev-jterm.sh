#!/usr/bin/env bash
set -euo pipefail

# Launch an isolated dev jterm instance so remote-control testing does not
# interfere with any existing jterm process using the default socket/config.
#
# Usage:
#   scripts/dev-jterm.sh [options] [-- <extra jterm args>]
#
# Options:
#   --binary <path>      Path to jterm binary
#   --socket <path>      Unix socket path (without unix: prefix)
#   --config <path>      Config file to write/use for this dev session
#   --log <path>         Log path (background mode)
#   --timeout <seconds>  Startup timeout for readiness check
#   --foreground         Run attached to current shell instead of background
#   --no-ready-check     Skip waiting for socket/ls readiness
#   -h, --help           Show this help text
#
# Environment variable defaults:
#   JTERM_DEV_BINARY
#   JTERM_DEV_SOCKET_PATH
#   JTERM_DEV_CONFIG_PATH
#   JTERM_DEV_LOG
#   JTERM_DEV_TIMEOUT

usage() {
  cat <<'EOF'
Usage: scripts/dev-jterm.sh [options] [-- <extra jterm args>]

Options:
  --binary <path>      Path to jterm binary
  --socket <path>      Unix socket path (without unix: prefix)
  --config <path>      Config file to write/use for this dev session
  --log <path>         Log path (background mode)
  --timeout <seconds>  Startup timeout for readiness check
  --foreground         Run attached to current shell instead of background
  --no-ready-check     Skip waiting for socket/ls readiness
  -h, --help           Show help
EOF
}

if [[ -n "${JTERM_DEV_BINARY:-}" ]]; then
  BINARY="${JTERM_DEV_BINARY}"
elif [[ -x "zig-out/jterm.app/Contents/MacOS/jterm" ]]; then
  BINARY="zig-out/jterm.app/Contents/MacOS/jterm"
elif [[ -x "zig-out/bin/jterm" ]]; then
  BINARY="zig-out/bin/jterm"
else
  BINARY="zig-out/bin/jterm"
fi

SOCKET_PATH="${JTERM_DEV_SOCKET_PATH:-/tmp/jterm-dev-${USER:-user}-$$.sock}"
CONFIG_PATH="${JTERM_DEV_CONFIG_PATH:-/tmp/jterm-dev-${USER:-user}-$$.ghostty}"
LOG_PATH="${JTERM_DEV_LOG:-/tmp/jterm-dev-${USER:-user}-$$.log}"
TIMEOUT_SECS="${JTERM_DEV_TIMEOUT:-20}"
FOREGROUND=0
READY_CHECK=1
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --binary)
      if [[ $# -lt 2 ]]; then
        echo "dev-jterm: --binary requires a value" >&2
        exit 1
      fi
      BINARY="$2"
      shift 2
      ;;
    --socket)
      if [[ $# -lt 2 ]]; then
        echo "dev-jterm: --socket requires a value" >&2
        exit 1
      fi
      SOCKET_PATH="$2"
      shift 2
      ;;
    --config)
      if [[ $# -lt 2 ]]; then
        echo "dev-jterm: --config requires a value" >&2
        exit 1
      fi
      CONFIG_PATH="$2"
      shift 2
      ;;
    --log)
      if [[ $# -lt 2 ]]; then
        echo "dev-jterm: --log requires a value" >&2
        exit 1
      fi
      LOG_PATH="$2"
      shift 2
      ;;
    --timeout)
      if [[ $# -lt 2 ]]; then
        echo "dev-jterm: --timeout requires a value" >&2
        exit 1
      fi
      TIMEOUT_SECS="$2"
      shift 2
      ;;
    --foreground)
      FOREGROUND=1
      shift
      ;;
    --no-ready-check)
      READY_CHECK=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      echo "dev-jterm: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ ! -x "${BINARY}" ]]; then
  echo "dev-jterm: binary not found or not executable: ${BINARY}" >&2
  exit 1
fi

if ! [[ "${TIMEOUT_SECS}" =~ ^[0-9]+$ ]] || [[ "${TIMEOUT_SECS}" -le 0 ]]; then
  echo "dev-jterm: --timeout must be a positive integer" >&2
  exit 1
fi

mkdir -p "$(dirname "${CONFIG_PATH}")"
mkdir -p "$(dirname "${LOG_PATH}")"

cat >"${CONFIG_PATH}" <<'EOF'
allow-remote-control = true
remote-control-default-no-response = true
EOF

TARGET="unix:${SOCKET_PATH}"
CMD=(
  "${BINARY}"
  "--config-default-files=false"
  "--config-file=${CONFIG_PATH}"
  "--allow-remote-control=true"
)
if [[ "${#EXTRA_ARGS[@]}" -gt 0 ]]; then
  CMD+=("${EXTRA_ARGS[@]}")
fi

wait_for_ready() {
  local app_pid="$1"
  local i
  local max_iters=$((TIMEOUT_SECS * 10))

  for ((i = 1; i <= max_iters; i += 1)); do
    if ! kill -0 "${app_pid}" 2>/dev/null; then
      echo "dev-jterm: process exited during startup" >&2
      if [[ -f "${LOG_PATH}" ]]; then
        echo "dev-jterm: startup log (${LOG_PATH}):" >&2
        sed -n '1,200p' "${LOG_PATH}" >&2 || true
      fi
      return 1
    fi

    if [[ -S "${SOCKET_PATH}" ]] && "${BINARY}" @ "--to=${TARGET}" ls >/dev/null 2>&1; then
      return 0
    fi

    sleep 0.1
  done

  echo "dev-jterm: timeout waiting for dev endpoint readiness (${TARGET})" >&2
  if [[ -f "${LOG_PATH}" ]]; then
    echo "dev-jterm: startup log (${LOG_PATH}):" >&2
    sed -n '1,200p' "${LOG_PATH}" >&2 || true
  fi
  return 1
}

if [[ "${FOREGROUND}" == "1" ]]; then
  echo "dev-jterm: launching isolated instance in foreground"
  echo "dev-jterm: target=${TARGET}"
  echo "dev-jterm: config=${CONFIG_PATH}"
  exec env JTERM_LISTEN_ON="${TARGET}" "${CMD[@]}"
fi

rm -f "${SOCKET_PATH}"
rm -f "${LOG_PATH}"

echo "dev-jterm: launching isolated instance in background"
echo "dev-jterm: target=${TARGET}"
echo "dev-jterm: config=${CONFIG_PATH}"
echo "dev-jterm: log=${LOG_PATH}"
env JTERM_LISTEN_ON="${TARGET}" "${CMD[@]}" >"${LOG_PATH}" 2>&1 &
APP_PID="$!"

if [[ "${READY_CHECK}" == "1" ]]; then
  wait_for_ready "${APP_PID}"
fi

echo "dev-jterm: pid=${APP_PID}"
echo "dev-jterm: remote-control example:"
echo "  ${BINARY} @ --to=${TARGET} ls"
echo "dev-jterm: stop with:"
echo "  kill ${APP_PID}"
