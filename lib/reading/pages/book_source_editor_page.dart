// 书源编辑页 —— 对齐备份3.0 book_source_editor_page：7 个 tab
//（源变量 / 基础 / 搜索 / 发现 / 详情 / 目录 / 正文）。
//
// 全部字段用一张 spec 表驱动（_Field/_Toggle/_Tab），读写在源 JSON 的
// 点分路径上；保存时把整份 _raw 重建为 ShuyuanSource 写回 store。
// 与当前模型差异：源变量保存到 `variableComment`（Nexhub 模型无 customVariable 键）。
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../novel_source/model/book_source.dart';
import '../novel_source/shuyuan_source_service.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';

/// 一个可编辑字段
class _Field {
  const _Field(this.key, this.label, {this.hint, this.multiline = false});

  /// 点分路径（如 ruleSearch.name）
  final String key;
  final String label;

  /// 占位提示
  final String? hint;

  /// 多行（JS 脚本、JSON 文本）
  final bool multiline;
}

/// 一个开关字段
class _Toggle {
  const _Toggle(this.key, this.label);
  final String key;
  final String label;
}

/// tab 定义
class _Tab {
  const _Tab(this.title,
      {this.toggles = const [],
      this.fields = const [],
      this.isVariable = false});
  final String title;
  final List<_Toggle> toggles;
  final List<_Field> fields;
  /// 「源变量」tab 是特殊布局（单值/键值对 切换 + 变量值框）。
  final bool isVariable;
}

/// 7 个 tab 的字段定义（与用户截图顺序一致）。
const _tabs = <_Tab>[
  _Tab('源变量', isVariable: true),
  _Tab(
    '基础',
    toggles: [
      _Toggle('enabled', '启用书源'),
      _Toggle('enabledExplore', '启用发现'),
      _Toggle('enabledCookieJar', '启用 Cookie 持久化'),
    ],
    fields: [
      _Field('bookSourceUrl', '源地址（唯一标识）', hint: 'https://www.example.com'),
      _Field('bookSourceName', '源名称', hint: '示例书源'),
      _Field('bookSourceGroup', '分组（逗号分隔）', hint: '通常书源,快速书源'),
      _Field('bookSourceComment', '说明', multiline: true),
      _Field('header', '请求头 (header)', hint: '{ "User-Agent": "..." }', multiline: true),
      _Field('loginUrl', '登录地址'),
      _Field('loginUi', '登录界面 (loginUi)', multiline: true),
      _Field('loginCheckJs', '登录检测 JS', multiline: true),
      _Field('coverDecodeJs', '封面解码 JS', multiline: true),
    ],
  ),
  _Tab(
    '搜索',
    fields: [
      _Field('searchUrl', '搜索地址', hint: 'https://…?key={{key}}&page={{page}}', multiline: true),
      _Field('ruleSearch.checkKeyWord', '校验关键字'),
      _Field('ruleSearch.bookList', '书籍列表', hint: r'$.data.list 或 js:...', multiline: true),
      _Field('ruleSearch.name', '书名', hint: r'$.title'),
      _Field('ruleSearch.author', '作者', hint: r'$.authorName'),
      _Field('ruleSearch.kind', '分类'),
      _Field('ruleSearch.wordCount', '字数'),
      _Field('ruleSearch.lastChapter', '最新章节'),
      _Field('ruleSearch.intro', '简介'),
      _Field('ruleSearch.coverUrl', '封面'),
    ],
  ),
  _Tab(
    '发现',
    fields: [
      _Field('exploreUrl', '发现地址', hint: '[{"title":"全部","url":"…"}]', multiline: true),
      _Field('ruleExplore.bookList', '书籍列表', multiline: true),
      _Field('ruleExplore.name', '书名'),
      _Field('ruleExplore.author', '作者'),
      _Field('ruleExplore.kind', '分类'),
      _Field('ruleExplore.wordCount', '字数'),
      _Field('ruleExplore.lastChapter', '最新章节'),
      _Field('ruleExplore.intro', '简介'),
      _Field('ruleExplore.coverUrl', '封面'),
      _Field('ruleExplore.bookUrl', '详情页 URL', multiline: true),
    ],
  ),
  _Tab(
    '详情',
    fields: [
      _Field('ruleBookInfo.init', '预处理 (init)', multiline: true),
      _Field('ruleBookInfo.name', '书名'),
      _Field('ruleBookInfo.author', '作者'),
      _Field('ruleBookInfo.kind', '分类'),
      _Field('ruleBookInfo.wordCount', '字数'),
      _Field('ruleBookInfo.lastChapter', '最新章节'),
      _Field('ruleBookInfo.intro', '简介'),
      _Field('ruleBookInfo.coverUrl', '封面'),
      _Field('ruleBookInfo.tocUrl', '目录 URL'),
      _Field('ruleBookInfo.canReName', '允许改名'),
      _Field('ruleBookInfo.downloadUrls', '下载 URL 规则', multiline: true),
    ],
  ),
  _Tab(
    '目录',
    fields: [
      _Field('ruleToc.preUpdateJs', '目录预处理 JS', multiline: true),
      _Field('ruleToc.chapterList', '章节列表', hint: r'$.data 或 id.list@tag.li@tag.a', multiline: true),
      _Field('ruleToc.chapterName', '章节名称', hint: 'text'),
      _Field('ruleToc.chapterUrl', '章节 URL', hint: 'href', multiline: true),
      _Field('ruleToc.formatJs', '格式化 JS', multiline: true),
      _Field('ruleToc.isVolume', '是否卷名'),
      _Field('ruleToc.updateTime', '更新时间'),
      _Field('ruleToc.isVip', '是否 VIP'),
      _Field('ruleToc.isPay', '是否付费'),
      _Field('ruleToc.nextTocUrl', '下一页目录 URL', multiline: true),
    ],
  ),
  _Tab(
    '正文',
    fields: [
      _Field('ruleContent.content', '正文', hint: '@css:div.con@textNodes', multiline: true),
      _Field('ruleContent.nextContentUrl', '下一页正文 URL', multiline: true),
      _Field('ruleContent.subContent', '子正文规则', multiline: true),
      _Field('ruleContent.replaceRegex', '净化替换', multiline: true),
      _Field('ruleContent.chapterName', '章节名'),
      _Field('ruleContent.sourceRegex', 'sourceRegex'),
      _Field('ruleContent.imageStyle', '图片样式'),
      _Field('ruleContent.imageDecode', '图片解码'),
      _Field('ruleContent.webJs', 'webJs', multiline: true),
      _Field('ruleContent.buyOption', '购买操作'),
      _Field('ruleContent.callBackJs', '回调 JS', multiline: true),
    ],
  ),
];

