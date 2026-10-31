import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/source_bean.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/generic_source_service.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/pages/drama/drama_settings.dart';
import 'package:tvbox/pages/drama/generic_source_page.dart';

/// 「短剧」管理页（2026-10-22 重做）。
///
/// 原来是一个从底部弹出的小面板：关键词挤在一个逗号分隔的输入框里、
/// 聚合源只有一行「已选 N 个」、通用源只能跳页再回来 —— 信息密度低、
/// 操作断成三段。现在改成完整页面：
///   · 关键词做成 chips，能逐个删、能回车添加；
///   · 聚合源独立成段，点进去多选（带搜索）；
///   · 通用源直接显示数量与入口，回来即刷新。
class DramaManagePage extends StatefulWidget {
  const DramaManagePage({super.key});

  @override
  State<DramaManagePage> createState() => _DramaManagePageState();
}

class _DramaManagePageState extends State<DramaManagePage> {
  final _kwCtrl = TextEditingController();

  List<String> _keywords = [];
  Set<String> _keys = {};
  int _genericCount = 0;
  bool _loading = true;
  bool _dirty = false;

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;
  Color get _line => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);
  Color get _tile => _isDark
      ? Colors.white.withValues(alpha: 0.05)
      : Colors.black.withValues(alpha: 0.025);

  /// 文字 / 图标用的强调色（暗色下 accentColor 是墨灰，看不见）
  Color get _accent => AppTheme.accentOnSurface;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _kwCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final kw = await DramaSettings.keywords();
    final keys = await DramaSettings.sourceKeys();
    final generic = await GenericSourceService.instance.list();
    if (!mounted) return;
    setState(() {
      _keywords = kw;
      _keys = keys;
      _genericCount = generic.length;
      _loading = false;
    });
  }

  void _addKeyword([String? raw]) {
    final text = (raw ?? _kwCtrl.text).trim();
    if (text.isEmpty) return;
    // 允许一次贴多个：逗号 / 顿号 / 空格分隔
    final parts = text
        .split(RegExp(r'[,，、\s]+'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    setState(() {
      for (final p in parts) {
        if (!_keywords.contains(p)) _keywords.add(p);
      }
      _kwCtrl.clear();
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (_keywords.isEmpty) {
      AppToast.show('至少留一个关键词', '');
      return;
    }
    await DramaSettings.saveKeywords(_keywords);
    await DramaSettings.saveSourceKeys(_keys);
    if (!mounted) return;
    setState(() => _dirty = false);
    AppToast.show('已保存，正在重新扫描', '');
    Navigator.of(context).pop(true);
  }

  Future<void> _pickSources() async {
    final api = ApiConfig.instance;
    final all = <SourceBean>[
      ...api.sourceBeanList,
      // 三族各看各的开关（2026-10-31 恢复本地 JS 开关后修正）：
      // 原来只判 `localSourcesEnabled`（那是本地 PY 的），于是把 PY 打开、
      // 把 JS / XBPQ 关掉时，这两族仍然会出现在短剧的源选择里 —— 用户说的
      // 「开关是串的」就是这种：关掉的那一族还在。
      ...api.localVideoSources.where(api.isLocalSourceEnabled),
    ];
    if (all.isEmpty) {
      AppToast.show('还没有可用的影视源', '');
      return;
    }
    final picked = await showDialog<Set<String>>(
      context: context,
      builder: (_) => _SourcePickerDialog(all: all, initial: _keys),
    );
    if (picked == null) return;
    setState(() {
      _keys = picked;
      _dirty = true;
    });
  }

  Future<void> _openGeneric() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      settings: const RouteSettings(name: 'drama:generic'),
      builder: (_) => const GenericSourcePage(),
    ));
    final generic = await GenericSourceService.instance.list();
    if (!mounted) return;
    setState(() => _genericCount = generic.length);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Text('短剧管理',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
              children: [
                _intro(),
                const SizedBox(height: 18),
                _sectionTitle('匹配关键词', '分类名包含任一关键词就算短剧'),
                const SizedBox(height: 8),
                _keywordBox(),
                const SizedBox(height: 22),
                _sectionTitle('聚合范围', '只影响搜索：不选 = 只搜当前源'),
                const SizedBox(height: 8),
                _sourceCard(),
                const SizedBox(height: 22),
                _sectionTitle('通用源', '标准 MacCMS / TVBox JSON 接口'),
                const SizedBox(height: 8),
                _genericCard(),
              ],
            ),
      bottomNavigationBar: _loading ? null : _saveBar(),
    );
  }

  Widget _intro() => Container(
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _accent.withValues(alpha: _isDark ? 0.18 : 0.10),
              _accent.withValues(alpha: _isDark ? 0.04 : 0.02),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
              color: _accent.withValues(alpha: 0.18), width: 0.8),
        ),
        child: Row(
          children: [
            Icon(Icons.movie_filter_rounded,
                size: 18, color: _accent),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                '短剧页一次只看一个源：点左上角源名切换；'
                '这里的关键词决定源的哪些分类算短剧，勾选的源用于搜索聚合。',
                style: TextStyle(
                    color: _sub, fontSize: AppTheme.fontCaption, height: 1.55),
              ),
            ),
          ],
        ),
      );

  Widget _sectionTitle(String title, String desc) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: TextStyle(
                  color: _fg,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(desc,
              style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
        ],
      );

  Widget _keywordBox() => Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
        decoration: BoxDecoration(
          color: _tile,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(color: _line, width: 0.8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final k in _keywords)
                  Container(
                    padding:
                        const EdgeInsets.fromLTRB(9, 4, 5, 4),
                    decoration: BoxDecoration(
                      color: _accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(k,
                            style: TextStyle(
                                color: _accent,
                                fontSize: AppTheme.fontCaption,
                                fontWeight: FontWeight.w500)),
                        const SizedBox(width: 2),
                        GestureDetector(
                          onTap: () => setState(() {
                            _keywords.remove(k);
                            _dirty = true;
                          }),
                          child: Icon(Icons.close_rounded,
                              size: 13,
                              color:
                                  _accent.withValues(alpha: 0.8)),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _kwCtrl,
                    style:
                        TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
                    decoration: InputDecoration(
                      hintText: '添加关键词，回车确认',
                      hintStyle: TextStyle(
                          color: _sub, fontSize: AppTheme.fontSubhead),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                        borderSide: BorderSide(color: _line, width: 0.8),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                        borderSide: BorderSide(color: _line, width: 0.8),
                      ),
                    ),
                    onSubmitted: _addKeyword,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 38,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          _accent.withValues(alpha: 0.14),
                      foregroundColor: _accent,
                      elevation: 0,
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMD)),
                    ),
                    onPressed: () => _addKeyword(),
                    child: const Text('添加'),
                  ),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _sourceCard() => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _pickSources,
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: _tile,
            borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
            border: Border.all(color: _line, width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _accent
                      .withValues(alpha: _keys.isEmpty ? 0.06 : 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.dns_outlined,
                    size: 18,
                    color: _keys.isEmpty
                        ? _sub
                        : _accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _keys.isEmpty ? '仅当前源' : '已选 ${_keys.length} 个源',
                      style: TextStyle(
                          color: _fg,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _keys.isEmpty
                          ? '点这里可以多选搜索时聚合的源'
                          : '点这里调整搜索时聚合的源',
                      style: TextStyle(
                          color: _sub, fontSize: AppTheme.fontCaption),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: _sub),
            ],
          ),
        ),
      );

  Widget _genericCard() => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _openGeneric,
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: _tile,
            borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
            border: Border.all(color: _line, width: 0.8),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _accent
                      .withValues(alpha: _genericCount == 0 ? 0.06 : 0.14),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.add_link_rounded,
                    size: 18,
                    color: _genericCount == 0
                        ? _sub
                        : _accent),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _genericCount == 0
                          ? '还没有通用源'
                          : '已添加 $_genericCount 个通用源',
                      style: TextStyle(
                          color: _fg,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text('管理 / 批量导入 MacCMS 接口',
                        style: TextStyle(
                            color: _sub, fontSize: AppTheme.fontCaption)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 20, color: _sub),
            ],
          ),
        ),
      );

  Widget _saveBar() => Container(
        decoration: BoxDecoration(
          color: _isDark
              ? const Color(0xFF141416).withValues(alpha: 0.96)
              : Colors.white.withValues(alpha: 0.96),
          border: Border(top: BorderSide(color: _line, width: 0.8)),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 46),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
                ),
                onPressed: _save,
                child: Text(_dirty ? '保存并重新扫描' : '保存'),
              ),
            ),
          ),
        ),
      );
}

