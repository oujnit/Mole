#!/bin/bash
# Optimization Tasks

set -euo pipefail

if [[ -n "${MOLE_OPTIMIZE_TASKS_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_OPTIMIZE_TASKS_LOADED=1

_MOLE_OPTIMIZE_TASKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly _MOLE_OPTIMIZE_TASKS_DIR
source "$_MOLE_OPTIMIZE_TASKS_DIR/catalog.sh"
source "$_MOLE_OPTIMIZE_TASKS_DIR/outcomes.sh"

# Config constants (override via env).
readonly MOLE_TM_THIN_TIMEOUT=180
readonly MOLE_TM_THIN_VALUE=9999999999
readonly MOLE_SQLITE_MAX_SIZE=104857600 # 100MB

# Dry-run aware output.
opt_msg() {
    local message="$1"
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} $message"
    else
        echo -e "  ${GREEN}${ICON_SUCCESS}${NC} $message"
    fi
}

opt_numeric_kb() {
    local size_kb="${1:-0}"
    [[ "$size_kb" =~ ^[0-9]+$ ]] && echo "$size_kb" || echo "0"
}

# Whether the current optimize run can use sudo without re-prompting.
# Set by bin/optimize.sh after the upfront ensure_sudo_session call.
# Test-mode env vars hard-deny so ad-hoc task calls under MOLE_TEST_NO_AUTH=1
# (e.g. ./scripts/test.sh, manual repro) cannot reach a real sudo invocation
# even when this helper is invoked outside the optimize entrypoint.
optimize_sudo_available() {
    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        return 1
    fi
    [[ "${MOLE_OPTIMIZE_SUDO_AVAILABLE:-true}" == "true" ]]
}

opt_existing_path_size_kb() {
    local path="$1"
    [[ -e "$path" ]] || {
        echo "0"
        return 0
    }

    local size_kb=0
    local size_rc=0
    size_kb=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
    [[ $size_rc -eq 124 || $size_rc -ge 128 ]] && return "$size_rc"
    [[ $size_rc -eq 0 ]] || size_kb=0
    opt_numeric_kb "$size_kb"
}

opt_existing_file_size_kb_strict() {
    local path="$1"
    local bytes=""
    bytes=$($STAT_BSD -f%z "$path" 2> /dev/null) || return 1
    [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
    echo "$(((bytes + 1023) / 1024))"
}

run_launchctl_unload() {
    local plist_file="$1"
    local need_sudo="${2:-false}"

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        return 0
    fi

    if [[ "$need_sudo" == "true" ]]; then
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
            return 0
        fi
        if ! optimize_sudo_available; then
            return 0
        fi
        local unload_rc=0
        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" sudo launchctl \
            unload "$plist_file" 2> /dev/null || unload_rc=$?
    else
        local unload_rc=0
        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" launchctl \
            unload "$plist_file" 2> /dev/null || unload_rc=$?
    fi
    [[ $unload_rc -eq 124 || $unload_rc -ge 128 ]] && return "$unload_rc"
    return 0
}

needs_permissions_repair() {
    local owner
    owner=$($STAT_BSD -f %Su "$HOME" 2> /dev/null || echo "")
    if [[ -n "$owner" && "$owner" != "$USER" ]]; then
        return 0
    fi

    local -a paths=(
        "$HOME"
        "$HOME/Library"
        "$HOME/Library/Preferences"
    )
    local path
    for path in "${paths[@]}"; do
        if [[ -e "$path" && ! -w "$path" ]]; then
            return 0
        fi
    done

    return 1
}

is_ac_power() {
    pmset -g batt 2> /dev/null | grep -q "AC Power"
}

# Return 0 when a VPN is active, 1 when probes completed without finding one,
# and 2 when the VPN state could not be determined safely.
has_active_vpn_interface() {
    case "${MOLE_ASSUME_VPN_ACTIVE:-}" in
        1 | true | TRUE | yes | YES)
            return 0
            ;;
        0 | false | FALSE | no | NO)
            return 1
            ;;
    esac

    # macOS creates utun* interfaces for many non-VPN features (iCloud
    # Private Relay, Continuity, Handoff, AirDrop, Apple Watch sync, Personal
    # Hotspot). Bare interface presence therefore over-reports active VPNs and
    # caused the Network Stack Refresh skip in #959. Use two narrower signals:
    #
    #   1. scutil --nc list flags Connected for system-managed VPN connections
    #      (L2TP, IPsec, IKEv2, Cisco IPSec).
    #   2. The default route's interface is utun* when a full-tunnel third-party
    #      VPN (WireGuard, OpenVPN, Tunnelblick, etc.) is routing all traffic.
    #
    # Split-tunnel third-party VPNs that do not own the default route will not
    # be detected; route flushing may briefly disrupt their explicit routes,
    # which the VPN client re-establishes on its next reconcile.
    if ! command -v scutil > /dev/null 2>&1; then
        return 2
    fi
    local scutil_output=""
    local scutil_status=0
    scutil_output=$(LC_ALL=C run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" scutil --nc list 2> /dev/null) || scutil_status=$?
    if [[ $scutil_status -ne 0 ]]; then
        return 2
    fi
    if echo "$scutil_output" | grep -Eq '^\* \(Connected\)'; then
        return 0
    fi

    if ! command -v route > /dev/null 2>&1; then
        return 2
    fi
    local route_output=""
    local route_status=0
    route_output=$(LC_ALL=C run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" route -n get default 2> /dev/null) || route_status=$?
    if [[ $route_status -ne 0 ]]; then
        return 2
    fi
    local default_iface
    default_iface=$(printf '%s\n' "$route_output" |
        awk -F': ' '$1 ~ /^[[:space:]]*interface$/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
    if [[ "$default_iface" =~ ^utun[0-9]+$ ]]; then
        return 0
    fi

    return 1
}

flush_dns_cache() {
    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        MOLE_DNS_FLUSHED=1
        return 0
    fi

    if ! optimize_sudo_available; then
        return 1
    fi

    if sudo dscacheutil -flushcache 2> /dev/null && sudo killall -HUP mDNSResponder 2> /dev/null; then
        MOLE_DNS_FLUSHED=1
        return 0
    fi
    return 1
}

# Basic system maintenance.
opt_system_maintenance() {
    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]] && ! optimize_sudo_available; then
        opt_msg "DNS 与 Spotlight 检查已跳过（需要管理员权限）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        return 0
    fi

    local dns_flushed="false"
    if flush_dns_cache; then
        opt_msg "DNS 缓存已刷新"
        dns_flushed="true"
    fi

    local spotlight_status=""
    local spotlight_failed=0
    if ! spotlight_status=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" mdutil -s / 2> /dev/null); then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法验证 Spotlight 索引"
        spotlight_failed=1
    elif echo "$spotlight_status" | grep -qi "Indexing disabled"; then
        echo -e "  ${GRAY}${ICON_EMPTY}${NC} Spotlight 索引已禁用"
    else
        opt_msg "Spotlight 索引已验证"
    fi

    local applied=0
    local failed="$spotlight_failed"
    [[ "$dns_flushed" == "true" ]] && applied=1 || failed=$((failed + 1))
    optimize_task_result_from_counts "$applied" "$failed"
}

# Refresh Finder caches (QuickLook/icon services).
opt_cache_refresh() {
    local cleaned_cache_size=0
    local removed_count=0
    local remove_failed=0
    local refresh_failed=0
    local quicklook_refreshed=0
    local icons_refreshed=0

    local -a cache_targets=(
        "$HOME/Library/Caches/com.apple.QuickLook.thumbnailcache"
        "$HOME/Library/Caches/com.apple.iconservices.store"
        "$HOME/Library/Caches/com.apple.iconservices"
    )
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "Finder 缓存刷新" "刷新 QuickLook 缩略图和图标服务"
        debug_operation_detail "方法" "移除缓存文件并通过 qlmanage 重建"
        debug_operation_detail "预期结果" "更快的 Finder 预览生成，修复图标显示问题"
        debug_risk_level "LOW" "缓存会自动重建"
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        quicklook_refreshed=1
        icons_refreshed=1
    else
        if qlmanage -r cache > /dev/null 2>&1; then
            quicklook_refreshed=1
        else
            refresh_failed=$((refresh_failed + 1))
        fi
        if qlmanage -r > /dev/null 2>&1; then
            icons_refreshed=1
        else
            refresh_failed=$((refresh_failed + 1))
        fi
    fi

    local -a removable_targets=()
    local -a removable_sizes=()

    local target_path=""
    for target_path in "${cache_targets[@]}"; do
        [[ -e "$target_path" ]] || continue
        should_protect_path "$target_path" && continue

        local size_kb=0
        local size_rc=0
        size_kb=$(opt_existing_path_size_kb "$target_path") || size_rc=$?
        [[ $size_rc -eq 124 || $size_rc -ge 128 ]] && return "$size_rc"
        [[ $size_rc -eq 0 ]] || size_kb=0
        removable_targets+=("$target_path")
        removable_sizes+=("$size_kb")
    done

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        if [[ ${#removable_targets[@]} -eq 0 ]]; then
            debug_operation_detail "待移除的文件" "无"
        else
            debug_operation_detail "待移除的文件" ""
            local index
            for index in "${!removable_targets[@]}"; do
                local size_human="未知"
                if [[ "${removable_sizes[$index]}" -gt 0 ]]; then
                    size_human=$(bytes_to_human "$((removable_sizes[index] * 1024))")
                fi
                debug_file_action "  将移除" "${removable_targets[$index]}" "$size_human" ""
            done
        fi
    fi

    local index
    for index in "${!removable_targets[@]}"; do
        local remove_rc=0
        safe_remove "${removable_targets[$index]}" true \
            "${removable_sizes[$index]}" > /dev/null 2>&1 || remove_rc=$?
        if [[ $remove_rc -eq 124 || $remove_rc -ge 128 ]]; then
            return "$remove_rc"
        elif [[ $remove_rc -eq 0 ]]; then
            removed_count=$((removed_count + 1))
            cleaned_cache_size=$((cleaned_cache_size + removable_sizes[index]))
        else
            remove_failed=$((remove_failed + 1))
        fi
    done

    export OPTIMIZE_CACHE_CLEANED_KB="${cleaned_cache_size}"
    if [[ $quicklook_refreshed -eq 1 ]]; then
        opt_msg "QuickLook 缩略图已刷新"
    fi
    if [[ $icons_refreshed -eq 1 ]]; then
        opt_msg "图标服务缓存已重建"
    fi
    if [[ $remove_failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法移除 $remove_failed 个 Finder 缓存目标"
    fi
    if [[ $refresh_failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法重建 $refresh_failed 个 Finder 缓存服务"
    fi
    optimize_task_result_from_counts \
        "$((removed_count + quicklook_refreshed + icons_refreshed))" \
        "$((remove_failed + refresh_failed))"
}

# Removed: opt_maintenance_scripts - macOS handles log rotation automatically via launchd

# Removed: opt_radio_refresh - Interrupts active user connections (WiFi, Bluetooth), degrading UX

# Old saved states cleanup.
opt_saved_state_cleanup() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "应用已保存状态清理" "移除旧的应用程序已保存状态"
        debug_operation_detail "方法" "查找并移除超过 $MOLE_SAVED_STATE_AGE_DAYS 天的 .savedState 文件夹"
        debug_operation_detail "位置" "$HOME/Library/Saved Application State"
        debug_operation_detail "预期结果" "减少磁盘占用，应用以全新状态启动"
        debug_risk_level "LOW" "旧的已保存状态，应用会创建新的"
    fi

    local state_dir="$HOME/Library/Saved Application State"
    local removed=0
    local scan_failed=0
    local remove_failed=0

    if [[ -d "$state_dir" ]]; then
        local scan_file=""
        if ! scan_file=$(mktemp_file "optimize-saved-states"); then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法准备已保存状态扫描"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
            return 0
        fi
        local scan_rc=0
        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find "$state_dir" \
            -type d -name "*.savedState" \
            -mtime "+$MOLE_SAVED_STATE_AGE_DAYS" -print0 \
            > "$scan_file" 2> /dev/null || scan_rc=$?
        if [[ $scan_rc -ne 0 ]]; then
            : > "$scan_file" || true
            [[ $scan_rc -eq 124 || $scan_rc -ge 128 ]] && return "$scan_rc"
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法扫描旧的已保存状态"
            scan_failed=1
        fi
        while IFS= read -r -d '' state_path; do
            if should_protect_path "$state_path"; then
                continue
            fi
            local remove_rc=0
            safe_remove "$state_path" true > /dev/null 2>&1 || remove_rc=$?
            if [[ $remove_rc -eq 124 || $remove_rc -ge 128 ]]; then
                return "$remove_rc"
            elif [[ $remove_rc -eq 0 ]]; then
                removed=$((removed + 1))
            else
                remove_failed=$((remove_failed + 1))
            fi
        done < "$scan_file"
    fi

    if [[ $scan_failed -eq 0 && $remove_failed -eq 0 ]]; then
        opt_msg "应用已保存状态已优化"
    elif [[ $removed -gt 0 ]]; then
        opt_msg "已移除 $removed 个旧的已保存状态"
    fi
    if [[ $remove_failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法移除 $remove_failed 个旧的已保存状态"
    fi
    optimize_task_result_from_counts "$removed" "$((scan_failed + remove_failed))"
}

# Removed: opt_swap_cleanup - Direct virtual memory operations pose system crash risk

# Removed: opt_startup_cache - Modern macOS has no such mechanism

# Removed: opt_local_snapshots - Deletes user Time Machine recovery points, breaks backup continuity

opt_fix_broken_configs() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "损坏配置修复" "检测并重置损坏的偏好设置文件"
        debug_operation_detail "方法" "通过 plutil 检查 ~/Library/Preferences 中的第三方 plist 并移除损坏项"
        debug_operation_detail "预期结果" "应用以全新偏好设置重新加载，而非因损坏的 plist 失败"
        debug_risk_level "LOW" "应用会在下次启动时重新生成偏好设置文件"
    fi

    local spinner_started="false"
    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "正在检查偏好设置…"
        spinner_started="true"
    fi

    local broken_prefs=""
    local prefs_partial=0
    broken_prefs=$(fix_broken_preferences) || prefs_partial=1
    broken_prefs=${broken_prefs:-0}

    if [[ "$spinner_started" == "true" ]]; then
        stop_inline_spinner
    fi

    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_detail "已修复的文件" "$broken_prefs"
    fi

    export OPTIMIZE_CONFIGS_REPAIRED="${broken_prefs}"
    if [[ $broken_prefs -gt 0 ]]; then
        if [[ $prefs_partial -ne 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 偏好设置扫描已达到时间预算，目前已修复 ${broken_prefs:-0} 个"
        else
            opt_msg "已修复 $broken_prefs 个损坏的偏好设置文件"
        fi
    elif [[ $prefs_partial -ne 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 偏好设置扫描已达到时间预算，目前已修复 ${broken_prefs:-0} 个"
    else
        opt_msg "所有偏好设置文件均有效"
    fi
    optimize_task_result_from_counts "$broken_prefs" "$prefs_partial"
}

# DNS cache refresh.
opt_network_optimization() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "网络优化" "刷新 DNS 缓存并重启 mDNSResponder"
        debug_operation_detail "方法" "通过 dscacheutil 刷新 DNS 缓存并 killall mDNSResponder"
        debug_operation_detail "预期结果" "更快的 DNS 解析，修复网络连接问题"
        debug_risk_level "LOW" "DNS 缓存会自动重建"
    fi

    if [[ "${MOLE_DNS_FLUSHED:-0}" == "1" ]]; then
        opt_msg "DNS 缓存已刷新"
        opt_msg "mDNSResponder 已重启"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]] && ! optimize_sudo_available; then
        opt_msg "网络缓存刷新已跳过（需要管理员权限）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        return 0
    fi

    if flush_dns_cache; then
        opt_msg "DNS 缓存已刷新"
        opt_msg "mDNSResponder 已重启"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法刷新 DNS 缓存"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
    fi
}

# Quarantine database cleanup (Gatekeeper download history).
opt_quarantine_cleanup() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "隔离数据库清理" "清除 Gatekeeper 下载跟踪历史"
        debug_operation_detail "方法" "对 QuarantineEventsV2 SQLite 数据库执行 DELETE + VACUUM"
        debug_operation_detail "安全性" "仅清除下载跟踪元数据，不影响文件隔离标志"
        debug_operation_detail "预期结果" "缩小数据库体积，清除下载跟踪历史"
        debug_risk_level "LOW" "数据库会由 macOS 自动重建"
    fi

    if ! command -v sqlite3 > /dev/null 2>&1; then
        echo -e "  ${GRAY}-${NC} 隔离数据库清理已跳过，sqlite3 不可用"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local quarantine_db="$HOME/Library/Preferences/com.apple.LaunchServices.QuarantineEventsV2"

    if [[ ! -f "$quarantine_db" ]]; then
        opt_msg "隔离数据库已清理"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if should_protect_path "$quarantine_db"; then
        opt_msg "隔离数据库已清理"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    # Check if database has any entries worth cleaning.
    local row_count=""
    local count_status=0
    row_count=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" sqlite3 "$quarantine_db" "SELECT COUNT(*) FROM LSQuarantineEvent;" 2> /dev/null) || count_status=$?

    if [[ $count_status -ne 0 || ! "$row_count" =~ ^[0-9]+$ ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查隔离数据库"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        return 0
    fi
    if [[ "$row_count" -eq 0 ]]; then
        opt_msg "隔离数据库已清理"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        local exit_code=0
        run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" sqlite3 "$quarantine_db" "DELETE FROM LSQuarantineEvent; VACUUM;" 2> /dev/null || exit_code=$?

        if [[ $exit_code -eq 0 ]]; then
            opt_msg "已清除隔离历史（$row_count 条记录）"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法清理隔离数据库"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        fi
    else
        opt_msg "已清除隔离历史（$row_count 条记录）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    fi
}

# SQLite vacuum for Mail/Messages/Safari (safety checks applied).
opt_sqlite_vacuum() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "数据库优化" "对 Mail、Safari 和 Messages 的 SQLite 数据库执行 Vacuum"
        debug_operation_detail "方法" "完整性检查后对数据库执行 VACUUM 命令"
        debug_operation_detail "安全检查" "应用运行时跳过，先验证完整性，20 秒超时"
        debug_operation_detail "预期结果" "缩小数据库体积，提升应用性能"
        debug_risk_level "LOW" "仅优化数据库，不会删除数据"
    fi

    if ! command -v pgrep > /dev/null 2>&1; then
        echo -e "  ${GRAY}-${NC} 数据库优化不可用，进程探测不可用"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local -a busy_apps=()
    local -a check_apps=("Mail" "Safari" "Messages")
    local app probe_status
    for app in "${check_apps[@]}"; do
        if pgrep -x "$app" > /dev/null 2>&1; then
            busy_apps+=("$app")
        else
            probe_status=$?
            if [[ $probe_status -ne 1 ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} 数据库优化前无法检查正在运行的应用"
                optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
                return 0
            fi
        fi
    done

    if [[ ${#busy_apps[@]} -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 数据库优化前请关闭这些应用：${busy_apps[*]}"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        return 0
    fi

    if ! command -v sqlite3 > /dev/null 2>&1; then
        echo -e "  ${GRAY}-${NC} 数据库已是最优，sqlite3 不可用"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local spinner_started="false"
    if [[ "${MOLE_DRY_RUN:-0}" != "1" && -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "正在优化数据库…"
        spinner_started="true"
    fi

    local -a db_paths=(
        "$HOME/Library/Mail/V*/MailData/Envelope Index*"
        "$HOME/Library/Messages/chat.db"
        "$HOME/Library/Safari/History.db"
        "$HOME/Library/Safari/TopSites.db"
    )

    local vacuumed=0
    local timed_out=0
    local failed=0
    local policy_skipped=0
    local already_optimal=0
    # Paths held back only by the size ceiling (issue #1367): never claim
    # "all already optimized" when this list is non-empty.
    local -a policy_skipped_paths=()

    for pattern in "${db_paths[@]}"; do
        while IFS= read -r db_file; do
            [[ ! -f "$db_file" ]] && continue
            [[ "$db_file" == *"-wal" || "$db_file" == *"-shm" ]] && continue

            should_protect_path "$db_file" && continue

            case "$(file -b "$db_file" 2> /dev/null || true)" in
                *SQLite*) ;;
                *) continue ;;
            esac

            # Skip large DBs (>100MB).
            local file_size
            file_size=$(get_file_size "$db_file")
            if [[ "$file_size" -gt "$MOLE_SQLITE_MAX_SIZE" ]]; then
                policy_skipped=$((policy_skipped + 1))
                policy_skipped_paths+=("$db_file")
                continue
            fi

            # Skip if freelist is tiny (already compact).
            local page_info=""
            local page_status=0
            page_info=$(run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" sqlite3 "$db_file" "PRAGMA page_count; PRAGMA freelist_count;" 2> /dev/null) || page_status=$?
            if [[ $page_status -ne 0 ]]; then
                failed=$((failed + 1))
                continue
            fi
            local page_count=""
            local freelist_count=""
            page_count="${page_info%%$'\n'*}"
            if [[ "$page_info" == *$'\n'* ]]; then
                freelist_count="${page_info#*$'\n'}"
                freelist_count="${freelist_count%%$'\n'*}"
            fi
            if [[ "$page_count" =~ ^[0-9]+$ && "$freelist_count" =~ ^[0-9]+$ && "$page_count" -gt 0 ]]; then
                if ((freelist_count * 100 < page_count * 5)); then
                    already_optimal=$((already_optimal + 1))
                    continue
                fi
            fi

            # Verify integrity before VACUUM.
            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                local integrity_check=""
                local integrity_status=0
                integrity_check=$(run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" sqlite3 "$db_file" "PRAGMA integrity_check;" 2> /dev/null) || integrity_status=$?

                if [[ $integrity_status -ne 0 || "$integrity_check" != "ok" ]]; then
                    failed=$((failed + 1))
                    continue
                fi
            fi

            local exit_code=0
            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                run_with_timeout "$MOLE_TIMEOUT_PKG_CLEANUP_SEC" sqlite3 "$db_file" "VACUUM;" 2> /dev/null || exit_code=$?

                if [[ $exit_code -eq 0 ]]; then
                    vacuumed=$((vacuumed + 1))
                elif [[ $exit_code -eq 124 ]]; then
                    timed_out=$((timed_out + 1))
                else
                    failed=$((failed + 1))
                fi
            else
                vacuumed=$((vacuumed + 1))
            fi
        done < <(compgen -G "$pattern" || true)
    done

    if [[ "$spinner_started" == "true" ]]; then
        stop_inline_spinner
    fi

    export OPTIMIZE_DATABASES_COUNT="${vacuumed}"
    # Headline must not say "already optimized" when size policy skipped
    # anything, or when nothing was even compact enough to claim success
    # (issue #1367).
    if [[ $vacuumed -gt 0 ]]; then
        opt_msg "已优化 $vacuumed 个 Mail、Safari、Messages 数据库"
    elif [[ $timed_out -ne 0 || $failed -ne 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 数据库优化未完成"
    elif [[ $policy_skipped -gt 0 ]]; then
        opt_msg "没有数据库被压缩"
    elif [[ $already_optimal -gt 0 ]]; then
        opt_msg "所有数据库均已优化"
    else
        opt_msg "未找到需要优化的数据库"
    fi

    if [[ $already_optimal -gt 0 ]]; then
        opt_msg "已是最优的数据库 $already_optimal 个"
    fi

    if [[ $policy_skipped -gt 0 ]]; then
        opt_msg "已跳过 $policy_skipped 个超过 100 MB 安全限制的数据库"
        local skipped_path skipped_size skipped_display
        for skipped_path in "${policy_skipped_paths[@]}"; do
            skipped_size=$(get_file_size "$skipped_path" 2> /dev/null || echo 0)
            if [[ "$skipped_size" =~ ^[0-9]+$ && "$skipped_size" -gt 0 ]]; then
                skipped_display=$(bytes_to_human "$skipped_size")
            else
                skipped_display="未知大小"
            fi
            echo -e "  ${GRAY}${ICON_SUBLIST}${NC} ${skipped_path/#$HOME/~} · ${skipped_display}"
        done
    fi

    if [[ $timed_out -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} $timed_out 个数据库超时"
    fi

    if [[ $failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} $failed 个数据库失败"
    fi

    optimize_task_result_from_counts "$vacuumed" "$((timed_out + failed))" "$policy_skipped"
}

# LaunchServices rebuild ("Open with" issues).
opt_launch_services_rebuild() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "LaunchServices 重建" "重建 LaunchServices 数据库"
        debug_operation_detail "方法" "运行 lsregister -gc，然后对本地、用户和系统域执行 -r -f 强制重新扫描"
        debug_operation_detail "目的" "修复「打开方式」菜单问题、文件关联和陈旧的应用元数据"
        debug_operation_detail "预期结果" "修正应用关联，修复重复条目，减少陈旧的应用列表"
        debug_risk_level "LOW" "数据库会自动重建"
    fi

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "正在修复 LaunchServices…"
    fi

    local lsregister
    lsregister=$(get_lsregister_path)

    if [[ -n "$lsregister" ]]; then
        local success=0

        if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
            "$lsregister" -gc > /dev/null 2>&1 || true
            "$lsregister" -r -f -domain local -domain user -domain system > /dev/null 2>&1 || success=$?
            if [[ $success -ne 0 ]]; then
                success=0
                "$lsregister" -r -f -domain local -domain user > /dev/null 2>&1 || success=$?
            fi
        else
            success=0
        fi

        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi

        if [[ $success -eq 0 ]]; then
            opt_msg "LaunchServices 已修复"
            opt_msg "文件关联已刷新"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法重建 LaunchServices"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        fi
    else
        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 未找到 lsregister"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
    fi
}

# Removed high-risk optimizations:
# - opt_startup_items_cleanup: Risk of deleting legitimate app helpers
# - opt_dyld_cache_update: Low benefit, time-consuming, auto-managed by macOS
# - opt_system_services_refresh: Risk of data loss when killing system services

# Network stack reset (route + ARP).
opt_network_stack_optimize() {
    local route_flushed="false"
    local arp_flushed="false"

    local vpn_status=0
    if has_active_vpn_interface; then
        vpn_status=0
    else
        vpn_status=$?
    fi
    case "$vpn_status" in
        0)
            opt_msg "网络栈刷新已跳过，检测到活动 VPN"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
            return 0
            ;;
        1) ;;
        *)
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查活动 VPN 状态"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
            return 0
            ;;
    esac

    local route_ok=true
    local dns_ok=true
    local route_status=0
    local dns_status=0

    if run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" route -n get default > /dev/null 2>&1; then
        route_status=0
    else
        route_status=$?
    fi
    if run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" dscacheutil -q host -a name "example.com" > /dev/null 2>&1; then
        dns_status=0
    else
        dns_status=$?
    fi

    if [[ $route_status -eq 124 || $dns_status -eq 124 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 网络健康检查超时"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        return 0
    fi
    if [[ $route_status -gt 1 || $dns_status -gt 1 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查网络状态"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        return 0
    fi

    if [[ $route_status -ne 0 ]]; then
        route_ok=false
    fi
    if [[ $dns_status -ne 0 ]]; then
        dns_ok=false
    fi

    if [[ "$route_ok" == "true" && "$dns_ok" == "true" ]]; then
        opt_msg "网络栈已是最优"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if ! optimize_sudo_available; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 网络栈刷新 · 已跳过（需要管理员权限）"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
            return 0
        fi

        if sudo route -n flush > /dev/null 2>&1; then
            route_flushed="true"
        fi

        if sudo arp -a -d > /dev/null 2>&1; then
            arp_flushed="true"
        fi
    else
        route_flushed="true"
        arp_flushed="true"
    fi

    local applied=0
    local failed=0
    if [[ "$route_flushed" == "true" ]]; then
        opt_msg "网络路由表已刷新"
        applied=$((applied + 1))
    else
        failed=$((failed + 1))
    fi
    if [[ "$arp_flushed" == "true" ]]; then
        opt_msg "ARP 缓存已清除"
        applied=$((applied + 1))
    else
        failed=$((failed + 1))
    fi

    if [[ $failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 网络栈刷新未完成（$failed 个操作失败）"
    fi
    optimize_task_result_from_counts "$applied" "$failed"
}

# User directory permissions repair.
opt_disk_permissions_repair() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "磁盘权限修复" "重置用户目录权限"
        debug_operation_detail "方法" "对用户主目录运行 diskutil resetUserPermissions"
        debug_operation_detail "条件" "仅在检测到权限问题时运行"
        debug_operation_detail "预期结果" "修复文件访问问题，纠正所有权"
        debug_risk_level "MEDIUM" "需要 sudo，会修改权限"
    fi

    local user_id
    user_id=$(id -u)

    if ! needs_permissions_repair; then
        opt_msg "用户目录权限已是最优"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if ! optimize_sudo_available; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 磁盘权限修复 · 已跳过（需要管理员权限）"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
            return 0
        fi

        if [[ -t 1 ]]; then
            start_inline_spinner "正在修复磁盘权限…"
        fi

        local success=false
        if sudo diskutil resetUserPermissions / "$user_id" > /dev/null 2>&1; then
            success=true
        fi

        if [[ -t 1 ]]; then
            stop_inline_spinner
        fi

        if [[ "$success" == "true" ]]; then
            opt_msg "用户目录权限已修复"
            opt_msg "文件访问问题已解决"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法修复权限，可能无需修复"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        fi
    else
        opt_msg "用户目录权限已修复"
        opt_msg "文件访问问题已解决"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    fi
}

# Spotlight index check/rebuild (only if slow).
opt_spotlight_index_optimize() {
    local spotlight_status=""
    local spotlight_status_code=0
    spotlight_status=$(run_with_timeout "$MOLE_TIMEOUT_SHORT_QUERY_SEC" mdutil -s / 2> /dev/null) || spotlight_status_code=$?

    if [[ $spotlight_status_code -ne 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查 Spotlight 索引（exit=${spotlight_status_code}）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        return 0
    fi

    if echo "$spotlight_status" | grep -qi "Indexing disabled"; then
        echo -e "  ${GRAY}${ICON_EMPTY}${NC} Spotlight 索引已禁用"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        return 0
    fi

    if echo "$spotlight_status" | grep -qi "Indexing enabled" && ! echo "$spotlight_status" | grep -qi "Indexing and searching disabled"; then
        # A rebuild is only offered on AC power, so skip the speed probe on
        # battery instead of measuring a result that would be discarded.
        if ! is_ac_power; then
            opt_msg "Spotlight 索引已是最优"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
            return 0
        fi

        local slow_threshold="${MOLE_OPTIMIZE_SPOTLIGHT_SLOW_SEC:-3}"
        if [[ ! "$slow_threshold" =~ ^-?[0-9]+$ ]]; then
            slow_threshold=3
        fi

        local spinner_started="false"
        if [[ -t 1 ]]; then
            MOLE_SPINNER_PREFIX="  " start_inline_spinner "正在检查 Spotlight 速度…"
            spinner_started="true"
        fi

        local slow_count=0
        local probe_failed=0
        local test_start test_end test_duration probe probe_status
        for probe in 1 2; do
            test_start=$(get_epoch_seconds)
            # A timeout counts as slow: an mdfind that cannot answer within
            # the probe ceiling is exactly the sluggishness being measured.
            probe_status=0
            run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" mdfind "kMDItemFSName == 'Applications'" > /dev/null 2>&1 || probe_status=$?
            test_end=$(get_epoch_seconds)
            test_duration=$((test_end - test_start))
            if [[ $probe_status -eq 124 ]]; then
                slow_count=$((slow_count + 1))
            elif [[ $probe_status -ne 0 ]]; then
                probe_failed=$((probe_failed + 1))
            elif [[ $test_duration -gt $slow_threshold ]]; then
                slow_count=$((slow_count + 1))
            fi
            if [[ "$probe" == "1" ]]; then
                sleep 1
            fi
        done

        if [[ "$spinner_started" == "true" ]]; then
            stop_inline_spinner
        fi

        if [[ $probe_failed -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Spotlight 速度检查失败（$probe_failed 次探测）"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
            return 0
        fi

        if [[ $slow_count -ge 2 ]]; then
            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                if ! optimize_sudo_available; then
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} Spotlight 索引重建 · 已跳过（需要管理员权限）"
                    optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
                    return 0
                fi
                echo -e "  ${BLUE}${ICON_INFO}${NC} Spotlight 搜索较慢，正在重建索引，可能需要 1-2 小时"
                if sudo mdutil -E / > /dev/null 2>&1; then
                    opt_msg "Spotlight 索引重建已开始"
                    echo -e "  ${GRAY}索引将在后台继续${NC}"
                    optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
                else
                    echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法重建 Spotlight 索引"
                    optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
                fi
            else
                opt_msg "Spotlight 索引重建已开始"
                optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
            fi
        else
            opt_msg "Spotlight 索引已是最优"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        fi
    else
        opt_msg "Spotlight 索引已验证"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
    fi
}

# Remove orphaned Spotlight search-rule entries.
# Uninstalling an app (especially Mac App Store apps that synced via iCloud)
# can leave its bundle id behind in com.apple.spotlight EnabledPreferenceRules,
# showing up as a dead row in System Settings > Spotlight (#1000). macOS never
# prunes these, so we drop entries whose app is no longer installed.
opt_prune_spotlight_orphan_rules() {
    local domain="com.apple.spotlight"
    local plist="$HOME/Library/Preferences/${domain}.plist"

    if ! defaults read "$domain" EnabledPreferenceRules &> /dev/null; then
        opt_msg "Spotlight 搜索规则已清理"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    local -a keep=() removed=()
    local i=0 entry
    while entry=$(/usr/libexec/PlistBuddy -c "Print :EnabledPreferenceRules:$i" "$plist" 2> /dev/null); do
        case "$entry" in
            # Never touch system or Apple rules (e.g. System.iphoneApps); these
            # pass the reverse-DNS shape check but are not removable app bundles.
            System.* | com.apple.*)
                keep+=("$entry")
                ;;
            *)
                # Only act on well-formed bundle ids; bundle_has_installed_app
                # double-checks with mdfind and a filesystem scan, so a return of
                # 1 means the app is genuinely gone. Anything else is kept.
                if ! mole_is_reverse_dns_bundle_id "$entry"; then
                    keep+=("$entry")
                else
                    local resolver_rc=0
                    bundle_has_installed_app "$entry" \
                        "$((SECONDS + MOLE_TIMEOUT_MEDIUM_PROBE_SEC))" || resolver_rc=$?
                    if [[ $resolver_rc -eq 1 ]]; then
                        removed+=("$entry")
                    elif [[ $resolver_rc -ge 128 ]]; then
                        return "$resolver_rc"
                    else
                        keep+=("$entry")
                    fi
                fi
                ;;
        esac
        i=$((i + 1))
    done

    if [[ ${#removed[@]} -eq 0 ]]; then
        opt_msg "Spotlight 搜索规则已清理"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        opt_msg "将移除 ${#removed[@]} 条孤立的 Spotlight 规则"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
        return 0
    fi

    # Rewrite the filtered array through cfprefsd (defaults), not by deleting
    # plist indices in place: this avoids the cfprefsd cache overwriting a direct
    # file edit, and ensures System Settings reflects the change and it persists.
    local write_status=0
    if [[ ${#keep[@]} -gt 0 ]]; then
        defaults write "$domain" EnabledPreferenceRules -array "${keep[@]}" 2> /dev/null || write_status=$?
    else
        defaults delete "$domain" EnabledPreferenceRules 2> /dev/null || write_status=$?
    fi

    if [[ $write_status -eq 0 ]]; then
        opt_msg "已移除 ${#removed[@]} 条孤立的 Spotlight 规则"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法移除孤立的 Spotlight 规则"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
    fi
}

# Prevent .DS_Store on network and USB volumes.
# Idempotent: writes two user defaults that stop Finder from creating
# .DS_Store files on SMB/AFP/NFS shares and removable USB volumes.
# Reversible with: defaults delete com.apple.desktopservices DSDontWrite{Network,USB}Stores
opt_prevent_network_dsstore() {
    local domain="com.apple.desktopservices"
    local -a keys=("DSDontWriteNetworkStores" "DSDontWriteUSBStores")
    local changed=0
    local already=0
    local failed=0

    for key in "${keys[@]}"; do
        local current
        current=$(defaults read "$domain" "$key" 2> /dev/null || echo "")
        if [[ "$current" == "1" ]]; then
            already=$((already + 1))
            continue
        fi

        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            changed=$((changed + 1))
            continue
        fi

        if defaults write "$domain" "$key" -bool true 2> /dev/null; then
            changed=$((changed + 1))
        else
            failed=$((failed + 1))
        fi
    done

    if [[ $changed -eq 0 && $already -gt 0 ]]; then
        opt_msg "网络与 USB 卷上已启用 .DS_Store 防生成"
    fi

    if [[ $changed -gt 0 ]]; then
        opt_msg "已在网络与 USB 卷上启用 .DS_Store 防生成"
    elif [[ $failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法启用 .DS_Store 防生成"
    fi
    if [[ $changed -gt 0 && $failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法为 $failed 种卷类型启用 .DS_Store 防生成"
    fi
    optimize_task_result_from_counts "$changed" "$failed"
}

# Legacy override audit (#1242, #1243): old tweak utilities leave behind
# hidden preferences that silently change safe macOS defaults, and current
# System Settings never surfaces them. Covered overrides: the global App Nap
# kill switch (NSAppSleepDisabled) and the DiskImages skip-verify family.
# Silent when the OS defaults are in effect. Repair deletes only the explicit
# override key, restoring automatic macOS behavior; it never writes a
# replacement preference and never touches the plist file itself.
opt_legacy_overrides_audit() {
    if [[ "${MO_DEBUG:-}" == "1" ]]; then
        debug_operation_start "旧版覆盖项" "检测 App Nap 和磁盘映像验证的覆盖设置"
        debug_operation_detail "方法" "defaults read -g NSAppSleepDisabled; defaults read com.apple.frameworks.diskimages skip-verify*"
        debug_operation_detail "预期结果" "移除覆盖设置，使 macOS 默认值重新生效"
        debug_risk_level "LOW" "仅删除显式覆盖键；macOS 会回退到默认行为"
    fi

    local -a found_labels=()
    local -a found_domains=()
    local -a found_keys=()
    local -a found_plists=()

    _opt_defaults_is_truthy() {
        [[ "$1" == "1" || "$1" =~ ^([Tt][Rr][Uu][Ee]|[Yy][Ee][Ss])$ ]]
    }

    local value
    value=$(defaults read -g NSAppSleepDisabled 2> /dev/null || echo "")
    if _opt_defaults_is_truthy "$value"; then
        found_labels+=("已全局禁用 App Nap（NSAppSleepDisabled）")
        found_domains+=("-g")
        found_keys+=("NSAppSleepDisabled")
        found_plists+=("$HOME/Library/Preferences/.GlobalPreferences.plist")
    fi

    local key
    for key in skip-verify skip-verify-locked skip-verify-remote; do
        value=$(defaults read com.apple.frameworks.diskimages "$key" 2> /dev/null || echo "")
        if _opt_defaults_is_truthy "$value"; then
            found_labels+=("磁盘映像验证已跳过（${key}）")
            found_domains+=("com.apple.frameworks.diskimages")
            found_keys+=("$key")
            found_plists+=("$HOME/Library/Preferences/com.apple.frameworks.diskimages.plist")
        fi
    done

    if [[ ${#found_keys[@]} -eq 0 ]]; then
        opt_msg "未发现旧版 App Nap 或磁盘映像覆盖设置"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    local changed=0 skipped=0 failed=0 idx
    for idx in "${!found_keys[@]}"; do
        if command -v is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "${found_plists[$idx]}"; then
            opt_msg "已跳过（白名单）：${found_labels[$idx]}"
            skipped=$((skipped + 1))
            continue
        fi
        if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} 将移除覆盖设置：${found_labels[$idx]}"
            changed=$((changed + 1))
            continue
        fi
        if defaults delete "${found_domains[$idx]}" "${found_keys[$idx]}" 2> /dev/null; then
            opt_msg "已移除覆盖设置：${found_labels[$idx]}"
            changed=$((changed + 1))
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法移除覆盖设置：${found_labels[$idx]}"
            failed=$((failed + 1))
        fi
    done

    optimize_task_result_from_counts "$changed" "$failed" "$skipped"
}

# True unless the path lives on an unmounted /Volumes/<disk>. A LaunchAgent
# program on an external or network volume is not broken while that volume is
# simply unplugged, so it must not be deleted.
launch_agent_volume_mounted() {
    local path="$1"
    case "$path" in
        /Volumes/*)
            local vol="${path#/Volumes/}"
            vol="${vol%%/*}"
            [[ -n "$vol" && -d "/Volumes/$vol" ]]
            ;;
        *) return 0 ;;
    esac
}

# Broken LaunchAgent cleanup.
opt_launch_agents_cleanup() {
    local agents_dir="$HOME/Library/LaunchAgents"

    if [[ ! -d "$agents_dir" ]]; then
        opt_msg "LaunchAgent 全部正常"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    local broken_count=0
    local -a broken_plists=()

    for plist in "$agents_dir"/*.plist; do
        [[ -f "$plist" ]] || continue

        local binary=""
        local plist_rc=0
        binary=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
            /usr/libexec/PlistBuddy -c "Print :ProgramArguments:0" \
            "$plist" 2> /dev/null) || plist_rc=$?
        [[ $plist_rc -eq 124 || $plist_rc -ge 128 ]] && return "$plist_rc"
        if [[ -z "$binary" ]]; then
            plist_rc=0
            binary=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
                /usr/libexec/PlistBuddy -c "Print :Program" \
                "$plist" 2> /dev/null) || plist_rc=$?
            [[ $plist_rc -eq 124 || $plist_rc -ge 128 ]] && return "$plist_rc"
        fi

        # Only an absolute path that is genuinely missing counts as broken.
        # Bare names (node, python3) resolve via PATH at launch time, and a
        # path on an unmounted /Volumes/<disk> just means the drive is
        # unplugged -- neither is a broken agent.
        if [[ -n "$binary" && "$binary" == /* && ! -e "$binary" ]] &&
            launch_agent_volume_mounted "$binary"; then
            broken_count=$((broken_count + 1))
            broken_plists+=("$plist")
        fi
    done

    if [[ $broken_count -eq 0 ]]; then
        opt_msg "LaunchAgent 全部正常"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    local removed_count=0
    local failed=0
    for plist in "${broken_plists[@]}"; do
        local unload_rc=0
        run_launchctl_unload "$plist" || unload_rc=$?
        [[ $unload_rc -eq 124 || $unload_rc -ge 128 ]] && return "$unload_rc"
        local remove_rc=0
        safe_remove "$plist" true > /dev/null 2>&1 || remove_rc=$?
        if [[ $remove_rc -eq 124 || $remove_rc -ge 128 ]]; then
            return "$remove_rc"
        elif [[ $remove_rc -eq 0 ]]; then
            removed_count=$((removed_count + 1))
        else
            failed=$((failed + 1))
        fi
    done

    if [[ $removed_count -gt 0 ]]; then
        opt_msg "已清理 $removed_count 个损坏的 LaunchAgent"
    fi
    if [[ $failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法移除 $failed 个损坏的 LaunchAgent"
    fi
    optimize_task_result_from_counts "$removed_count" "$failed"
}

# macOS periodic maintenance scripts (daily/weekly/monthly).
# Log path is configurable via MOLE_PERIODIC_LOG for testing; defaults to /var/log/daily.out.
# A missing log file is treated as stale and triggers maintenance.
opt_periodic_maintenance() {
    # Check if periodic command exists (removed in macOS 26+)
    if ! command -v periodic > /dev/null 2>&1; then
        opt_msg "定期维护已跳过（此 macOS 版本不可用）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi

    local daily_log="${MOLE_PERIODIC_LOG:-/var/log/daily.out}"
    local stale_days=7

    if [[ -f "$daily_log" ]]; then
        local last_mod now age_days
        last_mod=$(get_file_mtime "$daily_log")
        now=$(get_epoch_seconds)
        age_days=$(((now - last_mod) / 86400))

        if [[ $age_days -lt $stale_days ]]; then
            opt_msg "定期维护已是最新（${age_days} 天前）"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
            return 0
        fi
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]] || ! optimize_sudo_available; then
            opt_msg "定期维护已跳过（需要 sudo）"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
            return 0
        fi
        # Capture stderr so --debug can surface the real failure reason
        # (missing /etc/periodic scripts, SIP, broken launchd, etc.).
        local periodic_output rc
        if periodic_output=$(sudo periodic daily weekly monthly 2>&1); then
            opt_msg "定期维护已触发"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
        else
            rc=$?
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法运行定期维护（exit=${rc}）"
            if [[ -n "$periodic_output" ]]; then
                debug_log "periodic stderr: $periodic_output"
            fi
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        fi
    else
        opt_msg "定期维护已触发"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    fi
}

# Repair corrupted shared file list databases (Finder favorites, recent docs).
opt_shared_file_list_repair() {
    local sfl_dir="$HOME/Library/Application Support/com.apple.sharedfilelist"
    if [[ ! -d "$sfl_dir" ]]; then
        opt_msg "未找到共享文件列表目录"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    local repaired=0
    local scan_failed=0
    local remove_failed=0
    local scan_file=""
    if ! scan_file=$(mktemp_file "optimize-shared-file-lists"); then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法准备共享文件列表扫描"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        return 0
    fi
    local scan_rc=0
    run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" find "$sfl_dir" \
        \( -name "*.sfl2" -o -name "*.sfl3" \) -type f \
        ! -path "*ApplicationRecentDocuments*" -print0 \
        > "$scan_file" 2> /dev/null || scan_rc=$?
    if [[ $scan_rc -ne 0 ]]; then
        : > "$scan_file" || true
        [[ $scan_rc -eq 124 || $scan_rc -ge 128 ]] && return "$scan_rc"
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法扫描共享文件列表"
        scan_failed=1
    fi
    while IFS= read -r -d '' sfl_file; do
        [[ -f "$sfl_file" ]] || continue
        # Skip recent-documents list (user data, not a cache)
        [[ "$sfl_file" == *"ApplicationRecentDocuments"* ]] && continue
        if ! plutil -lint "$sfl_file" > /dev/null 2>&1; then
            local remove_rc=0
            if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
                safe_remove "$sfl_file" true > /dev/null 2>&1 || remove_rc=$?
            fi
            if [[ $remove_rc -eq 124 || $remove_rc -ge 128 ]]; then
                return "$remove_rc"
            elif [[ $remove_rc -eq 0 ]]; then
                repaired=$((repaired + 1))
            else
                remove_failed=$((remove_failed + 1))
            fi
        fi
    done < "$scan_file"

    if [[ $repaired -gt 0 ]]; then
        opt_msg "已修复 $repaired 个损坏的共享文件列表"
    elif [[ $scan_failed -eq 0 && $remove_failed -eq 0 ]]; then
        opt_msg "共享文件列表全部正常"
    fi
    if [[ $remove_failed -gt 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法修复 $remove_failed 个损坏的共享文件列表"
    fi
    optimize_task_result_from_counts "$repaired" "$((scan_failed + remove_failed))"
}

# Resolve the live Notification Center SQLite database.
# macOS 15+ (Sequoia and later) stores it under the usernoted group container;
# older systems keep it under DARWIN_USER_DIR. Prefer the path that actually
# exists so we never report "not found" while usernoted holds the real db open
# (issue #1368).
# shellcheck disable=SC2329
resolve_notification_center_db() {
    local group_db="$HOME/Library/Group Containers/group.com.apple.usernoted/db2/db"
    if [[ -f "$group_db" ]]; then
        printf '%s\n' "$group_db"
        return 0
    fi

    local darwin_dir=""
    darwin_dir="$(getconf DARWIN_USER_DIR 2> /dev/null || true)"
    darwin_dir="${darwin_dir%/}"
    if [[ -n "$darwin_dir" && -f "$darwin_dir/com.apple.notificationcenter/db2/db" ]]; then
        printf '%s\n' "$darwin_dir/com.apple.notificationcenter/db2/db"
        return 0
    fi
    return 1
}

# Clean old delivered notifications from NotificationCenter database.
opt_notification_cleanup() {
    local nc_db=""
    if ! nc_db=$(resolve_notification_center_db); then
        # Unavailable, not a healthy empty state: the success "not found" line
        # made a missed Sequoia path look like a no-op (issue #1368).
        echo -e "  ${GRAY}-${NC} 通知中心数据库不可用（无支持的路径）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        return 0
    fi
    debug_log "Notification Center database: $nc_db"

    local db_size=""
    if ! db_size=$(opt_existing_file_size_kb_strict "$nc_db"); then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查通知中心数据库大小"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        return 0
    fi

    # Only clean if database exceeds 50MB (51200 KB)
    if [[ $db_size -lt 51200 ]]; then
        opt_msg "通知中心数据库正常（$(bytes_to_human $((db_size * 1024))))"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if command -v sqlite3 > /dev/null 2>&1; then
            local sql_ok=0
            sqlite3 "$nc_db" \
                "DELETE FROM record WHERE delivered_date < strftime('%s','now','-30 days'); VACUUM;" \
                2> /dev/null || sql_ok=$?
            if [[ $sql_ok -eq 0 ]]; then
                killall NotificationCenter 2> /dev/null || true
                opt_msg "通知中心数据库已清理（原为 $(bytes_to_human $((db_size * 1024))))"
                optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
            else
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} 通知中心清理已跳过（数据库忙或被锁定）"
                optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
            fi
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} sqlite3 不可用"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
        fi
    else
        opt_msg "通知中心数据库已清理（原为 $(bytes_to_human $((db_size * 1024))))"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    fi
}

# Verify filesystem integrity via diskutil.
# Disabled by default: diskutil verifyVolume triggers kernel-level I/O that
# cannot be interrupted by SIGKILL when the volume has APFS inconsistencies,
# causing the system to freeze. Set MOLE_ENABLE_DISK_VERIFY=1 to opt in.
opt_disk_verify() {
    if [[ "${MOLE_ENABLE_DISK_VERIFY:-0}" != "1" ]]; then
        opt_msg "磁盘验证已跳过（设置 MOLE_ENABLE_DISK_VERIFY=1 以启用）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" == "1" ]]; then
        opt_msg "磁盘验证 · 预览模式下已跳过"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        return 0
    fi

    if [[ -t 1 ]]; then
        MOLE_SPINNER_PREFIX="  " start_inline_spinner "正在验证磁盘文件系统…"
    fi
    local output=""
    local verify_status=0
    output=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" diskutil verifyVolume / 2>&1) || verify_status=$?
    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    if [[ $verify_status -eq 124 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 磁盘验证超时"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
    elif [[ $verify_status -ne 0 ]]; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 磁盘验证失败（exit=${verify_status}）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
    elif echo "$output" | grep -qi "appears to be OK\|volume appears to be ok"; then
        opt_msg "磁盘文件系统验证正常"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
    elif echo "$output" | grep -qi "error\|corrupt\|invalid"; then
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 检测到磁盘问题 · 请运行：sudo diskutil repairVolume /"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法识别磁盘验证结果"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
    fi
}

# Clean Knowledge/CoreDuet usage tracking databases.
opt_coreduet_cleanup() {
    local knowledge_dir="$HOME/Library/Application Support/Knowledge"
    local knowledge_db="$knowledge_dir/knowledgeC.db"

    if [[ ! -f "$knowledge_db" ]]; then
        opt_msg "未找到 Knowledge 数据库"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    # Check combined size of WAL/SHM files + database
    local wal_file="$knowledge_db-wal"
    local shm_file="$knowledge_db-shm"
    local total_size=0
    local -a knowledge_files=()

    for f in "$knowledge_db" "$wal_file" "$shm_file"; do
        [[ -f "$f" ]] && knowledge_files+=("$f")
    done

    if [[ ${#knowledge_files[@]} -gt 0 ]]; then
        local size_status=0
        total_size=$(run_with_timeout "$MOLE_TIMEOUT_DISK_VERIFY_SEC" du -skcP "${knowledge_files[@]}" 2> /dev/null | awk 'END {print $1 + 0}') || size_status=$?
        if [[ $size_status -ne 0 || ! "$total_size" =~ ^[0-9]+$ ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查 Knowledge 数据库大小"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
            return 0
        fi
    fi

    # Skip if combined size < 100MB (102400 KB)
    if [[ $total_size -lt 102400 ]]; then
        opt_msg "Knowledge 数据库正常（$(bytes_to_human $((total_size * 1024))))"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    if [[ "${MOLE_DRY_RUN:-0}" != "1" ]]; then
        if ! command -v sqlite3 > /dev/null 2>&1; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} sqlite3 不可用"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNAVAILABLE"
            return 0
        fi

        # Remove WAL and SHM files safely (auto-regenerated by SQLite)
        local removed_count=0
        local remove_failed=0
        for f in "$wal_file" "$shm_file"; do
            if [[ -f "$f" ]]; then
                local remove_rc=0
                safe_remove "$f" true > /dev/null 2>&1 || remove_rc=$?
                if [[ $remove_rc -eq 124 || $remove_rc -ge 128 ]]; then
                    return "$remove_rc"
                elif [[ $remove_rc -eq 0 ]]; then
                    removed_count=$((removed_count + 1))
                else
                    remove_failed=$((remove_failed + 1))
                fi
            fi
        done
        # Remove ZOBJECT entries older than 90 days (CoreTime is Mac epoch: seconds since 2001-01-01)
        local sql_applied=0
        local sql_failed=0
        if sqlite3 "$knowledge_db" \
            "DELETE FROM ZOBJECT WHERE ZCREATIONDATE < (strftime('%s','now','-90 days') - strftime('%s','2001-01-01')); VACUUM;" \
            2> /dev/null; then
            sql_applied=1
        else
            sql_failed=1
        fi

        if [[ $sql_failed -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Knowledge 数据库清理已跳过（数据库忙或被锁定）"
        elif [[ $remove_failed -gt 0 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} Knowledge 数据库清理未完成"
        else
            opt_msg "Knowledge 数据库已清理（原为 $(bytes_to_human $((total_size * 1024))))"
        fi
        optimize_task_result_from_counts \
            "$((removed_count + sql_applied))" \
            "$((remove_failed + sql_failed))"
    else
        opt_msg "Knowledge 数据库已清理（原为 $(bytes_to_human $((total_size * 1024))))"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_APPLIED"
    fi
}

# Audit login items for broken entries referencing missing apps.
# Return a tab-separated snapshot: login item display name, then best-effort
# POSIX path. Display names can differ from the on-disk bundle name, so the
# audit needs both pieces before deciding an item is broken.
_login_items_snapshot() {
    local timeout_seconds="${1:-$MOLE_TIMEOUT_MEDIUM_PROBE_SEC}"
    run_with_timeout "$timeout_seconds" osascript << 'APPLESCRIPT'
set oldDelimiters to AppleScript's text item delimiters
set tabChar to ASCII character 9
set linefeedChar to ASCII character 10
set outputLines to {}

tell application "System Events"
    repeat with loginItem in login items
        set itemName to ""
        set itemPath to ""

        try
            set itemName to name of loginItem as text
        end try

        try
            set itemPath to POSIX path of (path of loginItem as alias)
        on error
            try
                set itemPath to path of loginItem as text
            end try
        end try

        set end of outputLines to itemName & tabChar & itemPath
    end repeat
end tell

set AppleScript's text item delimiters to linefeedChar
set outputText to outputLines as text
set AppleScript's text item delimiters to oldDelimiters
return outputText
APPLESCRIPT
}

_login_item_debug() {
    if [[ "${MO_DEBUG:-}" == "1" ]] && declare -f debug_log > /dev/null 2>&1; then
        debug_log "Login item audit: $*"
    fi
}

_login_item_name_matches() {
    local actual="$1"
    local expected="$2"
    local expected_nospace="$3"
    local expected_stripped="$4"

    [[ -z "$actual" ]] && return 1

    local actual_nospace="${actual// /}"
    local nocasematch_state
    nocasematch_state=$(shopt -p nocasematch || true)
    shopt -s nocasematch
    local matched=false
    if [[ "$actual" == "$expected" || "$actual_nospace" == "$expected_nospace" ||
        (-n "$expected_stripped" && "$actual_nospace" == "$expected_stripped") ]]; then
        matched=true
    fi
    eval "$nocasematch_state"
    [[ "$matched" == "true" ]]
}

_login_item_build_metadata_inventory() {
    local app_scan_file="$1"
    local metadata_file="$2"
    local deadline_seconds="$3"
    local probe_timeout=""
    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_HINT_SCAN_SEC" "$deadline_seconds") || return $?

    : > "$metadata_file" || return 2
    local metadata_rc=0
    # One bounded worker owns all per-plist subprocesses. Wrapping hundreds of
    # individual plutil calls makes the Perl timeout fallback itself dominate
    # the audit; the outer process-group timeout still kills a stalled child and
    # the caller discards the entire partial record stream on any failure.
    # shellcheck disable=SC2016 # The child expands its own positional data.
    run_with_timeout "$probe_timeout" /bin/bash --noprofile --norc -c '
        while IFS= read -r -d "" app_path; do
            info="$app_path/Contents/Info.plist"
            state=ready
            display_name=""
            bundle_name=""
            executable=""
            if [[ ! -f "$info" ]]; then
                state=missing
            elif [[ ! -r "$info" ]]; then
                state=unreadable
            elif ! /usr/bin/plutil -lint "$info" > /dev/null 2>&1; then
                state=invalid
            else
                display_name=$(/usr/bin/plutil -extract CFBundleDisplayName raw "$info" 2> /dev/null || true)
                bundle_name=$(/usr/bin/plutil -extract CFBundleName raw "$info" 2> /dev/null || true)
                executable=$(/usr/bin/plutil -extract CFBundleExecutable raw "$info" 2> /dev/null || true)
            fi
            printf "%s\0%s\0%s\0%s\0%s\0" \
                "$app_path" "$state" "$display_name" "$bundle_name" "$executable"
        done
    ' < "$app_scan_file" > "$metadata_file" 2> /dev/null || metadata_rc=$?
    if [[ $metadata_rc -ne 0 ]]; then
        : > "$metadata_file" || true
        return "$metadata_rc"
    fi
    return 0
}

_login_item_build_app_inventory() {
    local inventory_file="$1"
    local deadline_seconds="$2"
    local app_scan_file=""
    local root_metadata_file=""
    if ! app_scan_file=$(mktemp_file "optimize-login-item-paths") ||
        ! root_metadata_file=$(mktemp_file "optimize-login-item-root-metadata"); then
        return 2
    fi

    : > "$inventory_file" || return 2
    local -a inventory_roots=("$HOME/Applications" "/Applications")
    if declare -p _MOLE_BUNDLE_RESOLVER_APP_ROOTS > /dev/null 2>&1; then
        local configured_root already_listed
        for configured_root in "${_MOLE_BUNDLE_RESOLVER_APP_ROOTS[@]}"; do
            already_listed=false
            local listed_root
            for listed_root in "${inventory_roots[@]}"; do
                if [[ "$configured_root" == "$listed_root" ]]; then
                    already_listed=true
                    break
                fi
            done
            if [[ "$already_listed" != "true" ]]; then
                inventory_roots+=("$configured_root")
            fi
        done
    fi

    local -a scanned_roots=()
    local roots probe_timeout probe_rc metadata_rc
    # User-installed apps are usually the smaller tree and must not sit behind
    # a large /Applications traversal that can consume the whole shared budget.
    for roots in "${inventory_roots[@]}"; do
        [[ -d "$roots" ]] || continue
        local covered_by_parent=false
        local scanned_root
        if [[ ${#scanned_roots[@]} -gt 0 ]]; then
            for scanned_root in "${scanned_roots[@]}"; do
                if [[ "$roots" == "$scanned_root"/* ]]; then
                    covered_by_parent=true
                    break
                fi
            done
        fi
        [[ "$covered_by_parent" == "true" ]] && continue
        scanned_roots+=("$roots")
        : > "$app_scan_file" || return 2
        probe_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || return $?
        probe_rc=0
        run_with_timeout "$probe_timeout" find "$roots" -maxdepth 6 \
            -type d -iname "*.app" -print0 > "$app_scan_file" 2> /dev/null || probe_rc=$?
        if [[ $probe_rc -ne 0 ]]; then
            : > "$inventory_file" || true
            if [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]]; then
                return "$probe_rc"
            fi
            return 2
        fi

        metadata_rc=0
        _login_item_build_metadata_inventory \
            "$app_scan_file" "$root_metadata_file" \
            "$deadline_seconds" || metadata_rc=$?
        if [[ $metadata_rc -ne 0 ]]; then
            : > "$inventory_file" || true
            if [[ $metadata_rc -eq 124 || $metadata_rc -ge 128 ]]; then
                return "$metadata_rc"
            fi
            return 2
        fi
        if ! command cat "$root_metadata_file" >> "$inventory_file"; then
            : > "$inventory_file" || true
            return 2
        fi
    done
    return 0
}

# Check if a login item name corresponds to an installed app.
# Login item names often differ from .app bundle names (e.g. "AliLangClient" -> "AliLang.app",
# "Top Calendar" -> "TopCalendar.app"), so we try multiple matching strategies.
_login_item_app_exists() {
    local name="$1"
    local item_path="${2:-}"
    local deadline_seconds="${3:-$((SECONDS + MOLE_TIMEOUT_HINT_SCAN_SEC))}"
    local app_inventory_file="${4:-}"

    if [[ -n "$item_path" ]]; then
        if [[ -e "$item_path" || -L "$item_path" ]]; then
            _login_item_debug "'$name' resolved by login item path: $item_path"
            return 0
        fi
        _login_item_debug "'$name' login item path is missing: $item_path"
    else
        _login_item_debug "'$name' has no login item path from System Events"
    fi

    # Display names often need a no-space or helper-suffix variant. Query each
    # through the shared deadline and keep probe failures distinct from a clean
    # no-match result.
    local nospace="${name// /}"
    local stripped
    stripped=$(echo "$nospace" | sed -E 's/(Client|Helper|Agent|Launcher|Service)$//')
    local -a lookup_names=("$name")
    [[ "$nospace" != "$name" ]] && lookup_names+=("$nospace")
    [[ "$stripped" != "$nospace" ]] && lookup_names+=("$stripped")

    local probe_uncertain=false
    local lookup_name spotlight_output probe_timeout probe_rc
    for lookup_name in "${lookup_names[@]}"; do
        [[ "$lookup_name" != *"'"* ]] || continue
        probe_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || return $?
        spotlight_output=""
        probe_rc=0
        spotlight_output=$(run_with_timeout "$probe_timeout" \
            mdfind "kMDItemFSName == '${lookup_name}.app'" 2> /dev/null) || probe_rc=$?
        if [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]]; then
            return "$probe_rc"
        elif [[ $probe_rc -ne 0 ]]; then
            probe_uncertain=true
        elif [[ -n "$spotlight_output" ]]; then
            _login_item_debug "'$name' resolved by Spotlight app name '$lookup_name'"
            return 0
        fi
    done

    # The audit caller supplies one complete inventory for every unresolved
    # item. Standalone callers build the same plan once for this lookup.
    if [[ -z "$app_inventory_file" ]]; then
        if ! app_inventory_file=$(mktemp_file "optimize-login-item-inventory"); then
            return 2
        fi
        local inventory_rc=0
        _login_item_build_app_inventory \
            "$app_inventory_file" "$deadline_seconds" || inventory_rc=$?
        if [[ $inventory_rc -ne 0 ]]; then
            return "$inventory_rc"
        fi
    elif [[ ! -f "$app_inventory_file" ]]; then
        return 2
    fi

    local app_path app_basename metadata_state display_name bundle_name executable
    local record_complete=true
    while IFS= read -r -d '' app_path; do
        if ! IFS= read -r -d '' metadata_state ||
            ! IFS= read -r -d '' display_name ||
            ! IFS= read -r -d '' bundle_name ||
            ! IFS= read -r -d '' executable; then
            record_complete=false
            break
        fi
        if [[ ! -e "$app_path" && ! -L "$app_path" ]]; then
            probe_uncertain=true
            continue
        fi
        app_basename="${app_path##*/}"
        app_basename="${app_basename%.[aA][pP][pP]}"
        if _login_item_name_matches "$app_basename" "$name" "$nospace" "$stripped"; then
            _login_item_debug "'$name' resolved by filesystem app name: $app_path"
            return 0
        fi
        if [[ "$metadata_state" == "unreadable" || "$metadata_state" == "invalid" ]]; then
            probe_uncertain=true
            continue
        fi
        if _login_item_name_matches "$display_name" "$name" "$nospace" "$stripped" ||
            _login_item_name_matches "$bundle_name" "$name" "$nospace" "$stripped" ||
            _login_item_name_matches "$executable" "$name" "$nospace" "$stripped"; then
            _login_item_debug "'$name' matched bundle metadata at $app_path"
            return 0
        fi
    done < "$app_inventory_file"
    if [[ "$record_complete" != "true" ]]; then
        probe_uncertain=true
    fi

    # Last fallback: check sfltool dumpbtm for the actual on-disk path.
    #    Nested helper apps (e.g. DBnginMenuHelper.app inside DBngin.app) are
    #    invisible to mdfind but still have a valid URL in the BTM database.
    #    Root only: unprivileged dumpbtm pops the macOS "sfltool wants to
    #    make changes" admin-password dialog, so without an active sudo
    #    session this fallback is skipped rather than prompting.
    local btm_path=""
    if [[ "${MOLE_TEST_MODE:-0}" != "1" && "${MOLE_TEST_NO_AUTH:-0}" != "1" ]]; then
        local sudo_ready_rc=0
        probe_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || return $?
        run_with_timeout "$probe_timeout" sudo -n true 2> /dev/null || sudo_ready_rc=$?
        if [[ $sudo_ready_rc -eq 124 || $sudo_ready_rc -ge 128 ]]; then
            return "$sudo_ready_rc"
        elif [[ $sudo_ready_rc -eq 0 ]]; then
            local btm_output=""
            probe_timeout=$(_mole_timeout_with_deadline \
                "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || return $?
            probe_rc=0
            btm_output=$(run_with_timeout "$probe_timeout" \
                sudo -n sfltool dumpbtm 2> /dev/null) || probe_rc=$?
            if [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]]; then
                return "$probe_rc"
            elif [[ $probe_rc -ne 0 ]]; then
                probe_uncertain=true
            else
                btm_path=$(printf '%s\n' "$btm_output" | awk -v item="$name" '
        BEGIN { IGNORECASE = 1 }
        index($0, item) {
            if (match($0, "/.*\\.app")) {
                print substr($0, RSTART, RLENGTH)
                exit
            }
        }
    ')
            fi
        fi
    fi
    if [[ -n "$btm_path" ]] && [[ -e "$btm_path" ]]; then
        _login_item_debug "'$name' resolved by sfltool BTM path: $btm_path"
        return 0
    fi
    if [[ "$probe_uncertain" == "true" ]]; then
        _login_item_debug "'$name' unresolved because at least one owner probe was incomplete"
        return 2
    fi
    _login_item_debug "'$name' unresolved after path, Spotlight, filesystem, and BTM checks"
    return 1
}

opt_login_items_audit() {
    if [[ "${MOLE_TEST_NO_AUTH:-0}" == "1" ]]; then
        opt_msg "登录项审计 · 测试模式下已跳过"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        return 0
    fi

    local audit_deadline=$((SECONDS + MOLE_TIMEOUT_HINT_SCAN_SEC))
    local snapshot_timeout=""
    local snapshot_status=0
    snapshot_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$audit_deadline") || snapshot_status=$?
    local items_output=""
    if [[ $snapshot_status -eq 0 ]]; then
        items_output=$(_login_items_snapshot "$snapshot_timeout" 2> /dev/null) || snapshot_status=$?
    fi

    if [[ $snapshot_status -ne 0 ]]; then
        if [[ $snapshot_status -eq 124 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查登录项（快照超时）"
        elif [[ $snapshot_status -ge 128 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查登录项（快照被中断）"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 无法检查登录项"
        fi
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        if [[ $snapshot_status -ge 128 ]]; then
            return "$snapshot_status"
        fi
        return 0
    fi

    if [[ -z "$items_output" ]]; then
        opt_msg "未找到登录项"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
        return 0
    fi

    local -a login_item_names=()
    local -a login_item_paths=()
    local item item_path
    while IFS=$'\t' read -r item item_path; do
        [[ -z "$item" ]] && continue
        login_item_names+=("$item")
        login_item_paths+=("$item_path")
    done <<< "$items_output"

    local app_inventory_file=""
    local inventory_needed=false
    local item_index
    for ((item_index = 0; item_index < ${#login_item_names[@]}; item_index++)); do
        item_path="${login_item_paths[$item_index]:-}"
        if [[ -z "$item_path" || (! -e "$item_path" && ! -L "$item_path") ]]; then
            inventory_needed=true
            break
        fi
    done
    if [[ "$inventory_needed" == "true" ]]; then
        if ! app_inventory_file=$(mktemp_file "optimize-login-item-inventory"); then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 登录项检查不完整（无法准备应用清单；未给出结论）"
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
            return 0
        fi
        local inventory_status=0
        _login_item_build_app_inventory \
            "$app_inventory_file" "$audit_deadline" || inventory_status=$?
        if [[ $inventory_status -ne 0 ]]; then
            if [[ $inventory_status -eq 124 ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} 登录项检查不完整（应用清单超时；未给出结论）"
            elif [[ $inventory_status -ge 128 ]]; then
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} 登录项检查不完整（应用清单被中断；未给出结论）"
            else
                echo -e "  ${YELLOW}${ICON_WARNING}${NC} 登录项检查不完整（应用清单不可用；未给出结论）"
            fi
            optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
            if [[ $inventory_status -ge 128 ]]; then
                return "$inventory_status"
            fi
            return 0
        fi
    fi

    local broken=0
    local checked=0
    local audit_status=0
    local -a broken_items=()
    local item_status
    for ((item_index = 0; item_index < ${#login_item_names[@]}; item_index++)); do
        item="${login_item_names[$item_index]}"
        item_path="${login_item_paths[$item_index]:-}"
        checked=$((checked + 1))
        item_status=0
        _login_item_app_exists \
            "$item" "$item_path" "$audit_deadline" \
            "$app_inventory_file" || item_status=$?
        if [[ $item_status -eq 0 ]]; then
            continue
        elif [[ $item_status -eq 1 ]]; then
            broken_items+=("$item")
            continue
        fi
        audit_status=$item_status
        break
    done

    if [[ $audit_status -ne 0 ]]; then
        if [[ $audit_status -eq 124 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 登录项检查不完整（达到时间限制；未给出结论）"
        elif [[ $audit_status -ge 128 ]]; then
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 登录项检查不完整（探测被中断；未给出结论）"
        else
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 登录项检查不完整（所有者状态未知；未给出结论）"
        fi
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_FAILED"
        if [[ $audit_status -ge 128 ]]; then
            return "$audit_status"
        fi
        return 0
    fi

    if [[ ${#broken_items[@]} -gt 0 ]]; then
        for item in "${broken_items[@]}"; do
            echo -e "  ${YELLOW}${ICON_WARNING}${NC} 损坏的登录项：${item}（未找到应用）"
            broken=$((broken + 1))
        done
    fi

    if [[ $broken -eq 0 ]]; then
        opt_msg "登录项全部正常（已检查 $checked 项）"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_UNCHANGED"
    else
        echo -e "  ${YELLOW}${ICON_WARNING}${NC} $broken 个损坏的登录项 · 请通过 系统设置 > 通用 > 登录项 移除"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_ATTENTION"
    fi
}

# Dispatch optimization by action name.
execute_optimization() {
    local action="$1"

    local handler health_name
    if ! handler=$(optimize_catalog_handler_for "$action"); then
        echo -e "${YELLOW}${ICON_ERROR}${NC} 未知操作：$action"
        return 1
    fi
    health_name=$(optimize_catalog_health_name_for "$action")
    if ! declare -F "$handler" > /dev/null; then
        echo -e "${YELLOW}${ICON_ERROR}${NC} 缺少优化处理程序：$handler"
        return 1
    fi

    if command -v is_whitelisted > /dev/null && is_whitelisted "$action"; then
        optimize_task_start
        opt_msg "已跳过（白名单）：$health_name"
        optimize_task_result "$MOLE_OPTIMIZE_OUTCOME_SKIPPED"
        optimize_task_finish "$action"
        return 0
    fi

    optimize_task_start
    "$handler"
    optimize_task_finish "$action"
}
