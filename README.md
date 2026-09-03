# MacEverything

MacEverything 是一款专注于 macOS 平台的高性能本地文件搜索工具。它的核心目标是提供极其小巧的索引体积和**输入即响应**的极速搜索体验，成为 macOS 上的“Everything”完美替代品。

## 🌟 核心特性 (Features)

- **⚡️ 极致性能**：底层引擎完全使用 Rust 构建，UI 层采用原生 SwiftUI。毫秒级检索，绝对快于 Spotlight。
- **📦 极简索引**：使用内存扁平结构（紧凑字符串池 + 定长记录）+ 二进制快照持久化，冷启动毫秒级，在百万级文件下保持极低的内存和磁盘占用。
- **🔐 纯本地运行**：不需要网络连接，不上传任何数据，保护隐私。
- **☁️ 智能云盘穿透**：完美支持 OneDrive、Google Drive 等位于 `~/Library/CloudStorage` 的虚拟同步盘，索引时精确跳过其余 Library 缓存。
- **🇨🇳 拼音搜索**：原生支持全拼、拼音首字母以及拼音部分匹配（如输入 `weixin` 或 `wx` 即可搜索“微信”）。

## ⌨️ 快捷键 (Hotkeys)

- **全局唤醒 / 隐藏**：`Option + Space` (Alt+Space)
- **选择结果**：`↑` / `↓` 方向键
- **打开文件**：`Enter` (回车键)
- **在 Finder 中显示 (Reveal)**：`Command + Enter`
- **预览文件 (QuickLook)**：`Space` (空格键)，按 `Esc` 退出预览。
- **文本操作**：全面支持 `Command + C/V/A/X` 复制粘贴及全选。

## 🔍 搜索语法 (Search Syntax)

除了直接输入文件名外，MacEverything 支持极其强大的高级搜索语法：

### 1. 基础模式
- **普通搜索**：直接输入关键词，多关键词用空格隔开。
- **精准匹配**：使用双引号，如 `"2000 Core English Words"`。
- **全路径搜索**：在输入框内点击 `[路径]` 按钮，或输入 `path:` 前缀（例如 `downloads 2000` 会匹配 `Downloads` 目录下文件名包含 `2000` 的文件）。
- **正则表达式**：在输入框内点击 `[正则]` 按钮，或输入 `regex:` 前缀（例如 `regex:\.pdf$`）。

### 2. 高级过滤
- **类型过滤 (`kind:`)**：
  - `kind:image` (或 `图片`)
  - `kind:video` (或 `视频`)
  - `kind:audio` (或 `音频`)
  - `kind:doc` (或 `文档`，包含 pdf/doc/xls/ppt/txt 等)
  - `kind:archive` (或 `压缩包`，包含 zip/rar/7z 等)
- **大小过滤 (`size:`)**：
  - 语法示例：`size:>10mb`, `size:<1gb`, `size:10kb`
- **时间过滤 (`date:`)**：
  - `date:today` (今天修改的文件)
  - `date:yesterday` (昨天修改的文件)
  - `date:thisweek` (本周修改的文件)
  - `date:thismonth` (本月修改的文件)

**语法组合示例**：
想要搜索本周修改的、大于 10MB 的 PDF 文档：
`kind:doc size:>10mb date:thisweek`

## 📥 安装 (Installation)

1. 从 [Releases](https://github.com/yangaking/mac-everything/releases) 下载最新 `MacEverything-x.y.z.dmg`。
2. 双击挂载后，将 `MacEverything.app` 拖入「应用程序」文件夹。
3. **首次打开**：由于目前使用临时（ad-hoc）签名（未加入 Apple Developer Program），macOS 可能提示「无法验证开发者」。请**右键点击应用 → 打开 → 打开**；或在「系统设置 → 隐私与安全性」点「仍要打开」。
   - 也可用命令解除隔离：`xattr -d com.apple.quarantine /Applications/MacEverything.app`
4. 首次运行需授予「完全磁盘访问权限 (Full Disk Access)」以建立全局索引。

> 想彻底消除 Gatekeeper 警告，需 Apple Developer ID 签名 + 公证（$99/年）。

## 🛠️ 构建指南 (Build Instructions)

本项目分为 `mac-everything-core` (Rust) 和 SwiftUI 前端两部分。

1. **环境准备**：
   - 安装 Xcode (确保包含 Command Line Tools)
   - 安装 Rust 工具链 (`rustup default stable`)
2. **编译运行**：
   - 在项目根目录执行 `./build.sh` 
   - 脚本会自动编译 Rust 核心库为 C-ABI 动态链接库，再通过 `swiftc` 构建前端应用。
   - 编译产物位于 `build/MacEverything.app`。
3. **初次运行**：
   - 首次打开应用需要赋予**完全磁盘访问权限 (Full Disk Access)** 以便建立全局文件索引。赋予权限后重新打开应用即可享受极速搜索。

## 📜 许可证 (License)

本项目采用 Apache-2.0 License。