/// 源多选弹层：带搜索，勾选后确定
class _SourcePickerDialog extends StatefulWidget {
  const _SourcePickerDialog({required this.all, required this.initial});

  final List<SourceBean> all;
  final Set<String> initial;

  @override
  State<_SourcePickerDialog> createState() => _SourcePickerDialogState();
}

class _SourcePickerDialogState extends State<_SourcePickerDialog> {
  late final Set<String> _sel = {...widget.initial};
  String _kw = '';

  @override
  Widget build(BuildContext context) {
    final shown = _kw.isEmpty
        ? widget.all
        : widget.all
            .where((s) =>
                s.name.toLowerCase().contains(_kw.toLowerCase()) ||
                s.key.contains(_kw))
            .toList();
    return AlertDialog(
      title: const Text('搜索时聚合的源'),
      content: SizedBox(
        width: 420,
        height: MediaQuery.of(context).size.height * 0.55,
        child: Column(
          children: [
            TextField(
              decoration: const InputDecoration(
                hintText: '搜索源名',
                isDense: true,
                prefixIcon: Icon(Icons.search_rounded, size: 18),
              ),
              onChanged: (v) => setState(() => _kw = v.trim()),
            ),
            const SizedBox(height: 6),
            Expanded(
              // 一行两个的**卡片**（用户 2026-10-27：竖排列表改成网格）
              child: GridView.builder(
                padding: const EdgeInsets.only(bottom: 4),
                gridDelegate:
                    const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 8,
                  crossAxisSpacing: 8,
                  mainAxisExtent: 68,
                ),
                itemCount: shown.length,
                itemBuilder: (_, i) {
                  final s = shown[i];
                  final on = _sel.contains(s.key);
                  return InkWell(
                    borderRadius: BorderRadius.circular(12),
                    onTap: () => setState(() {
                      if (on) {
                        _sel.remove(s.key);
                      } else {
                        _sel.add(s.key);
                      }
                    }),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      decoration: BoxDecoration(
                        color: on
                            ? AppTheme.accentOnSurface.withValues(alpha: 0.14)
                            : AppTheme.backgroundTertiary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: on
                              ? AppTheme.accentOnSurface
                              : AppTheme.borderLight.withValues(alpha: 0.6),
                          width: on ? 1 : 0.6,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            on
                                ? Icons.check_box
                                : Icons.check_box_outline_blank,
                            size: 15,
                            color: on
                                ? AppTheme.accentOnSurface
                                : AppTheme.textTertiary,
                          ),
                          const SizedBox(height: 3),
                          Text(
                            s.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight:
                                  on ? FontWeight.w600 : FontWeight.w500,
                              color: on
                                  ? AppTheme.accentOnSurface
                                  : AppTheme.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 1),
                          Text(
                            s.key,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                fontSize: 10, color: AppTheme.textTertiary),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => setState(_sel.clear),
                child: const Text('清空（仅当前源）'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _sel),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
