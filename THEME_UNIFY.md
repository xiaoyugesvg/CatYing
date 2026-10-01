# 主题系统统一 — 进度与参考文档

> 最后更新：2026-10-01（HEAD `d443b45` 之后，工作区有未提交改动）
> 适用范围：影视/直播、音乐、阅读 三模块的**视觉统一**。
> 目标：切到任何一个模块都像同一个 App——底色/卡片/弹窗/字号一套 token，模块保留自己的布局与交互特征。

---

## 一、已完成改动（未提交，待你确认后 commit）

### 1. 「跟随系统」重启丢失 — 已修复（3 文件）

| 文件 | 改动 |
|---|---|
| `lib/main.dart` | 启动改为 `await ThemeModeStore.load()`（读 prefs，**保留 'system'**）→ `GlobalThemeSync.pushToModules(globalMode)` 拉齐音乐/阅读 → 按全局模式 `setAppearanceMode` 同步壁纸 |
| `lib/app.dart` | 删除 build 里用 `BackgroundService.appearanceMode`（仅 light/dark）的二值覆盖（原 66-69 行） |
| `lib/pages/content_view.dart` | 删除 `initState` 里 `load().then` 后的二值覆盖（原 71-79 行） |

**根因**：`BackgroundService.appearanceMode` 只有 dark/light 两值，冷启动用它覆盖 `ThemeModeStore`，把 prefs 里的 `'system'` 覆盖没了。
**现在链路**：prefs（含 system）→ 全局 → 三模块 + 壁纸，谁都不覆盖谁。

### 2. 组件层视觉统一 — 第一波（卡片 + 弹窗圆角，5 处）

| 文件 | 组件 | 原值 → 现值 |
|---|---|---|
| `lib/music/widgets/music_components.dart` | `GlassCard` 默认圆角 | 16 → **20** |
| 同上 | `CoverCard` 封面圆角 | 12 → **20** |
| 同上 | `showSongActions` 底部弹层顶部圆角 | 20 → **28** |
| `lib/music/pages/discover_page.dart` | `_pickCat` 底部弹层顶部圆角 | 20 → **28** |

对齐对象：影视/阅读卡片 = 20（`AppTheme.glassRadiusCard`）；影视弹窗 = 28（`AppTheme.glassRadius`）。

### 3. 已统一（此前提交 c050c1d / d443b45 完成）

- 明暗三模块全局同步（`theme_mode_store.dart` + `GlobalThemeSync`，音乐/阅读侧回写）
- 音乐基础色全部 palette 化（`music_theme.dart:139-194`，剩 20 处硬编码 = 9 种强调色方案，**有意保留**）
- lightTheme 补全（chip/bottomSheet/textTheme 等，含"曾有一个真 bug"注释 236-249 行）
- 悬浮栏三栏共用 `JellyNavBar`

---

## 二、第二批勘察结论（未实施，供将来开工参考）

### A. 空态 / 加载态 / 错误提示 —— 三套现状

| 模块 | 加载态 | 空态 | 错误提示 |
|---|---|---|---|
| 影视/直播 | `AppLoadingView`（`lib/widgets/app_loading_view.dart`）+ 散落 `CircularProgressIndicator` | 直播 `_EmptyLive`（`live/view.dart:1476`）、`_EmptyRow`（`settings_view.dart:425`） | `ScaffoldMessenger.showSnackBar`（detail 页 10+ 处） |
| 音乐 | `CircularProgressIndicator(color: MusicTheme.tint)`（5 处：search/library/playlist_detail/discover×2） | **散落文字提示**（搜索无结果 `discover_page.dart:390-392`、收藏空 `library_page.dart:143-154`），无统一 EmptyView | `lastError` ValueNotifier（`player_manager.dart:77`）+ 播放器内友好文案 |
| 阅读 | `CircularProgressIndicator(strokeWidth: 2)`（若干） | **`_buildEmpty` 私有方法**（`bookshelf_page.dart:2635` 漫画、`:2982` 图书，图标+文字），其余散落 Text | `AppToast.show(...)`（download_service 等）+ 部分 SnackBar 混用 |

**统一边界（用户确认）**：只统一**通用整页级**的加载 / 空态 / 错误提示；各模块**独特加载态保留各自实现**——
- 音乐：播放器音源切换加载（`lastError` 展示）、封面/歌曲行占位（`CoverImage._placeholder`）
- 阅读：阅读器翻页/章节加载、书源仓库 spinner、封面占位
- 影视：播放器缓冲 spinner、海报图占位
这些有模块专属语义与视觉，**不并入统一组件**。

