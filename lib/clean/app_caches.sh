#!/bin/bash
# User GUI Applications Cleanup Module (desktop apps, media, utilities).
set -euo pipefail

_xcode_cleanup_process_state() {
    xcode_build_tooling_process_state
}

_simulator_cleanup_process_state() {
    if declare -f _coresimulator_activity_state > /dev/null 2>&1; then
        _coresimulator_activity_state
        return $?
    fi

    mole_pgrep_any \
        -x "Xcode" \
        -x "Simulator" \
        -x "xcodebuild" \
        -x "xctest" \
        -x "XCTRunner"
}

_xcode_cleanup_skip_reason() {
    if [[ "$1" -eq 0 ]]; then
        printf 'Xcode or build tooling running\n'
    else
        printf 'process state unknown\n'
    fi
}

_app_cache_cleanup_directories_exist() {
    local target
    for target in "$@"; do
        [[ -d "$target" ]] || continue
        if declare -f should_protect_path > /dev/null 2>&1 && should_protect_path "$target" 2> /dev/null; then
            continue
        fi
        if declare -f is_path_whitelisted > /dev/null 2>&1 && is_path_whitelisted "$target" 2> /dev/null; then
            continue
        fi
        if declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$target" 2> /dev/null; then
            continue
        fi
        return 0
    done
    return 1
}

_xcode_app_cache_delete_guard_allows() {
    # Same mapping _xcode_cleanup_skip_reason applies (state 0 running, state 2
    # unknown; state 1 already returned), without its command substitution. The
    # scan-stage callers still use that helper, where one fork per section is
    # free; this one runs per delete candidate.
    mole_clean_process_guard _xcode_cleanup_process_state "Xcode or build tooling running"
}

_simulator_app_cache_delete_guard_allows() {
    mole_clean_process_guard _simulator_cleanup_process_state "Simulator or CoreSimulator running"
}

_final_cut_pro_delete_guard_allows() {
    mole_clean_process_guard final_cut_pro_is_running "Final Cut Pro started"
}

_defer_app_cache_guard_family() {
    case "$1" in
        _simulator_app_cache_delete_guard_allows) mole_defer_cleanup_family "Simulator" ;;
        _final_cut_pro_delete_guard_allows) mole_defer_cleanup_family "Final Cut Pro" ;;
        _autodesk_cache_delete_guard_allows) mole_defer_cleanup_family "Autodesk" ;;
        *) mole_defer_cleanup_family "Xcode" ;;
    esac
}

_app_cache_safe_clean_guarded() {
    local delete_guard="$1"
    local display_name="$2"
    shift 2
    local _MOLE_CLEAN_GUARD_REASON="process state changed"

    if ! declare -f safe_clean_guarded > /dev/null 2>&1; then
        if ! "$delete_guard"; then
            mole_report_guard_stop "$display_name" _defer_app_cache_guard_family "$delete_guard"
            return 1
        fi
        safe_clean "$@"
        return $?
    fi

    local guarded_rc=0
    safe_clean_guarded "$delete_guard" "$@" || guarded_rc=$?
    if [[ $guarded_rc -eq 75 ]]; then
        mole_report_guard_stop "$display_name" _defer_app_cache_guard_family "$delete_guard"
        return 1
    fi
    return "$guarded_rc"
}

