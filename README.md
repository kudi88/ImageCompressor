<div align="center">

# 🗜️ ImageCompressor

**轻量 macOS 图片批量压缩工具**

拖拽即压缩，支持 PNG / JPEG / HEIC / TIFF / BMP / WebP

[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue)](https://github.com/kudi88/ImageCompressor)
[![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-green)](LICENSE)

</div>

---

## ✨ 特性

- 🖱️ **拖拽压缩** — 拖入图片或文件夹，一键批量压缩
- 🎚️ **质量调节** — 10%~100% 滑块控制压缩质量
- 🖼️ **格式选择** — 输出 JPEG / PNG / 保持原格式
- 📦 **PNG 有损压缩** — 基于 pngquant 实现真正的 PNG 颜色量化压缩
- 📂 **自定义输出** — 自选输出目录，默认输出到 `compressed` 子文件夹
- 📊 **实时统计** — 每张图压缩前后对比 + 总节省空间
- 💾 **设置持久化** — 质量、格式、输出目录重启后自动恢复
- 🔍 **Finder 集成** — 压缩完成可直接在 Finder 中定位文件

## 📸 截图

| 拖拽区域 | 压缩结果 |
|:---:|:---:|
| 拖入图片即可开始 | 实时显示压缩前后对比与节省率 |

## 🚀 安装

### 方式一：下载预编译包

前往 [Releases](https://github.com/kudi88/ImageCompressor/releases) 下载 `ImageCompressor.zip`，解压后拖入「应用程序」文件夹即可。

### 方式二：从源码构建

```bash
# 克隆仓库
git clone https://github.com/kudi88/ImageCompressor.git
cd ImageCompressor

# 安装 PNG 压缩依赖（推荐）
brew install pngquant

# 编译
swift build -c release

# 生成 .app（可选）
mkdir -p ImageCompressor.app/Contents/MacOS
mkdir -p ImageCompressor.app/Contents/Resources
cp .build/release/ImageCompressor ImageCompressor.app/Contents/MacOS/
cp Info.plist ImageCompressor.app/Contents/
# 然后双击 ImageCompressor.app 运行
```

## 📋 使用

1. **拖入图片** — 将图片或包含图片的文件夹拖入虚线区域
2. **调整设置** — 选择压缩质量、输出格式、输出目录
3. **开始压缩** — 点击「开始压缩」按钮
4. **查看结果** — 列表中实时显示压缩进度和前后对比
5. **定位文件** — 点击文件旁的 📁 图标在 Finder 中打开

## ⚙️ 压缩说明

| 输出格式 | 压缩方式 | 说明 |
|---------|---------|------|
| **JPEG** | CGImageDestination 有损压缩 | 质量滑块直接控制 JPEG quality 值 |
| **PNG** | pngquant 颜色量化 | 有损压缩，通过减少颜色数实现压缩，质量滑块控制颜色数量 |
| **保持原格式** | 按源文件格式选择上述方式 | PNG→pngquant，JPEG→CGImageDestination |

> 💡 PNG 压缩需要安装 [pngquant](https://pngquant.org/)：`brew install pngquant`
> 未安装时 PNG 输出将直接复制原文件。

## 🛠 技术栈

- **UI**: SwiftUI + AppKit
- **压缩引擎**: CoreGraphics / ImageIO (JPEG) + pngquant (PNG)
- **依赖管理**: Swift Package Manager
- **最低系统**: macOS 13 (Ventura)
- **架构**: Apple Silicon (arm64) 原生

## 📝 开发

```bash
# 打开 Xcode 开发
open Package.swift

# 或命令行编译运行
swift build
swift run
```

## ⭐ 支持这个项目

如果这个工具对你有帮助，请给个 **Star** ⭐ — 这是对开源开发者最大的鼓励！

- 🐛 发现问题？[提交 Issue](https://github.com/kudi88/ImageCompressor/issues/new)
- 💡 有想法？[发起讨论](https://github.com/kudi88/ImageCompressor/discussions)
- 🔧 想贡献？[提交 PR](https://github.com/kudi88/ImageCompressor/compare)

**觉得好用？点右上角 ⭐ Star 让更多人看到！**

## 📄 License

[MIT License](LICENSE)
