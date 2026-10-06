// 涔︽簮浠撳簱锛圢exhub 寮曟搸鎺ュ叆锛夛細鍙傝€冩极鐢绘簮浠撳簱锛坰ource_repo_page锛夋牱寮忋€?//
// 椤堕儴涓恒€屽鍏ュ尯銆嶏細绮樿创鏂囨湰锛圝SON/XML/NDJSON锛夈€佸鍏ユ湰鍦版枃浠躲€佸鍑烘槑鏂囷紱
// 涓嬫柟鍒楀嚭鎵€鏈変功婧愶紝鍙惎鐢?鍋滅敤銆佺紪杈戝悕绉?鍒嗙粍/娉ㄩ噴銆佸垹闄ゃ€?// 鍚敤婧愬弬涓庝功婧愰〉鑱氭悳涓庢祻瑙堬紙瑙?shuyuan_page锛夈€?
import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../novel_source/model/book_source.dart';
import '../novel_source/shuyuan_source_service.dart';
import '../services/shuyuan_source_store.dart';
import '../theme/jelly_theme.dart';
import 'book_source_editor_page.dart';
import 'book_source_health_page.dart';
import 'book_source_login_page.dart';
import 'shuyuan_source_edit_page.dart';

class ShuyuanSourceRepoPage extends StatefulWidget {
  const ShuyuanSourceRepoPage({super.key});

  @override
  State<ShuyuanSourceRepoPage> createState() => _ShuyuanSourceRepoPageState();
}

