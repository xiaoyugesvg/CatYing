import 'package:flutter/material.dart';

import '../models/tts_source.dart';
import '../services/tts_source_store.dart';
import '../theme/jelly_theme.dart';
import 'tts_source_edit_page.dart';
import '../../common/theme.dart';

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
  @override
  void initState() {
    super.initState();
    TtsSourceStore.instance.init();
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
                for (final t in ['network', 'azure', 'mimo', 'openai', 'easyvoice'])
                  ListTile(
                    title: Text(
                      TtsSource.blank(t).typeLabel,
                      style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight),
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
              // ── 系统朗读（兜底引擎）────────────────────────
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                decoration: BoxDecoration(
                  color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.record_voice_over_rounded,
                            size: 20, color: label),
                        const SizedBox(width: 8),
                        Text('系统朗读',
                            style: TextStyle(
                                fontSize: AppTheme.fontHeadline,
                                fontWeight: FontWeight.w700,
                                color: label)),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.10)
                                : Colors.black.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('兜底引擎',
                              style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  color: JellyTheme.textSecondary)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '离线、零流量、不需要任何配置。其它朗读源不可用时一律回落到它。',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          height: 1.6,
                          color: JellyTheme.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Text('当前引擎',
                            style: TextStyle(fontSize: AppTheme.fontBody, color: label)),
                        const Spacer(),
                        TextButton(
                          onPressed: () async {
                            await TtsSourceStore.instance.setActive('');
                            if (!mounted) return;
                            ScaffoldMessenger.of(context)
                                .showSnackBar(const SnackBar(
                              content: Text('已切回系统朗读'),
                              duration: Duration(seconds: 2),
                            ));
                          },
                          child: const Text('切换'),
                        ),
                      ],
                    ),
                    Text(
                      TtsSourceStore.instance.activeId.isEmpty
                          ? '系统朗读（使用中）'
                          : '未使用',
                      style: TextStyle(
                          fontSize: AppTheme.fontSubhead,
                          color: TtsSourceStore.instance.activeId.isEmpty
                              ? label
                              : JellyTheme.textSecondary),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '未检测到已安装的朗读引擎。若系统设置·文字转语音里能试听，'
                      '通常是引擎被禁用或系统限制了应用查询已安装引擎。',
                      style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          height: 1.6,
                          color: JellyTheme.textSecondary),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Text('朗读源',
                  style: TextStyle(
                      fontSize: AppTheme.fontBody,
                      fontWeight: FontWeight.w600,
                      color: JellyTheme.textSecondary)),
              const SizedBox(height: 8),
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
                    '音色通常比系统引擎好得多（EasyVoice 免费无需 API Key，'
                    '其余需要你自己的 Key）。',
                    style: TextStyle(
                        fontSize: AppTheme.fontSubhead,
                        height: 1.7,
                        color: JellyTheme.textSecondary),
                  ),
                )
              else
                for (final s in sources)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: isDark
                          ? JellyTheme.cardDark
                          : JellyTheme.cardLight,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: ListTile(
                      title: Row(
                        children: [
                          Flexible(
                            child: Text(s.name,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: AppTheme.fontHeadline,
                                    color: label)),
                          ),
                          if (s.id == TtsSourceStore.instance.activeId) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 2),
                              decoration: BoxDecoration(
                                color: isDark
                                    ? Colors.white.withValues(alpha: 0.12)
                                    : JellyTheme.primary
                                        .withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text('使用中',
                                  style: TextStyle(
                                      fontSize: AppTheme.fontFootnote,
                                      color: isDark
                                          ? Colors.white
                                          : JellyTheme.primary)),
                            ),
                          ],
                        ],
                      ),
                      subtitle: Text(s.typeLabel,
                          style: TextStyle(
                              fontSize: AppTheme.fontFootnote,
                              color: JellyTheme.textSecondary)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(
                              s.id == TtsSourceStore.instance.activeId
                                  ? Icons.check_circle_rounded
                                  : Icons.radio_button_unchecked,
                              size: 22,
                              color: s.id == TtsSourceStore.instance.activeId
                                  ? JellyTheme.primary
                                  : JellyTheme.textSecondary,
                            ),
                            tooltip: s.id == TtsSourceStore.instance.activeId
                                ? '当前使用中'
                                : '设为当前使用',
                            onPressed: () =>
                                TtsSourceStore.instance.setActive(s.id),
                          ),
                          IconButton(
                            icon: Icon(Icons.delete_outline,
                                size: 20, color: JellyTheme.textSecondary),
                            onPressed: () =>
                                TtsSourceStore.instance.remove(s.id),
                          ),
                        ],
                      ),
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => TtsSourceEditPage(source: s),
                          ),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  ),
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
                      Text('网络导入 / Azure / OpenAI / EasyVoice',
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
            ],
          );
        },
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