# Xcode DerivedData cleanup with project count and size reporting.
# Fully regenerated on next build, safe to remove.
clean_xcode_derived_data() {
    local dd_dir="$HOME/Library/Developer/Xcode/DerivedData"

    [[ -d "$dd_dir" ]] || return 0

    # Count projects before recording an active-process skip, so an empty
    # DerivedData root stays silent.
    local -a projects=()
    local dir
    for dir in "$dd_dir"/*; do
        [[ -d "$dir" ]] || continue
        if should_protect_path "$dir" || is_path_whitelisted "$dir" || holds_compiled_model_cache "$dir"; then
            continue
        fi
        projects+=("$dir")
    done

    local project_count=${#projects[@]}
    [[ $project_count -eq 0 ]] && return 0

    # Only a conclusive "no matching process" result authorizes cleanup.
    local xcode_state=0
    _xcode_cleanup_process_state || xcode_state=$?
    if [[ $xcode_state -ne 1 ]]; then
        if [[ $xcode_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode DerivedData · 已跳过（进程状态未知）"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
        return 0
    fi

    local project_label="个项目"
    [[ $project_count -eq 1 ]] && project_label="个项目"

    if [[ "${DRY_RUN:-false}" == "true" ]]; then
        # Measure and register only the filtered project set. Sizing the parent
        # would include protected or whitelisted siblings that real cleanup
        # intentionally leaves untouched.
        local size_kb=0
        local dir_size_kb=0
        local dry_run_count=0
        local dry_run_stopped_reason=""
        local dry_run_seen=0
        # Sizing every project means one du per entry plus a process probe on
        # each side of it. On a real DerivedData that is tens of seconds with
        # nothing on screen, which reads as a freeze.
        start_section_spinner "正在测量 Xcode DerivedData，0/${project_count}..."
        for dir in "${projects[@]}"; do
            dry_run_seen=$((dry_run_seen + 1))
            start_section_spinner "正在测量 Xcode DerivedData，${dry_run_seen}/${project_count}..."
            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                dry_run_stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
                break
            fi
            local size_rc=0
            dir_size_kb=$(get_path_size_kb "$dir" 2> /dev/null) || size_rc=$?
            if [[ $size_rc -ne 0 ]]; then
                stop_section_spinner
                _mole_record_clean_cancellation "$size_rc"
                return "$size_rc"
            fi
            [[ "$dir_size_kb" =~ ^[0-9]+$ ]] || dir_size_kb=0
            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                dry_run_stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
                break
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$dir" "$dir_size_kb" 1 true || continue
            fi
            size_kb=$((size_kb + dir_size_kb))
            dry_run_count=$((dry_run_count + 1))
        done
        stop_section_spinner
        if [[ $dry_run_count -gt 0 ]]; then
            project_label="个项目"
            [[ $dry_run_count -eq 1 ]] && project_label="个项目"
            local size_human
            size_human=$(bytes_to_human "$((size_kb * 1024))")
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Xcode DerivedData · ${dry_run_count} ${project_label}，${size_human}"
            note_activity
        fi
        if [[ -n "$dry_run_stopped_reason" ]]; then
            if [[ "$dry_run_stopped_reason" == "process state unknown" ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode DerivedData · 已停止（进程状态未知）"
                note_activity
            else
                mole_defer_cleanup_family "Xcode"
            fi
        fi
        return 0
    fi

    # Remove all project build dirs using safe_remove.
    local removed=0
    local removed_size_kb=0
    local stopped_reason=""
    local seen=0
    # Each project costs a du, two process probes, and the removal itself, so a
    # large DerivedData runs for tens of seconds. Without this the section
    # prints nothing until every project is gone.
    start_section_spinner "正在移除 Xcode DerivedData，0/${project_count}..."
    for dir in "${projects[@]}"; do
        seen=$((seen + 1))
        start_section_spinner "正在移除 Xcode DerivedData，${seen}/${project_count}..."
        xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -ne 1 ]]; then
            stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
            break
        fi

        local dir_size_kb=0
        local size_rc=0
        dir_size_kb=$(get_path_size_kb "$dir" 2> /dev/null) || size_rc=$?
        if [[ $size_rc -ne 0 ]]; then
            stop_section_spinner
            _mole_record_clean_cancellation "$size_rc"
            return "$size_rc"
        fi
        [[ "$dir_size_kb" =~ ^[0-9]+$ ]] || dir_size_kb=0

        # Sizing is timeout-bounded but can still take long enough for a build
        # to start. Recheck at the deletion boundary, not only before du.
        xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -ne 1 ]]; then
            stopped_reason=$(_xcode_cleanup_skip_reason "$xcode_state")
            break
        fi
        if safe_remove "$dir" "true" "$dir_size_kb"; then
            removed=$((removed + 1))
            removed_size_kb=$((removed_size_kb + dir_size_kb))
        fi
    done
    stop_section_spinner

    if [[ $removed -gt 0 ]]; then
        project_label="个项目"
        [[ $removed -eq 1 ]] && project_label="个项目"
        local size_human
        size_human=$(bytes_to_human "$((removed_size_kb * 1024))")
        local line_color
        line_color=$(cleanup_result_color_kb "$removed_size_kb" 2> /dev/null || echo "$GREEN")
        echo -e "  ${line_color}${ICON_SUCCESS}${NC} Xcode DerivedData · ${removed} ${project_label}，${line_color}${size_human}${NC}"
        files_cleaned=$((${files_cleaned:-0} + removed))
        total_size_cleaned=$((${total_size_cleaned:-0} + removed_size_kb))
        total_items=$((${total_items:-0} + 1))
        note_activity
    fi
    if [[ -n "$stopped_reason" ]]; then
        if [[ "$stopped_reason" == "process state unknown" ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode DerivedData · 已停止（进程状态未知）"
            note_activity
        else
            mole_defer_cleanup_family "Xcode"
        fi
    fi
}
# Xcode and iOS tooling.
clean_xcode_tools() {
    local simulator_has_targets=false
    if mole_cleanup_targets_exist \
        "$HOME/Library/Developer/CoreSimulator/Caches"/* \
        "$HOME/Library/Developer/CoreSimulator/Devices"/*/data/tmp/* \
        "$HOME/Library/Logs/CoreSimulator"/*; then
        simulator_has_targets=true
    fi

    if [[ "$simulator_has_targets" == "true" ]]; then
        # Probe errors are unknown, never permission to clean active tool state.
        local simulator_state=0
        _simulator_cleanup_process_state || simulator_state=$?
        if [[ $simulator_state -eq 1 ]]; then
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "模拟器缓存" \
                ~/Library/Developer/CoreSimulator/Caches/* \
                "模拟器缓存" || return 0
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "模拟器临时文件" \
                ~/Library/Developer/CoreSimulator/Devices/*/data/tmp/* \
                "模拟器临时文件" || return 0
            _app_cache_safe_clean_guarded \
                _simulator_app_cache_delete_guard_allows \
                "CoreSimulator 日志" \
                ~/Library/Logs/CoreSimulator/* \
                "CoreSimulator 日志" || return 0
        else
            if [[ $simulator_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} 模拟器缓存 · 已跳过（进程状态未知）"
                note_activity
            else
                mole_defer_cleanup_family "Simulator"
            fi
        fi
    fi

    local xcode_cache_has_targets=false
    local xcode_build_has_targets=false
    mole_cleanup_targets_exist \
        "$HOME/Library/Caches/com.apple.dt.Xcode"/* && xcode_cache_has_targets=true
    if mole_cleanup_targets_exist "$HOME/Library/Developer/Xcode/Products"/* ||
        _app_cache_cleanup_directories_exist "$HOME/Library/Developer/Xcode/DerivedData"/*; then
        xcode_build_has_targets=true
    fi

    if [[ "$xcode_cache_has_targets" == "true" || "$xcode_build_has_targets" == "true" ]]; then
        local xcode_state=0
        _xcode_cleanup_process_state || xcode_state=$?
        if [[ $xcode_state -eq 1 ]]; then
            if [[ "$xcode_cache_has_targets" == "true" ]]; then
                _app_cache_safe_clean_guarded \
                    _xcode_app_cache_delete_guard_allows \
                    "Xcode 缓存" \
                    ~/Library/Caches/com.apple.dt.Xcode/* \
                    "Xcode 缓存" || return 0
            fi

            # The cache pass may take long enough for the separate build
            # candidates to disappear. Revalidate before another process gate
            # so a completed cache-only pass never reports a deferred build.
            xcode_build_has_targets=false
            if mole_cleanup_targets_exist "$HOME/Library/Developer/Xcode/Products"/* ||
                _app_cache_cleanup_directories_exist "$HOME/Library/Developer/Xcode/DerivedData"/*; then
                xcode_build_has_targets=true
            fi
            [[ "$xcode_build_has_targets" == "true" ]] || return 0

            xcode_state=0
            _xcode_cleanup_process_state || xcode_state=$?
            if [[ $xcode_state -ne 1 ]]; then
                if [[ $xcode_state -eq 2 ]]; then
                    echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode 构建产物/DerivedData · 已停止（进程状态未知）"
                    note_activity
                else
                    mole_defer_cleanup_family "Xcode"
                fi
                return 0
            fi
            _app_cache_safe_clean_guarded \
                _xcode_app_cache_delete_guard_allows \
                "Xcode 构建产物" \
                ~/Library/Developer/Xcode/Products/* \
                "Xcode 构建产物" || return 0
            clean_xcode_derived_data || return $?
        else
            if [[ $xcode_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Xcode 缓存/构建产物 · 已跳过（进程状态未知）"
                note_activity
            else
                mole_defer_cleanup_family "Xcode"
            fi
        fi
    fi
}
# The directory names an editor's `.obsolete` journal marks stale, one per line.
#
# Reads the XML plutil emits rather than the `plutil -p` rendering an earlier
# fix parsed. `man plutil` says of `-p`: "The output format is not stable and
# not designed for machine parsing", and it is not. macOS 15 prints a JSON
# boolean true as `1` while macOS 26 and 27 print `true`, so a filter pinned to
# one spelling silently cleans nothing on the other (tw93/Mole#1512), and where
# a boolean prints as `1` no filter can tell it from the integer 1 at all.
#
# That rendering is also depth-blind, which is the worse half: its keys carry
# no nesting, so `{"outer":{"inner":true}}` handed back `inner` as a top-level
# extension directory. That is a wrong deletion, not a missed one.
#
# In the XML, depth is explicit and each type is its own tag, so a key counts
# only when it sits in the root dict and its value is exactly `<true/>`. Empty
# containers are self-closing (`<dict/>`, `<array/>`) and must not move the
# depth, so every tag is compared for equality rather than by prefix.
_mole_obsolete_extension_keys() {
    local obsolete_file="$1"
    plutil -convert xml1 -o - "$obsolete_file" 2> /dev/null | awk '
        # &amp; is decoded LAST: a key holding the literal text "&lt;" arrives
        # as "&amp;lt;", and decoding &amp; first would turn it into a real "<".
        function decode(s) {
            gsub(/&lt;/, "<", s)
            gsub(/&gt;/, ">", s)
            gsub(/&amp;/, "\\&", s)
            return s
        }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "<dict>" || line == "<array>") { depth++; pending = ""; next }
            if (line == "</dict>" || line == "</array>") { depth--; pending = ""; next }
            if (depth == 1 && line ~ /^<key>.*<\/key>$/) {
                pending = substr(line, 6, length(line) - 11)
                next
            }
            if (depth == 1 && pending != "") {
                if (line == "<true/>") print decode(pending)
                pending = ""
                next
            }
            pending = ""
        }
    '
}

# Remove extension directories that VS Code / Cursor have marked obsolete.
# Each editor writes a .obsolete JSON file under its extensions root whose keys
# are stale extension directory names left behind after an extension update.
clean_editor_obsolete_extensions() {
    local -a editor_roots=(
        "$HOME/.vscode/extensions|VS Code"
        "$HOME/.vscode-insiders/extensions|VS Code Insiders"
        "$HOME/.cursor/extensions|Cursor"
    )
    local entry ext_root editor_label obsolete_file key target
    for entry in "${editor_roots[@]}"; do
        ext_root="${entry%%|*}"
        editor_label="${entry##*|}"
        obsolete_file="$ext_root/.obsolete"
        [[ -f "$obsolete_file" ]] || continue

        while IFS= read -r key; do
            # Each key must be a plain direct-child directory name; reject
            # anything that could escape the extensions root.
            case "$key" in
                "" | "." | ".." | */*) continue ;;
            esac
            target="$ext_root/$key"
            [[ -d "$target" ]] || continue
            safe_clean "$target" "过期的 $editor_label 扩展"
        done < <(_mole_obsolete_extension_keys "$obsolete_file")
    done
}
# Code editors.
clean_code_editors() {
    safe_clean ~/Library/Application\ Support/Code/logs/* "VS Code 日志"
    safe_clean ~/Library/Application\ Support/Code/Cache/* "VS Code 缓存"
    safe_clean ~/Library/Application\ Support/Code/CachedExtensions/* "VS Code 扩展缓存"
    safe_clean ~/Library/Application\ Support/Code/CachedData/* "VS Code 数据缓存"
    safe_clean ~/Library/Application\ Support/Code/WebStorage/*/CacheStorage/* "VS Code WebView 缓存"
    safe_clean ~/Library/Caches/com.sublimetext.*/* "Sublime Text 缓存"
    safe_clean ~/Library/Caches/Zed/* "Zed 缓存"
    # Zed npm caches: node/cache (system-node scratch) and node/node-v*/cache
    # (per-version managed runtime, see #88); keep editor state under db/ untouched.
    safe_clean ~/Library/Application\ Support/Zed/node/cache/* "Zed npm 缓存"
    safe_clean ~/Library/Application\ Support/Zed/node/node-v*/cache/* "Zed npm 缓存"
    safe_clean ~/Library/Logs/Zed/* "Zed 日志"
    clean_editor_obsolete_extensions
    # CodeBuddy Extension (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/CodeBuddyExtension ]]; then
        safe_clean ~/Library/Application\ Support/CodeBuddyExtension/Cache/* "CodeBuddy Extension 缓存"
        safe_clean ~/Library/Application\ Support/CodeBuddyExtension/logs/* "CodeBuddy Extension 日志"
    fi
    # CodeBuddy CN (VS Code fork, Electron)
    if [[ -d ~/Library/Application\ Support/CodeBuddy\ CN ]]; then
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/Cache/* "CodeBuddy CN 缓存"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/CachedData/* "CodeBuddy CN 缓存数据"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/CachedExtensionVSIXs/* "CodeBuddy CN 扩展缓存"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/Code\ Cache/* "CodeBuddy CN 代码缓存"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/GPUCache/* "CodeBuddy CN GPU 缓存"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/DawnGraphiteCache/* "CodeBuddy CN Dawn 缓存"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/DawnWebGPUCache/* "CodeBuddy CN WebGPU 缓存"
        safe_clean ~/Library/Application\ Support/CodeBuddy\ CN/logs/* "CodeBuddy CN 日志"
    fi
}
# Lark / Feishu desktop embeds a Chromium webview (the "aha" explorer profile)
# to render its in-app docs, sheets, slides, and AI surfaces. Every workspace
# origin the user opens precaches the full editor bundle into that profile's
# Service Worker CacheStorage, and stale workspaces plus superseded precache
# versions are never evicted, so it grows without bound (measured at 27GB across
# nine origin buckets on a heavy user's machine, oldest files ~11 months old).
# This lives at a non-standard path the browser cleaners never reach.
#
# Reuse the shared Service Worker cleaner so the same per-origin-hash iteration,
# PROTECTED_SW_DOMAINS skip, user-whitelist honoring, and safe_remove funnel that
# Chrome and Arc get apply here unchanged. Only CacheStorage is targeted, never
# the sibling ScriptCache (MV3 worker bytecode). Documents live on Lark's
# servers and auth lives in Cookies / Local Storage, neither of which this path
# touches; a cleared editor bundle is re-precached on next open.
feishu_or_lark_running() {
    mole_pgrep_any \
        -x "Feishu" \
        -x "Lark" \
        -f '/(Feishu|Lark)[.]app/'
}

_feishu_service_worker_delete_guard_allows() {
    mole_clean_process_guard feishu_or_lark_running "Feishu or Lark started"
}

clean_feishu_service_worker_caches() {
    local -a sw_roots=(
        "$HOME/Library/Application Support/LarkShell/aha/users"
        "$HOME/Library/Application Support/LarkInternational/aha/users"
    )
    local -a root_labels=("Feishu" "Lark")
    local -a cache_paths=()
    local -a cache_labels=()
    local root_index sw_root app_label physical_root _profile cache_path physical_cache
    for ((root_index = 0; root_index < ${#sw_roots[@]}; root_index++)); do
        sw_root="${sw_roots[$root_index]}"
        app_label="${root_labels[$root_index]}"
        [[ -d "$sw_root" ]] || continue
        physical_root=$(cd -P "$sw_root" 2> /dev/null && pwd -P) || continue
        if [[ "$physical_root" != "$sw_root" ]]; then
            debug_log "Refusing symlinked ${app_label} profile root: $sw_root -> $physical_root"
            continue
        fi
        for _profile in "$sw_root"/*/profile_explorer; do
            [[ -d "$_profile" ]] || continue
            cache_path="${_profile%/}/Service Worker/CacheStorage"
            [[ -d "$cache_path" ]] || continue
            physical_cache=$(cd -P "$cache_path" 2> /dev/null && pwd -P) || continue
            if [[ "$physical_cache" != "$cache_path" ]]; then
                debug_log "Refusing symlinked ${app_label} Service Worker cache: $cache_path -> $physical_cache"
                continue
            fi
            cache_paths+=("$cache_path")
            cache_labels+=("$app_label")
        done
    done
    [[ ${#cache_paths[@]} -gt 0 ]] || return 0

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! _feishu_service_worker_delete_guard_allows; then
        mole_report_guard_stop "Feishu/Lark Service Worker" \
            mole_defer_cleanup_family "Feishu/Lark"
        return 0
    fi

    local cleanup_deadline=$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))
    local cache_index guarded_rc=0
    for ((cache_index = 0; cache_index < ${#cache_paths[@]}; cache_index++)); do
        app_label="${cache_labels[$cache_index]}"
        cache_path="${cache_paths[$cache_index]}"
        guarded_rc=0
        clean_service_worker_cache "$app_label" "$cache_path" \
            _feishu_service_worker_delete_guard_allows \
            "$cleanup_deadline" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            mole_report_guard_stop "Feishu/Lark Service Worker" \
                mole_defer_cleanup_family "Feishu/Lark"
            return 0
        fi
        [[ $guarded_rc -eq 0 ]] || return "$guarded_rc"
    done
}
# Notion's desktop app renders the workspace in an Electron partition
# (`Partitions/<name>/`), and the web app it loads there is a service worker
# app: every workspace, page bundle, and asset version it precaches lands in
# that partition's CacheStorage and is never evicted, so it grows without
# bound. The partition sits under Application Support, which no browser
# cleaner walks, and `~/Library/Caches/notion.id` above reaches none of it.
#
# Value is the reporter's, not measured here: 5+ GB on their machine (#1587),
# with no Notion install on hand to confirm the reclaim or to check that login
# and workspace load survive it. The partition layout itself was verified
# against the Electron apps present locally, which all place
# `Partitions/<name>/Service Worker/CacheStorage` exactly here.
#
# Same contract as Feishu/Lark: the shared Service Worker cleaner, CacheStorage
# only and never the sibling ScriptCache (#785 #964 #968) or Database, both
# roots refused when reached through a symlink, and the process guard rechecked
# at every sink. Pages live on Notion's servers and auth lives in Cookies /
# Local Storage, neither of which this path touches; a cleared bundle is
# re-precached on next open.
notion_running() {
    mole_pgrep_any \
        -x "Notion" \
        -f '/Notion[.]app/'
}

_notion_service_worker_delete_guard_allows() {
    mole_clean_process_guard notion_running "Notion started"
}

clean_notion_service_worker_caches() {
    local partitions_root="$HOME/Library/Application Support/Notion/Partitions"
    [[ -d "$partitions_root" ]] || return 0
    local physical_root
    physical_root=$(cd -P "$partitions_root" 2> /dev/null && pwd -P) || return 0
    if [[ "$physical_root" != "$partitions_root" ]]; then
        debug_log "Refusing symlinked Notion partitions root: $partitions_root -> $physical_root"
        return 0
    fi

    local -a cache_paths=()
    local _partition cache_path physical_cache
    for _partition in "$partitions_root"/*; do
        [[ -d "$_partition" ]] || continue
        cache_path="${_partition%/}/Service Worker/CacheStorage"
        [[ -d "$cache_path" ]] || continue
        physical_cache=$(cd -P "$cache_path" 2> /dev/null && pwd -P) || continue
        if [[ "$physical_cache" != "$cache_path" ]]; then
            debug_log "Refusing symlinked Notion Service Worker cache: $cache_path -> $physical_cache"
            continue
        fi
        cache_paths+=("$cache_path")
    done
    [[ ${#cache_paths[@]} -gt 0 ]] || return 0

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! _notion_service_worker_delete_guard_allows; then
        mole_report_guard_stop "Notion Service Worker" \
            mole_defer_cleanup_family "Notion"
        return 0
    fi

    local cleanup_deadline=$((SECONDS + MOLE_TIMEOUT_DISK_VERIFY_SEC))
    local cache_index guarded_rc=0
    for ((cache_index = 0; cache_index < ${#cache_paths[@]}; cache_index++)); do
        cache_path="${cache_paths[$cache_index]}"
        guarded_rc=0
        clean_service_worker_cache "Notion" "$cache_path" \
            _notion_service_worker_delete_guard_allows \
            "$cleanup_deadline" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            mole_report_guard_stop "Notion Service Worker" \
                mole_defer_cleanup_family "Notion"
            return 0
        fi
        [[ $guarded_rc -eq 0 ]] || return "$guarded_rc"
    done
}
# WeChat and WeCom ship sandboxed, so their regenerable caches live under
# ~/Library/Containers/<bundle id>/Data/ and the ~/Library/Caches/<bundle id>
# entries above reach nothing on a current install. Same shape as JianyingPro
# (#1277): the app keeps heavy caches outside ~/Library/Caches, so standard
# cleanup never sees them.
#
# Measured on macOS 26.5.2 with WeChat 4.x and WeCom 4.x:
#   ~/Library/Caches/com.tencent.xinWeChat        absent
#   ~/Library/Caches/com.tencent.WeWorkMac        absent
#   WeCom  cefcache/<profile>/Service Worker      482 MB root measured;
#          only its rebuildable CacheStorage descendants are targeted
#   WeCom  cefcache/<profile>/Cache               424 MB
#   WeCom  cefcache/<profile>/Code Cache           48 MB
#   WeCom  Application Support/WXWork/Log          81 MB
#   WeChat Documents/app_data/log                 187 MB
#   WeChat .wxapplet/WMPF                         161 MB
#                                          total ~1.4 GB reclaimed
#
# Non-targets, never removed because they are user data or account state:
#   WeChat Documents/xwechat_files/**       chat databases and received files
#   WeChat Documents/app_data/radium/users  per-account webview state
#   WeCom  Documents/Profiles/*/Messages1   chat messages
#   WeCom  Documents/cefcache/<profile>/    cookies, Account Web Data, login state
#   WeCom  Documents/Profiles/*/Publishsys  distribution payloads, value unmeasured
wechat_running() {
    mole_pgrep_any \
        -x "WeChat" \
        -x "WeChatAppEx" \
        -f '/WeChat[.]app/Contents/MacOS/'
}

wecom_running() {
    # The main executable shipped by current WeCom builds is localized. Keep
    # both exact names and app-bundle paths so the guard also covers older or
    # differently localized installs, plus the short-lived helper processes.
    mole_pgrep_any \
        -x "企业微信" \
        -x "WeCom" \
        -x "WXWork" \
        -x "WeComAgent" \
        -f '/企业微信[.]app/Contents/MacOS/' \
        -f '/WeCom[.]app/Contents/MacOS/' \
        -f '/WeComAgent[.]app/Contents/MacOS/' \
        -f '/Contents/MacOS/wecom-agent'
}

_wechat_container_process_guard_allows() {
    mole_clean_process_guard wechat_running "WeChat started"
}

_wecom_container_process_guard_allows() {
    mole_clean_process_guard wecom_running "WeCom started"
}

_messaging_container_bind_candidate() {
    local path="$1"
    local cache_root="${2%/}"
    local container_data="${3%/}"
    local lexical_parent="${path%/*}"
    [[ "$lexical_parent" == "$cache_root" ]] || return 1
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 1
    [[ -e "$path" && ! -L "$path" ]] || return 1

    local physical_home=""
    local physical_container=""
    local expected_container=""
    local physical_root_parent=""
    local expected_root=""
    physical_home=$(cd -P "$HOME" 2> /dev/null && pwd -P) || return 1
    physical_container=$(cd -P "$container_data" 2> /dev/null && pwd -P) || return 1
    expected_container="${physical_home%/}/${container_data#"$HOME"/}"
    [[ "$physical_container" == "$expected_container" ]] || return 1
    physical_root_parent=$(cd -P "${cache_root%/*}" 2> /dev/null && pwd -P) || return 1
    expected_root="${physical_root_parent%/}/${cache_root##*/}"
    case "$expected_root" in
        "$physical_container"/*) ;;
        *) return 1 ;;
    esac

    _mole_snapshot_path_identity "$path" || return 1
    [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$expected_root" ]] || return 1
    _MOLE_SAFE_CLEAN_BOUND_PATH="$path"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
}

_wechat_container_delete_guard_allows() {
    local path="$1"
    _wechat_container_process_guard_allows || return $?

    local wechat_data="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
    local cache_root="${path%/*}"
    case "$cache_root" in
        "$wechat_data/Documents/app_data/log" | "$wechat_data/.wxapplet/WMPF") ;;
        *) return 1 ;;
    esac
    _messaging_container_bind_candidate "$path" "$cache_root" "$wechat_data"
}

_wecom_container_delete_guard_allows() {
    local path="$1"
    _wecom_container_process_guard_allows || return $?

    local wecom_data="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
    local cache_root="${path%/*}"
    local cef_root="$wecom_data/Documents/cefcache"
    if [[ "$cache_root" != "$wecom_data/Library/Application Support/WXWork/Log" ]]; then
        local relative="${cache_root#"$cef_root"/}"
        local profile="${relative%%/*}"
        local cache_kind="${relative#*/}"
        [[ -n "$profile" && "$profile" != "$relative" ]] || return 1
        [[ "$profile" == "Default" || "$profile" =~ ^wew_[0-9]+$ ]] || return 1
        case "$cache_kind" in
            "Cache" | "Code Cache" | "GPUCache" | "Service Worker/CacheStorage") ;;
            *) return 1 ;;
        esac
    fi
    _messaging_container_bind_candidate "$path" "$cache_root" "$wecom_data"
}

_clean_messaging_container_roots() {
    local family="$1"
    local process_guard="$2"
    local delete_guard="$3"
    shift 3
    [[ $# -gt 0 ]] || return 0

    local -a root_pairs=("$@")
    local has_eligible_targets=false
    local cache_root label
    while [[ $# -ge 2 ]]; do
        cache_root="$1"
        label="$2"
        shift 2
        if [[ -d "$cache_root" && ! -L "$cache_root" ]] &&
            mole_cleanup_targets_exist "$cache_root"/*; then
            has_eligible_targets=true
            break
        fi
    done
    [[ "$has_eligible_targets" == "true" ]] || return 0
    set -- "${root_pairs[@]}"

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! "$process_guard"; then
        mole_report_guard_stop "$family container caches" \
            mole_defer_cleanup_family "$family"
        return 0
    fi

    local _MOLE_SAFE_REMOVE_FINAL_GUARD="$delete_guard"
    local guarded_rc=0
    while [[ $# -ge 2 ]]; do
        cache_root="$1"
        label="$2"
        shift 2
        [[ -d "$cache_root" && ! -L "$cache_root" ]] || continue
        guarded_rc=0
        safe_clean_guarded "$delete_guard" "$cache_root"/* "$label" || guarded_rc=$?
        if [[ $guarded_rc -eq 75 ]]; then
            mole_report_guard_stop "$family container caches" \
                mole_defer_cleanup_family "$family"
            return 0
        fi
        [[ $guarded_rc -eq 0 ]] || return "$guarded_rc"
    done
}

clean_wechat_container_caches() {
    local wechat_data="$HOME/Library/Containers/com.tencent.xinWeChat/Data"
    local wecom_data="$HOME/Library/Containers/com.tencent.WeWorkMac/Data"
    [[ -d "$wechat_data" || -d "$wecom_data" ]] || return 0

    local -a wechat_targets=()
    if [[ -d "$wechat_data" ]]; then
        wechat_targets+=("$wechat_data/Documents/app_data/log" "WeChat logs")
        wechat_targets+=("$wechat_data/.wxapplet/WMPF" "WeChat mini program cache")
        _clean_messaging_container_roots "WeChat" \
            _wechat_container_process_guard_allows \
            _wechat_container_delete_guard_allows \
            "${wechat_targets[@]}"
    fi

    local -a wecom_targets=()
    if [[ -d "$wecom_data" ]]; then
        wecom_targets+=("$wecom_data/Library/Application Support/WXWork/Log" "WeCom logs")
        # cefcache is a Chromium user-data-dir, so most of its children are
        # component-updater payloads (AutofillStates, CertificateRevocation,
        # ...) holding version directories, not per-account profiles. Select a
        # profile by the two observed profile name shapes and by the Chromium
        # cache directories it owns. Refuse a profile reached through a
        # symlink so the sink stays inside the container inspected.
        local profile physical_profile
        for profile in "$wecom_data/Documents/cefcache"/*/; do
            profile="${profile%/}"
            [[ -d "$profile" ]] || continue
            [[ "${profile##*/}" == "Default" || "${profile##*/}" =~ ^wew_[0-9]+$ ]] || continue
            [[ -d "$profile/Cache" || -d "$profile/Service Worker/CacheStorage" ]] || continue
            physical_profile=$(cd -P "$profile" 2> /dev/null && pwd -P) || continue
            if [[ "$physical_profile" != "$profile" ]]; then
                debug_log "Refusing symlinked WeCom cefcache profile: $profile -> $physical_profile"
                continue
            fi
            wecom_targets+=("$profile/Service Worker/CacheStorage" "WeCom service worker cache")
            wecom_targets+=("$profile/Cache" "WeCom web cache")
            wecom_targets+=("$profile/Code Cache" "WeCom code cache")
            wecom_targets+=("$profile/GPUCache" "WeCom GPU cache")
        done
        _clean_messaging_container_roots "WeCom" \
            _wecom_container_process_guard_allows \
            _wecom_container_delete_guard_allows \
            "${wecom_targets[@]}"
    fi
}

# Communication apps.
clean_communication_apps() {
    safe_clean ~/Library/Application\ Support/discord/Cache/* "Discord 缓存"
    safe_clean ~/Library/Application\ Support/legcord/Cache/* "Legcord 缓存"
    safe_clean ~/Library/Application\ Support/Slack/Cache/* "Slack 缓存"
    safe_clean ~/Library/Caches/us.zoom.xos/* "Zoom 缓存"
    safe_clean ~/Library/Caches/com.tencent.xinWeChat/* "微信缓存"
    safe_clean ~/Library/Caches/ru.keepcoder.Telegram/* "Telegram 缓存"

    safe_clean ~/Library/Caches/com.microsoft.teams2/* "Microsoft Teams 缓存"
    safe_clean ~/Library/Caches/net.whatsapp.WhatsApp/* "WhatsApp 缓存"
    safe_clean ~/Library/Caches/com.skype.skype/* "Skype 缓存"
    safe_clean ~/Library/Caches/com.tencent.meeting/* "腾讯会议缓存"
    safe_clean ~/Library/Caches/com.tencent.WeWorkMac/* "企业微信缓存"
    safe_clean ~/Library/Caches/com.tencent.qq/* "QQ 缓存"
    safe_clean ~/Library/Caches/com.feishu.*/* "飞书缓存"
    clean_feishu_service_worker_caches
    clean_notion_service_worker_caches
    if [[ -d ~/Library/Application\ Support/Microsoft/Teams ]]; then
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Cache/* "Microsoft Teams 旧版缓存"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Application\ Cache/* "Microsoft Teams 旧版应用缓存"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/Code\ Cache/* "Microsoft Teams 旧版代码缓存"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/GPUCache/* "Microsoft Teams 旧版 GPU 缓存"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/logs/* "Microsoft Teams 旧版日志"
        safe_clean ~/Library/Application\ Support/Microsoft/Teams/tmp/* "Microsoft Teams 旧版临时文件"
    fi
    clean_wechat_container_caches
}
# DingTalk.
clean_dingtalk() {
    safe_clean ~/Library/Caches/dd.work.exclusive4aliding/* "钉钉 iDingTalk 缓存"
    safe_clean ~/Library/Caches/com.alibaba.AliLang.osx/* "AliLang 安全组件"
    if [[ -d ~/Library/Application\ Support/iDingTalk ]]; then
        safe_clean ~/Library/Application\ Support/iDingTalk/log/* "钉钉日志"
        safe_clean ~/Library/Application\ Support/iDingTalk/holmeslogs/* "钉钉 holmes 日志"
    fi
}
# AI assistants.
clean_ai_apps() {
    safe_clean ~/Library/Caches/com.openai.chat/* "ChatGPT 缓存"
    safe_clean ~/Library/Caches/com.anthropic.claudefordesktop/* "Claude 桌面版缓存"
    safe_clean ~/Library/Logs/Claude/* "Claude 日志"
    safe_clean ~/Library/Caches/com.lmstudio.lmstudio/* "LM Studio 缓存"
    # LM Studio <=0.3.5 used ~/.cache/lm-studio as its complete home directory,
    # including models, presets, chats, and runtime state. LM Studio moved new
    # installs to ~/.lmstudio in 0.3.6, but existing data is not migrated, so
    # never recursively clean the legacy root. The Library/Caches target above
    # is the only path treated as an auto-rebuildable cache here.
    safe_clean ~/Library/Caches/CCTClearcutLogger "Google Clearcut 日志"
    if [[ -d "$HOME/Library/Application Support/Codex" || -d "$HOME/Library/Logs/com.openai.codex" ]]; then
        debug_log "Codex Desktop state left intact by default"
    fi
}
# Design and creative tools.
clean_design_tools() {
    safe_clean ~/Library/Caches/com.bohemiancoding.sketch3/* "Sketch 缓存"
    safe_clean ~/Library/Application\ Support/com.bohemiancoding.sketch3/cache/* "Sketch 应用缓存"
    safe_clean ~/Library/Caches/Adobe/* "Adobe 缓存"
    safe_clean ~/Library/Caches/com.adobe.*/* "Adobe 应用缓存"
    safe_clean ~/Library/Caches/com.figma.Desktop/* "Figma 缓存"
    safe_clean ~/Library/Application\ Support/Adobe/Common/Media\ Cache\ Files/* "Adobe 媒体缓存文件"
}
# Video editing tools.
final_cut_pro_is_running() {
    mole_pgrep_any \
        -x "Final Cut Pro" \
        -f "/Final Cut Pro.app/"
}

final_cut_pro_path_has_protected_component() {
    local path="$1"

    case "$path" in
        */Original\ Media | */Original\ Media/* | \
            */CurrentVersion.flexolibrary | */CurrentVersion.plist | */Settings.plist | \
            */Motion\ Templates | */Motion\ Templates/* | \
            */Final\ Cut\ Pro\ Backups | */Final\ Cut\ Pro\ Backups/*)
            return 0
            ;;
    esac

    return 1
}

is_final_cut_pro_generated_cache_target() {
    local library="$1"
    local target="$2"

    [[ -n "$library" && -n "$target" ]] || return 1
    [[ "$library" == /* && "$target" == /* ]] || return 1
    [[ "$library" == "$HOME"/Movies/*.fcpbundle ]] || return 1
    [[ "$target" == "$library"/* ]] || return 1
    [[ -d "$library" && ! -L "$library" ]] || return 1
    [[ -d "$target" && ! -L "$target" ]] || return 1

    final_cut_pro_path_has_protected_component "$target" && return 1

    if declare -f validate_path_for_deletion > /dev/null 2>&1; then
        validate_path_for_deletion "$target" > /dev/null 2>&1 || return 1
    fi

    local relative_target="${target#"$library"/}"
    case "$relative_target" in
        */Render\ Files/High\ Quality\ Media | */Transcoded\ Media/Proxy\ Media)
            return 0
            ;;
    esac

    return 1
}

find_final_cut_pro_generated_cache_targets() {
    local movies_dir="$HOME/Movies"
    [[ -d "$movies_dir" ]] || return 0

    local library target
    while IFS= read -r -d '' library; do
        [[ -d "$library" && ! -L "$library" ]] || continue

        while IFS= read -r -d '' target; do
            if is_final_cut_pro_generated_cache_target "$library" "$target"; then
                printf '%s\0' "$target"
            fi
        done < <(command find "$library" \
            \( -type d \( \
            -name "Original Media" -o \
            -name "Analysis Files" -o \
            -name "Motion Templates" -o \
            -name "Final Cut Pro Backups" \
            \) -prune \) -o \
            \( -type d \( \
            -path "*/Render Files/High Quality Media" -o \
            -path "*/Transcoded Media/Proxy Media" \
            \) -print0 \) 2> /dev/null || true)
    done < <(command find "$movies_dir" -maxdepth 4 -type d -name "*.fcpbundle" -prune -print0 2> /dev/null || true)
}

clean_final_cut_pro_generated_caches() {
    local -a fcp_cache_targets=()
    local target
    while IFS= read -r -d '' target; do
        if mole_cleanup_targets_exist "$target"; then
            fcp_cache_targets+=("$target")
        fi
    done < <(find_final_cut_pro_generated_cache_targets)

    [[ ${#fcp_cache_targets[@]} -gt 0 ]] || return 0

    local process_state=0
    final_cut_pro_is_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Final Cut Pro 生成缓存 · 已跳过（进程状态未知）"
            note_activity
        else
            mole_defer_cleanup_family "Final Cut Pro"
        fi
        return 0
    fi

    # Final Cut Pro generated cache cleanup (issue #843).
    # Safety scope for the first pass:
    # - only scan ~/Movies, the default Apple library location;
    # - only delete exact generated-media directories documented by Apple as
    #   regenerable: render media and proxy media;
    # - never touch Original Media, library databases, plist settings, backups,
    #   Motion templates, Analysis Files, optimized media, or external .fcpcache.
    # Future expansion can add explicit flags or configurable roots for
    # optimized media, Analysis Files, and external cache bundles after more
    # field feedback.
    _app_cache_safe_clean_guarded \
        _final_cut_pro_delete_guard_allows \
        "Final Cut Pro 生成缓存" \
        "${fcp_cache_targets[@]}" \
        "Final Cut Pro 生成缓存" || true
}

jianying_pro_is_running() {
    command -v pgrep > /dev/null 2>&1 || return 2

    # Match the main editor process only. Narrow the -f pattern to the primary
    # executable path so the always-resident menu-bar agent
    # (.../Frameworks/VideoFusion-macOSTrayHelper.app/.../VideoFusion-macOSTrayHelper)
    # does not read as "editor running" and permanently skip cleanup.
    local probe_rc=0
    if pgrep -x "VideoFusion-macOS" > /dev/null 2>&1; then
        return 0
    else
        probe_rc=$?
        [[ $probe_rc -eq 1 ]] || return 2
    fi
    if pgrep -f "/VideoFusion-macOS.app/Contents/MacOS/VideoFusion-macOS" > /dev/null 2>&1; then
        return 0
    else
        probe_rc=$?
        [[ $probe_rc -eq 1 ]] || return 2
    fi
    return 1
}

clean_jianying_pro_generated_caches() {
    local cache_root="$HOME/Movies/JianyingPro/User Data/Cache"
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 0

    local process_state=0
    jianying_pro_is_running || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        local skip_reason="JianyingPro running"
        [[ $process_state -eq 2 ]] && skip_reason="process state unknown"
        echo -e "  ${GRAY}${ICON_WARNING}${NC} 剪映专业版生成缓存 · 已跳过（$(mole_localize_guard_reason "$skip_reason")）"
        note_activity
        return 0
    fi

    # JianyingPro (剪映专业版 / CapCut CN, com.lemon.lvpro) generated cache
    # cleanup (issue #1277). Same shape as Final Cut Pro (#843): the editor
    # keeps heavy generated caches under ~/Movies/JianyingPro/User Data/Cache/
    # instead of ~/Library/Caches, so standard cleanup never reaches them.
    #
    # Safety scope for the first pass:
    # - only the default cache root under ~/Movies; never User Data/Projects
    #   (the user's editable drafts) or any sibling of Cache;
    # - only remove an explicit whitelist of regenerable subdirectories:
    #   subtitle-recognition PCM scratch, frame thumbnails, audio waveforms,
    #   algorithm scratch, and prerender/remux temp;
    # - never touch draft-referenced or downloaded assets (effect,
    #   onlineMaterial, artistEffect, music, AITextTemplate, template,
    #   local_models, AigcMaterailCache, agencycache); plaintext draft configs
    #   reference effect 8000+ times, so anything not on this list is preserved.
    #
    # image/ and importcache3/ are deliberately excluded: both hold copies of
    # material the user imported, draft_info.json is encrypted so no plaintext
    # reference check can prove they are unreferenced, and mo clean deletes
    # permanently. If the user has since moved or deleted the source file, the
    # cached copy is the only remaining one. Revisit only with evidence that
    # the editor re-imports from the original on demand.
    #
    # Verified on a real machine (macOS 15.7 Intel, JianyingPro 11.1.0):
    # removing this set reclaimed ~70GB, 2025-era projects reopened cleanly, and
    # the app recreated the scratch directories on next launch.
    local -a regenerable_subdirs=(
        recognize
        frameThumbnail
        audioWave
        AlgorithmCache
        ILASDKDB
        RemuxCache
        prerender
        segmentPrerenderCache
        MotionBlurCache
        ttsTemp
        tmp
    )

    local -a targets=()
    local subdir path
    for subdir in "${regenerable_subdirs[@]}"; do
        path="$cache_root/$subdir"
        if [[ -d "$path" && ! -L "$path" ]]; then
            targets+=("$path")
        fi
    done

    [[ ${#targets[@]} -gt 0 ]] || return 0

    safe_clean "${targets[@]}" "JianyingPro 生成缓存"
}

clean_video_tools() {
    safe_clean ~/Library/Caches/net.telestream.screenflow10/* "ScreenFlow 缓存"
    safe_clean ~/Library/Caches/com.apple.FinalCut/* "Final Cut Pro 缓存"
    clean_final_cut_pro_generated_caches
    safe_clean ~/Library/Caches/com.blackmagic-design.DaVinciResolve/* "DaVinci Resolve 缓存"
    safe_clean ~/Movies/CacheClip/* "DaVinci Resolve CacheClip"
    safe_clean ~/Library/Caches/com.adobe.PremierePro.*/* "Premiere Pro 缓存"
    clean_jianying_pro_generated_caches
}
# Autodesk Fusion helpers (AcCoreConsole, ADPClientService) outlive the main
# window and keep SQLite caches open under ~/Library/Caches/com.autodesk.*.
# Deleting those while the helper runs can fill the volume with unlinked temp
# writes (#1390). Probe is intentionally broad on the Autodesk family; the
# safe_remove live-cache gate is the per-path backstop for every reverse-DNS
# cache tree, including the generic ~/Library/Caches/* sweep.
autodesk_cache_process_state() {
    mole_pgrep_any \
        -f "com.autodesk." \
        -x "AcCoreConsole" \
        -f "/AcCoreConsole" \
        -x "ADPClientService" \
        -f "/ADPClientService" \
        -x "streamer" \
        -f "/streamer" \
        -x "Fusion Client Downloader" \
        -x "Fusion 360 Client Downloader" \
        -f "Autodesk Fusion" \
        -f "Fusion 360" \
        -f "Fusion360"
}

_autodesk_cache_delete_guard_allows() {
    mole_clean_process_guard autodesk_cache_process_state "Autodesk running"
}

# Autodesk Fusion's in-app updater can leave tens of gigabytes of old app
# bundles under webdeploy/production (#1438 measured 60GB). This is not a
# generic Autodesk tree cleanup: only direct 40-hex version directories that
# contain one exact com.autodesk.fusion360 app bundle are eligible. Keep the
# current, equal-version, newer staged, unrecognized, non-hash, and symlinked
# entries. Version evidence is stronger than directory mtime, which an updater
# can preserve or reorder.
_MOLE_AUTODESK_FUSION_VERSION=""
_MOLE_AUTODESK_FUSION_APP=""
_MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
_MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
_MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
_MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
_MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
_MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()
_MOLE_AUTODESK_FUSION_GUARD_REASON=""

_autodesk_fusion_trusted_production_root() {
    local production_dir="$1"
    _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    [[ -d "$production_dir" && ! -L "$production_dir" ]] || return 1

    local physical_root=""
    physical_root=$(cd -P "$production_dir" 2> /dev/null && pwd -P) || return 1
    # Refuse every symlinked ancestor. A lexical path below Application Support
    # is not containment when webdeploy or production redirects elsewhere.
    [[ "$physical_root" == "$production_dir" ]] || return 1
    _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT="$physical_root"
}

_autodesk_fusion_version_dir_version() {
    local version_dir="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_VERSION=""
    _MOLE_AUTODESK_FUSION_APP=""

    [[ -d "$version_dir" && ! -L "$version_dir" ]] || return 1
    local app_candidate=""
    local app_count=0
    local candidate
    for candidate in \
        "$version_dir/Autodesk Fusion.app" \
        "$version_dir/Autodesk Fusion 360.app"; do
        [[ -d "$candidate" && ! -L "$candidate" ]] || continue
        app_candidate="$candidate"
        app_count=$((app_count + 1))
    done
    [[ $app_count -eq 1 ]] || return 1

    local contents_dir="$app_candidate/Contents"
    local macos_dir="$contents_dir/MacOS"
    [[ -d "$contents_dir" && ! -L "$contents_dir" ]] || return 1
    [[ -d "$macos_dir" && ! -L "$macos_dir" ]] || return 1
    local info_plist="$contents_dir/Info.plist"
    [[ -f "$info_plist" && ! -L "$info_plist" ]] || return 1

    local probe_timeout=""
    local probe_rc=0
    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"

    local bundle_id=""
    bundle_id=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleIdentifier raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 && "$bundle_id" == "com.autodesk.fusion360" ]] || return 1

    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"
    local version=""
    version=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleVersion raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 && "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1

    probe_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || probe_rc=$?
    [[ $probe_rc -eq 0 ]] || return "$probe_rc"
    local executable=""
    executable=$(run_with_timeout "$probe_timeout" /usr/bin/plutil \
        -extract CFBundleExecutable raw "$info_plist" < /dev/null 2> /dev/null) || probe_rc=$?
    [[ $probe_rc -eq 124 || $probe_rc -ge 128 ]] && return "$probe_rc"
    [[ $probe_rc -eq 0 &&
        ("$executable" == "Autodesk Fusion" || "$executable" == "Autodesk Fusion 360") ]] || return 1
    local executable_path="$macos_dir/$executable"
    [[ -f "$executable_path" && -x "$executable_path" && ! -L "$executable_path" ]] || return 1

    _MOLE_AUTODESK_FUSION_VERSION="$version"
    _MOLE_AUTODESK_FUSION_APP="$app_candidate"
}

_autodesk_fusion_version_is_older() {
    local candidate_version="$1"
    local current_version="$2"
    [[ "$candidate_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1
    [[ "$current_version" =~ ^[0-9]+([.][0-9]+)*$ ]] || return 1

    local saved_ifs="$IFS"
    IFS='.'
    # shellcheck disable=SC2206 # intentional numeric version split
    local -a candidate_parts=($candidate_version)
    # shellcheck disable=SC2206 # intentional numeric version split
    local -a current_parts=($current_version)
    IFS="$saved_ifs"

    local count=${#candidate_parts[@]}
    [[ ${#current_parts[@]} -gt $count ]] && count=${#current_parts[@]}
    local index candidate_part current_part
    for ((index = 0; index < count; index++)); do
        candidate_part="${candidate_parts[$index]:-0}"
        current_part="${current_parts[$index]:-0}"
        # Avoid arithmetic overflow on corrupt metadata. Unknown is retained.
        [[ ${#candidate_part} -le 9 && ${#current_part} -le 9 ]] || return 1
        if ((10#$candidate_part < 10#$current_part)); then
            return 0
        elif ((10#$candidate_part > 10#$current_part)); then
            return 1
        fi
    done
    return 1
}

_autodesk_fusion_resolve_current_dir() {
    local production_root="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""

    local current_alias="$production_root/Autodesk Fusion.app"
    [[ -e "$current_alias" || -L "$current_alias" ]] || return 1

    local resolved_target=""
    local resolve_rc=0
    if [[ -L "$current_alias" ]]; then
        [[ -e "$current_alias" ]] || return 1
        resolved_target=$(cd -P "$current_alias" 2> /dev/null && pwd -P) || return 1
    else
        # Resolve a Finder alias through Foundation, not Finder automation. The
        # static JXA receives the path as argv, so quotes or AppleScript syntax
        # in a user path cannot become code. Test/no-auth runs never launch it.
        if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ||
            ! -x /usr/bin/osascript ]]; then
            return 1
        fi
        local resolve_timeout=""
        resolve_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_QUICK_DETECT_SEC" "$deadline_seconds") || resolve_rc=$?
        [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
        # shellcheck disable=SC2016 # `$` belongs to the JXA bridge, not Bash
        local jxa_script='ObjC.import("Foundation"); function run(argv) { var url = $.NSURL.fileURLWithPath($(argv[0])); var resolved = $.NSURL.URLByResolvingAliasFileAtURLOptionsError(url, 0, null); if (!resolved) throw new Error("unresolved alias"); return ObjC.unwrap(resolved.path); }'
        resolved_target=$(run_with_timeout "$resolve_timeout" /usr/bin/osascript \
            -l JavaScript -e "$jxa_script" "$current_alias" < /dev/null 2> /dev/null) || resolve_rc=$?
        [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
        resolved_target="${resolved_target%/}"
        [[ -d "$resolved_target" ]] || return 1
        resolved_target=$(cd -P "$resolved_target" 2> /dev/null && pwd -P) || return 1
    fi

    local version_dir=""
    local target_name="${resolved_target##*/}"
    if [[ "${resolved_target%/*}" == "$production_root" &&
        "$target_name" =~ ^[0-9a-f]{40}$ ]]; then
        version_dir="$resolved_target"
    elif [[ "$target_name" == "Autodesk Fusion.app" ||
        "$target_name" == "Autodesk Fusion 360.app" ]]; then
        version_dir="${resolved_target%/*}"
        local version_name="${version_dir##*/}"
        [[ "${version_dir%/*}" == "$production_root" &&
            "$version_name" =~ ^[0-9a-f]{40}$ ]] || return 1
    else
        return 1
    fi
    [[ -d "$version_dir" && ! -L "$version_dir" ]] || return 1

    _MOLE_AUTODESK_FUSION_RESOLVED_DIR="$version_dir"
}

_autodesk_fusion_resolve_current_version() {
    local production_root="$1"
    local deadline_seconds="$2"
    _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""

    local resolve_rc=0
    _autodesk_fusion_resolve_current_dir \
        "$production_root" "$deadline_seconds" || resolve_rc=$?
    [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
    local version_dir="$_MOLE_AUTODESK_FUSION_RESOLVED_DIR"

    local version_rc=0
    _autodesk_fusion_version_dir_version \
        "$version_dir" "$deadline_seconds" || version_rc=$?
    [[ $version_rc -eq 0 ]] || return "$version_rc"
    local version="$_MOLE_AUTODESK_FUSION_VERSION"

    # The updater can switch the alias while plist metadata is being read and
    # exit before the caller's process recheck. End this resolver with an
    # alias-only rebind, so its returned directory/version are one stable
    # observation rather than metadata from an alias target that is no longer
    # current.
    resolve_rc=0
    _autodesk_fusion_resolve_current_dir \
        "$production_root" "$deadline_seconds" || resolve_rc=$?
    [[ $resolve_rc -eq 0 ]] || return "$resolve_rc"
    [[ "$_MOLE_AUTODESK_FUSION_RESOLVED_DIR" == "$version_dir" ]] || return 1

    _MOLE_AUTODESK_FUSION_RESOLVED_DIR="$version_dir"
    _MOLE_AUTODESK_FUSION_RESOLVED_VERSION="$version"
}

_autodesk_fusion_materialize_version_dirs() {
    local production_root="$1"
    local output_file="$2"
    local deadline_seconds="$3"
    : > "$output_file" || return 1

    local scan_timeout=""
    local scan_rc=0
    scan_timeout=$(_mole_timeout_with_deadline \
        "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" "$deadline_seconds") || scan_rc=$?
    if [[ $scan_rc -eq 0 ]]; then
        run_with_timeout "$scan_timeout" find "$production_root" \
            -mindepth 1 -maxdepth 1 -type d -print0 \
            < /dev/null > "$output_file" 2> /dev/null || scan_rc=$?
    fi
    if [[ $scan_rc -ne 0 ]]; then
        : > "$output_file" || true
        return "$scan_rc"
    fi
}

_autodesk_fusion_plan_old_versions() {
    local production_root="$1"
    local current_dir="$2"
    local current_version="$3"
    local deadline_seconds="$4"
    _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
    _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()

    local inventory_file=""
    inventory_file=$(create_temp_file) || return 1
    local inventory_rc=0
    _autodesk_fusion_materialize_version_dirs \
        "$production_root" "$inventory_file" "$deadline_seconds" || inventory_rc=$?
    if [[ $inventory_rc -ne 0 ]]; then
        rm -f -- "$inventory_file" 2> /dev/null || true # SAFE: exact tracked temp file created above
        return "$inventory_rc"
    fi

    local dir name candidate_version version_rc
    while IFS= read -r -d '' dir; do
        if [[ $SECONDS -ge $deadline_seconds ]]; then
            inventory_rc=124
            break
        fi
        name="${dir##*/}"
        [[ "$name" =~ ^[0-9a-f]{40}$ ]] || continue
        [[ "$dir" != "$current_dir" && "${dir%/*}" == "$production_root" ]] || continue
        [[ -d "$dir" && ! -L "$dir" ]] || continue

        version_rc=0
        _autodesk_fusion_version_dir_version \
            "$dir" "$deadline_seconds" || version_rc=$?
        if [[ $version_rc -eq 124 || $version_rc -ge 128 ]]; then
            inventory_rc=$version_rc
            break
        elif [[ $version_rc -ne 0 ]]; then
            debug_log "Autodesk Fusion old versions: keeping unverified directory $dir"
            continue
        fi
        candidate_version="$_MOLE_AUTODESK_FUSION_VERSION"
        _autodesk_fusion_version_is_older \
            "$candidate_version" "$current_version" || continue
        if should_protect_path "$dir" || is_path_whitelisted "$dir" ||
            (declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$dir"); then
            continue
        fi

        _mole_snapshot_path_identity "$dir" || continue
        [[ "$_MOLE_PATH_SNAPSHOT_PARENT" == "$production_root" ]] || continue
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS+=("$dir")
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS+=("$_MOLE_PATH_SNAPSHOT_PARENT")
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS+=("$_MOLE_PATH_SNAPSHOT_PARENT_ID")
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS+=("$_MOLE_PATH_SNAPSHOT_TARGET_ID")
    done < "$inventory_file"
    rm -f -- "$inventory_file" 2> /dev/null || true # SAFE: exact tracked temp file created above

    if [[ $inventory_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGETS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENTS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS=()
        _MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS=()
        return "$inventory_rc"
    fi
}

_autodesk_fusion_guard_current_is_unchanged() {
    local _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    local _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
    local resolve_rc=0
    _autodesk_fusion_resolve_current_version \
        "$_MOLE_AUTODESK_FUSION_GUARD_ROOT" \
        "$_MOLE_AUTODESK_FUSION_GUARD_DEADLINE" || resolve_rc=$?
    if [[ $resolve_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="current version unknown"
        [[ $resolve_rc -eq 124 || $resolve_rc -ge 128 ]] && return "$resolve_rc"
        return 1
    fi
    if [[ "$_MOLE_AUTODESK_FUSION_RESOLVED_DIR" != "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR" ||
        "$_MOLE_AUTODESK_FUSION_RESOLVED_VERSION" != "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION" ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="current version changed"
        return 1
    fi
}

_autodesk_fusion_delete_guard_allows() {
    local target="$1"
    _MOLE_AUTODESK_FUSION_GUARD_REASON=""

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard \
        autodesk_cache_process_state "Autodesk started"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi

    local _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    if ! _autodesk_fusion_trusted_production_root \
        "$_MOLE_AUTODESK_FUSION_GUARD_ROOT"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="production root changed"
        return 1
    fi

    local current_rc=0
    _autodesk_fusion_guard_current_is_unchanged || current_rc=$?
    [[ $current_rc -eq 0 ]] || return "$current_rc"

    local name="${target##*/}"
    if [[ ! "$name" =~ ^[0-9a-f]{40}$ || "${target%/*}" != "$_MOLE_AUTODESK_FUSION_GUARD_ROOT" ||
        "$target" == "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR" || ! -d "$target" || -L "$target" ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate changed"
        return 1
    fi

    local version_rc=0
    _autodesk_fusion_version_dir_version \
        "$target" "$_MOLE_AUTODESK_FUSION_GUARD_DEADLINE" || version_rc=$?
    if [[ $version_rc -ne 0 ]]; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate identity changed"
        [[ $version_rc -eq 124 || $version_rc -ge 128 ]] && return "$version_rc"
        return 1
    fi
    if ! _autodesk_fusion_version_is_older \
        "$_MOLE_AUTODESK_FUSION_VERSION" \
        "$_MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="retention changed"
        return 1
    fi
    if should_protect_path "$target" || is_path_whitelisted "$target" ||
        (declare -f holds_compiled_model_cache > /dev/null 2>&1 && holds_compiled_model_cache "$target"); then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="policy changed"
        return 1
    fi

    # Metadata probes above are bounded, but the updater can start during any
    # one of them. Rebind its tri-state immediately before the final identity
    # check; that identity remains the last operation before safe_remove's rm.
    _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard \
        autodesk_cache_process_state "Autodesk started"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="$_MOLE_CLEAN_GUARD_REASON"
        return 1
    fi

    # The updater may atomically switch the alias and exit during any earlier
    # metadata, policy, or process probe. Make current resolution the last
    # external-state check, immediately before the target identity binding.
    current_rc=0
    _autodesk_fusion_guard_current_is_unchanged || current_rc=$?
    [[ $current_rc -eq 0 ]] || return "$current_rc"

    # Make the object/parent identity check the last guard operation so a
    # replacement during the metadata probes is rejected at the sink.
    if ! _mole_path_matches_identity \
        "$target" \
        "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
        "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
        "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID"; then
        _MOLE_AUTODESK_FUSION_GUARD_REASON="candidate replaced"
        return 1
    fi
}

clean_autodesk_fusion_old_bundles() {
    local production_dir="$HOME/Library/Application Support/Autodesk/webdeploy/production"
    [[ -d "$production_dir" ]] || return 0
    local cleanup_deadline=$((SECONDS + 60))

    local _MOLE_AUTODESK_FUSION_PRODUCTION_ROOT=""
    if ! _autodesk_fusion_trusted_production_root "$production_dir"; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · 已跳过（production root not trusted）"
        note_activity
        return 0
    fi
    local production_root="$_MOLE_AUTODESK_FUSION_PRODUCTION_ROOT"

    local _MOLE_AUTODESK_FUSION_RESOLVED_DIR=""
    local _MOLE_AUTODESK_FUSION_RESOLVED_VERSION=""
    local current_rc=0
    _autodesk_fusion_resolve_current_version \
        "$production_root" "$cleanup_deadline" || current_rc=$?
    if [[ $current_rc -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · 已跳过（current version probe timed out）"
        note_activity
        return 0
    elif [[ $current_rc -ge 128 ]]; then
        return "$current_rc"
    elif [[ $current_rc -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · 已跳过（current version unknown）"
        note_activity
        return 0
    fi
    local current_dir="$_MOLE_AUTODESK_FUSION_RESOLVED_DIR"
    local current_version="$_MOLE_AUTODESK_FUSION_RESOLVED_VERSION"

    local plan_rc=0
    _autodesk_fusion_plan_old_versions \
        "$production_root" "$current_dir" "$current_version" \
        "$cleanup_deadline" || plan_rc=$?
    if [[ $plan_rc -eq 124 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · 已跳过（inventory timed out）"
        note_activity
        return 0
    elif [[ $plan_rc -ge 128 ]]; then
        return "$plan_rc"
    elif [[ $plan_rc -ne 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · 已跳过（inventory incomplete）"
        note_activity
        return 0
    fi
    [[ ${#_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[@]} -gt 0 ]] || return 0

    local process_state=0
    autodesk_cache_process_state || process_state=$?
    if [[ $process_state -ne 1 ]]; then
        if [[ $process_state -eq 2 ]]; then
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · 已跳过（进程状态未知）"
            note_activity
        else
            mole_defer_cleanup_family "Autodesk Fusion"
        fi
        return 0
    fi

    local cleaned_count=0
    local failed_count=0
    local total_size=0
    local stopped_reason=""
    local index dir size_kb size_rc size_timeout guard_rc remove_rc
    for ((index = 0; index < ${#_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[@]}; index++)); do
        dir="${_MOLE_AUTODESK_FUSION_CLEANUP_TARGETS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_ROOT="$production_root"
        local _MOLE_AUTODESK_FUSION_GUARD_CURRENT_DIR="$current_dir"
        local _MOLE_AUTODESK_FUSION_GUARD_CURRENT_VERSION="$current_version"
        local _MOLE_AUTODESK_FUSION_GUARD_DEADLINE="$cleanup_deadline"
        local _MOLE_AUTODESK_FUSION_GUARD_PARENT="${_MOLE_AUTODESK_FUSION_CLEANUP_PARENTS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_PARENT_ID="${_MOLE_AUTODESK_FUSION_CLEANUP_PARENT_IDS[$index]}"
        local _MOLE_AUTODESK_FUSION_GUARD_TARGET_ID="${_MOLE_AUTODESK_FUSION_CLEANUP_TARGET_IDS[$index]}"

        guard_rc=0
        _autodesk_fusion_delete_guard_allows "$dir" || guard_rc=$?
        if [[ $guard_rc -eq 124 ]]; then
            stopped_reason="verification timed out"
            break
        elif [[ $guard_rc -ge 128 ]]; then
            return "$guard_rc"
        elif [[ $guard_rc -ne 0 ]]; then
            stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
            break
        fi

        size_timeout=""
        size_rc=0
        size_timeout=$(_mole_timeout_with_deadline \
            "$MOLE_TIMEOUT_DISK_VERIFY_SEC" "$cleanup_deadline") || size_rc=$?
        if [[ $size_rc -eq 0 ]]; then
            size_kb=$(get_path_size_kb "$dir" "$size_timeout") || size_rc=$?
        fi
        if [[ $size_rc -eq 124 ]]; then
            stopped_reason="size probe timed out"
            break
        elif [[ $size_rc -ge 128 ]]; then
            return "$size_rc"
        elif [[ $size_rc -ne 0 || ! "$size_kb" =~ ^[0-9]+$ ]]; then
            failed_count=$((failed_count + 1))
            continue
        fi

        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            # Dry-run has no deletion sink to perform the final rebind. Recheck
            # after sizing so its preview uses the same current/process verdict
            # that a real safe_remove final guard would enforce.
            guard_rc=0
            _autodesk_fusion_delete_guard_allows "$dir" || guard_rc=$?
            if [[ $guard_rc -eq 124 ]]; then
                stopped_reason="verification timed out"
                break
            elif [[ $guard_rc -ge 128 ]]; then
                return "$guard_rc"
            elif [[ $guard_rc -ne 0 ]]; then
                stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
                break
            fi
            if declare -f record_dry_run_cleanup_target > /dev/null 2>&1; then
                record_dry_run_cleanup_target "$dir" "$size_kb" 1 true || continue
            fi
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
            continue
        fi

        remove_rc=0
        local _MOLE_SAFE_REMOVE_FINAL_GUARD="_autodesk_fusion_delete_guard_allows"
        safe_remove "$dir" true "$size_kb" "$cleanup_deadline" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
            "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID" \
            > /dev/null 2>&1 || remove_rc=$?
        if [[ $remove_rc -eq 0 ]]; then
            total_size=$((total_size + size_kb))
            cleaned_count=$((cleaned_count + 1))
        elif [[ $remove_rc -eq 124 ]]; then
            stopped_reason="removal timed out"
            break
        elif [[ $remove_rc -ge 128 ]]; then
            return "$remove_rc"
        elif [[ -n "$_MOLE_AUTODESK_FUSION_GUARD_REASON" ]]; then
            stopped_reason="$_MOLE_AUTODESK_FUSION_GUARD_REASON"
            break
        elif ! _mole_path_matches_identity \
            "$dir" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT" \
            "$_MOLE_AUTODESK_FUSION_GUARD_PARENT_ID" \
            "$_MOLE_AUTODESK_FUSION_GUARD_TARGET_ID"; then
            # safe_remove performs its generic identity rebind before the
            # caller-specific final guard. Diagnose that refusal after the
            # failed sink without adding a third full Fusion guard to the
            # successful deletion path.
            stopped_reason="candidate replaced"
            break
        else
            failed_count=$((failed_count + 1))
            debug_log "Autodesk Fusion old version removal failed: $dir"
        fi
    done

    if [[ $cleaned_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$((total_size * 1024))")
        if [[ "${DRY_RUN:-false}" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} Autodesk Fusion 旧版本${NC} · ${YELLOW}${cleaned_count} 个目录，$(colorize_human_size "$size_human") ${YELLOW}预览${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$total_size")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} Autodesk Fusion 旧版本${NC} · ${line_color}${cleaned_count} 个目录，${size_human}${NC}"
        fi
        files_cleaned=$((${files_cleaned:-0} + cleaned_count))
        total_size_cleaned=$((${total_size_cleaned:-0} + total_size))
        total_items=$((${total_items:-0} + 1))
        note_activity
    fi
    if [[ $failed_count -gt 0 ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · ${failed_count} 项失败"
        note_activity
    fi
    if [[ -n "$stopped_reason" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk Fusion 旧版本 · 已停止（$(mole_localize_guard_reason "$stopped_reason")）"
        note_activity
    fi
}

# 3D and CAD tools.
clean_3d_tools() {
    safe_clean ~/Library/Caches/org.blenderfoundation.blender/* "Blender 缓存"
    safe_clean ~/Library/Caches/com.maxon.cinema4d/* "Cinema 4D 缓存"

    local -a autodesk_targets=()
    local autodesk_entry
    for autodesk_entry in "$HOME"/Library/Caches/com.autodesk.*; do
        [[ -e "$autodesk_entry" ]] || continue
        if mole_cleanup_targets_exist "$autodesk_entry"/*; then
            autodesk_targets+=("$autodesk_entry"/*)
        elif mole_cleanup_targets_exist "$autodesk_entry"; then
            autodesk_targets+=("$autodesk_entry")
        fi
    done
    if [[ ${#autodesk_targets[@]} -gt 0 ]]; then
        local process_state=0
        autodesk_cache_process_state || process_state=$?
        if [[ $process_state -ne 1 ]]; then
            if [[ $process_state -eq 2 ]]; then
                echo -e "  ${GRAY}${ICON_WARNING}${NC} Autodesk 缓存 · 已跳过（进程状态未知）"
                note_activity
            else
                mole_defer_cleanup_family "Autodesk"
            fi
        else
            _app_cache_safe_clean_guarded \
                _autodesk_cache_delete_guard_allows \
                "Autodesk 缓存" \
                "${autodesk_targets[@]}" \
                "Autodesk 缓存" || true
        fi
    fi

    safe_clean ~/Library/Caches/com.sketchup.*/* "SketchUp 缓存"

    # Remove old Autodesk Fusion app bundles left by the in-app updater.
    # The updater keeps every version under webdeploy/production and leaves an
    # alias named "Autodesk Fusion.app" pointing at the current one. Delete
    # every older bundle, keep the current target and any newer staged update.
    clean_autodesk_fusion_old_bundles
}
# Productivity apps.
clean_productivity_apps() {
    safe_clean ~/Library/Caches/com.tw93.MiaoYan/* "妙言缓存"
    safe_clean ~/Library/Caches/com.klee.desktop/* "Klee 缓存"
    safe_clean ~/Library/Caches/klee_desktop/* "Klee 桌面缓存"
    safe_clean ~/Library/Caches/com.orabrowser.app/* "Ora 浏览器缓存"
    safe_clean ~/Library/Caches/com.filo.client/* "Filo 缓存"
    safe_clean ~/Library/Caches/com.flomoapp.mac/* "flomo 缓存"
    safe_clean ~/Library/Application\ Support/Quark/Cache/videoCache/* "夸克视频缓存"
    safe_clean ~/Library/Containers/com.ranchero.NetNewsWire-Evergreen/Data/Library/Caches/* "NetNewsWire 缓存"
    safe_clean ~/Library/Containers/com.ideasoncanvas.mindnode/Data/Library/Caches/* "MindNode 缓存"
    safe_clean ~/.cache/kaku/* "Kaku 缓存"
    safe_clean ~/Library/Application\ Support/spacedrive/thumbnails/* "Spacedrive 缩略图缓存"
    safe_clean ~/Library/Containers/is.follow/Data/Library/Application\ Support/Folo/Cache/Cache_Data/* "Folo 缓存"
}
# Music/media players (protect Spotify offline music).
clean_media_players() {
    local spotify_cache="$HOME/Library/Caches/com.spotify.client"
    local spotify_data="$HOME/Library/Application Support/Spotify"
    local has_offline_music=false
    # offline.bnk exists even with no offline downloads; only treat it as evidence
    # when it has real content (>1 KB). Encrypted track blobs (*.file) are reliable.
    local bnk_file="$spotify_data/PersistentCache/Storage/offline.bnk"
    local bnk_size=0
    [[ -f "$bnk_file" ]] && bnk_size=$(stat -f%z "$bnk_file" 2> /dev/null || echo 0)
    if [[ $bnk_size -gt 1024 ]] ||
        [[ -d "$spotify_data/PersistentCache/Storage" && -n "$(find "$spotify_data/PersistentCache/Storage" -type f -name "*.file" 2> /dev/null | head -1)" ]]; then
        has_offline_music=true
    fi
    if [[ "$has_offline_music" == "true" ]]; then
        echo -e "  ${GRAY}${ICON_WARNING}${NC} Spotify 缓存受保护 · 检测到离线音乐"
        note_activity
    else
        safe_clean ~/Library/Caches/com.spotify.client/* "Spotify 缓存"
    fi
    safe_clean ~/Library/Caches/com.apple.Music "Apple Music 缓存"
    safe_clean ~/Library/Caches/com.apple.podcasts "Apple Podcasts 缓存"
    # Apple Podcasts sandbox container: zombie sparse files and stale artwork cache (#387)
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/StreamedMedia "播客流媒体"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.heic "播客封面缓存"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*.img "播客图片缓存"
    safe_clean ~/Library/Containers/com.apple.podcasts/Data/tmp/*CFNetworkDownload*.tmp "播客下载临时文件"
    safe_clean ~/Library/Caches/com.apple.TV/* "Apple TV 缓存"
    safe_clean ~/Library/Caches/tv.plex.player.desktop "Plex 缓存"
    safe_clean ~/Library/Caches/com.netease.163music "网易云音乐缓存"
    safe_clean ~/Library/Caches/com.tencent.QQMusic/* "QQ 音乐缓存"
    safe_clean ~/Library/Caches/com.tencent.QQMusicMac/* "QQ 音乐 Mac 缓存"
    # QQ Music Mac sandboxed container caches (protect offline downloads in iDownloadProxy).
    local _qqmusic_container="$HOME/Library/Containers/com.tencent.QQMusicMac/Data/Library/Application Support/QQMusicMac"
    if [[ -d "$_qqmusic_container" ]]; then
        safe_clean "$_qqmusic_container/iRRCache"/* "QQ 音乐流媒体缓存"
        safe_clean "$_qqmusic_container/iLog"/* "QQ 音乐日志"
        safe_clean "$_qqmusic_container/iCache"/* "QQ 音乐缓存"
        safe_clean "$_qqmusic_container/iTemp"/* "QQ 音乐临时文件"
    fi
    safe_clean ~/Library/Containers/com.tencent.QQMusicMac/Data/Library/Caches/* "QQ 音乐容器缓存"
    safe_clean ~/Library/Caches/com.kugou.mac/* "酷狗音乐缓存"
    safe_clean ~/Library/Caches/com.kuwo.mac/* "酷我音乐缓存"
}
# Video players.
clean_video_players() {
    safe_clean ~/Library/Caches/com.colliderli.iina "IINA 缓存"
    safe_clean ~/Library/Caches/org.videolan.vlc "VLC 缓存"
    safe_clean ~/Library/Caches/io.mpv "MPV 缓存"
    safe_clean ~/Library/Caches/com.iqiyi.player "爱奇艺缓存"
    safe_clean ~/Library/Caches/com.tencent.tenvideo "腾讯视频缓存"
    # Tencent Video sandboxed container caches.
    local _tenvideo_as="$HOME/Library/Containers/com.tencent.tenvideo/Data/Library/Application Support"
    if [[ -d "$_tenvideo_as" ]]; then
        safe_clean "$_tenvideo_as/Upgrade"/* "腾讯视频旧安装包"
        safe_clean "$_tenvideo_as/VideoNative"/* "腾讯视频原生缓存"
        safe_clean "$_tenvideo_as/documentCache"/* "腾讯视频文档缓存"
    fi
    safe_clean ~/Library/Caches/tv.danmaku.bili/* "哔哩哔哩缓存"
    safe_clean ~/Library/Caches/com.douyu.*/* "斗鱼缓存"
    safe_clean ~/Library/Caches/com.huya.*/* "虎牙缓存"
    safe_clean ~/Library/Containers/com.wuziqi.SenPlayer/Data/tmp/videoCache/* "SenPlayer 视频缓存"
    safe_clean ~/Library/Caches/smart.stremio*/* "Stremio 缓存"
    if [[ -d ~/Library/Application\ Support/stremio ]]; then
        safe_clean ~/Library/Application\ Support/stremio/stremio-server/stremio-cache/* "Stremio 服务器缓存"
    fi
}
# Download managers.
clean_download_managers() {
    safe_clean ~/Library/Caches/net.xmac.aria2gui "Aria2 缓存"
    safe_clean ~/Library/Caches/org.m0k.transmission "Transmission 缓存"
    safe_clean ~/Library/Caches/com.qbittorrent.qBittorrent "qBittorrent 缓存"
    safe_clean ~/Library/Caches/com.downie.Downie-* "Downie 缓存"
    safe_clean ~/Library/Caches/com.folx.*/* "Folx 缓存"
    safe_clean ~/Library/Caches/com.charlessoft.pacifist/* "Pacifist 缓存"
    clean_neatdm_stale_segments || return $?
}
# Neat Download Manager: clean stale incomplete download segments.
# History database (NeatDB.db) is never touched; only numbered segment
# directories whose seg.x0 file is older than MOLE_ORPHAN_AGE_DAYS are removed.
# Download URLs expire within hours/days so 30-day-old segments cannot be resumed.
clean_neatdm_stale_segments() {
    local neatdm_dir="$HOME/Library/Application Support/com.NeatDownloadManager"
    [[ -d "$neatdm_dir" ]] || return 0

    local stale_count=0
    local stale_kb=0
    local current_epoch
    current_epoch=$(get_epoch_seconds)

    local -a stale_dirs=()
    local seg_dir
    for seg_dir in "$neatdm_dir"/*/; do
        [[ -d "$seg_dir" ]] || continue
        local seg_name
        seg_name=$(basename "${seg_dir%/}")
        [[ "$seg_name" =~ ^[0-9]+$ ]] || continue
        [[ -f "$seg_dir/seg.x0" ]] || continue

        local seg_mtime
        seg_mtime=$(get_file_mtime "$seg_dir/seg.x0")
        local age_days=$(((current_epoch - seg_mtime) / 86400))

        if [[ $age_days -ge ${MOLE_ORPHAN_AGE_DAYS:-30} ]]; then
            stale_dirs+=("$seg_dir")
        fi
    done

    [[ ${#stale_dirs[@]} -eq 0 ]] && return 0

    for seg_dir in "${stale_dirs[@]}"; do
        local size_kb=""
        local size_rc=0
        size_kb=$(get_path_size_kb "$seg_dir") || size_rc=$?
        [[ $size_rc -eq 0 ]] || _mole_record_clean_cancellation "$size_rc"
        [[ $size_rc -eq 0 ]] || return "$size_rc"
        [[ "$size_kb" =~ ^[0-9]+$ ]] || size_kb=0

        if [[ "$DRY_RUN" != "true" ]]; then
            if safe_remove "$seg_dir" true; then
                stale_count=$((stale_count + 1))
                stale_kb=$((stale_kb + size_kb))
            fi
        else
            stale_count=$((stale_count + 1))
            stale_kb=$((stale_kb + size_kb))
        fi
    done

    if [[ $stale_count -gt 0 ]]; then
        local size_human
        size_human=$(bytes_to_human "$((stale_kb * 1024))")
        if [[ "$DRY_RUN" == "true" ]]; then
            echo -e "  ${YELLOW}${ICON_DRY_RUN}${NC} NeatDM 过期下载 · ${stale_count} 个项目，$(colorize_human_size "$size_human") ${YELLOW}预览${NC}"
        else
            local line_color
            line_color=$(cleanup_result_color_kb "$stale_kb")
            echo -e "  ${line_color}${ICON_SUCCESS}${NC} NeatDM 过期下载 · ${stale_count} 个项目，${line_color}${size_human}${NC}"
        fi
        files_cleaned=$((files_cleaned + stale_count))
        total_size_cleaned=$((total_size_cleaned + stale_kb))
        total_items=$((total_items + 1))
        note_activity
    fi
}
# Gaming platforms.
clean_gaming_platforms() {
    safe_clean ~/Library/Caches/com.valvesoftware.steam/* "Steam 缓存"
    if [[ -d ~/Library/Application\ Support/Steam ]]; then
        safe_clean ~/Library/Application\ Support/Steam/htmlcache/* "Steam Web 缓存"
        safe_clean ~/Library/Application\ Support/Steam/appcache/* "Steam 应用缓存"
        safe_clean ~/Library/Application\ Support/Steam/depotcache/* "Steam depot 缓存"
        safe_clean ~/Library/Application\ Support/Steam/steamapps/shadercache/* "Steam 着色器缓存"
        safe_clean ~/Library/Application\ Support/Steam/logs/* "Steam 日志"
    fi
    safe_clean ~/Library/Caches/com.epicgames.EpicGamesLauncher/* "Epic Games 缓存"
    safe_clean ~/Library/Caches/com.blizzard.Battle.net/* "Battle.net 缓存"
    if [[ -d ~/Library/Application\ Support/Battle.net ]]; then
        safe_clean ~/Library/Application\ Support/Battle.net/Cache/* "Battle.net 应用缓存"
    fi
    safe_clean ~/Library/Caches/com.ea.*/* "EA Origin 缓存"
    safe_clean ~/Library/Caches/com.gog.galaxy/* "GOG Galaxy 缓存"
    safe_clean ~/Library/Caches/com.riotgames.*/* "Riot Games 缓存"
    if [[ -d ~/Library/Application\ Support/minecraft ]]; then
        safe_clean ~/Library/Application\ Support/minecraft/logs/* "Minecraft 日志"
        safe_clean ~/Library/Application\ Support/minecraft/crash-reports/* "Minecraft 崩溃报告"
        safe_clean ~/Library/Application\ Support/minecraft/webcache/* "Minecraft Web 缓存"
        safe_clean ~/Library/Application\ Support/minecraft/webcache2/* "Minecraft Web 缓存 2"
    fi
    if [[ -d ~/.lunarclient ]]; then
        safe_clean ~/.lunarclient/game-cache/* "Lunar Client 游戏缓存"
        safe_clean ~/.lunarclient/launcher-cache/* "Lunar Client 启动器缓存"
        safe_clean ~/.lunarclient/logs/* "Lunar Client 日志"
        safe_clean ~/.lunarclient/offline/*/logs/* "Lunar Client 离线日志"
        safe_clean ~/.lunarclient/offline/files/*/logs/* "Lunar Client 离线文件日志"
    fi
    safe_clean ~/Library/Caches/net.pcsx2.PCSX2/* "PCSX2 缓存"
    if [[ -d ~/Library/Application\ Support/PCSX2 ]]; then
        safe_clean ~/Library/Application\ Support/PCSX2/cache/* "PCSX2 着色器缓存"
        safe_clean ~/Library/Logs/PCSX2/* "PCSX2 日志"
    fi
    if [[ -d ~/Library/Application\ Support/rpcs3 ]]; then
        safe_clean ~/Library/Caches/net.rpcs3.rpcs3/* "RPCS3 缓存"
        safe_clean ~/Library/Application\ Support/rpcs3/logs/* "RPCS3 日志"
    fi
}
# Translation/dictionary apps.
clean_translation_apps() {
    safe_clean ~/Library/Caches/com.youdao.YoudaoDict "有道词典缓存"
    safe_clean ~/Library/Caches/com.eudic.* "欧路词典缓存"
    safe_clean ~/Library/Caches/com.bob-build.Bob "Bob 翻译缓存"
}
# Screenshot/recording tools.
clean_screenshot_tools() {
    safe_clean ~/Library/Caches/com.cleanshot.* "CleanShot 缓存"
    safe_clean ~/Library/Caches/com.reincubate.camo "Camo 缓存"
    safe_clean ~/Library/Caches/com.xnipapp.xnip "Xnip 缓存"
}
# Email clients.
clean_email_clients() {
    safe_clean ~/Library/Caches/com.readdle.smartemail-Mac "Spark 缓存"
    safe_clean ~/Library/Caches/com.airmail.* "Airmail 缓存"
}
# Task management apps.
clean_task_apps() {
    safe_clean ~/Library/Caches/com.todoist.mac.Todoist "Todoist 缓存"
    safe_clean ~/Library/Caches/com.any.do.* "Any.do 缓存"
}
# Shell/terminal utilities.
clean_shell_utils() {
    safe_clean ~/.zcompdump* "Zsh 补全缓存"
    safe_clean ~/.lesshst "less 历史"
    safe_clean ~/.viminfo.tmp "Vim 临时文件"
    safe_clean ~/.wget-hsts "wget HSTS 缓存"
    safe_clean ~/.cacher/logs/* "Cacher 日志"
    safe_clean ~/.kite/logs/* "Kite 日志"
    safe_clean ~/Library/Caches/dev.warp.Warp-Stable/* "Warp 缓存"
    safe_clean ~/Library/Logs/warp.log "Warp 日志"
    safe_clean ~/Library/Caches/SentryCrash/Warp/* "Warp Sentry 崩溃报告"
    safe_clean ~/Library/Caches/com.mitchellh.ghostty/* "Ghostty 缓存"
}
# Input methods and system utilities.
clean_system_utils() {
    safe_clean ~/Library/Caches/com.runjuu.Input-Source-Pro/* "Input Source Pro 缓存"
    safe_clean ~/Library/Caches/macos-wakatime.WakaTime/* "WakaTime 缓存"
    # WeType input method (image and dict update cache, not engine or user dict)
    safe_clean ~/Library/Application\ Support/WeType/com.onevcat.Kingfisher.ImageCache.WeType/* "WeType 图片缓存"
    safe_clean ~/Library/Application\ Support/WeType/DictUpdate/* "WeType 词库更新缓存"
    # mihomo-party proxy tool (Electron)
    if [[ -d ~/Library/Application\ Support/mihomo-party ]]; then
        safe_clean ~/Library/Application\ Support/mihomo-party/Cache/* "mihomo-party 缓存"
        safe_clean ~/Library/Application\ Support/mihomo-party/Code\ Cache/* "mihomo-party 代码缓存"
        safe_clean ~/Library/Application\ Support/mihomo-party/GPUCache/* "mihomo-party GPU 缓存"
        safe_clean ~/Library/Application\ Support/mihomo-party/DawnGraphiteCache/* "mihomo-party Dawn 缓存"
        safe_clean ~/Library/Application\ Support/mihomo-party/DawnWebGPUCache/* "mihomo-party WebGPU 缓存"
        safe_clean ~/Library/Application\ Support/mihomo-party/logs/* "mihomo-party 日志"
    fi
    # Stash proxy tool
    safe_clean ~/Library/Caches/ws.stash.app.mac/* "Stash 缓存"
}
# Note-taking apps.
clean_note_apps() {
    safe_clean ~/Library/Caches/notion.id/* "Notion 缓存"
    safe_clean ~/Library/Caches/md.obsidian/* "Obsidian 缓存"
    safe_clean ~/Library/Caches/com.logseq.*/* "Logseq 缓存"
    safe_clean ~/Library/Caches/com.bear-writer.*/* "Bear 缓存"
    safe_clean ~/Library/Caches/com.evernote.*/* "Evernote 缓存"
    safe_clean ~/Library/Caches/com.yinxiang.*/* "印象笔记缓存"
}
# Launchers and automation tools.
clean_launcher_apps() {
    safe_clean ~/Library/Caches/com.runningwithcrayons.Alfred/* "Alfred 缓存"
    safe_clean ~/Library/Caches/cx.c3.theunarchiver/* "The Unarchiver 缓存"
}
# Remote desktop tools.
clean_remote_desktop() {
    safe_clean ~/Library/Caches/com.teamviewer.*/* "TeamViewer 缓存"
    safe_clean ~/Library/Caches/com.anydesk.*/* "AnyDesk 缓存"
    safe_clean ~/Library/Caches/com.todesk.*/* "ToDesk 缓存"
    safe_clean ~/Library/Caches/com.sunlogin.*/* "向日葵缓存"
}
# Main entry for GUI app cleanup.
clean_user_gui_applications() {
    # Product and media App Container rows share one recursive-handle budget.
    local _MOLE_CONTAINER_CACHE_PROBE_DEADLINE=""
    stop_section_spinner
    clean_communication_apps
    clean_dingtalk
    clean_ai_apps
    clean_design_tools
    clean_video_tools
    clean_3d_tools
    clean_productivity_apps
    clean_media_players
    clean_video_players
    clean_download_managers || return $?
    clean_gaming_platforms
    clean_translation_apps
    clean_screenshot_tools
    clean_email_clients
    clean_task_apps
    clean_shell_utils
    clean_system_utils
    clean_note_apps
    clean_launcher_apps
    clean_remote_desktop
}
