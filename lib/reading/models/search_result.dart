/// 搜索结果包装
class SearchResult<T> {
  final List<T> items;
  final int total;
  final int currentPage;
  final int totalPages;
  final bool hasMore;

  SearchResult({
    required this.items,
    required this.total,
    required this.currentPage,
    required this.totalPages,
  }) : hasMore = currentPage < totalPages;

  factory SearchResult.empty() {
    return SearchResult(items: [], total: 0, currentPage: 1, totalPages: 0);
  }

  SearchResult<R> map<R>(R Function(T) mapper) {
    return SearchResult<R>(
      items: items.map(mapper).toList(),
      total: total,
      currentPage: currentPage,
      totalPages: totalPages,
    );
  }
}

// ── ⚠️ 这里原来还有一套 `DownloadStatus` + `DownloadTask`，已删除 ──────────
//
// 它与 `reading/services/download_service.dart` 里的**同名类**并存，
// 是两份独立演化的定义，而且**枚举值已经不同步**：
//   · 本文件（已删）：queued / downloading / completed / failed / **cancelled**
//   · download_service：queued / downloading / completed / failed / **paused**
// 字段也完全对不上（本文件用 id，那边用 key（含源 id 前缀，防多源冲突）；
// 那边还多了 epubPath / trimParamsJson / cancelToken / batchId 等）。
//
// 删除依据（三条，均已核实）：
//   1. `DownloadStatus.cancelled`（本文件独有）**全项目 0 处使用**
//   2. import 了本文件的 5 个文件（book_search_page / search_page /
//      comic_api / zlibrary_service / adapter）**0 处**引用这两个类
//      （adapter.dart 里那一处是注释）
//   3. `download_page.dart` 的 switch 用的是 `paused` —— 即
//      `download_service.dart` 那套；它也只 import 了那个文件
//
// 两份同名定义最危险的地方不是冗余，而是**枚举不同步**：
// 哪天有人的 switch 漏了分支，编译器不会报错，只会静默走错逻辑。
// 全项目请统一用 `reading/services/download_service.dart` 里的 DownloadTask。