class BookSourceEditorPage extends StatefulWidget {
  const BookSourceEditorPage({super.key, required this.source});

  final ShuyuanSource source;

  @override
  State<BookSourceEditorPage> createState() => _BookSourceEditorPageState();
}

class _BookSourceEditorPageState extends State<BookSourceEditorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  /// 编辑中的整份源 JSON（点分路径读写都在它上面，保存时整体重建）。
  late Map<String, dynamic> _raw;

  /// 编辑中的值（key = 点分路径；源变量用 variableComment）。
  final Map<String, String> _draft = {};
  final Map<String, bool> _draftBool = {};

  /// 点分路径读值。
  dynamic _readPath(String path) {
    final parts = path.split('.');
    dynamic cur = _raw;
    for (final p in parts) {
      if (cur is Map && cur.containsKey(p)) {
        cur = cur[p];
      } else {
        return null;
      }
    }
    return cur;
  }

  /// 点分路径写值（中间 Map 缺省自动创建；null 则删除键）。
  void _writePath(String path, dynamic value) {
    final parts = path.split('.');
    var cur = _raw;
    for (var i = 0; i < parts.length - 1; i++) {
      final p = parts[i];
      final next = cur[p];
      if (next is! Map) {
        cur[p] = <String, dynamic>{};
      }
      cur = cur[p] as Map<String, dynamic>;
    }
    final last = parts.last;
    if (value == null) {
      cur.remove(last);
    } else {
      cur[last] = value;
    }
  }

  @override
  void initState() {
    super.initState();
    _raw = Map<String, dynamic>.from(widget.source.toJson());
    _tab = TabController(length: _tabs.length, vsync: this);
    _tab.addListener(() => setState(() {}));
    _varCtrl.text = (_raw['variableComment'] ?? '').toString();
    _draft['variableComment'] = _varCtrl.text;
    for (final t in _tabs) {
      for (final f in t.fields) {
        final v = _readPath(f.key);
        _draft[f.key] = v?.toString() ?? '';
      }
      for (final tg in t.toggles) {
        final v = _readPath(tg.key);
        _draftBool[tg.key] = v == true;
      }
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    _varCtrl.dispose();
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    _fieldCtrls.clear();
    super.dispose();
  }

  Future<void> _save() async {
    // 一次性写回 _raw，避免每字段一次写盘。
    _draft.forEach((k, v) {
      final key = k == 'variableComment' ? 'variableComment' : k;
      _writePath(key, v.trim().isEmpty ? null : v.trim());
    });
    _draftBool.forEach((k, v) => _writePath(k, v));
    final updated = ShuyuanSource.fromJson(_raw);
    await ShuyuanSourceStore.instance.addSource(updated);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
    );
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    final name = (_raw['bookSourceName'] ?? '').toString();
    return Scaffold(
      backgroundColor:
          isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor:
            isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
        centerTitle: true,
        title: Text(
          name.isEmpty ? '书源编辑' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: AppTheme.fontHeadline,
              fontWeight: FontWeight.w600,
              color: label),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text('保存',
                style: TextStyle(fontSize: AppTheme.fontHeadline, color: label)),
          ),
        ],
        bottom: TabBar(
          controller: _tab,
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          labelColor: label,
          unselectedLabelColor: JellyTheme.textSecondary,
          indicatorColor: label,
          indicatorSize: TabBarIndicatorSize.label,
          labelStyle: const TextStyle(
              fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600),
          unselectedLabelStyle: const TextStyle(fontSize: AppTheme.fontBody),
          tabs: [for (final t in _tabs) Tab(text: t.title)],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [for (final t in _tabs) _buildTab(t, isDark)],
      ),
    );
  }

  /// 源变量 tab 的"单值 / 键值对"模式
  bool _varKvMode = false;
  final _varCtrl = TextEditingController();
  final _fieldCtrls = <String, TextEditingController>{};
  TextEditingController _ctrlFor(String key) => _fieldCtrls.putIfAbsent(
        key,
        () => TextEditingController(text: (_draft[key] ?? '').toString()),
      );

  Widget _buildVariableTab(bool isDark) {
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        Text('源变量可在脚本中通过 source.getVariable() 获取',
            style: TextStyle(
                fontSize: AppTheme.fontSubhead,
                color: JellyTheme.textSecondary)),
        const SizedBox(height: 4),
        Text(
          _varKvMode
              ? '键值对：每行一个 key=value，脚本里按键取值'
              : '单值：整条串直接保存，适合单个 Token 等裸值',
          style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: JellyTheme.textSecondary),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : JellyTheme.primary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            children: [
              for (final kv in [false, true])
                Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _varKvMode = kv),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: _varKvMode == kv
                            ? (isDark
                                ? Colors.white.withValues(alpha: 0.14)
                                : JellyTheme.primary.withValues(alpha: 0.12))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        kv ? '键值对' : '单值',
                        style: TextStyle(
                          fontSize: AppTheme.fontBody,
                          fontWeight: _varKvMode == kv
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: _varKvMode == kv
                              ? (isDark
                                    ? Colors.white
                                    : JellyTheme.textPrimaryLight)
                              : JellyTheme.textSecondary,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TextField(
            controller: _varCtrl,
            onChanged: (v) => _draft['variableComment'] = v,
            maxLines: 6,
            minLines: 3,
            style: TextStyle(fontSize: AppTheme.fontBody, color: label),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              hintText: _varKvMode ? 'key1=value1\nkey2=value2' : '变量值',
              hintStyle: TextStyle(
                  fontSize: AppTheme.fontBody,
                  color: JellyTheme.textSecondary),
              border: InputBorder.none,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTab(_Tab t, bool isDark) {
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    if (t.isVariable) return _buildVariableTab(isDark);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
      children: [
        if (t.toggles.isNotEmpty) ...[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            decoration: BoxDecoration(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                for (var i = 0; i < t.toggles.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Row(
                    children: [
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(t.toggles[i].label,
                              style: TextStyle(
                                  fontSize: AppTheme.fontHeadline,
                                  color: label)),
                        ),
                      ),
                      Switch(
                        value: _draftBool[t.toggles[i].key] ?? false,
                        onChanged: (v) => setState(
                            () => _draftBool[t.toggles[i].key] = v),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 14),
        ],
        for (final f in t.fields) ...[
          Text(f.label,
              style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                  color: label)),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
              borderRadius: BorderRadius.circular(12),
            ),
            child: TextField(
              controller: _ctrlFor(f.key),
              onChanged: (v) => _draft[f.key] = v,
              maxLines: f.multiline ? 6 : 1,
              minLines: f.multiline ? 3 : 1,
              style: TextStyle(fontSize: AppTheme.fontBody, color: label),
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                hintText: f.hint,
                hintStyle: TextStyle(
                    fontSize: AppTheme.fontBody,
                    color: JellyTheme.textSecondary),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
              ),
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );
  }
}
