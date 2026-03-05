#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
zig build test -Dtest-filter='stream: claude VT replay fuzz safety'
