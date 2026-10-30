import 'dart:io';
import 'package:tvbox/music/widgets/music_sheet.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/services/music_api.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/services/source_health_service.dart';
import 'package:tvbox/music/services/source_import_parser.dart';
import 'package:tvbox/music/services/unblock_service.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/pages/plugin_variables_page.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 音源管理页 —— 移植自 Beans 的 `ThirdPartySourceManagerSheet.swift`。
/// 界面样式对齐洛雪（LX Music）"自定义音源"设置页（参考图 IMG_8538）：
///   标题「自定义音源」+ 右上角「完成」；
///   导入区内嵌三 tab（文本 / 链接 / 文件）+「识别并导入」按钮；
///   音源列表 = 名称 / 类型·音质标签 / 描述 + 编辑·排序·删除 + 数量角标。
///
/// ── 功能不变 ──────────────────────────────────────────────────
/// 用户可以自己导入音源（文本粘贴 / 从文件 / 从 URL），
/// 支持两种形态（见 `ThirdPartySource`）：
///   · **模板法** `kind: keyword` —— 用 `{name}` `{artist}` `{id}` 占位符拼 URL
///   · **脚本法** `kind: script`  —— 整份 LX 脚本，能力更强
/// 导入解析器按 5 种格式依次尝试（JSON / 完整 LX 脚本 / JS 嵌 JSON /
/// 注释头 / 宽松脚本），异常宽容 —— 用户收集来的源格式五花八门。
class SourceManagerPage extends StatefulWidget {
  const SourceManagerPage({super.key});

  @override
  State<SourceManagerPage> createState() => _SourceManagerPageState();
}

class _SourceManagerPageState extends State<SourceManagerPage> {
  // ── 🔴 每张卡**各有一套**输入状态（这是修的一个真 bug）──────────
  //
  // 原来只有一对 `_tab` / `_textCtrl` / `_urlCtrl`，两张卡都用它 →
  //   · 在洛雪卡输入 → **MusicFree 卡的输入框里也显示同样的文字** ✗
  //     （两张卡同时渲染，用同一个 controller = 同一条文本）
  //   · 在洛雪卡打好字 → 切到 MusicFree 卡打字 → 切回来，
  //     **原来的字被覆盖了** ✗
  //   · tab 也串：在洛雪卡选"链接"，MusicFree 卡也跟着变 ✗
  //
  // 现在按 [_CardKind] 索引分开存。用户"在两个框里放不同内容"是
  // 完全合理的使用方式（比如洛雪源和 MusicFree 源各粘一份）。
  final _tab = <_CardKind, int>{
    _CardKind.lx: 0,
    _CardKind.musicFree: 0,
  };
  final _textCtrl = <_CardKind, TextEditingController>{
    _CardKind.lx: TextEditingController(),
    _CardKind.musicFree: TextEditingController(),
  };
  final _urlCtrl = <_CardKind, TextEditingController>{
    _CardKind.lx: TextEditingController(),
    _CardKind.musicFree: TextEditingController(),
  };
  // ── 🔴 「文件」那一栏也必须**按卡分开存**（同一个 bug 的漏网之鱼）──
  //
  // 上面 `_tab` / `_textCtrl` / `_urlCtrl` 已经按 `_CardKind` 分开了，
  // 但**选中的文件**原来还是共用的两个变量：
  // ```dart
  //   String? _pickedName;
  //   String? _pickedContent;
  // ```
  // 于是：
  //   · 在洛雪卡选一个文件 → **MusicFree 卡的文件行显示同一个文件名** ✗
  //   · 此时在 MusicFree 卡点「导入」→ 会拿**洛雪卡选的那个文件**
  //     去导入，而 `expectMusicFree: true` 会对它做 MusicFree 校验 →
  //     报"格式不匹配"，用户完全看不懂为什么 ✗
  //
  // 佐证：`_fileRow({required _CardKind kind})` 原来**收了 `kind` 却没用**，
  // 正是"打算按卡分开但没做完"的痕迹。
  final _pickedName = <_CardKind, String?>{
    _CardKind.lx: null,
    _CardKind.musicFree: null,
  };
  final _pickedContent = <_CardKind, String?>{
    _CardKind.lx: null,
    _CardKind.musicFree: null,
  };
  bool _busy = false;

  /// 列表类型筛选：'' = 全部 / 'lx' = 洛雪音乐源 / 'musicfree' = MusicFree 源
  /// / 'failed' = 仅看体检失效
  String _kindFilter = '';

