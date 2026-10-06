// 鎹㈡簮椤?鈥斺€?瀵归綈澶囦唤3.0 book_source_switch_page锛堝弬鑰冨浘 IMG_8482 / IMG_8483锛夈€?//
// 纭鎬侊細璇存槑鍖?+ 銆屽紑濮嬫悳绱€嶏紱
// 鎼滅储鎬侊細椤堕儴瀹炴椂杩涘害銆屾鍦ㄦ悳绱?x/N 涓簮 路 鎵惧埌 M 鏈€? 缁撴灉鍒楄〃杈规悳杈规彃锛?// 鐐逛腑涓€涓粨鏋滃悗 pop 杩斿洖缁欒鎯呴〉鏇挎崲褰撳墠婧愩€?import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../novel_source/model/book_source.dart';
import '../novel_source/model/search_book.dart';
import '../novel_source/web_book/web_book.dart';
import '../theme/jelly_theme.dart';

class BookSourceSwitchPage extends StatefulWidget {
  const BookSourceSwitchPage({
    super.key,
    required this.bookName,
    required this.author,
    required this.sources,
    required this.currentSource,
  });

  final String bookName;
  final String author;
  final List<XiaoshuoBookSource> sources;
  final XiaoshuoBookSource currentSource;

  @override
  State<BookSourceSwitchPage> createState() => _BookSourceSwitchPageState();
}

class _BookSourceSwitchPageState extends State<BookSourceSwitchPage> {
  final WebBook _webBook = WebBook();

  bool _searching = false;
  bool _done = false;
  int _doneCount = 0;
  final List<SearchBook> _results = [];

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _titleColor =>
      _isDark ? Colors.white : JellyTheme.textPrimaryLight;