class _ShuyuanSourceRepoPageState extends State<ShuyuanSourceRepoPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 2),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  Future<void> _importFromClipboard() async {
    final ctrl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('绮樿创涔︽簮'),
        content: TextField(
          controller: ctrl,
          maxLines: 8,
          minLines: 4,
          decoration: const InputDecoration(
            hintText: '绮樿创涔︽簮 JSON / XML / NDJSON 鏂囨湰',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('鍙栨秷'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('瀵煎叆'),
          ),
        ],
      ),
    );
    if (text == null || text.trim().isEmpty) return;
    await _doImport(text);
  }

  Future<void> _importFromFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.any,
      allowedExtensions: const ['json', 'txt', 'xml'],
    );
    if (result == null || result.isEmpty) return;
    final path = result.single.path;
    if (path == null) return;
    final content = await Future.sync(() async {
      final f = await File(path).readAsString();
      return f;
    }).catchError((_) => '');
    if (content.isEmpty) {
      _toast('璇诲彇鏂囦欢澶辫触');
      return;
    }
    await _doImport(content);
  }

  Future<void> _doImport(String text) async {
    setState(() => _busy = true);
    try {
      final r = await ShuyuanSourceStore.instance.importText(text);
      _toast('瀵煎叆鎴愬姛 ${r.count} 涓紝璺宠繃 ${r.skipped} 涓?);
    } catch (e) {
      _toast('瀵煎叆澶辫触: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _export() async {
    final json = ShuyuanSourceStore.instance.exportJson();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('瀵煎嚭涔︽簮'),
        content: Text(
          '宸插皢 ${ShuyuanSourceStore.instance.allSources.length} 涓功婧愬鍑轰负鏄庢枃 JSON锛屽鍒跺埌鍓创鏉匡紵',
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('鍙栨秷'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('澶嶅埗'),
          ),
        ],
      ),
    );
    if (ok == true) {
      try {
        // ignore: deprecated_member_use
        await Clipboard.setData(ClipboardData(text: json));
        _toast('宸插鍒跺埌鍓创鏉?);
      } catch (_) {
        _toast('澶嶅埗澶辫触');
      }
    }
  }

  /// 鍏ㄩ儴鍚敤 / 鍏ㄩ儴鍋滅敤銆?  Future<void> _setAllEnabled(bool enabled) async {
    setState(() => _busy = true);
    await ShuyuanSourceStore.instance.setAllEnabled(enabled);
    if (mounted) {
      setState(() => _busy = false);
      _toast(enabled ? '宸插叏閮ㄥ惎鐢? : '宸插叏閮ㄥ仠鐢?);
    }
  }

  /// 娓呯┖鍏ㄩ儴涔︽簮锛堢‘璁ゅ悗鎵ц锛夈€?  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('娓呯┖涔︽簮'),
        content: Text(
          '纭畾娓呯┖鍏ㄩ儴 ${ShuyuanSourceStore.instance.allSources.length} 涓功婧愶紵姝ゆ搷浣滀笉鍙挙閿€銆?,
          style: const TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('鍙栨秷'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('娓呯┖'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await ShuyuanSourceStore.instance.clearAll();
    if (mounted) {
      setState(() => _busy = false);
      _toast('宸叉竻绌哄叏閮ㄤ功婧?);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final titleColor = isDark ? Colors.white : JellyTheme.textPrimaryLight;
    return Scaffold(
      backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor: isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: titleColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          '涔︽簮浠撳簱',
          style: TextStyle(
            fontSize: AppTheme.fontHeadline,
            fontWeight: FontWeight.w600,
            color: titleColor,
          ),
        ),
        actions: [
          IconButton(
            tooltip: '涔︽簮浣撴',
            icon: Icon(
              Icons.shield_outlined,
              size: 20,
              color: titleColor,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BookSourceHealthPage(),
                ),
              );
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: ShuyuanSourceStore.instance,
        builder: (context, _) {
          final all = ShuyuanSourceStore.instance.allSources;
          // 鎳掑姞杞斤細鍥哄畾澶达紙瀵煎叆鍗?鏍囬/鎵归噺琛岋級鐢?SliverToBoxAdapter锛?          // 婧愬崱鐗囩敤 SliverList.builder 鈥斺€?涔︽簮澶氭椂锛?24+锛変笉涓€娆℃€?build銆?          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildImportCard(isDark),
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Text(
                        '宸插鍏ヤ功婧愶紙${all.length}锛壜?鍏抽棴鍚庝笉鍙備笌鑱氭悳',
                        style: TextStyle(
                          fontSize: 12,
                          color: JellyTheme.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    // 鎵归噺鎿嶄綔锛氬叏閮ㄥ惎鐢?/ 鍏ㄩ儴鍋滅敤 / 娓呯┖
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: all.isEmpty || _busy
                                ? null
                                : () => _setAllEnabled(true),
                            icon: const Icon(Icons.done_all_rounded, size: 16),
                            label: const Text('鍏ㄩ儴鍚姩'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: all.isEmpty || _busy
                                ? null
                                : () => _setAllEnabled(false),
                            icon: const Icon(Icons.block_rounded, size: 16),
                            label: const Text('鍏ㄩ儴鍏抽棴'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: all.isEmpty || _busy ? null : _clearAll,
                            style: OutlinedButton.styleFrom(
                              foregroundColor:
                                  Theme.of(context).colorScheme.error,
                            ),
                            icon: const Icon(Icons.delete_sweep_rounded,
                                size: 16),
                            label: const Text('娓呯┖'),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (all.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 40),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(
                                Icons.library_books_outlined,
                                size: 48,
                                color: JellyTheme.textSecondary,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                '杩樻病鏈変功婧愶紝鐐瑰嚮涓婃柟銆岀矘璐村鍏ャ€嶆垨\n瀵煎叆鏈湴涔︽簮鏂囦欢',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: JellyTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
                ),
              ),
              if (all.isNotEmpty)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  sliver: SliverList.builder(
                    itemCount: all.length,
                    itemBuilder: (context, i) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _buildSourceCard(isDark, all[i]),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildImportCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '瀵煎叆涔︽簮',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : JellyTheme.textPrimaryLight,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '鏀寔 闃呰 3.0 / Nexhub 鏍煎紡鐨?JSON銆乆ML銆丯DJSON 鏂囨湰',
            style: TextStyle(fontSize: 12, color: JellyTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromClipboard,
                  icon: const Icon(Icons.content_paste_rounded, size: 18),
                  label: const Text('绮樿创瀵煎叆'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _importFromFile,
                  icon: const Icon(Icons.file_open_rounded, size: 18),
                  label: const Text('瀵煎叆鏂囦欢'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _export,
              icon: const Icon(Icons.ios_share_rounded, size: 16),
              label: const Text('瀵煎嚭鏄庢枃'),
              style: TextButton.styleFrom(foregroundColor: JellyTheme.primary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(bool isDark, ShuyuanSource src) {
    final enabled = src.enabled;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? JellyTheme.cardDark : JellyTheme.cardLight,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          _buildSourceIcon(src),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        src.bookSourceName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: isDark
                              ? Colors.white
                              : JellyTheme.textPrimaryLight,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  src.bookSourceGroup?.isNotEmpty == true
                      ? '${src.bookSourceGroup} 路 ${src.bookSourceUrl}'
                      : src.bookSourceUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: JellyTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '缂栬緫',
            iconSize: 20,
            icon: Icon(
              Icons.edit_outlined,
              color: JellyTheme.textSecondary,
            ),
            onPressed: () async {
              final edited = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => BookSourceEditorPage(source: src),
                ),
              );
              if (edited == true && mounted) setState(() {});
            },
          ),
          IconButton(
            tooltip: '鐧诲綍',
            iconSize: 20,
            icon: Icon(
              Icons.login_rounded,
              color: JellyTheme.textSecondary,
            ),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => BookSourceLoginPage(
                    source: src.toBookSource(),
                  ),
                ),
              );
            },
          ),
          IconButton(
            tooltip: '鍒犻櫎',
            iconSize: 20,
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('鍒犻櫎涔︽簮'),
                  content: Text('纭畾鍒犻櫎銆?{src.bookSourceName}銆嶏紵'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('鍙栨秷'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('鍒犻櫎'),
                    ),
                  ],
                ),
              );
              if (ok == true) {
                await ShuyuanSourceStore.instance.removeSource(
                  src.bookSourceUrl,
                );
              }
            },
          ),
          Switch(
            value: enabled,
            activeThumbColor: JellyTheme.primary,
            onChanged: (v) async {
              await ShuyuanSourceStore.instance.setEnabled(
                src.bookSourceUrl,
                v,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSourceIcon(ShuyuanSource src) {
    const size = 40.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: JellyTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        src.bookSourceName.isNotEmpty ? src.bookSourceName[0] : '?',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.bold,
          color: JellyTheme.primary,
        ),
      ),
    );
  }
}

