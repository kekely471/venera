# WebDAV 功能可改进项

基于当前仓库实现，对 WebDAV 漫画浏览、缓存、流式阅读、阅读进度同步和数据同步做了一轮代码检查。下面按优先级整理可完善项，优先列出明确存在行为缺陷的问题，再列增强建议。

## 高优先级问题

### 1. `mobi-stream` / `epub-stream` 封面链路不完整

当前 WebDAV 书架和历史封面只处理了以下几类缓存目录：

- `webdav_mobi`
- `webdav_archive_stream`
- `webdav_archive`
- 普通远程目录图片

但 MOBI 和 EPUB 在流式模式下，实际会落到：

- `webdav-mobi-stream://...`
- `webdav-epub-stream://...`

这两类目录目前没有被封面组件统一处理，结果是书架/历史页会把本地流式目录信息误当成远端封面路径，导致封面加载失败或不稳定。

相关位置：

- `lib/pages/webdav_comics_page.dart`
- `lib/components/comic.dart`
- `lib/foundation/image_provider/history_image_provider.dart`

建议：

- 给封面解析逻辑补齐 `WebDavMobiService.decodeStreamDirectory()` 和 `WebDavEpubService.decodeStreamDirectory()` 分支。
- 将 WebDAV 封面解析抽成统一工具，避免 `comic.dart` 和 `history_image_provider.dart` 两处继续分叉。

---

### 2. “测试连接” 会先保存配置

当前“测试连接”直接调用 `_saveConfig()`，而 `_saveConfig()` 会：

- 立即写入配置
- 将页面状态改为已连接
- 触发目录加载

这意味着即使连接测试失败，错误配置也已经被保存。

相关位置：

- `lib/pages/webdav_comics_page.dart`

建议：

- 将“测试连接”和“保存配置”拆开。
- 测试连接应基于临时客户端完成，不应落盘。
- 只有测试通过或用户明确保存时才写入配置。

---

### 3. 漫画扫描规则过于死板

当前扫描逻辑主要按“目录里是否只有子目录、没有图片”来判断是否为多章节漫画。这个假设过强，会误判常见结构，例如：

```text
/ComicA
  /chapter1
  /chapter2
  cover.jpg
```

这种结构会被当成单章节目录，而不是多章节漫画。

此外，扫描过程只递归目录，不把根目录下的单文件书籍纳入扫描结果，例如：

- `.cbz`
- `.zip`
- `.mobi`
- `.epub`
- `.pdf`

这样批量扫描/导入无法覆盖这类文件。

相关位置：

- `lib/foundation/webdav_comic_manager.dart`

建议：

- 允许“封面文件 + 子章节目录”共存的目录结构。
- 扫描时将单文件漫画资源一并识别出来，生成可导入项。
- 将目录漫画和单文件漫画的扫描结果统一成同一套数据结构，避免页面层继续分支判断。

---

### 4. 缓存清理不完整

当前 WebDAV 缓存统计和清理没有覆盖全部目录，已发现遗漏：

- `webdav_epub_stream`
- `webdav_mobi_preview`

另外，删除单本 WebDAV 漫画或“清空 WebDAV 缓存”时，也没有完整覆盖：

- EPUB 流式缓存
- PDF 缓存
- MOBI 预览缓存

结果会出现以下问题：

- UI 显示已清缓存，但磁盘残留仍然存在
- 部分旧元数据会继续命中，影响刷新和回读

相关位置：

- `lib/foundation/webdav_comic_manager.dart`
- `lib/foundation/local.dart`

建议：

- 统一维护一份 WebDAV 缓存目录清单。
- `getCacheSize()`、`clearCache()`、删除单本漫画、批量清理都复用这份清单。
- 删除漫画时按目录类型完整清理：普通图片、MOBI、MOBI 流式、MOBI 预览、Archive、Archive 流式、EPUB 流式、PDF。

---

### 5. 阅读进度同步是“覆盖导入”，不是“合并同步”

当前 `WebDavReadingProgress` 存在几个明显问题：

- 拉取进度时，任意读取异常都被当成“远端没有文件”
- 本地与远端不比较时间戳，直接覆盖本地
- 多设备使用时，较新的本地进度可能被旧的远端数据覆盖
- 进度文件固定写在 WebDAV 漫画根目录下，浏览页会把它当普通文件显示出来

