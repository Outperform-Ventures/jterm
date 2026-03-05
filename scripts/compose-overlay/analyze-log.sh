#!/usr/bin/env bash
set -euo pipefail

LOG_PATH="${1:-/tmp/jterm-compose-events.log}"
if [[ ! -f "$LOG_PATH" ]]; then
  echo "error: log file not found: $LOG_PATH" >&2
  exit 1
fi

status_ok=true

pass() { echo "PASS  $1"; }
fail() { echo "FAIL  $1"; status_ok=false; }
info() { echo "INFO  $1"; }

# Geometry drift + resize/frame tracking checks (tests 2 + 8)
geom_count=$(rg -c 'tracker geom reason=' "$LOG_PATH" || true)
if [[ "$geom_count" -eq 0 ]]; then
  fail "No tracker geometry telemetry found (tests 2/8 blocked)."
else
  max_drift=$(rg 'tracker geom reason=' "$LOG_PATH" \
    | sed -E 's/.*drift_x=([-0-9.]+).*drift_y=([-0-9.]+).*/\1 \2/' \
    | awk '{dx=$1; dy=$2; if (dx<0) dx=-dx; if (dy<0) dy=-dy; d=(dx>dy)?dx:dy; if (d>m) m=d} END {if (NR==0) print "nan"; else printf "%.4f", m}')
  changed_count=$(rg -c 'tracker geom reason=.*changed=true' "$LOG_PATH" 2>/dev/null || true)
  changed_count=${changed_count:-0}
  info "geometry samples=$geom_count changed_frames=$changed_count max_abs_drift_px=$max_drift"
  awk_check=$(awk -v v="$max_drift" 'BEGIN { if (v+0 <= 1.0) print "ok"; else print "bad"; }')
  if [[ "$awk_check" == "ok" ]]; then
    pass "Pixel drift <= 1px"
  else
    fail "Pixel drift > 1px"
  fi
  if [[ "$changed_count" -gt 0 ]]; then
    pass "Tracker recorded frame updates"
  else
    fail "No frame updates observed (resize/reflow not exercised)"
  fi
fi

# Latency envelope (test 10)
latency_tmp=$(mktemp)
trap 'rm -f "$latency_tmp"' EXIT
rg 'latency sample_ms=' "$LOG_PATH" \
  | sed -E 's/.*latency sample_ms=([0-9.]+).*/\1/' > "$latency_tmp" || true
latency_count=$(wc -l < "$latency_tmp" | tr -d ' ')
if [[ "$latency_count" -eq 0 ]]; then
  fail "No latency samples found (test 10 not run)."
else
  sort -n "$latency_tmp" -o "$latency_tmp"
  idx95=$(( (95 * (latency_count - 1)) / 100 + 1 ))
  idx99=$(( (99 * (latency_count - 1)) / 100 + 1 ))
  p95=$(sed -n "${idx95}p" "$latency_tmp")
  p99=$(sed -n "${idx99}p" "$latency_tmp")
  info "latency samples=$latency_count p95_ms=$p95 p99_ms=$p99"
  p95_ok=$(awk -v v="$p95" 'BEGIN { if (v+0 < 16.0) print "ok"; else print "bad"; }')
  p99_ok=$(awk -v v="$p99" 'BEGIN { if (v+0 < 25.0) print "ok"; else print "bad"; }')
  if [[ "$p95_ok" == "ok" && "$p99_ok" == "ok" ]]; then
    pass "Latency envelope met (p95 < 16ms, p99 < 25ms)"
  else
    fail "Latency envelope exceeded"
  fi
fi

# Selection + clipboard markers (test 5)
if rg -q 'clipboard action=copy' "$LOG_PATH" \
  && rg -q 'clipboard action=cut' "$LOG_PATH" \
  && rg -q 'clipboard action=paste' "$LOG_PATH" \
  && rg -q 'selection location=.*length=[1-9]' "$LOG_PATH"; then
  pass "Selection and clipboard events observed"
else
  fail "Missing selection/clipboard evidence"
fi

# Focus/blur + recovery checks (tests 7 + 11)
blur_activate_tmp=$(mktemp)
trap 'rm -f "$latency_tmp" "$blur_activate_tmp"' EXIT
awk '
  /finish reason=blur/ {
    ts = $0;
    sub(/^.*t_ms:/, "", ts);
    sub(/].*$/, "", ts);
    blur_ms = ts + 0;
  }
  /tracker activate reason=start-focus-gained/ {
    ts = $0;
    sub(/^.*t_ms:/, "", ts);
    sub(/].*$/, "", ts);
    if (blur_ms > 0) {
      delta = (ts + 0) - blur_ms;
      print delta;
      blur_ms = 0;
    }
  }
' "$LOG_PATH" > "$blur_activate_tmp"

pair_count=$(wc -l < "$blur_activate_tmp" | tr -d ' ')
if [[ "$pair_count" -eq 0 ]]; then
  fail "No blur->activate recovery pairs found"
else
  min_delta=$(sort -n "$blur_activate_tmp" | head -n 1)
  info "blur->activate pairs=$pair_count fastest_ms=$min_delta"
  if awk -v v="$min_delta" 'BEGIN { exit !(v+0 <= 100); }'; then
    pass "Recovery <= 100ms observed"
  else
    fail "No recovery <= 100ms observed"
  fi
fi

# Commit path sanity (test 3)
commit_count=$(rg -c 'commit key context=claude key=Enter sent' "$LOG_PATH" || true)
if [[ "$commit_count" -gt 0 ]]; then
  pass "Commit key events observed"
else
  fail "No commit key events observed"
fi

if [[ "$status_ok" == true ]]; then
  echo "SUMMARY: PASS"
  exit 0
else
  echo "SUMMARY: FAIL"
  exit 1
fi