  /// 体检进度：_checking 为 true 时画进度条
  int _checkDone = 0;
  int _checkTotal = 0;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    SourceHealthService.instance.ensureLoaded();
  }

  @override
  void dispose() {
    for (final c in _textCtrl.values) {
      c.dispose();
    }
    for (final c in _urlCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = ThirdPartySourceStore.instance;
    final health = SourceHealthService.instance;
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        // push 到 root Navigator → 不在音乐 Theme 作用域里；
        // 透明底色会让**影视侧**的 canvas 色透出来（深色下一眼能看出不对）。
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text(
            '音乐源',
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          bottom: _checking
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(2),
                  child: LinearProgressIndicator(
                    minHeight: 2,
                    value: _checkTotal == 0 ? null : _checkDone / _checkTotal,
                    backgroundColor: Colors.transparent,
                    color: MusicTheme.tint,
                  ),
                )
              : null,
          actions: [
            IconButton(
              tooltip: _checking
                  ? '体检中 $_checkDone/$_checkTotal'
                  : '音源体检（批量测活）',
              icon: Icon(
                _checking
                    ? Icons.hourglass_top_rounded
                    : Icons.monitor_heart_outlined,
                color: MusicTheme.tint,
              ),
              onPressed: _checking ? null : _runHealth,
            ),
            IconButton(
              tooltip: 'LX 引擎自检',
              icon: Icon(Icons.verified_outlined, color: MusicTheme.tint),
              onPressed: () => runLxSelfTest(context),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                '完成',
                style: TextStyle(
                  color: MusicTheme.tint,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        body: AnimatedBuilder(
          animation: Listenable.merge([store.revision, health.revision]),
          builder: (context, _) {
            final all = store.all;
            final failed = all.where((s) => health.isFailed(s.id)).toList();
            // 类型筛选：'' = 全部 / 'lx' = 洛雪 / 'musicfree' = MusicFree
            // / 'failed' = 仅看体检失效
            final list = _kindFilter.isEmpty
                ? all
                : all.where((s) {
                    if (_kindFilter == 'failed') return health.isFailed(s.id);
                    if (_kindFilter == 'musicfree') return s.isMusicFree;
                    // 洛雪一侧包含 LX 脚本 + 模板法（都是洛雪生态）
                    return !s.isMusicFree;
                  }).toList();
            final lxCount = all.where((s) => !s.isMusicFree).length;
            final mfCount = all.where((s) => s.isMusicFree).length;
            return ListView(
              padding: const EdgeInsets.only(bottom: 40),
              children: [
                _intro(),
                // ── 两个**独立**的导入入口（洛雪 / MusicFree）────────
                _sourceCard(context, _CardKind.lx),
                _sourceCard(context, _CardKind.musicFree),
                _filterRow(all.length, lxCount, mfCount, failed.length),
                if (_checking) _checkBanner(),
                if (!_checking && failed.isNotEmpty)
                  _failedBanner(failed.where((s) => s.enabled).length),
                _listHeader(list.length),
                if (list.isEmpty)
                  _emptyHint(all.isEmpty)
                else
                  ...list.map((s) => _tile(context, store, s)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 跑一轮体检：只测**已启用**的源（禁用的本来就不参与播放）
  Future<void> _runHealth() async {
    final health = SourceHealthService.instance;
    if (health.checking) {
      AppToast.show('正在体检中…', '');
      return;
    }
    final targets = ThirdPartySourceStore.instance.all
        .where((s) => s.enabled)
        .toList();
    if (targets.isEmpty) {
      AppToast.show('没有已启用的音源', '');
      return;
    }
    setState(() {
      _checking = true;
      _checkDone = 0;
      _checkTotal = targets.length;
    });
    final ok = await health.checkAll(
      targets,
      onProgress: (d, t) {
        if (mounted) setState(() => _checkDone = d);
      },
    );
    if (!mounted) return;
    setState(() => _checking = false);
    AppToast.show('体检完成：$ok/${targets.length} 可用', '');
  }

  Widget _checkBanner() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Row(
      children: [
        SizedBox(
          width: 13,
          height: 13,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: MusicTheme.tint,
          ),
        ),
        const SizedBox(width: 8),
        Text(
          '正在测活 $_checkDone/$_checkTotal（每源最多 15 秒）',
          style: TextStyle(
            color: MusicTheme.secondary,
            fontSize: AppTheme.fontCaption,
          ),
        ),
      ],
    ),
  );

  /// 有失效源时给一条「一键禁用」的操作条
  Widget _failedBanner(int enabledFailed) => Container(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
    decoration: BoxDecoration(
      color: Colors.redAccent.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(
        color: Colors.redAccent.withValues(alpha: 0.35),
        width: 0.8,
      ),
    ),
    child: Row(
      children: [
        const Icon(Icons.error_outline, size: 16, color: Colors.redAccent),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            enabledFailed > 0 ? '$enabledFailed 个已启用音源体检失效' : '失效音源都已被禁用',
            style: TextStyle(
              color: MusicTheme.label,
              fontSize: AppTheme.fontFootnote,
            ),
          ),
        ),
        if (enabledFailed > 0)
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Colors.redAccent,
              minimumSize: const Size(0, 32),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              visualDensity: VisualDensity.compact,
            ),
            onPressed: () async {
              final n = await SourceHealthService.instance.disableFailed();
              if (!context.mounted) return;
              AppToast.show('已禁用 $n 个失效音源', '');
            },
            child: const Text(
              '一键禁用',
              style: TextStyle(fontSize: AppTheme.fontFootnote),
            ),
          ),
      ],
    ),
  );

  // ── 顶部说明：一句话讲清"有两个入口、为什么分两张卡" ──────────
  Widget _intro() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '两种音乐源，各用各的卡片。',
          style: TextStyle(
            color: MusicTheme.label,
            fontSize: AppTheme.fontSubhead,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          '导入后，内置接口拿不到播放地址时会自动逐个尝试。在线导入会保存本地副本。',
          style: TextStyle(
            color: MusicTheme.secondary,
            fontSize: AppTheme.fontFootnote,
            height: 1.5,
          ),
        ),
      ],
    ),
  );

  // ============================================================
  // 两种音乐源的展示元数据
  // ============================================================

  /// 卡片身份：洛雪音乐源 / MusicFree 源
  ///
  /// 为什么要显式区分而不是靠自动识别：
  /// 用户的心智是"我要加一个洛雪源"或"我要加一个 MusicFree 源"，
  /// 把两种格式混在一个导入框里，粘错了会被静默接受，很难解释。
  /// 分成两张卡后，粘错会得到明确提示。

  Widget _sourceCard(BuildContext context, _CardKind kind) {
    final color = kind.accent;
    final isLx = kind == _CardKind.lx;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: MusicTheme.label.withValues(alpha: 0.06),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 卡头：图标徽章 + 名称 + 说明 ──────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 34,
                  height: 34,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(kind.icon, size: 19, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kind.title,
                        style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        kind.subtitle,
                        style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontFootnote,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ⚠️ 用**本卡**的 tab 与 controller（见 _tab/_textCtrl 的说明）
                _segmented(kind),
                const SizedBox(height: 12),
                if (_tab[kind] == 0)
                  _inputBox(
                    controller: _textCtrl[kind]!,
                    hint: isLx
                        ? '粘贴洛雪源的 JSON 配置 或 JS 脚本'
                        : '粘贴 MusicFree 插件内容（module.exports = { platform, getMediaSource }）',
                    maxLines: 6,
                  )
                else if (_tab[kind] == 1)
                  _inputBox(
                    controller: _urlCtrl[kind]!,
                    hint: isLx
                        ? 'https://…/音源.js'
                        : 'https://…/plugin.js（会自动下载并保存本地副本）',
                    maxLines: 1,
                    keyboardType: TextInputType.url,
                  )
                else
                  _fileRow(context, kind: kind),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      backgroundColor: color,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                    onPressed: _busy ? null : () => _import(context, kind),
                    icon: Icon(
                      _busy ? Icons.hourglass_top : Icons.add_rounded,
                      size: 18,
                    ),
                    label: Text(_busy ? '导入中…' : kind.buttonText),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  kind.hint,
                  style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontCaption,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 统一样式的输入框（文本 / 链接共用）
  Widget _inputBox({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
    TextInputType? keyboardType,
  }) => TextField(
    controller: controller,
    maxLines: maxLines,
    minLines: maxLines > 1 ? 3 : 1,
    keyboardType: keyboardType,
    style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontSubhead),
    cursorColor: MusicTheme.tint,
    decoration: InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: MusicTheme.secondary,
        fontSize: AppTheme.fontSubhead,
      ),
      hintMaxLines: maxLines > 1 ? 3 : 2,
      filled: false,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: MusicTheme.divider, width: 0.5),
      ),
    ),
  );

  /// 列表筛选（全部 / 洛雪 / MusicFree / 仅看失效）
  ///
  /// 用 Wrap 而不是 Row：四个 chip 带数字，窄屏会溢出
  Widget _filterRow(int all, int lx, int mf, int failed) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _filterChip('全部', '', all, MusicTheme.tint),
        _filterChip('洛雪音乐源', 'lx', lx, _CardKind.lx.accent),
        _filterChip('MusicFree', 'musicfree', mf, _CardKind.musicFree.accent),
        // 只有体检过才出现 —— 没数据时这个筛选没有意义
        if (SourceHealthService.instance.hasResults)
          _filterChip('失效', 'failed', failed, Colors.redAccent),
      ],
    ),
  );

  Widget _filterChip(String label, String value, int count, Color color) {
    final selected = _kindFilter == value;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => setState(() => _kindFilter = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.16) : MusicTheme.fill,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: selected
                ? color.withValues(alpha: 0.45)
                : Colors.transparent,
            width: 0.8,
          ),
        ),
        child: Text(
          '$label $count',
          style: TextStyle(
            color: selected ? color : MusicTheme.secondary,
            fontSize: AppTheme.fontCaption,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  /// 文本 / 链接 / 文件 三 tab（自绘分段，选中主题色）
  Widget _segmented(_CardKind kind) {
    const labels = ['文本', '链接', '文件'];
    return Container(
      height: 36,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: MusicTheme.fill,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Row(
        children: List.generate(3, (i) {
          final selected = i == _tab[kind];
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _tab[kind] = i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? MusicTheme.tint : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  labels[i],
                  style: TextStyle(
                    color: selected ? Colors.white : MusicTheme.secondary,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _fileRow(BuildContext context, {required _CardKind kind}) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _pickFile(kind),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(color: MusicTheme.divider, width: 0.5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              Icons.insert_drive_file_outlined,
              size: 20,
              color: MusicTheme.tint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                // ⚠️ 读**本卡**选中的文件名（见字段声明处的说明）
                _pickedName[kind] ?? '点击选择本地音源文件（JSON / JS）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: _pickedName[kind] == null
                      ? MusicTheme.secondary
                      : MusicTheme.label,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
            ),
            Icon(
              Icons.folder_open_rounded,
              size: 18,
              color: MusicTheme.secondary,
            ),
          ],
        ),
      ),
    );
  }

  /// 选本地音源文件。**[kind] 决定存到哪张卡**（见字段声明处的说明）。
  Future<void> _pickFile(_CardKind kind) async {
    try {
      // file_picker 13：pickFiles 是静态方法，直接返回 List<PlatformFile>
      final res = await FilePicker.pickFiles(type: FileType.any);
      if (res.isEmpty) return;
      final f = res.first;
      if (f.path == null) return;
      final content = await File(f.path!).readAsString();
      if (!mounted) return;
      setState(() {
        _pickedName[kind] = f.name;
        _pickedContent[kind] = content;
      });
    } catch (e) {
      // ⚠️ 这里**必须**判 mounted：上面有两次 await（选文件 + 读内容），
      //    期间用户完全可能已经退出本页 → `_toast(context, ...)` 里
      //    `ScaffoldMessenger.of(context)` 会命中已 deactivated 的 element
      //    并抛异常（成功分支 :445 一直有判，只有这个 catch 漏了）。
      if (!mounted) return;
      _toast(context, '读取文件失败：$e');
    }
  }

  Future<void> _import(BuildContext context, _CardKind kind) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // ── 取输入内容（三 tab 各自来源，且只取**本卡**的）────────
      //
      // ⚠️ 必须用 `_tab[kind]` / `_textCtrl[kind]` —— 用共用索引会把
      //    另一张卡的内容导进来（见 `_textCtrl` 字段上的说明）。
      final tab = _tab[kind]!;
      String content;
      String? fallback;
      if (tab == 0) {
        content = _textCtrl[kind]!.text.trim();
        if (content.isEmpty) {
          _toast(context, '请先粘贴音源内容');
          return;
        }
      } else if (tab == 1) {
        content = _urlCtrl[kind]!.text.trim();
        if (content.isEmpty) {
          _toast(context, '请输入音源链接');
          return;
        }
        // 传 fallbackName 让"URL 里没有平台名"时也能有个名字
        fallback = content;
      } else {
        // ⚠️ 读**本卡**的内容 —— 否则在洛雪卡选的文件会被
        //    MusicFree 卡拿去导入并报"格式不匹配"（见字段声明处的说明）。
        final picked = _pickedContent[kind];
        if (picked == null) {
          _toast(context, '请先选择文件');
          return;
        }
        content = picked;
        fallback = _pickedName[kind];
      }

      // ── 按**卡片类型**导入：粘错格式会明确拒绝而不是静默接受 ──
      final r = await SourceImportParser.importIntoStoreTyped(
        content,
        expectMusicFree: kind == _CardKind.musicFree,
        fallbackName: fallback,
      );
      if (!mounted) return;
      if (r.mismatch != null) {
        _toast(context, r.mismatch!);
        return;
      }
      _toast(
        context,
        r.count > 0 ? '已导入 ${r.count} 个${kind.title}' : '这些音源已存在，未重复导入',
      );
    } on SourceImportException catch (e) {
      if (!mounted) return;
      _toast(context, '无法识别：${e.message}');
    } catch (e) {
      if (!mounted) return;
      _toast(context, '导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 本页统一提示。**不依赖 `BuildContext`**（见下）。
  ///
  /// ── 🔴 为什么改成 `AppToast`（一次修好两个问题）────────────────
  ///
  /// **问题 1：会崩。** 原来实现是
  /// ```dart
  /// void _toast(BuildContext context, String msg) {
  ///   ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(...);
  /// }
  /// ```
  /// 而调用点里有好几处是在 `await` **之后**调的
  ///（保存音源 `:933`、导入结果 `:529/:532/:535` —— 导入本身要跑几秒）。
  /// 期间用户完全可能已经退出本页 → `ScaffoldMessenger.of(context)`
  /// 会命中已 deactivated 的 element 并抛异常。
  /// 因为 `_toast` 是**单一收口点**，改它一处就覆盖了全部 10 个调用点，
  /// 不用在每个 await 后面补 `if (!mounted) return;`（那样容易漏）。
  ///
  /// **问题 2：位置不对、长相不统一。** SnackBar 出现在屏幕**最底部**，
  /// 而音乐模块底部有全局 `MusicBottomChrome`（迷你条 + 导航栏，
  /// 见 `app.dart`）→ 提示正好被压在它下面看不见 ✗
  /// 而且同一 App 里"音乐用气泡、这一页用 SnackBar"本身就不统一
  ///（约定见 `lib/widgets/app_toast.dart` 顶部注释：
  ///  屏幕底部会被底栏盖住，所以统一走顶部气泡）。
  ///
  /// `AppToast` 挂在 root Overlay 上、自动消失，**不需要 context**，
  /// 所以 `context` 参数保留只是为了不改 10 个调用点的签名，
  /// 实现里刻意不用它（这也顺带消除了"跨 await 用 context"的风险）。
  void _toast(BuildContext context, String msg) {
    AppToast.show(msg, '');
  }

  // ── 音源列表标题行 + 数量角标 ────────────────────────────────
  Widget _listHeader(int count) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
    child: Row(
      children: [
        Text(
          '音源列表',
          style: TextStyle(
            color: MusicTheme.label,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
          ),
        ),
        const Spacer(),
        Text(
          '$count',
          style: TextStyle(
            color: MusicTheme.tint,
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _emptyHint(bool storeEmpty) => Padding(
    padding: const EdgeInsets.fromLTRB(40, 30, 40, 10),
    child: Column(
      children: [
        Icon(
          storeEmpty
              ? Icons.queue_music_outlined
              : Icons.filter_alt_off_outlined,
          size: 30,
          color: MusicTheme.secondary.withValues(alpha: 0.5),
        ),
        const SizedBox(height: 10),
        Text(
          storeEmpty
              ? '还没有音乐源。\n用上面两张卡片导入后，播放时内置接口拿不到地址会自动尝试这里。'
              : (_kindFilter == 'failed'
                    ? '没有体检失效的音源。\n点上面的「全部」看所有源。'
                    : '这个分类下还没有音乐源。\n点上面的「全部」看所有源。'),
          textAlign: TextAlign.center,
          style: TextStyle(
            color: MusicTheme.secondary,
            fontSize: AppTheme.fontFootnote,
            height: 1.6,
          ),
        ),
      ],
    ),
  );

  // ── 音源条目（对齐参考图：名称 / 标签 / 描述 + 编辑·排序·删除）──
  Widget _tile(
    BuildContext context,
    ThirdPartySourceStore store,
    ThirdPartySource s,
  ) {
    // ⚠️ 用 `usesScript` / `kindLabel`，不要用 `isScript` ——
    // MusicFree 插件也是"脚本型"，用 isScript 会显示成 KEYWORD
    // 内置源加「内置」标记，让用户一眼认出"这是 App 自带的"
    final builtinTag = s.isBuiltin ? '内置' : null;
    // 固定平台徽标：该源被绑定为哪些平台的固定第三方源（如 固定:酷狗/QQ）
    final boundLabel = _boundPlatformsLabel(s.id);
    final tagText = [
      builtinTag,
      s.kindLabel,
      s.quality,
      boundLabel,
      // 插件变量（Cookie/卡密）配过没有 —— 配过给个提示，方便排查"能搜不能播"
      if (s.isMusicFree && s.variables.isNotEmpty) '已配变量',
    ].where((t) => t != null && t.isNotEmpty).join('·');
    // 有脚本的再把脚本类型也拼上（保留原来的 urlPath 信息）
    // final tagText = '${s.kindLabel}·${s.quality}'
    //     '${s.usesScript ? "" : "·${s.urlPath}"}';
    final desc = s.isMusicFree
        ? 'MusicFree 插件 · ${(s.script ?? '').length} 字符'
        : (s.isScript
              ? 'LX 脚本 · ${(s.script ?? '').length} 字符'
              : (s.template.isEmpty ? '（无模板）' : s.template));
    final descExtra = s.headers.isEmpty ? '' : ' · ${s.headers.length} 个请求头';
    // 体检结果：失效 → 整卡描红 + 红标签；可用 → 绿标签带耗时
    final h = SourceHealthService.instance.of(s.id);
    final failed = h != null && !h.ok;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 4),
      decoration: BoxDecoration(
        color: MusicTheme.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: failed
              ? Colors.redAccent.withValues(alpha: 0.55)
              : MusicTheme.label.withValues(alpha: 0.06),
          width: failed ? 1.0 : 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: failed ? Colors.redAccent : MusicTheme.label,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _tag(tagText),
                        if (h != null) _healthTag(h),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$desc$descExtra',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                    if (failed && h.message.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        h.message,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.redAccent.withValues(alpha: 0.85),
                          fontSize: AppTheme.fontCaption,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Switch(
                value: s.enabled,
                activeThumbColor: MusicTheme.tint,
                onChanged: (v) => store.setEnabled(s.id, v),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _action(
                Icons.play_circle_outline,
                '测试',
                () => testSource(context, s),
              ),
              // MusicFree 插件：登录变量（Cookie / Token / 卡密）
              if (s.isMusicFree)
                _action(Icons.tune_rounded, '变量', () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      settings: const RouteSettings(name: 'music:page'),
                      builder: (_) => PluginVariablesPage(source: s),
                    ),
                  );
                }),
              _action(Icons.edit_outlined, '编辑', () => _showDetail(context, s)),
              _action(
                Icons.swap_vert,
                '排序',
                () => _sortMenu(context, store, s),
              ),
              _action(
                Icons.delete_outline,
                '删除',
                () => _confirmDelete(context, store, s),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tag(String text) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: MusicTheme.tint.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: MusicTheme.tint,
        fontSize: AppTheme.fontCaption,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  /// 体检状态标签：可用（绿·耗时）/ 失效（红）
  Widget _healthTag(SourceHealth h) {
    final color = h.ok ? MusicTheme.sage : Colors.redAccent;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            h.ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 11,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            h.ok ? '可用 ${h.ms}ms' : '体检失效',
            style: TextStyle(
              color: color,
              fontSize: AppTheme.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _action(IconData icon, String label, VoidCallback onTap) =>
      TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: MusicTheme.secondary,
          minimumSize: const Size(0, 36),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          visualDensity: VisualDensity.compact,
        ),
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(
          label,
          style: TextStyle(
            color: MusicTheme.secondary,
            fontSize: AppTheme.fontFootnote,
          ),
        ),
      );

  /// 该源被绑定的平台名列表（如 ['酷狗','QQ']；无绑定 → null）
  ///
  /// 绑定本身已挪到 **设置 → 音乐源**（按平台分类、可绑多个）——
  /// 这里只保留只读徽标，让人一眼看出"这个源被哪些平台固定使用"。
  String? _boundPlatformsLabel(String sourceId) {
    final names = SongSource.values
        .where(
          (p) => SettingsStore.instance.boundSourceIdsFor(p).contains(sourceId),
        )
        .map((p) => p.displayName)
        .toList();
    return names.isEmpty ? null : '固定:${names.join('/')}';
  }

  Future<void> _sortMenu(
    BuildContext context,
    ThirdPartySourceStore store,
    ThirdPartySource s,
  ) async {
    final action = await showMusicSheet<String>(
      context: context,
      backgroundColor: MusicTheme.card,
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.arrow_upward, color: MusicTheme.tint),
              title: Text(
                '上移',
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
              onTap: () => Navigator.pop(ctx, 'up'),
            ),
            ListTile(
              leading: Icon(Icons.arrow_downward, color: MusicTheme.tint),
              title: Text(
                '下移',
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
              onTap: () => Navigator.pop(ctx, 'down'),
            ),
          ],
        ),
      ),
    );
    if (action == 'up') await store.move(s.id, -1);
    if (action == 'down') await store.move(s.id, 1);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    ThirdPartySourceStore store,
    ThirdPartySource s,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: MusicTheme.card,
        title: Text(
          '删除音源',
          style: TextStyle(
            color: MusicTheme.label,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          s.isBuiltin
              ? '确定删除内置音源「${s.name}」？\n\n（内置源删除后，App 下次启动会自动重新出现。）'
              : '确定删除「${s.name}」？',
          style: TextStyle(
            color: MusicTheme.secondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      // 该源被某平台固定绑定时一并解绑（避免绑定指向已删源）
      await SettingsStore.instance.clearBindingsForSource(s.id);
      await store.remove(s.id);
    }
  }

  /// 点击「编辑」：弹窗里可直接修改名称与内容（模板/脚本），保存后写回存储
  Future<void> _showDetail(BuildContext context, ThirdPartySource s) async {
    final nameCtrl = TextEditingController(text: s.name);
    final scriptCtrl = TextEditingController(text: s.script ?? '');
    final templateCtrl = TextEditingController(text: s.template);
    final urlPathCtrl = TextEditingController(text: s.urlPath);
    final qualityCtrl = TextEditingController(text: s.quality);
    final headersCtrl = TextEditingController(
      text: s.headers.entries.map((e) => '${e.key}=${e.value}').join('\n'),
    );
    final saved = await showMusicSheet<bool>(
      context: context,
      backgroundColor: MusicTheme.card,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.viewInsetsOf(ctx).bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '编辑音源',
                      style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      foregroundColor: MusicTheme.secondary,
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(
                          text: const JsonEncoderShim().encode(s.toJson()),
                        ),
                      );
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(content: Text('已复制音源配置')),
                      );
                    },
                    icon: const Icon(Icons.copy_rounded, size: 15),
                    label: Text(
                      '复制配置',
                      style: TextStyle(
                        color: MusicTheme.secondary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _fieldLabel('名称'),
              TextField(
                controller: nameCtrl,
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontSubhead,
                ),
                decoration: _fieldDeco('音源名称'),
              ),
              const SizedBox(height: 12),
              if (s.usesScript) ...[
                _fieldLabel('脚本内容（LX 脚本）'),
                TextField(
                  controller: scriptCtrl,
                  maxLines: 12,
                  minLines: 6,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontFootnote,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                  decoration: _fieldDeco('整份脚本源码，保存后生效'),
                ),
              ] else ...[
                _fieldLabel('模板 URL'),
                TextField(
                  controller: templateCtrl,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontSubhead,
                  ),
                  decoration: _fieldDeco('如 https://api.xxx.com/url?id={id}'),
                ),
                const SizedBox(height: 12),
                _fieldLabel('取值路径'),
                TextField(
                  controller: urlPathCtrl,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontSubhead,
                  ),
                  decoration: _fieldDeco('播放地址在响应里的字段路径，如 data.url'),
                ),
                const SizedBox(height: 12),
                _fieldLabel('音质'),
                TextField(
                  controller: qualityCtrl,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontSubhead,
                  ),
                  decoration: _fieldDeco(
                    '128k / 320k / flac / flac24bit / hires',
                  ),
                ),
                const SizedBox(height: 12),
                _fieldLabel('请求头（每行 键=值）'),
                TextField(
                  controller: headersCtrl,
                  maxLines: 5,
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontFootnote,
                    fontFamily: 'monospace',
                    height: 1.4,
                  ),
                  decoration: _fieldDeco('User-Agent=Mozilla/5.0 …'),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('取消'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: MusicTheme.accentFill,
                        foregroundColor: MusicTheme.onAccentFill,
                      ),
                      onPressed: () {
                        final name = nameCtrl.text.trim();
                        if (name.isEmpty) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('名称不能为空')),
                          );
                          return;
                        }
                        Navigator.pop(ctx, true);
                      },
                      child: const Text('保存'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final name = nameCtrl.text.trim();
    final updated = s.copyWith(
      name: name,
      template: s.usesScript ? s.template : templateCtrl.text.trim(),
      urlPath: s.usesScript
          ? s.urlPath
          : urlPathCtrl.text.trim().isEmpty
          ? 'url'
          : urlPathCtrl.text.trim(),
      quality: qualityCtrl.text.trim().isEmpty
          ? '320k'
          : qualityCtrl.text.trim(),
      headers: s.usesScript ? s.headers : _parseHeaders(headersCtrl.text),
      // 🔴 **关键**：必须是 `usesScript` —— 用 `isScript` 时
      // MusicFree 插件会走 else 分支把 `script` 写回**旧值**，
      // 用户在编辑器里对该插件的任何编辑都会丢 ✗
      script: s.usesScript ? scriptCtrl.text : s.script,
    );
    await ThirdPartySourceStore.instance.upsert(updated);
    _toast(context, '已保存「$name」');
  }

  /// 请求头文本 → Map（每行 键=值，容忍冒号分隔）
  static Map<String, String> _parseHeaders(String text) {
    final out = <String, String>{};
    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final sep = t.indexOf(RegExp(r'[=:]'));
      if (sep <= 0) continue;
      final k = t.substring(0, sep).trim();
      final v = t.substring(sep + 1).trim();
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        color: MusicTheme.secondary,
        fontSize: AppTheme.fontFootnote,
      ),
    ),
  );

  InputDecoration _fieldDeco(String hint) => InputDecoration(
    hintText: hint,
    hintStyle: TextStyle(
      color: MusicTheme.secondary,
      fontSize: AppTheme.fontSubhead,
    ),
    filled: true,
    fillColor: MusicTheme.fill,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide.none,
    ),
  );
}