相关位置：

- `lib/foundation/webdav_reading_progress.dart`
- `lib/pages/webdav_comics_page.dart`

建议：

- 区分“文件不存在”和“网络/鉴权错误”。
- 以条目级时间戳做合并，至少做到“谁更新谁生效”。
- 将进度文件放到隐藏目录或专用元数据目录，例如 `.venera/reading_progress.json`。
- 文件列表页默认隐藏内部元数据文件。

---

### 6. EPUB / PDF 能力与其他格式不一致

当前：

- MOBI 支持流式失败后回退全量下载
- Archive 支持流式失败后回退全量下载
- EPUB 只有流式解析，没有全量下载 fallback
- PDF 虽然能读取远端，但未接入历史记录与续读

结果：

- 遇到不支持 Range 的 EPUB 服务端时，文件直接打不开
- PDF 退出后页码不会恢复

相关位置：

- `lib/pages/webdav_comics_page.dart`
- `lib/pages/webdav_pdf_reader_page.dart`
- `lib/foundation/webdav_pdf_service.dart`

建议：

- 为 EPUB 补充全量下载 fallback。
- 为 PDF 接入 `HistoryManager`，至少保存：
  - 当前页
  - 总页数
  - 最后阅读时间
- 统一单文件格式的阅读状态模型，减少每种格式各写一套逻辑。

## 中优先级增强项

### 1. WebDAV 漫画配置与应用数据同步配置需要进一步统一

当前项目里实际存在两套 WebDAV 配置：

- `webdavComics`：用于远程漫画浏览
- `webdav`：用于应用数据同步

这不是错误，但现在两套逻辑各自维护连接、错误处理、配置校验和 UI，已经开始出现重复和割裂。

建议：

- 抽出统一的 WebDAV 配置模型和客户端工厂。
- 明确区分“漫画源 WebDAV”和“数据同步 WebDAV”是两个独立连接，还是允许复用同一连接。
- 如果允许复用，可以在设置页提供“沿用数据同步 WebDAV 配置”的选项。

---

### 2. 大目录体验还能继续优化

当前已经有：

- 大目录阈值判断
- 封面预取数量限制
- 封面并发限制

这部分方向是对的，但还可以继续增强：

- 支持按文件类型过滤
- 支持仅看漫画文件 / 仅看目录
- 支持按修改时间排序
- 支持分页加载或分段加载

适用于 WebDAV 根目录文件量特别大的 NAS 场景。

---

### 3. 内部元数据文件需要统一隐藏策略

目前可能出现在 WebDAV 根目录或缓存目录内的内部文件包括：

- `reading_progress.json`
- 各类 `meta.json`
- 预览图缓存

建议：

- 浏览页默认隐藏内部文件
- 专用缓存/元数据目录命名统一
- 所有内部文件增加统一前缀或隐藏目录归档，避免污染用户视图

## 建议实施顺序

建议按下面顺序推进：

1. 修复封面链路、测试连接、缓存清理
2. 重做扫描规则和阅读进度同步策略
3. 补齐 EPUB fallback 和 PDF 续读
4. 统一 WebDAV 配置模型与缓存管理
5. 增强大目录浏览体验

## 建议补的测试

当前仓库里没有看到 WebDAV 专项测试，建议至少补以下几类：

### 1. 扫描识别测试

- 纯图片目录
- 章节目录
- 封面文件 + 章节目录混合结构
- 根目录单文件漫画识别

### 2. 缓存清理测试

- 单本删除是否清理对应缓存
- 批量删除是否清理全部格式缓存
- `clearCache()` 是否覆盖全部 WebDAV 缓存目录

### 3. 阅读进度同步测试

- 远端无文件
- 远端 404
- 网络异常
- 本地和远端时间戳冲突
- 多设备合并

### 4. Range / fallback 测试

- 服务端支持 Range
- 服务端不支持 Range
- Range 返回 200 整文件
- EPUB 流式失败后 fallback
- PDF 流式失败后本地缓存 fallback

## 附加说明

对相关文件做过一次定向静态分析，当前只有 3 个轻量告警：

- `lib/foundation/webdav_mobi_service.dart` 有一个未使用私有方法
- `lib/pages/webdav_comics_page.dart` 有 2 处无意义的空判断

这些不是当前 WebDAV 体验的主要问题，优先级低于上面的行为缺陷。
