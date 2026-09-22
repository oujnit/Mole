#!/bin/bash
# Mole self-removal: Homebrew formula, manual binaries, config/cache/logs.
# Extracted from the `mole` dispatcher, which now only routes.

set -euo pipefail

if [[ -n "${MOLE_MANAGE_REMOVE_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_MANAGE_REMOVE_LOADED=1

# Resolve this install without using directory contents as ownership proof.
# Source checkouts and Homebrew keep settings at the default path; install.sh
# records the chosen config in SCRIPT_DIR, including colocated installations.
_remove_config_dir() {
    local candidate="${MOLE_CONFIG_DIR:-${SCRIPT_DIR:-}}"
    local launcher="${SCRIPT_PATH:-}"
    if [[ -z "${MOLE_CONFIG_DIR:-}" ]]; then
        if declare -f is_homebrew_install > /dev/null 2>&1 && is_homebrew_install; then
            candidate=""
        elif [[ "${candidate%/}" == "${launcher%/*}" &&
            -f "$candidate/AGENTS.md" && -f "$candidate/go.mod" &&
            ! -f "$candidate/install_channel" && ! -f "$candidate/.helper_install_incomplete" ]]; then
            candidate=""
        fi
    fi
    candidate="${candidate:-${HOME%/}/.config/mole}"
    printf '%s\n' "${candidate%/}"
}

# Remove flow (Homebrew + manual + config/cache).
remove_mole() {
    local dry_run_mode="${1:-false}"
    local remove_config_dir
    local test_mode=false
    if [[ "${MOLE_TEST_MODE:-0}" == "1" ]]; then
        test_mode=true
    fi

    if [[ -t 1 ]]; then
        start_inline_spinner "正在检测 Mole 安装…"
    else
        echo "正在检测安装…"
    fi

    local is_homebrew=false
    local brew_cmd=""
    local brew_has_mole="false"
    local -a manual_installs=()
    local -a alias_installs=()

    if [[ "$test_mode" != "true" ]]; then
        if command -v brew > /dev/null 2>&1; then
            brew_cmd="brew"
        elif [[ -x "/opt/homebrew/bin/brew" ]]; then
            brew_cmd="/opt/homebrew/bin/brew"
        elif [[ -x "/usr/local/bin/brew" ]]; then
            brew_cmd="/usr/local/bin/brew"
        fi

        if [[ -n "$brew_cmd" ]]; then
            if brew_mole_formula_installed "$brew_cmd"; then
                brew_has_mole="true"
            fi
        fi

        if [[ "$brew_has_mole" == "true" ]] || is_homebrew_install; then
            is_homebrew=true
        fi
    fi

    local found_mole
    found_mole=""
    if [[ "$test_mode" != "true" ]]; then
        found_mole=$(command -v mole 2> /dev/null || true)
        if [[ -n "$found_mole" && -f "$found_mole" ]]; then
            if [[ ! -L "$found_mole" ]] || ! readlink "$found_mole" | grep -q "Cellar/mole"; then
                manual_installs+=("$found_mole")
            fi
        fi
    fi

    local -a fallback_paths=()
    if [[ "$test_mode" == "true" ]]; then
        fallback_paths=("$HOME/.local/bin/mole")
    else
        fallback_paths=(
            "/usr/local/bin/mole"
            "$HOME/.local/bin/mole"
            "/opt/local/bin/mole"
        )
    fi

    for path in "${fallback_paths[@]}"; do
        if [[ -f "$path" && "$path" != "$found_mole" ]]; then
            if [[ ! -L "$path" ]] || ! readlink "$path" | grep -q "Cellar/mole"; then
                manual_installs+=("$path")
            fi
        fi
    done

    local found_mo
    found_mo=""
    if [[ "$test_mode" != "true" ]]; then
        found_mo=$(command -v mo 2> /dev/null || true)
        if [[ -n "$found_mo" && -f "$found_mo" ]]; then
            if [[ ! -L "$found_mo" ]] || ! readlink "$found_mo" | grep -q "Cellar/mole"; then
                alias_installs+=("$found_mo")
            fi
        fi
    fi

    local -a alias_fallback=()
    if [[ "$test_mode" == "true" ]]; then
        alias_fallback=("$HOME/.local/bin/mo")
    else
        alias_fallback=(
            "/usr/local/bin/mo"
            "$HOME/.local/bin/mo"
            "/opt/local/bin/mo"
        )
    fi

    for alias in "${alias_fallback[@]}"; do
        if [[ -f "$alias" && "$alias" != "$found_mo" ]]; then
            if [[ ! -L "$alias" ]] || ! readlink "$alias" | grep -q "Cellar/mole"; then
                alias_installs+=("$alias")
            fi
        fi
    done

    if [[ -t 1 ]]; then
        stop_inline_spinner
    fi

    printf '\n'

    remove_config_dir="$(_remove_config_dir)"

    local manual_count=${#manual_installs[@]}
    local alias_count=${#alias_installs[@]}
    if [[ "$is_homebrew" == "false" && ${manual_count:-0} -eq 0 && ${alias_count:-0} -eq 0 ]]; then
        printf '%s\n\n' "${YELLOW}未检测到 Mole 安装${NC}"
        exit 0
    fi

    # Dry-run mode: show preview and exit without confirmation
    if [[ "$dry_run_mode" == "true" ]]; then
        echo -e "${YELLOW}${ICON_DRY_RUN} 预览模式${NC}，不会删除任何文件"
        echo ""
        echo -e "${YELLOW}移除 Mole${NC}，将删除以下内容："
        if [[ "$is_homebrew" == "true" ]]; then
            echo -e "  ${GRAY}${ICON_LIST} 将执行：brew uninstall --force mole${NC}"
        fi
        if [[ ${manual_count:-0} -gt 0 ]]; then
            for install in "${manual_installs[@]}"; do
                [[ -f "$install" ]] && echo -e "  ${GRAY}${ICON_LIST} 将删除：${install}${NC}"
            done
        fi
        if [[ ${alias_count:-0} -gt 0 ]]; then
            for alias in "${alias_installs[@]}"; do
                [[ -f "$alias" ]] && echo -e "  ${GRAY}${ICON_LIST} 将删除：${alias}${NC}"
            done
        fi
        [[ -d "$HOME/.cache/mole" ]] && echo -e "  ${GRAY}${ICON_LIST} 将删除：$HOME/.cache/mole${NC}"
        if [[ -d "$remove_config_dir" ]]; then
            if [[ "$remove_config_dir" == "${HOME%/}/.config/mole" ]]; then
                echo -e "  ${GRAY}${ICON_LIST} 将移到废纸篓：$remove_config_dir${NC}"
            else
                echo "  ${ICON_LIST} ${remove_config_dir}（保留供手动检查）"
            fi
        fi
        [[ -d "$HOME/Library/Logs/mole" ]] && echo -e "  ${GRAY}${ICON_LIST} 将删除：$HOME/Library/Logs/mole${NC}"

        printf '\n%s\n\n' "${GREEN}${ICON_SUCCESS}${NC} 预览完成，未做任何更改"
        exit 0
    fi

    echo -e "${YELLOW}移除 Mole${NC}，将删除以下内容："
    if [[ "$is_homebrew" == "true" ]]; then
        echo "  ${ICON_LIST} 通过 Homebrew 安装的 Mole"
    fi
    for install in ${manual_installs[@]+"${manual_installs[@]}"} ${alias_installs[@]+"${alias_installs[@]}"}; do
        echo "  ${ICON_LIST} $install"
    done
    if [[ "$remove_config_dir" == "${HOME%/}/.config/mole" ]]; then
        echo "  ${ICON_LIST} ~/.config/mole（移至废纸篓）"
    elif [[ -d "$remove_config_dir" ]]; then
        echo "  ${ICON_LIST} ${remove_config_dir}（保留供手动检查）"
    fi
    echo "  ${ICON_LIST} ~/.cache/mole"
    echo "  ${ICON_LIST} ~/Library/Logs/mole"
    echo -ne "${PURPLE}${ICON_ARROW}${NC} 按 ${GREEN}回车${NC} 确认，${GRAY}ESC${NC} 取消: "

    IFS= read -r -s -n1 key || key=""
    drain_pending_input # Clean up any escape sequence remnants
    case "$key" in
        $'\e')
            exit 0
            ;;
        "" | $'\n' | $'\r')
            printf "\r\033[K" # Clear the prompt line
            ;;
        *)
            exit 0
            ;;
    esac

    local has_error=false
    if [[ "$is_homebrew" == "true" ]]; then
        if [[ -z "$brew_cmd" ]]; then
            log_error "未找到 Homebrew 命令。请确保已安装 Homebrew 且位于 PATH 中。"
            log_warning "手动步骤：brew uninstall --force mole"
            exit 1
        fi

        log_info "正在尝试通过 Homebrew 卸载 Mole…"
        local brew_uninstall_output
        if ! brew_uninstall_output=$("$brew_cmd" uninstall --force mole 2>&1); then
            has_error=true
            log_error "通过 Homebrew 卸载失败："
            printf "%s\n" "$brew_uninstall_output" | sed "s/^/${RED}  | ${NC}/" >&2
            log_warning "手动步骤：${YELLOW}brew uninstall --force mole${NC}"
            echo "" # Add a blank line for readability
        else
            log_success "已通过 Homebrew 卸载 Mole。"
        fi
    fi
    if [[ ${manual_count:-0} -gt 0 ]]; then
        for install in "${manual_installs[@]}"; do
            if [[ -f "$install" ]]; then
                if [[ ! -w "$(dirname "$install")" ]]; then
                    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]] || ! sudo rm -f "$install" 2> /dev/null; then
                        has_error=true
                    fi
                else
                    if ! rm -f "$install" 2> /dev/null; then
                        has_error=true
                    fi
                fi
            fi
        done
    fi
    if [[ ${alias_count:-0} -gt 0 ]]; then
        for alias in "${alias_installs[@]}"; do
            if [[ -f "$alias" ]]; then
                if [[ ! -w "$(dirname "$alias")" ]]; then
                    if [[ "${MOLE_TEST_MODE:-0}" == "1" || "${MOLE_TEST_NO_AUTH:-0}" == "1" ]] || ! sudo rm -f "$alias" 2> /dev/null; then
                        has_error=true
                    fi
                else
                    if ! rm -f "$alias" 2> /dev/null; then
                        has_error=true
                    fi
                fi
            fi
        done
    fi
    if [[ -d "$HOME/.cache/mole" ]]; then
        rm -rf "$HOME/.cache/mole" 2> /dev/null || true # SAFE: hardcoded Mole-owned dir, -d guarded
    fi
    # --config can merge into a shared tree such as ~/.local. Neither known
    # top-level names nor a recursive filename inventory proves ownership.
    # Only the reserved default config root can be moved as a whole.
    if [[ "$remove_config_dir" == "${HOME%/}/.config/mole" && -d "$remove_config_dir" ]]; then
        # The config dir holds user-authored state (whitelist, purge config),
        # which is the one thing here a reinstall cannot rebuild. Move it to
        # Trash so it stays recoverable (#1346); cache and logs around it are
        # rebuildable and stay permanent removals. On failure leave it in
        # place rather than falling back to deletion.
        local config_trash="$HOME/.Trash/mole-config"
        local config_trash_n=1
        while [[ -e "$config_trash" || -L "$config_trash" ]]; do
            config_trash="$HOME/.Trash/mole-config-$config_trash_n"
            config_trash_n=$((config_trash_n + 1))
        done
        if ! mkdir -p "$HOME/.Trash" 2> /dev/null ||
            ! mv -f "$remove_config_dir" "$config_trash" 2> /dev/null; then
            has_error=true
            log_warning "无法将 $remove_config_dir 移到废纸篓；已保留原处"
        fi
    fi
    if [[ -d "$HOME/Library/Logs/mole" ]]; then
        rm -rf "$HOME/Library/Logs/mole" 2> /dev/null || true # SAFE: hardcoded Mole-owned dir, -d guarded
    fi

    local final_message
    if [[ "$has_error" == "true" ]]; then
        final_message="${YELLOW}${ICON_ERROR} Mole 卸载过程中出现一些错误，感谢使用 Mole！${NC}"
    else
        final_message="${GREEN}${ICON_SUCCESS} Mole 已成功卸载，感谢使用 Mole！${NC}"
    fi
    printf '\n%s\n\n' "$final_message"

    exit 0
}
