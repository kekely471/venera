# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

Venera — 跨平台漫画阅读器（Flutter 3.38.5 / Dart >=3.8.0 <4.0.0），支持 Android、iOS、Windows、Linux、macOS、Web。通过 JavaScript 脚本动态加载漫画源，支持本地漫画与 WebDAV 远程同步。

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

# 无头模式（CLI 自动化）
flutter run -- --headless webdav up    # WebDAV 上传同步
flutter run -- --headless webdav down  # WebDAV 下载同步
```

构建前提：需安装 Flutter 和 Rust (1.85.1+)。多个依赖使用 git 自定义分支（flutter_qjs、photo_view、rhttp 等），pub get 时会从 GitHub 拉取。

## 架构

### 分层结构

- **`lib/foundation/`** — 核心逻辑层：应用状态、漫画源管理、图片加载、数据持久化、JS 引擎
- **`lib/network/`** — 网络层：DIO 客户端配置、缓存拦截器、Cookie 持久化、下载管理、代理
- **`lib/pages/`** — 页面层：各业务页面和阅读器
- **`lib/components/`** — 可复用 UI 组件库
- **`lib/utils/`** — 工具函数：文件 I/O、数据同步、格式处理（PDF/EPUB/CBZ/MOBI）

### 关键子系统

**漫画源系统** (`foundation/comic_source/`)：通过 flutter_qjs JavaScript 引擎执行漫画源脚本。`ComicSourceManager` 单例管理源的加载/卸载。源脚本规范见 `doc/comic_source.md`，JS API 见 `doc/js_api.md`。`JsEngine` 缓存单例，整合加密（RSA/AES）、HTML 解析、网络请求等丰富 JS API。

**图片加载系统** (`foundation/image_provider/`)：`BaseImageProvider` 为基类，提供屏幕自适应缩放和缓存。子类按场景区分：`ReaderImageProvider`（阅读器）、`WebDavComicImageProvider`（WebDAV）、`LocalComicImageProvider`（本地）等。

**状态管理**：自定义 `GlobalState` 容器（`foundation/global_state.dart`），支持带 key 的多实例和自动生命周期管理（`AutomaticGlobalState`）。配合 `ChangeNotifier` 用于各 Manager。无第三方状态管理框架。

**数据持久化**：SQLite3（非 sqflite）存储 cookie/历史/设置；JSON 文件存储应用配置（`appdata.json`）和同步数据（`syncdata.json`）。`Settings` 容器支持 WebDAV 同步时的字段排除。

**阅读器** (`pages/reader/`)：支持多种阅读模式，含手势识别、章节管理、图片预加载。WebDAV 场景支持 MOBI/PDF/CBZ 流式读取（仅下载头部即可阅读）。

**网络客户端** (`network/app_dio.dart`)：DIO + 自定义拦截器，处理错误消息国际化、网络异常诊断、Cookie 过滤。高性能场景使用 rhttp（Rust HTTP 客户端）。

### 导航与路由

主页面 5 标签导航（首页、收藏、发现、WebDAV、分类），`MainNavigatorKey` 独立导航栈。路由通过 `context.dart` 扩展方法（`to()`/`toReplacement()`）和自定义 `AppPageRoute`。

### 初始化流程 (`lib/init.dart`)

`App.init()` → Cookie 初始化 → 并行初始化 8 模块（Rhttp、UI 组件、SAF、翻译、标签、JS 引擎、漫画源、OpenCC）→ 迁移检查。Windows 有心跳机制防崩溃重启。

### 入口 (`lib/main.dart`)

支持 `--headless` 标志进入无头模式（CLI 自动化任务）。桌面端使用 `window_manager` 管理窗口。全局异常通过 `runZonedGuarded` 捕获。

### 核心设计特点

- **最小化外部依赖**：自实现状态管理、自定义 JS 引擎和 Rust HTTP 客户端
- **性能优先**：rhttp 替代 DIO 用于高性能场景；流式读取大文件；图片自适应缩放 + 缓存
- **灵活的源系统**：JS 脚本动态加载，无需重编译即可扩展漫画源
- **多语言**：zh-CN、zh-TW、en-US，OpenCC 繁简转换

## Lint 配置

基于 `flutter_lints`，已禁用：`use_build_context_synchronously`、`avoid_print`、`collection_methods_unrelated_type`。

## 文档

- 漫画源开发：`doc/comic_source.md`
- JS API 参考：`doc/js_api.md`
- 无头模式：`doc/headless_doc.md`
- 漫画导入：`doc/import_comic.md`
