import 'package:flutter/material.dart';

import '../models/book_source.dart';
import '../theme/jelly_theme.dart';
import '../../common/theme.dart';

/// 书源编辑页 —— 7 个 tab（源变量 / 基础 / 搜索 / 发现 / 详情 / 目录 / 正文）。
///
/// ── 字段路径的来源（重要）─────────────────────────────────────
/// 所有点分路径都取自**一份真实书源 JSON**，不是猜的：
/// ```json
/// { "bookSourceName":"…", "bookSourceUrl":"…", "bookSourceGroup":"…",
///   "bookSourceComment":"…", "enabled":true, "enabledExplore":true,
///   "enabledCookieJar":true, "header":"{…}", "searchUrl":"…",
///   "exploreUrl":"[…]",
///   "ruleSearch":{"bookList":"…","name":"…","author":"…","bookUrl":"…",
///                 "checkKeyWord":"…","intro":"…","lastChapter":"…","wordCount":"…"},
///   "ruleBookInfo":{…}, "ruleToc":{"chapterList":"…","chapterName":"…","chapterUrl":"…"},
///   "ruleContent":{"content":"…"} }
/// ```
/// `BookSource.readPath/writePath` 按这些路径读写。
///
/// ⚠️ 路径写错的后果不是报错，而是**静默失效**：用户改了规则、
/// 保存成功、但引擎读的是另一个键 → 书源莫名其妙不工作。
/// 所以这里宁可啰嗦，每个字段都写明它对应哪个键（见 [_Field.key]）。
///
/// ── 为什么用字段表驱动而不是手写 7 个 TabView ────────────────
/// 全部字段加起来 60 多个，手写会产生 7 份几乎一样的
/// 「标签 + 输入框」代码。用一张 spec 表生成，改样式只改一处。
class BookSourceEditorPage extends StatefulWidget {
  const BookSourceEditorPage({super.key, required this.source});

  final BookSource source;

  @override
  State<BookSourceEditorPage> createState() => _BookSourceEditorPageState();
}

/// 一个可编辑字段
class _Field {
  const _Field(this.key, this.label, {this.hint, this.multiline = false});

  /// 点分路径，直接交给 `readPath/writePath`
  final String key;
  final String label;

  /// 占位提示（截图里多数字段是空的灰框）
  final String? hint;

  /// 多行（JS 脚本、JSON 文本这类都不是单行）
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
  /// 「源变量」tab 是特殊布局（单值/键值对 切换 + 变量值框），
  /// 与其它 tab 的"标签+输入框"列表不同，所以单列一个标记。
  final bool isVariable;
}

