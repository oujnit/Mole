#!/bin/bash

show_clean_help() {
    echo "用法：mo clean [选项]"
    echo ""
    echo "删除缓存、日志、临时文件以及已卸载应用的残留，以释放磁盘空间。"
    echo ""
    echo "选项："
    echo "  --dry-run, -n     预览清理操作而不做任何更改"
    echo "  --external PATH   清理已挂载外置硬盘上的系统元数据"
    echo "  --whitelist       管理受保护路径"
    echo "  --debug           显示详细操作日志"
    echo "  -h, --help        显示本帮助信息"
}

show_installer_help() {
    echo "用法：mo installer [选项]"
    echo ""
    echo "查找并删除安装包文件（.dmg、.pkg、.iso、.xip、.zip）。"
    echo ""
    echo "选项："
    echo "  --dry-run         预览安装包清理操作而不做任何更改"
    echo "  --debug           显示详细操作日志"
    echo "  -h, --help        显示本帮助信息"
}

show_optimize_help() {
    echo "用法：mo optimize [选项]"
    echo ""
    echo "刷新系统缓存与服务，修复安全的维护问题。"
    echo ""
    echo "选项："
    echo "  --dry-run         预览优化操作而不做任何更改"
    echo "  --whitelist       管理受保护项"
    echo "  --debug           显示详细操作日志"
    echo "  -h, --help        显示本帮助信息"
}

show_touchid_help() {
    echo "用法：mo touchid [命令]"
    echo ""
    echo "配置 Touch ID 用于 sudo 认证。"
    echo ""
    echo "命令："
    echo "  enable            启用 Touch ID 用于 sudo"
    echo "  disable           禁用 Touch ID 用于 sudo"
    echo "  status            显示当前 Touch ID 状态"
    echo ""
    echo "选项："
    echo "  --dry-run         预览 Touch ID 更改而不修改 sudo 配置"
    echo "  -h, --help        显示本帮助信息"
    echo ""
    echo "如未提供命令，将显示交互式菜单。"
}

show_uninstall_help() {
    echo "用法：mo uninstall [选项] [应用名称 ...]"
    echo ""
    echo "交互式移除应用及其残留文件。"
    echo "也可指定一个或多个应用名称直接卸载。"
    echo "对于已卸载应用的残留，请使用 mo clean。"
    echo ""
    echo "示例："
    echo "  mo uninstall                   打开交互式应用选择器"
    echo "  mo uninstall slack             卸载 Slack"
    echo "  mo uninstall slack zoom        卸载 Slack 和 Zoom"
    echo "  mo uninstall --dry-run slack   预览 Slack 的卸载"
    echo "  mo uninstall --list            显示已安装应用及 mo uninstall 可接受的名称"
    echo ""
    echo "选项："
    echo "  --list            列出已安装应用及其 mo uninstall 可接受的精确名称"
    echo "  --dry-run         预览应用卸载而不做任何更改"
    echo "  --permanent       跳过 macOS 废纸篓并立即执行 rm -rf"
    echo "  --whitelist       卸载不支持（请使用 clean/optimize）"
    echo "  --debug           显示详细操作日志"
    echo "  -h, --help        显示本帮助信息"
    echo ""
    echo "默认情况下，被卸载的文件会移入 macOS 废纸篓，以便"
    echo "恢复。使用 --permanent 可跳过废纸篓步骤。"
}
