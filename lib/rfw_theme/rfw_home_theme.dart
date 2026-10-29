import 'package:flutter/material.dart';

import 'package:tvbox/rfw_theme/rfw_theme_events.dart';
import 'package:tvbox/rfw_theme/rfw_theme_host.dart';
import 'package:tvbox/rfw_theme/rfw_theme_store.dart';

/// 影视首页的 RFW 皮肤渲染器。
///
/// 职责只有两件：**把选中的主题文本读出来** + **把 host 挂上去**。
/// 业务动作（点片、切分类、切筛选…）通过 [onAction] 回给首页，
/// 主题文件本身不碰任何宿主状态 —— 这是 RFW 的隔离前提。
///
/// 主题文本按 id 缓存：切分类/翻页会频繁重建，不能每次都读磁盘。
class RfwHomeTheme extends StatefulWidget {
  const RfwHomeTheme({
    super.key,
    required this.data,
    required this.onAction,
  });

  final Map<String, Object?> data;
  final void Function(RfwThemeAction action) onAction;

  @override
  State<RfwHomeTheme> createState() => _RfwHomeThemeState();
}

class _RfwHomeThemeState extends State<RfwHomeTheme> {
  static final Map<String, String> _textCache = {};

  String? _themeId;
  String? _text;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    rfwThemeIdNotifier.addListener(_onThemeChanged);
    _load();
  }

  @override
  void dispose() {
    rfwThemeIdNotifier.removeListener(_onThemeChanged);
    super.dispose();
  }

  void _onThemeChanged() => _load();

  Future<void> _load() async {
    final id = rfwThemeIdNotifier.value;
    if (_themeId == id && _text != null) return;
    setState(() {
      _themeId = id;
      _loading = true;
      _error = null;
    });
    try {
      final entries = await loadRfwThemeEntries();
      if (entries.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '没有可用的主题';
          });
        }
        return;
      }
      final entry = entries.firstWhere(
        (e) => e.id == id,
        orElse: () => entries.first,
      );
      final cached = _textCache[entry.id];
      final text = cached ?? await loadRfwThemeText(entry);
      if (text == null || text.isEmpty) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = '主题文件读不出来：${entry.name}';
          });
        }
        return;
      }
      _textCache[entry.id] = text;
      if (!mounted) return;
      setState(() {
        _text = text;
        _themeId = entry.id;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '主题加载失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final error = _error;
    final text = _text;
    if (error != null || text == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            error ?? '主题不可用',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13),
          ),
        ),
      );
    }
    return RfwThemeHost(
      themeText: text,
      homeData: widget.data,
      onAction: widget.onAction,
    );
  }
}
