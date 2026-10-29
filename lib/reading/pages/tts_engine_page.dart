import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/reading/models/tts_source.dart';
import 'package:tvbox/reading/services/tts_source_store.dart';
import 'package:tvbox/reading/theme/jelly_theme.dart';
import 'package:tvbox/reading/pages/tts_source_edit_page.dart';
import 'package:tvbox/common/theme.dart';

/// 朗读引擎（截图 IMG_8087/8088）。
///
/// ── 页面结构 ──────────────────────────────────────────────────
///   系统朗读（兜底引擎）
///     当前引擎：未取到 / 切换
///     未检测到已安装的朗读引擎时的说明
///   朗读源
///     还没有添加朗读源时的说明
///     ＋ 添加朗读源   网络导入 / Azure / OpenAI 兼容
///
/// 点「添加朗读源」先弹**朗读源类型**底部弹层（4 个类型），
/// 选完进入对应的配置页（见 TtsSourceEditPage）。
class TtsEnginePage extends StatefulWidget {
  const TtsEnginePage({super.key});

  @override
  State<TtsEnginePage> createState() => _TtsEnginePageState();
}

class _TtsEnginePageState extends State<TtsEnginePage> {
  /// 系统朗读引擎是否可用（null = 还没问出来）
  bool? _sysAvailable;

  @override
  void initState() {
    super.initState();
    TtsSourceStore.instance.init();
    _probeSystemEngine();
  }

  /// 真去问一次原生 `available`，别把「未检测到」写死。
  Future<void> _probeSystemEngine() async {
    var ok = true;
    try {
      const ch = MethodChannel('tts_engine');
      ok = await ch.invokeMethod<bool>('available') ?? true;
    } catch (_) {
      // 通道不可用（比如桌面端没实现）→ 按可用处理，不吓用户
      ok = true;
    }
    if (!mounted) return;
    setState(() => _sysAvailable = ok);
  }