**建议路径**（将来做）：
1. 抽一个全局 `AppLoadingView` / `AppEmptyView` / `AppToast` 到 `lib/widgets/`，三模块引用同一组件（颜色走 palette）
2. 先替换**整页级**的加载/空态（每模块 1-2 处入口页），播放器内/详情页内的局部 spinner 保留
3. 音乐 `lastError` 是**播放器状态**而非全局提示，建议保留其数据流，仅把"展示层"换成统一组件

### B. 字号常量 —— 分布与差异

- 影视基准（`lib/common/theme.dart:224-230`）：fontCaption 11 / footnote 12 / subhead 13 / body 14 / headline 16 / title3 18 / title2 20
- 三模块实际散落值：10 / 11 / 12 / 13 / 14 / 15 / 16 / 17 / 18 / 20 / 22（**132KB grep 输出，几百处字面量**）
- 主要差异点：音乐用 15/17（如 `music_components.dart:202,289` fontSize 15、`:401` 17）；影视/阅读用 14/16/18 阶梯
- 全局 `fontScale`（`theme.dart` fs() + textScaler）已统一缩放——**用户手动调字体是全局生效的**

**统一边界（用户确认）**：只统一**通用整页级**的加载 / 空态 / 错误提示；各模块**独特加载态保留各自实现**——
- 音乐：播放器音源切换加载（`lastError` 展示）、封面/歌曲行占位（`CoverImage._placeholder`）
- 阅读：阅读器翻页/章节加载、书源仓库 spinner、封面占位
- 影视：播放器缓冲 spinner、海报图占位
这些有模块专属语义与视觉，**不并入统一组件**。

**建议路径**（将来做）：
- **不要一次性替换全部字面量**（几百处，回归风险极高）
- 抽语义常量（`AppTheme.fontBody` 等已存在）→ 音乐/阅读各建自己的 `MusicFonts`/`JellyFonts` 转发同一数值表 → 新代码强制用常量，旧代码**按页面渐进替换**
- 优先级：先对齐"标题行"（音乐 17 → 18）和"正文"（15 → 14 或反之，三模块统一），次要文字 12/13 差异影响小

---

## 三、保留不动的项（刻意为之）

| 项 | 原因 |
|---|---|
| 两个设置入口并存（「外观」页 + 「主题与外观」页） | 用户明确：可以不动 |
| 阅读书卡彩色阴影（primary alpha 0.15/0.2 blur 15） | 果冻风品牌特征 |
| 各模块按压动画（GlassPress 弹性 / 阅读 scale 0.95/0.97 / 音乐 InkWell） | 交互手感差异 |
| 播放器大封面 18/14、歌曲行小图 10、歌手头像圆形 | 专属 UI 语义不同 |
| 音乐 9 种强调色硬编码（20 处） | Beans 风格可选项 |
| `MusicTheme` 不反向依赖 `lib/common` 存储层 | 架构约束（用 MusicPaletteBridge 注入） |

---

## 四、剩余待办（按优先级）

- [x] 冷启动「跟随系统」丢失
- [x] 卡片/弹窗圆角统一
- [ ] 空态/加载态/错误提示三套统一（见二.A）
- [ ] 字号常量语义化（见二.B，渐进式）
- [ ] 音乐页悬浮栏缺失疑点（IMG_8144 截图无栏但代码无条件渲染）——**需真机复现确认**

---

## 五、验证状态

- `flutter analyze`（FVM）：**无 error**；1913 个 issue 与改动前完全一致（本轮 5 处改动零新增）
- 明暗切换链路：`ThemeModeStore.set` → `GlobalThemeSync` → 音乐 `applyFromGlobal` / 阅读 `applyThemeModeFromGlobal`；反向 `notifyModuleChanged` 回写，`_syncing` 防递归
- 待真机：跟随系统重启、浅色模式组件观感、音乐页悬浮栏

## 六、关键架构事实（排查时先看这里）

1. 主题四层：调色板源头 `lib/reading/theme/jelly_palette.dart`（7 预设）→ 模块入口（AppTheme / MusicTheme / SettingsService）→ 桥接（module_theme_store / module_theme_sync / theme_mode_store / appearance_sync）→ 设置入口（unified / appearance）
2. 启动注册链在 `lib/main.dart:130-176`（ModuleThemeStore → applyModuleThemes → GlobalThemeSync → AppearanceSync）
3. 音频互斥：`lib/services/audio_focus.dart`，video/live/music 三方注册（已提交 d91aa2e）
