# ClipFlow 0.3.0 — 开发预览 / Apple Silicon DMG

## 下载与安装

在本页 Assets 下载 **ClipFlow-0.3.0-macOS-arm64.dmg**。这是可以直接安装的应用，无需 Xcode、Swift 或终端编译；Source code 是源码包。

1. 双击 DMG，把 ClipFlow.app 拖到 Applications（应用程序）。
2. 从“应用程序”打开 ClipFlow，不要直接在 DMG 中运行。
3. 首次若被提示无法验证开发者或 Apple 无法检查恶意软件：先尝试打开一次，关闭提示，到“系统设置 → 隐私与安全性 → 安全性”找到 ClipFlow，点击“仍要打开 / Open Anyway”，按系统要求本人验证身份，再点击“打开”。不需要反复双击固定次数。
4. 再到“隐私与安全性 → 辅助功能”（部分系统称“设备控制和数据访问”），添加并启用安装好的 ClipFlow。退出重开或点“重试注册”，确认输入权限就绪、Command快捷键12/12。
5. 正常复制内容，点击目标输入框后，用 Command+1～9、0、-、= 粘贴。历史页可置顶，让记录优先占快捷键。

DMG 内附“安装与首次打开说明.html / .txt”。完整在线步骤：[安装与首次使用](https://github.com/lrc839-tech/ClipFlow/blob/main/docs/INSTALL.md)。系统提示流程参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。允许打开与辅助功能授权是两个步骤。

## 适用范围

- **仅 Apple Silicon（M系列）Mac / arm64**；不是 Intel、Windows 或通用二进制。
- 临时签名，**未经过 Developer ID 签名或 Apple 公证**。
- 仅在 macOS 27.0.1 / Apple Silicon 实测；声明最低macOS14不代表已完成其他版本兼容验证。
- 若提示“将损坏你的电脑”或“已损坏”，请停止安装、重新从本页下载并核对SHA-256，联系维护者。不要关闭系统安全保护或移除隔离属性。

## 验证与限制

53项核心测试通过。DMG完整性、只读挂载、复制出的App签名、原App所有文件一致性、安装说明与Applications拖放入口已校验。该包复用现有0.3.0 App，没有重新构建或改签名，不含开发机剪贴板历史、配置和诊断日志。

外部下载后的Gatekeeper首次打开流程及新用户辅助功能授权需手工验证，未用本机复制验证冒充已通过。完整Command12键、连续高速粘贴、Edge冲突/释放、Finder双文件实际复制、混合格式队列和其他应用兼容性仍待验收，不是稳定版或所有软件优先级保证。

## SHA-256

另附 `SHA256SUMS.txt`；本次DMG校验值：

```text
242e40685d09058fee222a64abecbe369d35687942e1c5ea8de4bec9ec43e299  ClipFlow-0.3.0-macOS-arm64.dmg
```

更新前请退出旧App，替换原安装位置，避免运行多份。若旧权限开关开启但当前版本仍未授权，移除旧条目再添加当前App；历史目录默认保留。
