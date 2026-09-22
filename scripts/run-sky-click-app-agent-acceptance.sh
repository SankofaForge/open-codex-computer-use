#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "${repo_root}"

if [[ "${OPEN_COMPUTER_USE_ALLOW_ACTIVE_GUI:-0}" != "1" ]]; then
  echo "Refusing live GUI acceptance in the current desktop session. Set OPEN_COMPUTER_USE_ALLOW_ACTIVE_GUI=1 only in a dedicated GUI test session." >&2
  exit 2
fi

app_agent_binary="${repo_root}/dist/Open Computer Use (Dev).app/Contents/MacOS/OpenComputerUse"
list_app_agent_pids() {
  ps -axo pid=,command= | while read -r pid command; do
    case "${command}" in
      "${app_agent_binary} __open-computer-use-app-agent"*)
        printf '%s\n' "${pid}"
        ;;
    esac
  done
}

existing_app_agent_pids="$(list_app_agent_pids)"
cleanup_app_agent() {
  current_app_agent_pids="$(list_app_agent_pids)"
  for pid in ${current_app_agent_pids}; do
    case " ${existing_app_agent_pids} " in
      *" ${pid} "*)
        ;;
      *)
        kill -TERM "${pid}" 2>/dev/null || true
        ;;
    esac
  done
}
trap cleanup_app_agent EXIT INT TERM

if [[ "${OPEN_COMPUTER_USE_SKIP_APP_BUILD:-0}" != "1" ]]; then
  swift build --product OpenComputerUse --product OpenComputerUseFixture
  ./scripts/build-open-computer-use-app.sh debug
else
  [[ -x ".build/debug/OpenComputerUse" ]] || {
    echo "OpenComputerUse debug executable is missing; run without OPEN_COMPUTER_USE_SKIP_APP_BUILD=1 first." >&2
    exit 1
  }
  [[ -d "dist/Open Computer Use (Dev).app" ]] || {
    echo "Open Computer Use (Dev).app is missing; run without OPEN_COMPUTER_USE_SKIP_APP_BUILD=1 first." >&2
    exit 1
  }
fi

OPEN_COMPUTER_USE_RUN_SKY_CLICK_APP_AGENT_TEST=1 \
  swift test --filter SkyClickAppAgentLiveTests
