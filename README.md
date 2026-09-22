<div align="center">
  <h1>Mole</h1>
  <p><em>深度清理并优化你的 Mac。</em></p>
</div>

<p align="center">
  <a href="https://github.com/tw93/mole/stargazers"><img src="https://img.shields.io/github/stars/tw93/mole?style=flat-square" alt="Stars"></a>
  <a href="https://github.com/tw93/mole/releases"><img src="https://img.shields.io/github/v/tag/tw93/mole?label=version&style=flat-square" alt="Version"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License"></a>
  <a href="https://github.com/tw93/mole/commits"><img src="https://img.shields.io/github/commit-activity/m/tw93/mole?style=flat-square" alt="Commits"></a>
  <a href="https://twitter.com/HiTw93"><img src="https://img.shields.io/badge/follow-Tw93-red?style=flat-square&logo=Twitter" alt="Twitter"></a>
  <a href="https://t.me/+GclQS9ZnxyI2ODQ1"><img src="https://img.shields.io/badge/chat-Telegram-blueviolet?style=flat-square&logo=Telegram" alt="Telegram"></a>
</p>

<p align="center">
  <img src="https://cdn.tw93.fun/img/mole.jpeg" alt="Mole - 已释放 95.50GB" width="1000" />
</p>

> 本仓库是 [tw93/Mole](https://github.com/tw93/Mole) 的中文汉化 Fork。最新汉化代码位于 [`upgrade-origin-main`](https://github.com/oujnit/Mole/tree/upgrade-origin-main) 分支。

## 功能亮点

- **一体化工具箱**：将 CleanMyMac、AppCleaner、DaisyDisk 和 iStat Menus 的常用能力整合进**单个二进制文件**
- **深度清理**：移除缓存、日志和浏览器残留，**释放数 GB 磁盘空间**
- **智能卸载**：删除应用及其启动项、偏好设置和**隐藏残留**
- **磁盘分析**：可视化空间占用、查找大文件、**重建缓存**并刷新系统服务
- **实时监控**：展示 CPU、GPU、内存、磁盘和网络的实时状态

## 快速开始

**通过 Homebrew 安装官方版**

```bash
brew install mole
```

**通过脚本安装本 Fork 的中文汉化版**

```bash
curl -fsSL https://raw.githubusercontent.com/oujnit/Mole/upgrade-origin-main/install.sh | bash
```

> Mole 主要面向 macOS。官方仓库还提供实验性的 [Windows 分支](https://github.com/tw93/Mole/tree/windows)，供早期体验。

**运行命令**

```bash
mo                           # 交互式菜单
mo clean                     # 深度清理
mo uninstall                 # 卸载应用及残留文件
mo optimize                  # 刷新缓存与系统服务
mo analyze                   # 可视化磁盘分析器
mo status                    # 实时系统健康面板
mo purge                     # 清理项目构建产物
mo installer                 # 查找并删除安装包

mo touchid                   # 配置 Touch ID 以执行 sudo
mo completion                # 配置 Shell 命令补全
mo update                    # 更新 Mole
mo update --nightly          # 更新到尚未发布的最新主分支版本，仅适用于脚本安装
mo remove                    # 从系统中移除 Mole
mo --help                    # 显示帮助
mo --version                 # 显示已安装版本
```

**安全预览**

```bash
mo clean --dry-run
mo uninstall --dry-run
mo purge --dry-run

# 同样适用于：optimize、installer、remove、completion、touchid enable
mo clean --dry-run --debug   # 预览并显示详细日志
mo optimize --whitelist      # 管理受保护的优化规则
mo clean --whitelist         # 管理受保护的缓存
mo purge --paths             # 配置项目扫描目录
mo analyze /Volumes          # 仅分析外置磁盘
```

## 安全设计

Mole 是本地系统维护工具，部分命令会执行具有破坏性的本地文件操作。

Mole 默认以安全为先：验证路径、保护关键目录、采用保守的清理边界，并对高风险操作要求明确确认。当风险较高或状态无法确认时，Mole 会跳过、拒绝操作或要求更严格的确认，而不会擅自扩大删除范围。

临时清理文件时，`mo analyze` 更为稳妥，因为它会通过 Finder 将文件移入废纸篓，而不是直接永久删除。

有关问题报告、安全边界和当前限制，请阅读 [SECURITY.md](SECURITY.md) 与 [SECURITY_AUDIT.md](SECURITY_AUDIT.md)。

## 使用提示

- 视频教程：感谢 PAPAYA 電腦教室制作的 [Mole 教程视频](https://www.youtube.com/watch?v=UEe9-w4CcQ0)。
- 安全与日志：`clean`、`uninstall`、`purge`、`installer` 和 `remove` 都可能删除文件。建议先使用 `--dry-run` 预览，需要排查问题时再加上 `--debug`。文件操作会记录在 `~/Library/Logs/mole/operations.log`，可通过 `MO_NO_OPLOG=1` 关闭。另请阅读 [SECURITY.md](SECURITY.md) 与 [SECURITY_AUDIT.md](SECURITY_AUDIT.md)。
- 导航操作：Mole 支持方向键与 Vim 风格的 `h/j/k/l` 按键。

## 功能详解

### 深度系统清理

```bash
$ mo clean

正在扫描缓存目录...

  ✓ 用户应用缓存                                             45.2GB
  ✓ 浏览器缓存（Chrome、Safari、Firefox）                    10.5GB
  ✓ 开发工具（Xcode、Node.js、npm）                          23.3GB
  ✓ 系统日志与临时文件                                        3.8GB
  ✓ 应用专用缓存（Spotify、Dropbox、Slack）                   8.4GB
  ✓ 废纸篓                                                   12.3GB

====================================================================
已释放空间：95.5GB | 当前可用空间：223.5GB
====================================================================
```

说明：在 `mo clean` → 开发工具清理中，Mole 会移除未使用的 CoreSimulator `Volumes/Cryptex` 条目，并跳过标记为 `IN_USE` 的项目。

### 智能应用卸载

```bash
$ mo uninstall

选择要移除的应用
═══════════════════════════
▶ ☑ Photoshop 2024            (4.2G) | 旧应用
  ☐ IntelliJ IDEA             (2.8G) | 最近使用
  ☐ Premiere Pro              (3.4G) | 最近使用

正在卸载：Photoshop 2024

  ✓ 已移除应用
  ✓ 已清理 12 个位置中的 52 个相关文件
    - 应用支持文件、缓存、偏好设置
    - 日志、WebKit 存储、Cookie
    - 扩展、插件、启动守护程序

====================================================================
已释放空间：12.8GB
====================================================================
```

### 系统优化

```bash
$ mo optimize

系统：内存 5/32 GB | 磁盘 333/460 GB（72%）| 已运行 6 天

  ✓ 重建系统数据库并清理缓存
  ✓ 重置网络服务
  ✓ 刷新 Finder 与程序坞
  ✓ 清理诊断与崩溃日志
  ✓ 移除交换文件并重启动态分页器
  ✓ 重建启动服务与 Spotlight 索引

====================================================================
系统优化完成
====================================================================

使用 `mo optimize --whitelist` 可排除指定的优化项目。
```

### 磁盘空间分析

> 默认情况下，Mole 会跳过 `/Volumes` 下的外置磁盘以加快启动。若要分析外置磁盘，请运行 `mo analyze /Volumes` 或指定具体挂载路径。

```bash
$ mo analyze

磁盘分析  ~/Documents  |  总计：156.8GB

 ▶  1. ███████████████████  48.2%  |  📁 Library                     75.4GB  >6个月
    2. ██████████░░░░░░░░░  22.1%  |  📁 Downloads                   34.6GB
    3. ████░░░░░░░░░░░░░░░  14.3%  |  📁 Movies                      22.4GB
    4. ███░░░░░░░░░░░░░░░░  10.8%  |  📁 Documents                   16.9GB
    5. ██░░░░░░░░░░░░░░░░░   5.2%  |  📄 backup_2023.zip              8.2GB

  ↑↓←→ 导航  |  O 打开  |  F 显示  |  ⌫ 删除  |  L 大文件  |  Q 退出
```

### 实时系统状态

实时仪表盘会展示健康评分、硬件信息和性能指标。

```bash
$ mo status

Mole 状态  健康 ● 92  MacBook Pro · M4 Pro · 32GB · macOS 14.5

⚙ CPU                                    ▦ 内存
总计    ████████████░░░░░░░  45.2%       已用    ███████████░░░░░░░  58.4%
负载    0.82 / 1.05 / 1.23（8 核）       总计    14.2 / 24.0 GB
核心 1  ███████████████░░░░  78.3%       空闲    ████████░░░░░░░░░░  41.6%
核心 2  ████████████░░░░░░░  62.1%       可用    9.8 GB

▤ 磁盘                                   ⚡ 电源
已用    █████████████░░░░░░  67.2%       电量    ██████████████████  100%
空闲    156.3 GB                         状态    已充满
读取    ▮▯▯▯▯  2.1 MB/s                  健康    正常 · 423 次循环
写入    ▮▮▮▯▯  18.3 MB/s                 温度    58°C · 1200 RPM

⇅ 网络                                   ▶ 进程
下载    ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s      Code       ▮▮▮▮▯  42.1%
上传    ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s      Chrome     ▮▮▮▯▯  28.3%
代理    HTTP · 192.168.1.100             Terminal   ▮▯▯▯▯  12.5%
```

健康评分根据 CPU、内存、磁盘、温度和 I/O 负载计算，并通过颜色区间直观呈现。

快捷键：在 `mo status` 中按 `k` 可显示或隐藏小猫并保存偏好，按 `q` 退出。

启用进程告警后，若某个进程持续超过设定的 CPU 阈值，`mo status` 会显示只读告警横幅。可通过 `--proc-cpu-threshold`、`--proc-cpu-window` 或 `--proc-cpu-alerts=false` 调整或关闭该功能。

#### 机器可读输出

`mo analyze` 和 `mo status` 都支持 `--json` 参数，可用于脚本和自动化。

当输出被管道接收而不是直接显示在终端时，`mo status` 也会自动切换为 JSON。

```bash
# 以 JSON 格式分析磁盘
$ mo analyze --json ~/Documents
{
  "path": "/Users/you/Documents",
  "entries": [
    { "name": "Library", "path": "...", "size": 80939438080, "is_dir": true },
    ...
  ],
  "total_size": 168393441280,
  "total_files": 42187
}

# 以 JSON 格式查看系统状态
$ mo status --json
{
  "host": "MacBook-Pro",
  "health_score": 92,
  "cpu": { "usage": 45.2, "logical_cpu": 8, ... },
  "memory": { "total": 25769803776, "used": 15049334784, "used_percent": 58.4 },
  "disks": [ ... ],
  "uptime": "3d 12h 45m",
  ...
}

# 通过管道输出时自动使用 JSON
$ mo status | jq '.health_score'
92
```

### 清理项目构建产物

清理 `node_modules`、`target`、`build` 和 `dist` 等旧构建产物，以释放磁盘空间。

```bash
mo purge

选择要清理的类别 - 18.5GB（已选择 8 项）

➤ ● my-react-app       3.2GB | node_modules
  ● old-project        2.8GB | node_modules
  ● rust-app           4.1GB | target
  ● next-blog          1.9GB | node_modules
  ○ current-work       856MB | node_modules  | 最近使用
  ● django-api         2.3GB | venv
  ● vue-dashboard      1.7GB | node_modules
  ● backend-service    2.5GB | node_modules
```

> 建议在 macOS 上安装 `fd`：
> `brew install fd`

> 安全提示：此功能会永久删除选中的构建产物，请在确认前仔细检查。最近 7 天内更新的项目会被标记，并默认取消选择。

<details>
<summary><strong>自定义扫描路径</strong></summary>

运行 `mo purge --paths` 配置扫描目录，或直接编辑 `~/.config/mole/purge_paths`：

```shell
~/Documents/MyProjects
~/Work/ClientA
~/Work/ClientB
```

配置自定义路径后，Mole 只会扫描这些目录；否则将使用 `~/Projects`、`~/GitHub`、`~/dev` 等默认路径。

</details>

### 清理安装包

查找并删除“下载”、桌面、Homebrew 缓存、iCloud 和邮件中的大型安装包。每个文件都会标注来源。

```bash
mo installer

选择要移除的安装包 - 3.8GB（已选择 5 项）

➤ ● Photoshop_2024.dmg     1.2GB | 下载
  ● IntelliJ_IDEA.dmg       850.6MB | 下载
  ● Illustrator_Setup.pkg   920.4MB | 下载
  ● PyCharm_Pro.dmg         640.5MB | Homebrew
  ● Acrobat_Reader.dmg      220.4MB | 下载
  ○ AppCode_Legacy.zip      410.6MB | 下载
```

## 快速启动器

通过 Raycast 或 Alfred 启动 Mole 命令：

```bash
curl -fsSL https://raw.githubusercontent.com/tw93/Mole/main/scripts/setup-quick-launchers.sh | bash
```

脚本会添加 5 个命令：`Mole Clean`、`Mole Uninstall`、`Mole Optimize`、`Mole Analyze`、`Mole Status`。

### 配置 Raycast

运行脚本后，在 Raycast 中完成以下设置：

1. 打开 Raycast 设置（⌘ + ,）
2. 进入 **Extensions** → **Script Commands**
3. 点击 **Add Script Directory**（或 **+**）
4. 添加路径：`~/Library/Application Support/Raycast/script-commands`
5. 在 Raycast 中搜索并运行 **Reload Script Directories**
6. 完成。搜索 `Mole Clean`、`clean`、`Mole Optimize` 或 `Mole Status` 即可使用

> 脚本会创建命令，但 Raycast 仍需要进行一次手动的脚本目录设置。

### 终端检测

Mole 会自动检测终端应用。iTerm2 存在已知兼容性问题，因此强烈推荐使用 [Kaku](https://github.com/tw93/Kaku)。Alacritty、kitty、WezTerm、Ghostty 和 Warp 也是不错的选择。若要手动指定，请设置 `MO_LAUNCHER_APP=<名称>`。

## 社区支持

感谢所有帮助构建 Mole 的贡献者，也欢迎关注他们。❤️

<a href="https://github.com/tw93/Mole/graphs/contributors">
  <img src="./CONTRIBUTORS.svg?v=2" width="1000" />
</a>

<br/><br/>
以下是用户在 X 上分享 Mole 时留下的真实反馈。

<img src="https://cdn.tw93.fun/pic/lovemole.jpeg" alt="Mole 社区反馈" width="1000" />

## 支持项目

- 如果 Mole 对你有帮助，欢迎为仓库点亮 Star，或[分享给朋友](https://twitter.com/intent/tweet?url=https://github.com/tw93/Mole&text=Mole%20-%20Deep%20clean%20and%20optimize%20your%20Mac.)。
- 有想法或遇到问题？请阅读[贡献指南](CONTRIBUTING.md)，并提交 Issue 或 PR。
- 喜欢 Mole？可以<a href="https://miaoyan.app/cats.html?name=Mole" target="_blank">请 Tw93 喝可乐</a>来支持项目。🥤 支持者名单见下方。

<a href="https://miaoyan.app/cats.html?name=Mole"><img src="https://miaoyan.app/assets/sponsors.svg" width="1000" loading="lazy" /></a>

## 开源许可

Mole 采用 MIT 许可证。欢迎自由使用并参与贡献。
