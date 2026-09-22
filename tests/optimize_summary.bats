#!/usr/bin/env bats

setup_file() {
	PROJECT_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
	export PROJECT_ROOT

	TEST_HOME="$(mktemp -d "${BATS_TEST_DIRNAME}/tmp-optimize-summary.XXXXXX")"
	export TEST_HOME
}

teardown_file() {
	if [[ "$TEST_HOME" == "${BATS_TEST_DIRNAME}/tmp-optimize-summary."* ]]; then
		rm -rf "$TEST_HOME"
	fi
}

@test "optimize dry-run summary reports outcomes instead of catalog size" {
	run env HOME="$TEST_HOME" MOLE_TEST_NO_AUTH=1 MOLE_ASSUME_VPN_ACTIVE=0 NO_COLOR=1 "$PROJECT_ROOT/mole" optimize --dry-run

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" =~ 将应用\ [0-9]+\ 项优化 ]] || { echo "$output"; return 1; }
	local applied_count="${BASH_REMATCH[0]#将应用 }"
	applied_count="${applied_count% 项优化}"
	[[ "$output" != *"将应用 23 项优化"* ]] || return 1
	[[ "$output" =~ [0-9]+\ 项未更改 ]] || return 1
	[[ "$output" =~ [0-9]+\ 项已跳过 ]] || return 1
	[[ "$output" != *"System fully optimized"* ]] || return 1

	run env HOME="$TEST_HOME" "$PROJECT_ROOT/mole" history --json
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"\"items\": $applied_count"* ]] || return 1
	[[ "$output" == *"\"failed_tasks\": 0"* ]] || return 1
}

@test "optimize failure reaches terminal exit and history contracts" {
	local config_dir="$TEST_HOME/.config/mole"
	local stub_dir="$TEST_HOME/bin"
	mkdir -p "$config_dir" "$stub_dir"

	run env PROJECT_ROOT="$PROJECT_ROOT" CONFIG_FILE="$config_dir/whitelist_optimize" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/optimize/catalog.sh"
for action in "${MOLE_OPTIMIZE_ACTIONS[@]}"; do
    [[ "$action" == "cache_refresh" ]] || printf '%s\n' "$action"
done > "$CONFIG_FILE"
EOF
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }

	cat > "$stub_dir/qlmanage" <<'EOF'
#!/bin/bash
exit 9
EOF
	chmod +x "$stub_dir/qlmanage"

	run env HOME="$TEST_HOME" MOLE_TEST_NO_AUTH=1 NO_COLOR=1 PATH="$stub_dir:$PATH" \
		"$PROJECT_ROOT/mole" optimize
	[[ "$status" -eq 1 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"1 项失败"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"无法重建 2 个 Finder 缓存服务"* ]] || return 1

	run env HOME="$TEST_HOME" "$PROJECT_ROOT/mole" history --json
	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	printf '%s\n' "$output" | python3 -c '
import json
import sys

data = json.load(sys.stdin)
session = data["sessions"][0]
assert session["command"] == "optimize"
assert session["items"] == 0
assert session["failed_tasks"] == 1
'
}

@test "optimize cleanup records startup and interrupt failures in history" {
	run env HOME="$TEST_HOME/cleanup-history" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/optimize/outcomes.sh"
eval "$(sed -n '/^cleanup_all() {/,/^}/p' "$PROJECT_ROOT/bin/optimize.sh")"

stop_inline_spinner() { :; }
stop_sudo_session() { :; }
cleanup_temp_files() { :; }
log_operation_session_end() { :; }
log_operation() { printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "$4"; }

optimize_outcomes_reset
cleanup_all 1
cleanup_all 130
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
	[[ "$output" == *"optimize|TASK_FAILED|session|exit status 1"* ]] || return 1
	[[ "$output" == *"optimize|TASK_FAILED|interrupted|exit status 130"* ]]
}

@test "optimize EXIT trap forwards the terminal status to cleanup" {
	run env PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'EOF'
set -euo pipefail
grep -qF "trap 'cleanup_all \"\$?\"' EXIT" "$PROJECT_ROOT/bin/optimize.sh"
EOF

	[[ "$status" -eq 0 ]] || { echo "$output"; return 1; }
}
