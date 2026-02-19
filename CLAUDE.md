# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Venera 是一个跨平台漫画阅读器应用，使用 Flutter 开发，支持 Android、iOS、Linux、macOS 和 Windows。

核心特性：
- 本地漫画阅读
- 使用 JavaScript 创建可扩展的网络漫画源
- 漫画收藏、下载和历史记录管理
- 支持 headless 模式

## 开发环境要求

### 必需组件
- Flutter 3.38.5+
- Dart SDK >= 3.8.0
- Rust 工具链（用于 rhttp 等 Rust 依赖）

### macOS 开发额外要求
- Xcode 16.0+（完整版本，非仅命令行工具）
- CocoaPods 1.15+
- 需要接受 Xcode 许可协议：`sudo xcodebuild -license`
- 需要运行首次初始化：`sudo xcodebuild -runFirstLaunch`

### 首次构建注意事项
- macOS 首次构建需要 15-25 分钟（包含 pod install 和 Xcode 编译）
- `pod install` 会从 GitHub 下载依赖，需要稳定的网络连接
- Rust 依赖（如 rhttp）会在编译时构建，需要时间
- 可能出现关于废弃 API 的编译警告，这是正常的

## 常用命令

### 构建
```bash
# Android
flutter build apk

# iOS
flutter build ios

# Linux
flutter build linux

# macOS
flutter build macos

# Windows
flutter build windows
```

### 运行
```bash
# 指定平台运行（推荐）
flutter run -d macos

# 运行应用（自动选择设备）
flutter run

# 热重载（应用运行时按 'r'）
# 热重启（应用运行时按 'R'）

# Headless 模式
flutter run --release -- --headless
```

### 测试和质量检查
```bash
# 运行所有测试
flutter test

# 运行单个测试文件
flutter test test/channel_test.dart

# Lint 检查
flutter analyze

# 获取依赖
flutter pub get
```

## 代码架构

### 目录结构

#### `lib/foundation/`
核心功能层，包含应用的基础设施：

- **Comic Source 系统** (`comic_source/`, `js_engine.dart`, `js_pool.dart`):
  - 使用 JavaScript 引擎（flutter_qjs）管理可扩展的漫画源
  - 每个漫画源是一个 JS 文件，实现标准接口（探索、搜索、详情、阅读等）
  - JS 引擎池管理并发执行

- **数据管理** (`appdata.dart`, `favorites.dart`, `history.dart`, `image_favorites.dart`):
  - 应用配置和用户数据
  - 本地收藏系统（支持多个收藏夹）
  - 浏览历史记录
  - 图片收藏

- **本地漫画** (`local.dart`):
  - 扫描和管理本地漫画文件
  - 支持多种格式（见 `lib/utils/` 中的格式处理）

- **其他** (`cache_manager.dart`, `image_provider/`):
  - 图片缓存策略
  - 自定义图片加载器

#### `lib/components/`
可复用的 UI 组件库：
- `comic.dart`: 漫画卡片、网格、列表视图
- `appbar.dart`, `navigation_bar.dart`: 导航组件
- `image.dart`: 图片加载和显示组件
- `loading.dart`, `message.dart`: 加载状态和消息提示
- `window_frame.dart`: 桌面平台窗口框架

#### `lib/pages/`
应用页面和视图：
- `main_page.dart`: 主导航页面
- `home_page.dart`: 首页
- `explore_page.dart`: 漫画源探索页
- `comic_details_page/`: 漫画详情页面
- `reader/`: 阅读器相关页面
- `favorites/`: 收藏管理页面
- `settings/`: 设置页面
- `local_comics_page.dart`: 本地漫画管理

#### `lib/network/`
网络层：
- `app_dio.dart`: HTTP 客户端封装（基于 dio + rhttp）
- `download.dart`, `file_downloader.dart`: 漫画下载管理
- `images.dart`: 网络图片加载
- `cache.dart`: 网络缓存策略
- `cloudflare.dart`: Cloudflare 保护处理
- `cookie_jar.dart`: Cookie 管理

#### `lib/utils/`
工具类：
- 文件格式支持: `cbz.dart`, `epub.dart`, `pdf.dart`
- `import_comic.dart`: 漫画导入逻辑
- `data_sync.dart`: WebDAV 数据同步
- `tags_translation.dart`: 标签翻译（基于 EhTagTranslation）
- `io.dart`: 文件系统操作
- `image.dart`: 图片处理工具

### 关键系统流程

#### Comic Source 工作流程
1. 用户通过仓库 URL 添加漫画源（JSON 索引文件）
2. 下载 JS 源文件到本地
3. JS 引擎加载并执行源代码
4. 源实现 `ComicSource` 类，提供探索、搜索、详情、阅读等方法
5. 应用调用 JS 方法获取数据，JS 通过网络 API 与网站交互

详见 `doc/comic_source.md` 了解如何编写漫画源。

#### 图片加载流程
1. 请求图片 URL（可能来自 JS 源的 `onImageLoad` 配置）
2. 检查缓存（`cache_manager.dart`）
3. 使用自定义图片提供器加载（`foundation/image_provider/`）
4. 网络请求（`network/images.dart`）可能包含特殊 headers、代理等
5. 缓存并显示

## 代码风格

遵循 `package:flutter_lints/flutter.yaml` 规则，但有以下例外（见 `analysis_options.yaml`）：
- `collection_methods_unrelated_type: false`
- `use_build_context_synchronously: false`
- `avoid_print: false`

## 常见问题

### CocoaPods 网络问题
如果 `pod install` 失败并提示无法连接到 GitHub：
```bash
# 清理缓存后重试
cd macos && rm -rf Pods Podfile.lock && cd ..
flutter run -d macos
```

### Git HTTP/2 错误
如果出现 `Error in the HTTP2 framing layer`：
```bash
git config --global http.version HTTP/1.1
git config --global http.postBuffer 524288000
```

### Xcode 相关问题
- 确保已接受许可：`sudo xcodebuild -license`
- 运行首次初始化：`sudo xcodebuild -runFirstLaunch`
- 切换开发者路径：`sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`

## 作者署名

生成代码时使用 `kirk` 作为作者署名。
