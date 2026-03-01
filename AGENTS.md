# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

Venera — 跨平台漫画阅读器（Flutter 3.38.5 / Dart >=3.8.0），支持 Android、iOS、Windows、Linux、macOS、Web。通过 JavaScript 脚本动态加载漫画源，支持本地漫画与 WebDAV 远程同步。

## 常用命令

```bash
# 开发运行
flutter run
flutter run -d <device_id>

# 构建
flutter build apk              # Android
flutter build ios              # iOS
flutter build macos --release  # macOS
flutter build windows          # Windows
flutter build linux            # Linux

# 代码分析与格式化
flutter analyze
dart format lib/

# 测试
flutter test

# 无头模式
flutter run -- --headless webdav up    # WebDAV 上传同步
flutter run -- --headless webdav down  # WebDAV 下载同步
```

构建前提：需安装 Flutter 和 Rust (1.85.1+)。多个依赖使用 git 自定义分支（flutter_qjs、photo_view、rhttp 等）。

## 架构

### 分层结构

- **`lib/foundation/`** — 核心逻辑层：应用状态、漫画源管理、图片加载、数据持久化、JS 引擎
- **`lib/network/`** — 网络层：DIO 客户端配置、缓存拦截器、Cookie 持久化、下载管理、代理
- **`lib/pages/`** — 页面层：各业务页面和阅读器
- **`lib/components/`** — 可复用 UI 组件库
- **`lib/utils/`** — 工具函数：文件 I/O、数据同步、格式处理（PDF/EPUB/CBZ/MOBI）

### 关键子系统

**漫画源系统** (`foundation/comic_source/`)：通过 flutter_qjs JavaScript 引擎执行漫画源脚本。`ComicSourceManager` 统一管理源的加载/卸载。源脚本规范见 `doc/comic_source.md`，JS API 见 `doc/js_api.md`。

**图片加载系统** (`foundation/image_provider/`)：`BaseImageProvider` 为基类，提供屏幕自适应缩放和缓存。子类按场景区分：`ReaderImageProvider`（阅读器）、`WebDavComicImageProvider`（WebDAV）、`LocalComicImageProvider`（本地）等。

**状态管理**：自定义 `GlobalState` 容器（`foundation/global_state.dart`），配合 `ChangeNotifier` 用于各 Manager。无第三方状态管理框架。

**数据持久化**：SQLite3 存储 cookie/历史/设置；JSON 文件存储应用配置（`appdata.json`）和同步数据（`syncdata.json`）。

**阅读器** (`pages/reader/`)：支持多种阅读模式，含手势识别、章节管理、图片预加载。WebDAV 场景支持 MOBI/PDF 流式读取（仅下载头部）。

### 初始化流程 (`lib/init.dart`)

`App.init()` → Cookie 初始化 → 并行初始化（Rhttp、UI 组件、多语言、JS 引擎、漫画源、标签翻译）→ 迁移检查。

### 入口 (`lib/main.dart`)

支持 `--headless` 标志进入无头模式（CLI 自动化任务）。桌面端使用 `window_manager` 管理窗口。

## Lint 配置

基于 `flutter_lints`，已禁用：`use_build_context_synchronously`、`avoid_print`、`collection_methods_unrelated_type`。

## 文档

- 漫画源开发：`doc/comic_source.md`
- JS API 参考：`doc/js_api.md`
- 无头模式：`doc/headless_doc.md`
- 漫画导入：`doc/import_comic.md`
