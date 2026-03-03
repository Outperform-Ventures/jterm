#!/usr/bin/env bash
set -euo pipefail

# End-to-end smoke test for jterm remote control.
#
# Usage:
#   scripts/e2e-remote.sh
#
# Optional environment variables:
#   JTERM_BINARY       Path to jterm binary (default: zig-out/bin/jterm)
#   JTERM_SOCKET_PATH  Unix socket path (default: /tmp/jterm.sock)
#   JTERM_E2E_TIMEOUT  Seconds to wait for startup/socket (default: 20)
#   JTERM_E2E_LOG      Log file for app stdout/stderr (default: /tmp/jterm-e2e.log)
#   JTERM_E2E_KEEP_APP Keep app running after test if set to 1 (default: 0)

if [[ -n "${JTERM_BINARY:-}" ]]; then
  BINARY="${JTERM_BINARY}"
elif [[ -x "zig-out/jterm.app/Contents/MacOS/jterm" ]]; then
  # On macOS, prefer the native app binary built from libghostty.
  BINARY="zig-out/jterm.app/Contents/MacOS/jterm"
elif [[ -x "zig-out/bin/jterm" ]]; then
  BINARY="zig-out/bin/jterm"
else
  BINARY="zig-out/bin/jterm"
fi
SOCKET_PATH="${JTERM_SOCKET_PATH:-/tmp/jterm.sock}"
TIMEOUT_SECS="${JTERM_E2E_TIMEOUT:-20}"
APP_LOG="${JTERM_E2E_LOG:-/tmp/jterm-e2e.log}"
KEEP_APP="${JTERM_E2E_KEEP_APP:-0}"
TARGET="unix:${SOCKET_PATH}"

APP_PID=""

cleanup() {
  if [[ "${KEEP_APP}" == "1" ]]; then
    return
  fi

  if [[ -n "${APP_PID}" ]] && kill -0 "${APP_PID}" 2>/dev/null; then
    kill "${APP_PID}" >/dev/null 2>&1 || true
    wait "${APP_PID}" >/dev/null 2>&1 || true
  fi
}

on_error() {
  local line="$1"
  echo "e2e-remote: failed at line ${line}" >&2
  if [[ -f "${APP_LOG}" ]]; then
    echo "e2e-remote: app log (${APP_LOG}):" >&2
    sed -n '1,200p' "${APP_LOG}" >&2 || true
  fi
}

trap cleanup EXIT
trap 'on_error $LINENO' ERR

if [[ ! -x "${BINARY}" ]]; then
  echo "e2e-remote: binary not found or not executable: ${BINARY}" >&2
  exit 1
fi

rm -f "${SOCKET_PATH}"
rm -f "${APP_LOG}"

echo "e2e-remote: starting app (${BINARY})"
JTERM_LISTEN_ON="${TARGET}" "${BINARY}" --allow-remote-control=true >"${APP_LOG}" 2>&1 &
APP_PID="$!"

wait_for_socket_and_ready() {
  local i
  for ((i = 1; i <= TIMEOUT_SECS; i += 1)); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
      echo "e2e-remote: app exited during startup" >&2
      return 1
    fi

    if [[ -S "${SOCKET_PATH}" ]]; then
      if run_remote_raw ls >/dev/null 2>&1; then
        return 0
      fi
    fi

    sleep 1
  done

  echo "e2e-remote: timeout waiting for socket readiness (${SOCKET_PATH})" >&2
  return 1
}

wait_for_surface_ready() {
  local i
  local output
  for ((i = 1; i <= TIMEOUT_SECS; i += 1)); do
    if ! kill -0 "${APP_PID}" 2>/dev/null; then
      echo "e2e-remote: app exited before first surface initialized" >&2
      return 1
    fi

    output="$(run_remote_raw ls 2>/dev/null || true)"
    if grep -q '"ok":true' <<<"${output}" && grep -q '"id":' <<<"${output}"; then
      return 0
    fi

    if grep -q 'OpenGL version is too old' "${APP_LOG}" 2>/dev/null; then
      echo "e2e-remote: renderer cannot initialize a surface (OpenGL too old)." >&2
      echo "e2e-remote: rebuild with Metal (requires full Xcode, not just CLT)." >&2
      return 1
    fi

    sleep 1
  done

  echo "e2e-remote: timeout waiting for first surface to become ready" >&2
  return 1
}

run_remote_raw() {
  "${BINARY}" @ --to="${TARGET}" "$@"
}

run_remote_ok() {
  local output
  output="$(run_remote_raw "$@")"

  if ! grep -q '"ok":true' <<<"${output}"; then
    echo "e2e-remote: command failed: $*" >&2
    echo "e2e-remote: response: ${output}" >&2
    return 1
  fi

  echo "${output}"
}

wait_for_socket_and_ready
wait_for_surface_ready

echo "e2e-remote: socket ready at ${SOCKET_PATH}"
echo "e2e-remote: running remote command suite"

run_remote_ok ls >/dev/null
run_remote_ok new-window >/dev/null
run_remote_ok set-window-title "jterm-e2e-title" >/dev/null
run_remote_ok send-text "echo jterm-e2e" >/dev/null
run_remote_ok action clear_screen >/dev/null
run_remote_ok ls >/dev/null

echo "e2e-remote: PASS"
if [[ "${KEEP_APP}" == "1" ]]; then
  echo "e2e-remote: app still running with pid ${APP_PID}"
fi
