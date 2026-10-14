import 'package:flutter/material.dart';

import '../../../common/theme.dart';
import '../../../services/prefs_mirror.dart';
import '../../../widgets/common_widgets.dart';

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
      builder: (ctx) => kbSheet(SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(title,
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: AppTheme.fontHeadline)),
            ),
            for (final o in options)
              ListTile(
                title: Text(labelBuilder(o),
                    style: TextStyle(color: AppTheme.textSecondary)),
                trailing: selected == o
                    ? Icon(Icons.check, color: AppTheme.accentColor)
                    : null,
                onTap: () => Navigator.pop(ctx, o),
              ),
          ],
        ),
      )),
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

/// 分类子页的统一外壳：标题栏 + 可滚动的分组内容。
///
/// 让 8 个子页外观一致，也省掉每页重复写 Scaffold/AppBar。
class SettingsSubPage extends StatefulWidget {
  final String title;
  final List<Widget> children;

  /// 右上角可选操作（如"重置"）
  final Widget? action;

  const SettingsSubPage({
    super.key,
    required this.title,
    required this.children,
    this.action,
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
    PrefsMirror.snapshotSoon();
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
        actions: action == null ? null : [action!],
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
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 6),
            child: Text(
              title!,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
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
        if (hint != null)
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
    trailingSwitch: true,
    switchValue: value,
    switchEnabled: enabled,
    onSwitchChanged: onChanged,
  );
}
