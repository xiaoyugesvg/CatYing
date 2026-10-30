import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/import_conflict.dart';
import 'package:tvbox/services/prefs_mirror.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/widgets/help_sheet.dart';

/// 设置子页的共享构件。
///
/// 为什么需要它：把 1807 行的设置页拆成 8 个分类子页后，每页都要用
/// 「选项选择弹窗」「多行文本编辑弹窗」「说明卡片」这类东西。
/// 不抽出来就会在 8 个文件里各写一遍（原来的 settings/view.dart 就是这样
/// 堆积到 1807 行的）。
class SettingsDialogs {
  SettingsDialogs._();

  /// 底部弹窗式单选（用于外观模式、自动清理、播放内核、画质…）
  ///
  /// 返回选中项；用户取消返回 null。
  ///
  /// 版式与直播/详情页的选项弹层统一：拖拽条 + 标题 + 圆角卡片行，
  /// 选中项为主题色浅底 + 细描边 + ✓（原来是最朴素的 ListTile）。
  static Future<T?> pick<T>({
    required BuildContext context,
    required String title,
    required List<T> options,
    required T? selected,
    required String Function(T) labelBuilder,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => kbSheet(SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 顶部把手
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textTertiary.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
              child: Row(
                children: [
                  Text(title,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${options.length} 项',
                      style: TextStyle(
                          color: AppTheme.textTertiary, fontSize: 12)),
                ],
              ),
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.5,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                itemCount: options.length,
                separatorBuilder: (_, __) => const SizedBox(height: 6),
                itemBuilder: (c, i) {
                  final o = options[i];
                  final on = selected == o;
                  return Material(
                    color: on
                        ? AppTheme.accentColor.withValues(alpha: 0.12)
                        : AppTheme.backgroundTertiary,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => Navigator.pop(ctx, o),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: on
                              ? Border.all(
                                  color: AppTheme.accentColor
                                      .withValues(alpha: 0.45),
                                  width: 0.8,
                                )
                              : null,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                labelBuilder(o),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: on
                                      ? AppTheme.accentColor
                                      : AppTheme.textPrimary,
                                  fontSize: AppTheme.fontBody,
                                  fontWeight:
                                      on ? FontWeight.w600 : FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Icon(
                              on
                                  ? Icons.check_circle_rounded
                                  : Icons.circle_outlined,
                              size: 19,
                              color: on
                                  ? AppTheme.accentColor
                                  : AppTheme.textTertiary
                                      .withValues(alpha: 0.5),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 10),
          ],
        ),
      )),
    );
  }

  /// 导入本地源时**同名冲突**的选择：替换 / 重命名 / 取消。
  ///
  /// 用户 2026-10-28：
  ///   「不管是本地py还是本地的js同名导入的时候都要给我选择是替换还是重命名」
  ///
  /// 以前是同名就静默加 `(2)`，用户既不知道撞了名、也没法选择覆盖。
  /// 返回 null = 用户取消（整批都不导入）。
  static Future<ImportConflict?> askImportConflict(
    BuildContext context, {
    required List<String> names,
    required String kind,
  }) {
    final preview = names.take(6).toList();
    final rest = names.length - preview.length;
    return showModalBottomSheet<ImportConflict>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => kbSheet(SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppTheme.textTertiary.withValues(alpha: 0.35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text(
                '有 ${names.length} 个同名$kind源',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontHeadline,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '${preview.join('、')}${rest > 0 ? ' 等 $rest 个' : ''}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              _conflictTile(
                ctx: ctx,
                icon: Icons.swap_horiz_rounded,
                title: '替换',
                subtitle: '覆盖原有脚本，位置和选中状态保持不变',
                value: ImportConflict.replace,
              ),
              const SizedBox(height: 8),
              _conflictTile(
                ctx: ctx,
                icon: Icons.content_copy_rounded,
                title: '重命名',
                subtitle: '另存为新的一份，名字自动加 (2)',
                value: ImportConflict.rename,
              ),
              const SizedBox(height: 12),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    '取消',
                    style: TextStyle(color: AppTheme.textTertiary),
                  ),
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }

  static Widget _conflictTile({
    required BuildContext ctx,
    required IconData icon,
    required String title,
    required String subtitle,
    required ImportConflict value,
  }) {
    return Material(
      color: AppTheme.backgroundTertiary,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.pop(ctx, value),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppTheme.accentColor),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 12,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 多行文本编辑弹窗（用于弹幕 API、屏蔽关键词、源地址等）
  ///
  /// 返回编辑后的文本；取消返回 null。
  static Future<String?> editText({
    required BuildContext context,
    required String title,
    required String initial,
    String? hint,
    int maxLines = 1,
    String? helper,
  }) {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(title, style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: ctrl,
                maxLines: maxLines,
                autofocus: true,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontSubhead),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle:
                      TextStyle(color: AppTheme.textTertiary, fontSize: AppTheme.fontFootnote),
                  filled: true,
                  fillColor: AppTheme.backgroundTertiary,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              if (helper != null) ...[
                const SizedBox(height: 8),
                Text(helper,
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.4)),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child:
                Text('保存', style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  /// 二次确认弹窗
  static Future<bool> confirm({
    required BuildContext context,
    required String title,
    required String message,
    String confirmText = '确定',
    Color confirmColor = Colors.redAccent,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(title, style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(message,
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
                height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmText, style: TextStyle(color: confirmColor)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

/// 设置/管理页右上角「?」说明弹窗里的一条说明。
///
/// 2026-10-30：实现搬到了 `widgets/help_sheet.dart`（听书 / 音乐模块
/// 也要用，但它们的配色体系不是 AppTheme）。这里保留别名，
/// 24 个子页里的 `SettingsHelpItem(...)` 一个字都不用改。
typedef SettingsHelpItem = HelpItem;

/// 设置/管理页右上角的「?」说明按钮 + 弹窗（AppTheme 配色版）。
///
/// 用户（本会话）：「卡片里的小字说明别直接铺在卡片下，
/// 改成在页面右上角放个 ? 图标，想看就点开看。」
///
/// 原先这些说明是 `SettingsRow.subtitle`（卡片下方灰色小字），
/// 现在收进这里：点 ? 弹出一张统一的卡片式说明列表，卡片本身只留标题。
class SettingsHelp {
  SettingsHelp._();

  /// 设置体系的说明配色（AppTheme）
  static HelpPalette get palette => HelpPalette(
        surface: AppTheme.backgroundSecondary,
        textPrimary: AppTheme.textPrimary,
        textSecondary: AppTheme.textSecondary,
        textTertiary: AppTheme.textTertiary,
        accent: AppTheme.accentColor,
        border: AppTheme.borderLight,
        radius: AppTheme.radiusLG,
      );

  /// 右上角「?」按钮（与 `action` 并列）。
  static Widget helpButton({required VoidCallback onPressed}) {
    return helpAction(onPressed: onPressed, color: AppTheme.textPrimary);
  }

  /// 弹出说明弹窗（AlertDialog 风格，与 SettingsDialogs 统一）。
  static Future<void> show(
    BuildContext context,
    String pageTitle,
    List<SettingsHelpItem> items,
  ) {
    return showHelpSheet(
      context,
      title: pageTitle,
      items: items,
      palette: palette,
    );
  }
}

/// 分类子页的统一外壳：标题栏 + 可滚动的分组内容。
///
/// 让 8 个子页外观一致，也省掉每页重复写 Scaffold/AppBar。
class SettingsSubPage extends StatefulWidget {
  final String title;
  final List<Widget> children;

  /// 右上角可选操作（如"重置"）
  final Widget? action;

  /// 右上角「?」说明按钮内容；非空时展示 ? 按钮，点击弹出说明列表。
  final List<SettingsHelpItem>? help;

  const SettingsSubPage({
    super.key,
    required this.title,
    required this.children,
    this.action,
    this.help,
  });

  @override
  State<SettingsSubPage> createState() => _SettingsSubPageState();
}

class _SettingsSubPageState extends State<SettingsSubPage> {
  // 转发到 widget.* —— 这样下面 `_buildPage` 里原有的 `title` / `children` /
  // `action` 引用**一行都不用改**（改动面越小越不容易出错）。
  String get title => widget.title;
  List<Widget> get children => widget.children;
  Widget? get action => widget.action;
  List<SettingsHelpItem>? get help => widget.help;

  /// 离开设置子页就落一次盘。
  ///
  /// 为什么放这里（用户 2026-10-14）：这个 App 被崩溃/信号硬杀是常态，
  /// 而设置项的写入点只接了少数几处（菜单栏 / 悬浮样式 / 只显示图标 / 幻灯样式），
  /// 其余（播放、弹幕、订阅、主题…）以前只能等 15s 周期快照或切后台 ——
  /// **改完立刻被杀就丢**。设置子页是这些改动的唯一出口，
  /// 在这里落一次盘就把覆盖面补全了。
  /// `snapshotSoon()` 内部会先 `flushNow()`（让 plist 立即落盘）再写镜像文件。
  @override
  void dispose() {
    // 用 snapshotNow 而不是 snapshotSoon：页面正在销毁，要的是"走之前把改动
    // 存下来"，不需要再挂一个 400ms 的去抖定时器（那会让 flutter_test 报
    // 「A Timer is still pending」，生产环境也是无意义的延迟写）。
    PrefsMirror.snapshotNow();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ⚠️ **必修：本页必须监听「明暗 + 配色版本」并重建**（用户 2026-10-07：
    //   「点击了保存后，整个界面像是蒙了一层白」）✗→✓
    //
    // 根因 ✗：本页（AppBar 标题/图标 + 各分组）的颜色全部来自 `AppTheme.*`
    //   —— 那是**静态 getter**，读的是 `AppBrightness.isLight` / `_palette`，
    //   **改颜色时不会通知任何 widget**；
    //   而"全局背景层"恰好**监听了** `AppBrightness`（见
    //   `BackgroundService.buildBackground` 外层的 ValueListenableBuilder）⇒
    //   明暗一变：**背景当场换成浅色（浅色模式的白色蒙版 + 亮壁纸）**，
    //   本页却**停在旧色**（深色那套的白字/深控件色）⇒ 浅底 + 白字 ⇒
    //   整页看起来就是"蒙了一层白、字还看不清"✗（用户实测截图完全吻合 ✓）。
    //
    // 这一层监听补上后：外观一变，**11 个设置子页一起立刻跟着换色** ✓
    //   （外观/播放/数据源/元数据/缓存/弹幕/主页页面/关于/统一主题 + 2 个内部页）
    //
    // ⚠️ 这也是 `app.dart` 注释里写明的「已知残留」：先前靠"换 key 重建整棵树"
    //   来兜底，但那样会把 7 个 tab 的 State 全销毁（切主题卡顿/跳回首页）；
    //   改成在**真正需要变色的容器**上逐个监听后，设置子页这一处漏了 ✓
    return ValueListenableBuilder<bool>(
      valueListenable: AppBrightness.isLight,
      builder: (context, _, __) => ValueListenableBuilder<int>(
        valueListenable: AppTheme.paletteRevision,
        builder: (context, ___, ____) => _buildPage(context),
      ),
    );
  }

  Widget _buildPage(BuildContext context) {
    // ── 背景透明：透出全局壁纸层（与阅读模块一致）────────────────
    //
    // 三模块视觉统一：**以阅读为准，页面透出壁纸**。
    // 阅读侧 41 处页面 Scaffold 都是 `Colors.transparent`。
    //
    // 这里改一处 = **11 个设置子页一起统一**
    //（外观/播放/数据源/元数据/缓存/弹幕/主页页面/关于/统一主题 + 2 个内部页）。
    //
    // ⚠️ 只改「页面 Scaffold / AppBar」这两处。
    // 本文件里 L27 / L68 / L131 那几处是**弹层**
    //（showModalBottomSheet / AlertDialog）的底色 —— 那些**必须保持不透明**，
    // 否则弹层浮在壁纸上会看不清内容。
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(title,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: AppTheme.fontTitle3)),
        actions: [
          if (help != null && help!.isNotEmpty)
            SettingsHelp.helpButton(
                onPressed: () => SettingsHelp.show(context, title, help!)),
          if (action != null) action!,
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: children,
      ),
    );
  }
}

/// 子页里的一个分组：小标题 + 卡片。
///
/// 对应参考图那种「数据 / 偏好」分区 + 白卡列表的样式。
/// 分组卡片下方那行灰色脚注是否显示。
///
/// 与 [kShowSettingsRowSubtitle] 同一次要求（2026-10-30）：设置页的"小字"
/// 全部去掉，只留标题 + 控件本身。
const bool kShowSettingsGroupHint = false;

class SettingsGroup extends StatelessWidget {
  final String? title;
  final List<Widget> children;
  final String? hint;

  const SettingsGroup({
    super.key,
    this.title,
    required this.children,
    this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null) ...[
          // ── 分组标题统一成「主题色竖条 + 加粗标题」────────────────
          //
          // 原来是「11 号浅灰小字、无竖条」—— 11 个设置子页的分区标题
          // 全是一片灰字，页面上看不出分段（用户 2026-10-30：
          // 「TG 设置页那个竖条标题挺好，其余页也这样」）。
          // 现在与 `tg_source_page._section`、TG 首页/海阔的区块标题
          // **完全同一套**（竖条 3×12 + 间距 7 + 12.5 加粗 textSecondary），
          // 一处改动 = 所有走 SettingsGroup 的子页一起统一。
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 12,
                  decoration: BoxDecoration(
                    color: AppTheme.accentOnSurface,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    title!,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
        // dense：纵向内边距 4，配合行高 38 → 单行卡片约 46px
        //（原来 72px，列表显得又高又空）
        AppCard(
          dense: true,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0)
                  Divider(
                      color: AppTheme.borderLight,
                      height: 1,
                      thickness: 0.5,
                      indent: 28,
                      endIndent: 4),
                children[i],
              ],
            ],
          ),
        ),
        // ── 分组脚注小字已**全局关闭**（2026-10-30）──────────────
        //
        // 用户：「所有模块里面，影视模块的设置页面以及子页面、音乐模块里面
        // 我的页面以及子页、阅读模块里面我的页面以及子页面，不要那些小字」。
        // 分组卡片下面那行灰色脚注和行内副标题是同一类东西，一起关掉，
        // 页面才干净。`hint` 参数保留（30 处调用点仍在传），
        // 想恢复把 `kShowSettingsGroupHint` 改成 true 即可。
        if (hint != null && kShowSettingsGroupHint)
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 8),
            child: Text(
              hint!,
              style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: AppTheme.fontCaption,
                  height: 1.4),
            ),
          ),
      ],
    );
  }
}


/// 统一的「图标 + 标题 + 可选副标题 + 开关」行。
///
/// 之前 playback / danmu 两页各自实现了一份 `_switchRow` / `_switchTile`，
/// 样式与间距容易走偏。现在收敛到这里，所有设置页共用同一种观感。
Widget unifiedSwitchRow({
  required IconData icon,
  required String title,
  String? subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
  bool enabled = true,
}) {
  return SettingsRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    trailingSwitch: true,
    switchValue: value,
    switchEnabled: enabled,
    onSwitchChanged: onChanged,
  );
}