  Future<void> _startSearch() async {
    final keyword = widget.bookName.trim();
    if (keyword.isEmpty) return;
    setState(() {
      _searching = true;
      _done = false;
      _doneCount = 0;
      _results.clear();
    });
    // 鍥哄畾 6 璺苟鍙戞壂鎻忥紙瀵归綈涔︽簮椤佃仛鎼滐紝閬垮厤 iOS 涓婃棤鐣屽苟鍙?OOM锛夈€?    final sources = widget.sources.where((s) => s.enabled).toList();
    final total = sources.length;
    const limit = 6;
    var cursor = 0;
    Future<void> worker() async {
      while (cursor < sources.length) {
        final i = cursor++;
        final source = sources[i];
        try {
          final list = await _webBook.searchBook(source: source, key: keyword);
          if (!mounted) return;
          if (list.isNotEmpty) {
            setState(() {
              for (final r in list) {
                if (!_results.any((e) =>
                    e.bookSourceUrl == r.bookSourceUrl &&
                    e.bookUrl == r.bookUrl)) {
                  _results.add(r);
                }
              }
            });
          }
        } catch (_) {
          // 鍗曟簮澶辫触涓嶆墦鎵?        }
        if (!mounted) return;
        setState(() => _doneCount++);
      }
    }

    await Future.wait(
      <Future<void>>[for (var w = 0; w < limit; w++) worker()],
    );
    if (!mounted) return;
    setState(() {
      _searching = false;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.sources.where((s) => s.enabled).length;
    return Scaffold(
      backgroundColor:
          _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
      appBar: AppBar(
        backgroundColor:
            _isDark ? JellyTheme.backgroundDark : JellyTheme.backgroundLight,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_ios_new_rounded,
              size: 20, color: _titleColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(widget.bookName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600,
                      color: _titleColor)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('鎹㈡簮',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: JellyTheme.primary,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        actions: const [SizedBox(width: 4)],
      ),
      body: Column(
        children: [
          // 鈹€鈹€ 璇存槑 / 杩涘害鍖?鈹€鈹€
          Container(
            width: double.infinity,
            color: (_isDark
                    ? JellyTheme.cardDark
                    : JellyTheme.cardLight)
                .withValues(alpha: 0.6),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('鍦ㄥ叾浠栦功婧愰噷鎵惧悓鍚嶄功',
                    style: TextStyle(
                        fontSize: AppTheme.fontBody,
                        fontWeight: FontWeight.w700,
                        color: _titleColor)),
                const SizedBox(height: 4),
                Text('鎸変功鍚嶃€?{widget.bookName}銆嶆悳绱?,
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: JellyTheme.textSecondary)),
                const SizedBox(height: 2),
                Text(
                  _searching || _done
                      ? '姝ｅ湪鎼滅储 $_doneCount/$total 涓簮 路 鎵惧埌 ${_results.length} 鏈?
                      : '鍏?$total 涓惎鐢ㄤ功婧愶紝涓€杞悳 50 涓紙鍚屾椂 10 璺級',
                  style: TextStyle(
                      fontSize: AppTheme.fontFootnote,
                      color: _searching
                          ? JellyTheme.primary
                          : JellyTheme.textSecondary,
                      fontWeight:
                          _searching ? FontWeight.w600 : FontWeight.normal),
                ),
                if (_searching) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: total == 0 ? 0 : _doneCount / total,
                    color: JellyTheme.primary,
                    backgroundColor: Colors.white12,
                    minHeight: 4,
                  ),
                ],
                if (!_searching && !_done) ...[
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: JellyTheme.primary,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onPressed: total == 0 ? null : _startSearch,
                      icon: const Icon(Icons.search_rounded, size: 18),
                      label: const Text('寮€濮嬫悳绱?,
                          style: TextStyle(
                              fontSize: AppTheme.fontBody,
                              color: Colors.white,
                              fontWeight: FontWeight.w600)),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _results.isEmpty
                ? _empty()
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _results.length,
                    itemBuilder: (c, i) => _resultTile(_results[i]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _empty() {
    if (_searching) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 12),
            Text('姝ｅ湪鍏跺畠涔︽簮涓煡鎵?..'),
          ],
        ),
      );
    }
    if (_done) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded,
                size: 48, color: Colors.orangeAccent),
            const SizedBox(height: 12),
            Text('鍏跺畠涔︽簮閲屾病鎵惧埌銆?{widget.bookName}銆?,
                style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: JellyTheme.textSecondary)),
          ],
        ),
      );
    }
    return Center(
      child: Text('鐐瑰嚮銆屽紑濮嬫悳绱€嶅湪鍏跺畠涔︽簮涓煡鎵惧悓鍚嶄功',
          style: TextStyle(
              fontSize: AppTheme.fontSubhead,
              color: JellyTheme.textSecondary)),
    );
  }

  Widget _resultTile(SearchBook r) {
    final isCurrent =
        r.bookSourceUrl == widget.currentSource.bookSourceUrl;
    final sourceName = r.bookSourceName?.isNotEmpty == true
        ? r.bookSourceName!
        : '';
    return ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: SizedBox(
          width: 40,
          height: 54,
          child: (r.coverUrl == null || r.coverUrl!.isEmpty)
              ? Container(
                  color: JellyTheme.primary.withValues(alpha: 0.1),
                  child: Icon(Icons.menu_book_rounded,
                      size: 20, color: JellyTheme.primary),
                )
              : CachedNetworkImage(
                  imageUrl: r.coverUrl!,
                  fit: BoxFit.cover,
                  errorWidget: (_, __, ___) => Container(
                    color: JellyTheme.primary.withValues(alpha: 0.1),
                    child: Icon(Icons.menu_book_rounded,
                        size: 20, color: JellyTheme.primary),
                  ),
                ),
        ),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                    color: _titleColor)),
          ),
          if (isCurrent)
            Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: JellyTheme.primary.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text('褰撳墠',
                  style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      color: JellyTheme.primary,
                      fontWeight: FontWeight.w600)),
            ),
        ],
      ),
      subtitle: Text(
        '${r.author.isEmpty ? '' : '${r.author} 路 '}$sourceName',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: AppTheme.fontFootnote, color: JellyTheme.textSecondary),
      ),
      onTap: () => Navigator.pop(context, r),
    );
  }
}

