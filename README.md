# ClipFlow

原生 macOS 剪贴板历史工具。默认通过 **Command + `1234567890-=`** 粘贴置顶优先的前12条记录；提供 Option 回退、释放全部快捷键和按应用排除。

当前版本为 **0.3.0 开发预览**，尚未完成全部跨应用和连续粘贴验收。仓库包含源码、测试、构建脚本与阶段验证记录。

## 功能

- 菜单栏常驻，关闭管理窗口后继续运行。
- SQLite 保存历史索引，独立文件保存原始二进制数据；默认不按时间或数量自动删除。
- 保留纯文本、Markdown、RTF/HTML、图片、PDF、文件引用及可物化的自定义剪贴板格式，支持多个剪贴板项目。
- 本地 HTML 历史页面：搜索、格式筛选、分页、预览、复制、置顶、取消置顶和删除历史索引。
- 置顶记录优先占用快捷键；最后置顶的排在最前。新复制不会挤掉置顶记录，粘贴不改变历史顺序。
- 纯文本优先使用 Unicode 输入；其他格式使用临时剪贴板与串行队列，提供等待参数。
- 暂停监听、权限诊断、快捷键冲突提示、按前台应用释放快捷键。
- 历史仅本机存储，无云同步、遥测或网络传输；管理页面不执行剪贴板中的 HTML。

Markdown 保留剪贴板中提供的源码和原始字节，不从已渲染网页推测或还原原始 Markdown。文件仅保存引用，不备份文件本体；移动或删除源文件可能导致旧记录失效。

## 构建与运行

需要 macOS 和 Swift 6 工具链（Xcode 或 Command Line Tools），系统自带 SQLite，无第三方包依赖。

```sh
git clone https://github.com/lrc839-tech/ClipFlow.git
cd ClipFlow
./scripts/test.sh
./scripts/build.sh
```

构建脚本会安装到 `~/Applications/ClipFlow.app`，并生成 `dist/ClipFlow-0.3.zip`。脚本使用本机缓存目录构建和签名，避免文件提供方目录附加 Finder 元数据导致签名失效。

App 使用临时签名，未做 Developer ID 签名或公证。当前实际测试环境为 Apple Silicon、macOS 27.0.1、Swift 6.4 / Command Line Tools。包声明最低 macOS 14，不代表已验证所有系统版本或 Intel Mac。

### 输入权限

1. 打开 `~/Applications/ClipFlow.app`。
2. 到系统设置 → 隐私与安全性 → 辅助功能（部分系统显示“设备控制和数据访问”），添加并启用本机 App。
3. 退出重开，或点击历史页“重试注册”，确认权限就绪和快捷键注册状态。

重新构建会改变临时签名。旧条目即使显示开启，也可能不匹配新二进制；需要移除旧条目并重新添加当前 App。不要修改 TCC 数据库或关闭系统安全保护。

未取得输入权限时不占用全局快捷键，历史查看和复制按钮仍可使用。

### 快捷键与历史

`Command+1` 对应当前第一槽，依次到 `Command+=` 的第12槽。置顶记录排在普通历史之前；超过12条置顶时，只有前12条占用快捷键。

Command 模式会占用浏览器切标签、缩放等同组合功能。历史页顶部可释放全部快捷键、切换 Option，或配置按应用排除。排除应用进入前台后注销12键，切回允许应用后重新注册；应用切换通知存在短暂处理间隔。

系统保留组合、安全输入或其他全局工具可能阻止接管，不能保证在所有软件上无条件优先。暂停历史监听与释放快捷键是两个独立操作。

## 数据与隐私

| 内容 | 本机路径 |
|---|---|
| 历史索引 | `~/Library/Application Support/ClipFlow/history.sqlite3` |
| 二进制内容 | `~/Library/Application Support/ClipFlow/blobs/` |
| 诊断摘要 | `~/Library/Logs/ClipFlow/diagnostics.json` |