  /// 「朗读源类型」弹层（截图 IMG_8088）
  Future<void> _showTypePicker() async {
    final type = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        return Container(
          decoration: BoxDecoration(
            color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(22)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 12, 8),
                  child: Row(
                    children: [
                      Text('朗读源类型',
                          style: TextStyle(
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.w700,
                              color: isDark
                                  ? Colors.white
                                  : JellyTheme.textPrimaryLight)),
                      const Spacer(),
                      IconButton(
                        onPressed: () => Navigator.pop(ctx),
                        icon: Icon(Icons.close_rounded,
                            size: 20, color: JellyTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                for (final t in [
                  'edge',
                  'mimo',
                  'easyvoice',
                  'openai',
                  'azure',
                  'http',
                  'network',
                ])
                  ListTile(
                    title: Text(
                      TtsSource.blank(t).typeLabel,
                      style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight),
                    ),
                    // 用户 2026-10-29：「感觉搞得好混乱」——七个类型光看名字
                    // 分不清谁免费、谁要 Key、谁最灵活。每行补一句区别。
                    subtitle: Text(
                      _typeHint(t),
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: JellyTheme.textSecondary),
                    ),
                    onTap: () => Navigator.pop(ctx, t),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (type == null || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TtsSourceEditPage(source: TtsSource.blank(type)),
      ),
    );
    if (mounted) setState(() {});
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
        title: Text('朗读引擎',
            style: TextStyle(
                fontSize: AppTheme.fontTitle3, fontWeight: FontWeight.w700, color: label)),
      ),
      body: ListenableBuilder(
        listenable: TtsSourceStore.instance,
        builder: (context, _) {
          final sources = TtsSourceStore.instance.all;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 40),
            children: [
              // ── 顶部：现在到底用哪个引擎 ─────────────────────
              //
              // 用户 2026-10-29：「AI朗读还有其余听书引擎感觉搞得好混乱呢」。
              // 原来这页最上面是一大张「系统朗读」卡（带「兜底引擎」徽标 +
              // 「当前引擎 / 切换」+ 两段说明），朗读源又在下面单独一套单选，
              // 用户要自己在脑子里拼"现在到底谁在念"。这里先给一句结论。
              _currentEngineCard(isDark, label),
              const SizedBox(height: 18),
              Text('引擎',
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: JellyTheme.textSecondary)),
              const SizedBox(height: 8),
              _sysEngineTile(isDark, label),
              if (sources.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text('朗读源',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w600,
                        color: JellyTheme.textSecondary)),
                const SizedBox(height: 8),
              ],

              if (sources.isEmpty)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color:
                        isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Text(
                    '还没有添加朗读源。朗读源用来接入系统之外的语音合成服务，'
                    '音色通常比系统引擎好得多（Edge 内置 / 小米 MiMo 都免费、免 Key）。',
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        height: 1.7,
                        color: JellyTheme.textSecondary),
                  ),
                )
              else
                for (final s in sources) _sourceTile(s, isDark, label),
              const SizedBox(height: 8),
              // ── 添加朗读源 ────────────────────────────────
              InkWell(
                onTap: _showTypePicker,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color:
                        isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.add_rounded, size: 20, color: label),
                      const SizedBox(width: 10),
                      Text('添加朗读源',
                          style: TextStyle(
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.w600,
                              color: label)),
                      const Spacer(),
                      Text('Edge 免费 / MiMo / Azure / 自定义',
                          style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: JellyTheme.textSecondary)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // 「导入朗读引擎」入口（截图 IMG_8101）
              InkWell(
                onTap: _showImportEngine,
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 16),
                  decoration: BoxDecoration(
                    color:
                        isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.input_rounded,
                          size: 20, color: label),
                      const SizedBox(width: 10),
                      Text('导入朗读引擎',
                          style: TextStyle(
                              fontSize: AppTheme.fontHeadline,
                              fontWeight: FontWeight.w600,
                              color: label)),
                      const Spacer(),
                      Icon(Icons.chevron_right_rounded,
                          size: 20, color: JellyTheme.textSecondary),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // 用户 2026-10-29：「AI朗读还有其余听书引擎感觉搞得好混乱呢」——
              // 把"什么时候生效 / 失败会怎样"写在这里，省得用户去猜。
              Text(
                '切换后从下一段开始生效，不用重新点播放。\n'
                '网络源合成失败时会整章回落系统朗读（不会一段 AI 一段系统），'
                '下一章再自动重试。',
                style: TextStyle(
                    fontSize: AppTheme.fontFootnote,
                    height: 1.7,
                    color: JellyTheme.textSecondary),
              ),
            ],
          );
        },
      ),
    );
  }

  // ══════════════════════════════════════════════════════════
  // 视觉零件（用户 2026-10-29：「感觉搞得好混乱」→ 先给结论，再给列表）
  // ══════════════════════════════════════════════════════════

  /// 朗读源类型的一句话区别（弹层副标题用）
  static String _typeHint(String type) {
    switch (type) {
      case 'edge':
        return '免配置、免 Key，走 App 内置 Node，音色比系统朗读好';
      case 'mimo':
        return '小米 MiMo，限时免费，需要填 Key';
      case 'easyvoice':
        return '自建 EasyVoice 服务（免费 Edge 音色），需要填服务地址';
      case 'openai':
        return '任意 OpenAI 兼容的 /audio/speech 接口，需要地址 + Key';
      case 'azure':
        return '微软 Azure 语音，需要区域 + Key，音色最全';
      case 'http':
        return '自定义 URL 模板，最灵活；知道接口长什么样再选它';
      default:
        return '从链接或 JSON 导入别人配好的引擎（新手最省事）';
    }
  }

  /// 顶部总览：**现在到底谁在念**
  ///
  /// 原来这页要用户自己从两张卡里拼答案（「系统朗读 → 当前引擎：未使用
  /// （当前走「小米 MiMo」）」+ 下面某一行挂着「使用中」徽标）。
  Widget _currentEngineCard(bool isDark, Color label) {
    final store = TtsSourceStore.instance;
    final active = store.active;
    final onSystem = active == null;
    final name = onSystem ? '系统朗读' : active.name;
    final kind = onSystem ? '离线 · 零流量 · 无需配置' : active.typeLabel;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: JellyTheme.primary.withValues(alpha: isDark ? 0.5 : 0.28),
          width: 0.8,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: JellyTheme.primary.withValues(alpha: isDark ? 0.22 : 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              onSystem
                  ? Icons.record_voice_over_rounded
                  : Icons.graphic_eq_rounded,
              size: 20,
              color: isDark ? Colors.white : JellyTheme.primary,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前引擎',
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption,
                        color: JellyTheme.textSecondary)),
                const SizedBox(height: 2),
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w700,
                      color: label),
                ),
                const SizedBox(height: 2),
                Text(
                  kind,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: JellyTheme.textSecondary),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : JellyTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('使用中',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : JellyTheme.primary)),
          ),
        ],
      ),
    );
  }

  /// 系统朗读行 —— 与朗读源同一套单选样式（原来它是张独立大卡 + 「切换」按钮）
  Widget _sysEngineTile(bool isDark, Color label) {
    final on = TtsSourceStore.instance.activeId.isEmpty;
    return _tile(
      isDark: isDark,
      selected: on,
      title: '系统朗读',
      subtitle: _sysAvailable == false
          ? '未检测到系统语音引擎（若「设置 · 朗读内容」里能试听，通常是系统限制了查询）'
          : '手机自带语音合成 · 离线 · 其它源不可用时自动兜底',
      icon: Icons.smartphone_rounded,
      onSelect: () async {
        await TtsSourceStore.instance.setActive('');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('已切回系统朗读'),
          duration: Duration(seconds: 2),
        ));
      },
    );
  }

  /// 一个朗读源行（点圆点设为使用中；点整行进编辑；右侧删除要确认）
  Widget _sourceTile(TtsSource s, bool isDark, Color label) {
    final on = s.id == TtsSourceStore.instance.activeId;
    return _tile(
      isDark: isDark,
      selected: on,
      title: s.name,
      subtitle: s.typeLabel,
      icon: Icons.graphic_eq_rounded,
      onSelect: () => TtsSourceStore.instance.setActive(s.id),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => TtsSourceEditPage(source: s)),
        );
        if (mounted) setState(() {});
      },
      onDelete: () async {
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('删除朗读源'),
            content: Text('删除「${s.name}」？它保存的 API Key 也会一起清掉。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await TtsSourceStore.instance.remove(s.id);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('已删除「${s.name}」'),
          duration: const Duration(seconds: 2),
        ));
      },
    );
  }

  /// 单选行骨架（系统朗读 / 朗读源共用，样式一致才不会显得"两套体系"）
  Widget _tile({
    required bool isDark,
    required bool selected,
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onSelect,
    VoidCallback? onTap,
    VoidCallback? onDelete,
  }) {
    final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(14),
        border: selected
            ? Border.all(
                color: JellyTheme.primary.withValues(alpha: isDark ? 0.6 : 0.4),
                width: 0.8,
              )
            : null,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
          child: Row(
            children: [
              Icon(icon,
                  size: 19,
                  color: selected ? label : JellyTheme.textSecondary),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontHeadline, color: label),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          height: 1.4,
                          color: JellyTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked,
                  size: 22,
                  color:
                      selected ? JellyTheme.primary : JellyTheme.textSecondary,
                ),
                tooltip: selected ? '当前使用中' : '设为当前使用',
                onPressed: onSelect,
              ),
              if (onDelete != null)
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      size: 20, color: JellyTheme.textSecondary),
                  tooltip: '删除',
                  onPressed: onDelete,
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「导入朗读引擎」（截图 IMG_8101）
  Future<void> _showImportEngine() async {
    final ctrl = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        final isDark = Theme.of(ctx).brightness == Brightness.dark;
        final label = isDark ? Colors.white : JellyTheme.textPrimaryLight;
        String? msg;
        return StatefulBuilder(
          builder: (ctx, setSheet) => Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Container(
              decoration: BoxDecoration(
                color:
                    isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(22)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('导入朗读引擎',
                          style: TextStyle(
                              fontSize: AppTheme.fontTitle3,
                              fontWeight: FontWeight.w700,
                              color: label)),
                      const SizedBox(height: 12),
                      Text('粘贴朗读引擎的链接或 JSON 文本（支持单条与数组）',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              color: JellyTheme.textSecondary)),
                      const SizedBox(height: 10),
                      TextField(
                        controller: ctrl,
                        maxLines: 4,
                        minLines: 1,
                        style: TextStyle(fontSize: AppTheme.fontBody, color: label),
                        decoration: InputDecoration(
                          hintText: 'https://.../engine.json',
                          hintStyle: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: JellyTheme.textSecondary),
                          filled: true,
                          fillColor: isDark
                              ? Colors.white.withValues(alpha: 0.07)
                              : Colors.black.withValues(alpha: 0.045),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () async {
                          final r = await TtsSourceStore.instance
                              .importJson(ctrl.text.trim());
                          setSheet(() {
                            msg = r.error != null
                                // ✅ **文案复核结论（本会话 ✓）：此处有意不接入统一失败表** ✗。
                                //   原因 ✓：`importJson` 的 error 是**本地粘贴文本的 JSON 解析失败** ✓
                                //   （**没有网络请求** ✓），与 `utils/source_fail_text.dart` 服务的
                                //   "**源 / 网络**失败分级"**不同域** ✗ —— 硬套统一表反而把话说糊 ✓。
                                //   用户看到「解析失败：<具体原因>」✓ 直接指向"你粘的内容有问题"✓ 最有用 ✓。
                                ? '解析失败：${r.error}'
                                : '新增 ${r.added} 个，更新 ${r.updated} 个';
                          });
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor:
                              isDark ? Colors.white : JellyTheme.primary,
                          foregroundColor: isDark
                              ? JellyTheme.backgroundDark
                              : Colors.white,
                        ),
                        child: const Text('拉取解析'),
                      ),
                      if (msg != null) ...[
                        const SizedBox(height: 10),
                        Text(msg!,
                            style: TextStyle(
                                fontSize: AppTheme.fontSubhead, color: label)),
                      ],
                      const SizedBox(height: 14),
                      Text(
                        '解析后的引擎会列在这里\n带「更新」徽标的会覆盖本地同名条目',
                        style: TextStyle(
                            fontSize: AppTheme.fontFootnote,
                            height: 1.7,
                            color: JellyTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