/// 7 个 tab 的字段定义。
///
/// 顺序与用户截图一致：源变量 / 基础 / 搜索 / 发现 / 详情 / 目录 / 正文。
const _tabs = <_Tab>[
  // ── 源变量（截图第一个 tab）────────────────────────────────
  //
  // 说明文字（截图原文）：
  //   "源变量可在脚本中通过 source.getVariable() 获取"
  //   "单值：整条串直接保存，适合单个 Token 等裸值"
  // 右上角有「单值 / 键值对」分段切换。
  _Tab('源变量', isVariable: true),

  // ── 基础 ──────────────────────────────────────────────────
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

  // ── 搜索 ──────────────────────────────────────────────────
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

  // ── 发现 ──────────────────────────────────────────────────
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

  // ── 详情 ──────────────────────────────────────────────────
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

  // ── 目录 ──────────────────────────────────────────────────
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

  // ── 正文 ──────────────────────────────────────────────────
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

class _BookSourceEditorPageState extends State<BookSourceEditorPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  late BookSource _src;

  /// 编辑中的值（key = 点分路径）。保存时一次性写入。
  final Map<String, String> _draft = {};
  final Map<String, bool> _draftBool = {};

  @override
  void initState() {
    super.initState();
    _src = widget.source;
    _tab = TabController(length: _tabs.length, vsync: this);
    _tab.addListener(() => setState(() {}));
    // 源变量（自定义变量存在 customVariable 里，Legado 就是这个键）
    _varCtrl.text = (_src.readPath('customVariable') ?? '').toString();
    _draft['variable'] = _varCtrl.text;
    // 把已有值读进 draft（只读一次，之后以 draft 为准）
    for (final t in _tabs) {
      for (final f in t.fields) {
        final v = _src.readPath(f.key);
        _draft[f.key] = v?.toString() ?? '';
      }
      for (final tg in t.toggles) {
        final v = _src.readPath(tg.key);
        _draftBool[tg.key] = v == true;
      }
    }
  }

  @override
  void dispose() {
    _tab.dispose();
    _varCtrl.dispose();
    // 表单字段的持久 controller 也要释放 ✓（不放就是换个地方泄漏 ✗）
    for (final c in _fieldCtrls.values) {
      c.dispose();
    }
    _fieldCtrls.clear();
    super.dispose();
  }

  Future<void> _save() async {
    // 一次性写回：每改一个字段写一次盘会有 60 次写操作
    final values = <String, dynamic>{};
    _draft.forEach((k, v) {
      // 「源变量」在 Legado 里对应的键是 customVariable
      final key = k == 'variable' ? 'customVariable' : k;
      values[key] = v.trim().isEmpty ? null : v.trim();
    });
    _draftBool.forEach((k, v) => values[k] = v);
    await BookSourceStore.instance.updatePaths(_src.id, values);
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
    return Scaffold(
      backgroundColor:
          isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        centerTitle: true,
        title: Text(
          _src.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: AppTheme.fontTitle3, fontWeight: FontWeight.w700, color: label),
        ),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('保存', style: TextStyle(fontSize: AppTheme.fontHeadline)),
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
          labelStyle:
              const TextStyle(fontSize: AppTheme.fontBody, fontWeight: FontWeight.w600),
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
  // 🔴 表单各字段的 controller：原来是在 `build` 里**每次重建都 new 一个** ✗
  //（见下面 `TextField(controller: TextEditingController(text: …))` ✓）
  // → 每帧泄漏一个 ✓（而且那个 `..selection = …末尾` 的写法正是为了掩盖
  //   "新 controller 光标总跳到开头/末尾" ✗）。
  // ✓ 改成**按字段名缓存**的持久 controller ✓。
  // ⚠️ **不能共用一个** ✗：这些字段是**同屏同时显示**的 ✓，
  //   共用一个会让所有输入框显示同一段文字 ✗✗（比泄漏更糟 ✓）
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
            style: TextStyle(fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary)),
        const SizedBox(height: 4),
        Text(
          _varKvMode ? '键值对：每行一个 key=value，脚本里按键取值' : '单值：整条串直接保存，适合单个 Token 等裸值',
          style: TextStyle(fontSize: AppTheme.fontSubhead, color: JellyTheme.textSecondary),
        ),
        const SizedBox(height: 14),
        // ── 单值 / 键值对 分段切换（按截图 IMG_8112）────────────
        //
        // ⚠️ 我第一版做错了 3 处，对照截图后修正：
        //   ① 容器要是**整宽**的（我原来 mainAxisSize.min 只包住内容）
        //   ② 两个选项要**等宽**（截图里"单值"胶囊占左半，右边留白给"键值对"）
        //   ③ 选中态是**浅灰胶囊 + 深色字**（不是黑底白字 —— 那是另一套视觉）
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
                        // 选中 = 浅灰胶囊（浅色模式比底色略深一点）
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
            onChanged: (v) => _draft['variable'] = v,
            maxLines: 6,
            minLines: 3,
            style: TextStyle(fontSize: AppTheme.fontBody, color: label),
            decoration: InputDecoration(
              isDense: true,
              filled: false,
              hintText: _varKvMode ? 'key1=value1\nkey2=value2' : '变量值',
              hintStyle: TextStyle(
                  fontSize: AppTheme.fontBody, color: JellyTheme.textSecondary),
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
        // 开关组（基础 tab）
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
                              style:
                                  TextStyle(fontSize: AppTheme.fontHeadline, color: label)),
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
        // 普通字段
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
              // ✓ 按字段名取**持久** controller（见 `_fieldCtrls` 的说明 ✓）——
              // 顺带修掉一个观感问题 ✓：原来每次重建都新建 controller +
              // 强行把光标塞到末尾 ✗ → 输入时**光标会乱跳** ✓；
              // 现在光标停在用户实际输入的位置 ✓
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
                    fontSize: AppTheme.fontBody, color: JellyTheme.textSecondary),
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