/// 极简 JSON 编码（避免为了一个小功能再引依赖；只处理本模块的数据结构）
class JsonEncoderShim {
  const JsonEncoderShim();
  String encode(Object? o) {
    final sb = StringBuffer();
    _w(sb, o);
    return sb.toString();
  }

  void _w(StringBuffer sb, Object? o) {
    if (o == null) {
      sb.write('null');
    } else if (o is String) {
      sb.write('"${o.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"');
    } else if (o is num || o is bool) {
      sb.write(o);
    } else if (o is Map) {
      sb.write('{');
      var first = true;
      o.forEach((k, v) {
        if (!first) sb.write(',');
        first = false;
        _w(sb, k.toString());
        sb.write(':');
        _w(sb, v);
      });
      sb.write('}');
    } else if (o is List) {
      sb.write('[');
      for (var i = 0; i < o.length; i++) {
        if (i > 0) sb.write(',');
        _w(sb, o[i]);
      }
      sb.write(']');
    } else {
      _w(sb, o.toString());
    }
  }
}

/// 测试单个音源：用一首固定的歌去解析，把结果（成功地址 / 失败原因）显示出来。
///
/// 为什么用固定测试曲：用户需要判断"是音源坏了还是这首歌找不到"，
/// 固定输入才能横向比较不同音源。用一首无版权争议的常见曲目。
Future<void> testSource(BuildContext context, ThirdPartySource s) async {
  const probe = Song(
    id: 347230,
    name: '海阔天空',
    artists: 'Beyond',
    album: '乐与怒',
  );

  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    SnackBar(
      content: Text('正在测试「${s.name}」…'),
      duration: const Duration(seconds: 1),
    ),
  );

  final sw = Stopwatch()..start();
  final r = await UnblockService.instance.testOne(s, probe);
  sw.stop();
  // 顺手记进体检结果：列表卡片立刻能看出这个源现在是红是绿
  SourceHealthService.instance.record(
    s.id,
    ok: r.ok,
    ms: sw.elapsedMilliseconds,
    message: r.ok ? '' : (r.error.isEmpty ? '未返回播放地址' : r.error),
  );
  if (!context.mounted) return;

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: MusicTheme.card,
      title: Text(
        r.ok ? '音源可用' : '音源不可用',
        style: TextStyle(
          color: r.ok ? MusicTheme.sage : Colors.redAccent,
          fontSize: AppTheme.fontHeadline,
        ),
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '音源：${s.name}',
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
            Text(
              '方式：${s.isMusicFree ? "MusicFree 插件" : (s.isScript ? "LX 脚本" : "模板")}',
              style: TextStyle(
                color: MusicTheme.secondary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
            const SizedBox(height: 10),
            if (r.ok) ...[
              Text(
                '解析到播放地址：',
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
              const SizedBox(height: 4),
              SelectableText(
                r.url,
                style: TextStyle(
                  color: MusicTheme.tint,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
            ] else
              Text(
                r.error.isEmpty ? '未返回播放地址' : r.error,
                style: TextStyle(
                  color: MusicTheme.label,
                  fontSize: AppTheme.fontSubhead,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
        if (!r.ok)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // 失败时把配置摊开，方便用户自己比对哪里配错了
              Clipboard.setData(
                ClipboardData(
                  text: const JsonEncoderShim().encode(s.toJson()),
                ),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('已复制该音源配置，便于排查')),
              );
            },
            child: const Text('复制配置'),
          ),
      ],
    ),
  );
}

/// LX 引擎自检：在**真机上**验证沙箱与超时真的生效。
///
/// 这一步很有必要：LX 脚本是用户导入的任意 JS，最坏情况是死循环。
/// Node 与 App 同进程，事件循环被占住就会**整个 App 卡死**。
/// 这个按钮会跑一段"故意死循环"的脚本，用 8 秒超时把它中断 ——
/// 你能亲眼确认 App 没卡住。
Future<void> runLxSelfTest(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(
    const SnackBar(
      content: Text('正在自检（含一段死循环，约 8 秒）…'),
      duration: Duration(seconds: 1),
    ),
  );

  final r = await MusicApi.instance.lxSelfTest();
  if (!context.mounted) return;

  final cases = (r['cases'] as List?) ?? const [];
  final info = (r['info'] as Map?) ?? const {};

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: MusicTheme.card,
      title: Text(
        r['allPass'] == true ? 'LX 引擎自检通过' : 'LX 引擎自检有问题',
        style: TextStyle(
          color: r['allPass'] == true ? MusicTheme.sage : Colors.redAccent,
          fontSize: AppTheme.fontHeadline,
        ),
      ),
      content: SizedBox(
        width: 340,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '超时 ${info['timeoutMs']}ms · '
                '脚本上限 ${asInt(info['maxScriptChars']) ~/ 1024}KB · '
                '沙箱已开',
                style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote,
                ),
              ),
              const SizedBox(height: 10),
              ...cases.map((c) {
                final m = (c as Map).cast<String, dynamic>();
                final ok = m['pass'] == true;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            ok ? Icons.check_circle : Icons.cancel,
                            size: 14,
                            color: ok ? MusicTheme.sage : Colors.redAccent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              '${m['name']}',
                              style: TextStyle(
                                color: MusicTheme.label,
                                fontSize: AppTheme.fontSubhead,
                              ),
                            ),
                          ),
                          Text(
                            '${m['ms']}ms',
                            style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                        ],
                      ),
                      if (m['error'] != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 20, top: 2),
                          child: Text(
                            '${m['error']}',
                            style: TextStyle(
                              color: MusicTheme.secondary,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}

// ============================================================
// 两种音乐源的展示元数据
// ============================================================

/// 导入卡的身份：洛雪音乐源 / MusicFree 源
///
/// 拆成两个**独立入口**而不是一个自动识别的框：
/// 用户的心智是"我要加一个洛雪源"或"我要加一个 MusicFree 源"；
/// 混在一起的话，粘错格式会被静默接受（解析是成功的），
/// 用户只会困惑"我明明加在洛雪里，怎么跑 MusicFree 去了"。
enum _CardKind {
  /// 洛雪音乐源（LX）：JSON 配置 / JS 脚本 / 模板法
  lx,

  /// MusicFree 插件：`module.exports = { platform, getMediaSource }`
  musicFree,
}

extension on _CardKind {
  /// 卡片标题
  String get title => switch (this) {
    _CardKind.lx => '洛雪音乐源',
    _CardKind.musicFree => 'MusicFree 源',
  };

  /// 卡片副标题（一句话讲清是什么）
  String get subtitle => switch (this) {
    _CardKind.lx => '洛雪音乐的 LX 音源：JSON 配置、JS 脚本、模板 URL。',
    _CardKind.musicFree => 'MusicFree 插件：带 platform 的 getMediaSource 插件。',
  };

  /// 卡头图标
  IconData get icon => switch (this) {
    _CardKind.lx => Icons.library_music_outlined,
    _CardKind.musicFree => Icons.extension_outlined,
  };

  /// 主题色（两卡一眼区分）
  ///
  /// ⚠️ 用 MusicTheme 的语义色，不要在深/浅色模式下手写死颜色 ——
  /// 手写色在浅色模式下会糊掉。
  Color get accent => switch (this) {
    _CardKind.lx => MusicTheme.sage,
    _CardKind.musicFree => MusicTheme.tint,
  };

  /// 导入按钮文案
  String get buttonText => switch (this) {
    _CardKind.lx => '导入洛雪音乐源',
    _CardKind.musicFree => '导入 MusicFree 源',
  };

  /// 卡内灰色小字（说明支持哪些格式）
  String get hint => switch (this) {
    _CardKind.lx =>
      '支持：JSON 数组 / 洛雪 User API 导出 JSON / JS 脚本 / '
          '`SERVER_SCRIPT_CONFIG` 片段 / `@name`+`@template` 头部格式。',
    _CardKind.musicFree =>
      '支持：MusicFree 插件（`module.exports` 里有 `platform` 与 '
          '`getMediaSource`）。插件里的 require("axios")/require("he") '
          '会自动注入，无需自己打包。',
  };
}
