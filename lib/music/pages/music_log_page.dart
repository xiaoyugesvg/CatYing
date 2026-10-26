import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/music/theme/music_theme.dart';

/// 音乐模块的**运行日志查看页**。
///
/// ── 🔴 为什么要有它（用户实测反馈）────────────────────────────────
/// 用户原话：「那个源切换过程中源不能用的日志在哪看呢？…
///            「详情见日志」在哪呢？」
///
/// 原状：日志**确实在写**（`AppLog` → `<Documents>/nodejs-project/runtime/app.log`），
/// 但查看入口在**阅读模块**的「设置 → 我的 → 软件日志」里 ——
/// 而音乐这边报错时提示"详情见日志"，**用户根本找不到** ✗
///
/// 现在音乐自己的「我的」页里也有一个入口，出错时一句话就能到。
///
/// ── 为什么不用阅读那个页面 ──────────────────────────────────────
/// `_AppLogPage` 是 `general_settings_page.dart` 里的**私有类**，
/// 且它带的是阅读模块的配色（`JellyTheme`）。音乐模块有自己的主题
/// （`MusicTheme`），直接复用会让这个页面在音乐里"格格不入"。
///
/// ── 附加的两个排查便利（因为音乐排错主要靠这两点）────────────
///   · **只看 `[Music]` / `[Unblock]`** 的开关：日志里别的东西很多，
///     而音乐的问题基本只在这两类前缀里
///   · **复制全部**：方便把日志发出来
class MusicLogPage extends StatefulWidget {
  const MusicLogPage({super.key});

  @override
  State<MusicLogPage> createState() => _MusicLogPageState();
}

class _MusicLogPageState extends State<MusicLogPage> {
  /// 只显示音乐相关的行
  bool _onlyMusic = true;

  bool _loading = true;
  String _raw = '';

  /// 音乐相关的前缀：抓包时只关心这几类
  static const _musicTags = ['[Music]', '[Unblock]', '[MusicApi]', '[BGM]'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // 800 行够覆盖一次「点歌 → 试音源 → 失败/成功」的全过程
    final text = await AppLog.instance.readRecentLines(lines: 800);
    if (!mounted) return;
    setState(() {
      _raw = text;
      _loading = false;
    });
  }

  /// 按开关过滤（`_raw` 为空时才真的显示"暂无"）
  String get _shown {
    if (_raw.trim().isEmpty) return '';
    if (!_onlyMusic) return _raw;
    final lines = _raw.split('\n').where((l) {
      for (final t in _musicTags) {
        if (l.contains(t)) return true;
      }
      return false;
    }).toList();
    return lines.join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final text = _shown;
    return Theme(
      data: MusicTheme.themeData(),
      child: Scaffold(
        backgroundColor: MusicTheme.background,
        appBar: AppBar(
          backgroundColor: MusicTheme.background,
          elevation: 0,
          iconTheme: IconThemeData(color: MusicTheme.label),
          title: Text('音乐运行日志',
              style: TextStyle(
                  color: MusicTheme.label, fontSize: AppTheme.fontTitle3)),
          actions: [
            IconButton(
              tooltip: '复制全部',
              icon: Icon(Icons.copy_rounded,
                  size: 20, color: MusicTheme.label),
              onPressed: text.trim().isEmpty
                  ? null
                  : () async {
                      await Clipboard.setData(ClipboardData(text: text));
                      AppToast.show('日志已复制', '可以直接粘贴给别人看');
                    },
            ),
            IconButton(
              tooltip: '刷新',
              icon: Icon(Icons.refresh_rounded,
                  size: 20, color: MusicTheme.label),
              onPressed: _load,
            ),
            IconButton(
              tooltip: '清空日志',
              icon: Icon(Icons.delete_outline_rounded,
                  size: 20, color: MusicTheme.label),
              onPressed: () async {
                await AppLog.instance.clear();
                await _load();
              },
            ),
          ],
        ),
        body: _loading
            ? Center(
                child: SizedBox(
                  width: 26,
                  height: 26,
                  child: CircularProgressIndicator(
                      strokeWidth: 2.5, color: MusicTheme.tint),
                ),
              )
            : Column(
                children: [
                  // ── 只看音乐相关 ──────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _onlyMusic
                                ? '只看音乐相关（[Music] / [Unblock] 等）'
                                : '显示全部日志',
                            style: TextStyle(
                                color: MusicTheme.secondary,
                                fontSize: AppTheme.fontFootnote),
                          ),
                        ),
                        Switch(
                          value: _onlyMusic,
                          activeThumbColor: MusicTheme.tint,
                          onChanged: (v) => setState(() => _onlyMusic = v),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: text.trim().isEmpty
                        ? Center(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 40),
                              child: Text(
                                _raw.trim().isEmpty
                                    ? '（暂无日志，先播一首歌再回来）'
                                    : '（没有音乐相关的日志 —— '
                                        '试试关掉上面那个开关看全部）',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    color: MusicTheme.secondary,
                                    fontSize: AppTheme.fontBody),
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            padding: const EdgeInsets.all(14),
                            child: SelectableText(
                              text,
                              style: TextStyle(
                                color: MusicTheme.label,
                                fontSize: AppTheme.fontCaption,
                                height: 1.5,
                                // 等宽字体：日志对齐才好读
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                  ),
                ],
              ),
      ),
    );
  }
}