历史目录权限0700，主数据库和新写 blob 为0600；没有应用级加密。备份应保持数据库和 blob 一致，运行中的 SQLite 还可能有 WAL 文件。

已识别的敏感剪贴板标记、文件承诺及超过64 MiB的快照会拒绝收录；无法可靠识别未标记的密码。50ms轮询也无法追回两次采样之间已被覆盖的复制。

删除目前只移除历史索引，blob和SQLite空闲页仍可能保留，不是安全擦除。启动时不重复导入现有系统剪贴板；恢复监听时也不补存暂停期间的内容。

本仓库排除了剪贴板数据库、blob、原始诊断日志、测试输出、构建缓存和本机安装包。阶段文档引用的 `output/` 证据仅保留在开发机器上，不随仓库公开。

## 验证状态

2026-11-06发布前在开发机重跑 **53项测试、12个测试套件全部通过**。测试使用隔离临时数据库和具名系统剪贴板，不读取或修改用户的 general 剪贴板。

| 验证项 | 已取得的证据 / 尚存边界 |
|---|---|
| 持久化 | 真实应用重开、隔离进程 SIGKILL 提交前后恢复、schema迁移及原始多格式字节检查通过；系统重启仍待手工测试 |
| Command注册 | 当前固定版本授权恢复后，12键实际注册成功；独立Carbon实验验证占用冲突与释放 |
| Command实键 | Target中1/2/3三次按所选记录逐项接收、焦点正确；严格固定CBA与连续压力验收尚未通过 |
| 原Option测试 | 12键实键匹配通过；两轮各90次发送与接收映射匹配，但各有两组预设123变成132，根因尚未确定 |
| 格式与管理 | 多格式存储、Markdown原字节、双文件引用结构、历史页面和置顶持久化已验证；不代表各目标软件保真验收通过 |
| 待验收 | 完整Command12键、持续高速粘贴、Edge冲突与释放、Finder双文件真实复制、混合格式队列、多应用兼容、屏幕可见延迟 |

事件状态 `posted-unconfirmed` 只代表已发布输入事件。没有通用的目标应用消费回执，等待参数是估计策略；仅检查前台进程，无法覆盖同一应用内所有窗口/输入框变化。

手工验证请使用独立测试输入区和测试目录。完整步骤与限制见[手工验收](docs/manual-acceptance.md)和[0.3 Command模式记录](docs/v0.3-command-mode.md)。未通过项不会因为发布源码而标为完成。

## 开发目录

- `Sources/ClipFlowCore`：热键、快照、监听、FIFO、持久化与粘贴服务。
- `Sources/ClipFlowApp`：正式菜单栏服务和本地历史页面。
- `Sources/ClipFlowProbe`：早期固定槽位 M0 原型，使用 Option 快捷键。
- `Sources/ClipFlowTarget`：独立输入接收窗口，日志保留内容摘要，不保留输入明文。
- `Tests/ClipFlowCoreTests`：核心自动化测试。
- `scripts`：构建、测试与需显式运行的实验脚本。

```sh
# 隔离临时数据库中的真实崩溃恢复实验
python3 scripts/test_crash.py
# 构建早期 M0 Probe 和 Target（与当前 App 分开）
./scripts/build.sh m0
```

`test_general.sh`、`test_external_copy.sh` 等实验会使用真实 general 剪贴板；请先阅读脚本说明，不能放入日常自动构建。M0 Probe 和当前 App 不应同时占用相同组合。

原始需求：[ClipFlow_Codex_开发需求.md](ClipFlow_Codex_开发需求.md)。阶段记录：[M0设计](docs/M0-design.md)、[M0结果](docs/M0-results.md)、[M1结果](docs/M1-results.md)、[0.2多格式与历史管理](docs/v0.2-results.md)、[0.3 Command接管](docs/v0.3-command-mode.md)。历史文档中的阶段状态和Option说明以其记录时点为准，当前行为以本页和0.3文档为准。
