import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import '../models/bookshelf.dart';
import '../utils/constants.dart';
import '../utils/app_toast.dart';
import '../utils/cover_generator.dart';
import 'book_parser.dart';
import 'bookshelf_service.dart';
import 'settings_service.dart';
import 'zlibrary_service.dart';
import '../source/global_proxy.dart';

/// 日志工具
///
/// ✅ **本文件的日志已自动进入「软件日志」**（我的 → 通用设置 → 软件日志 ✓）——
///   由 `lib/main.dart:70` 的 `debugPrint` 重定向统一覆盖 ✓✓，此处**不再手工调 AppLog** ✓
///   （手工调会让同一条失败写两遍 ✗）。
///   ℹ️ 本文件是**图书下载失败原因**的主要产地 ✓（"登录已失效，请重新登录"✓ "请先登录账号"✓
///     限额 ✓ 合并失败 ✓ DioException 摘要 ✓ …）—— 现在都能在日志页看到 ✓✓
void _log(String message) {
  if (kDebugMode) debugPrint('[BookDownload] $message');
}

enum BookDownloadStatus { queued, downloading, completed, failed, paused }

/// 同步返回的下载发起结果（UI 据此弹 toast）；后续状态由任务反映在下载管理页
enum BookDownloadResult {
  started,
  alreadyDownloading,
  limitExceeded,
  needLogin,
}

class BookDownloadTask {
  final String bookId;
  String hash;
  // 书名/作者/封面可变：阅读器「编辑书籍」会直接改 + 落盘（updateMeta）
  String title;
  String? author;
  final String? extension;
  String? cover;
  BookDownloadStatus status;
  double progress; // 0~1
  String? localPath;
  String? error;
  int? downloadedAt; // 完成时间戳（ms）
  // 运行时（不持久化）
  CancelToken? cancelToken;
  int startIndex; // 内置账号轮询起点（reserve 时确定）
  bool reserved; // 是否已占用每日限额名额
  bool resumeMode; // 续传标记（运行时）：true 时从已下载字节接着下
  bool isLocalImport; // 本地导入的图书（非 z-library 下载，不占名额、不自动入"已下载的书"）

  BookDownloadTask({
    required this.bookId,
    required this.hash,
    required this.title,
    this.author,
    this.extension,
    this.cover,
    this.status = BookDownloadStatus.queued,
    this.progress = 0,
    this.localPath,
    this.error,
    this.downloadedAt,
    this.startIndex = 0,
    this.reserved = false,
    this.resumeMode = false,
    this.isLocalImport = false,
  });

  factory BookDownloadTask.fromBook(
    Book book, {
    int startIndex = 0,
    bool reserved = false,
  }) => BookDownloadTask(
    bookId: book.id,
    hash: book.hash,
    title: book.title,
    author: book.author,
    extension: book.extension,
    cover: book.cover,
    startIndex: startIndex,
    reserved: reserved,
  );

  factory BookDownloadTask.fromJson(Map<String, dynamic> j) {
    final status = BookDownloadStatus.values.firstWhere(
      (s) => s.name == j['status'],
      // 🔴 原来是 `orElse: () => completed` ✗ —— 落盘的状态名**认不出来**时
      // （坏数据 / 枚举改名 / 手改 prefs ✓）会被**当成"已下载"** ✓
      // → 卡片显示"已下载"、点开却找不到文件 ✓（离线打开直接失败 ✓），
      // 而用户看到的是"已下载"三个字 ✓，属于"坏数据伪装成正常" ✗。
      // 改成 `failed`：**宁可显示失败让用户重下** ✓，也不谎报已下载 ✓
      //（同族问题在 `download_service.dart` 的 `DownloadTask.fromJson` 也有一份 ✗）
      orElse: () => BookDownloadStatus.failed,
    );
    return BookDownloadTask(
      bookId: j['bookId'] as String? ?? '',
      hash: j['hash'] as String? ?? '',
      title: j['title'] as String? ?? '',
      author: j['author'] as String?,
      extension: j['extension'] as String?,
      cover: j['cover'] as String?,
      status: status,
      localPath: j['localPath'] as String?,
      downloadedAt: j['downloadedAt'] as int?,
      startIndex: j['startIndex'] as int? ?? 0,
      // 🔴 名额占用必须**按落盘值读回** ✓：原实现从状态反推（`status != failed` ✗）
      // → 重启后**连 queued 任务也被算成"已占当日名额"** ✗（它们从未 reserve 过 ✓），
      // 于是记账与实际不符、每日上限被静默放宽 ✓；而 failed 在失败时已释放过 ✓，
      // 反推成 false 只是**碰巧**对 ✓。
      // 老数据没有该键 → 仍按状态兜底，但只承认**真正会持有名额**的状态 ✓
      reserved: j['reserved'] as bool? ??
          (status == BookDownloadStatus.completed ||
              status == BookDownloadStatus.paused ||
              status == BookDownloadStatus.downloading),
      isLocalImport: j['isLocalImport'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() => {
    'bookId': bookId,
    'hash': hash,
    'title': title,
    'author': author,
    'extension': extension,
    'cover': cover,
    'status': status.name,
    'localPath': localPath,
    'downloadedAt': downloadedAt,
    'startIndex': startIndex,
    // ⚠️ **名额占用要落盘** ✓（原来不写 ✗ → 只能靠状态反推 → 重启即漂移 ✓）
    'reserved': reserved,
    'isLocalImport': isLocalImport,
  };
}

/// 图书下载服务（单例 + ChangeNotifier）
/// 对标漫画 DownloadService：队列 + 并发 + 暂停/继续/取消/重试 + 持久化。
/// 下载逻辑对应 cmbook BookDownload：限额预留 -> 取下载链接 -> 流式下载。
class BookDownloadService extends ChangeNotifier {
  BookDownloadService._();
  static final BookDownloadService _instance = BookDownloadService._();
  factory BookDownloadService() => _instance;

  static const _kRecords = 'book_download_records';

  /// 构造图书下载用的 Dio，并**挂上「全局网络代理」**（本轮接上 ✓）。
  ///
  /// 为什么 ✗：本服务原来是**纯直连** ✓ —— 用户开了「网络代理」后，
  /// **图书文件下载照样不走代理** ✗（同 z-library 那批问题 ✓）。
  /// 手法与 `download_service._createImageDio()` ✓、`zlibrary_service._createDio()` ✓ **完全一致** ✓
  /// （都是"先构造 ✓ 再 `applyGlobalProxy`"✓），**不发明新机制** ✗。
  /// ⚠️ 本服务**没有**自定义 UA 工厂 ✓ → 不必传 `createHttpClient` ✓；
  ///   若将来加了 UA ✓，务必**同样传进来** ✓（否则 `applyProxy` 会整替换适配器 ✓、
  ///   把 UA 丢掉 ✗ —— 那个坑今天已经在 `download_service` 那边识别并规避过 ✓✓）。
  /// · 代理**关闭** ✓ → `applyGlobalProxy` 直接返回 false ✓ **连适配器都不换** ✓（一字不差 ✓）
  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 120),
      ),
    );
    applyGlobalProxy(dio);
    return dio;
  }

  final Dio _dio = _createDio();

  final Map<String, BookDownloadTask> _tasks = {};
  Map<String, BookDownloadTask> get tasks => Map.unmodifiable(_tasks);

  BookDownloadTask? task(String bookId) => _tasks[bookId];
  bool isDownloaded(String bookId) =>
      _tasks[bookId]?.status == BookDownloadStatus.completed;

  /// 编辑书籍元数据（书名/作者/封面）—— 阅读器右悬浮「编辑书籍」用。
  /// 只改非空传入项；书名不允许改空。改完立即通知 + 落盘。
  void updateMeta(String bookId, {String? title, String? author, String? cover}) {
    final t = _tasks[bookId];
    if (t == null) return;
    final newTitle = title?.trim();
    if (newTitle != null && newTitle.isNotEmpty) t.title = newTitle;
    if (author != null) {
      final a = author.trim();
      t.author = a.isEmpty ? null : a;
    }
    if (cover != null) {
      final c = cover.trim();
      t.cover = c.isEmpty ? null : c;
    }
    notifyListeners();
    _persist();
  }

  List<BookDownloadTask> get activeTasks => _tasks.values
      .where((t) => t.status != BookDownloadStatus.completed)
      .toList();
  List<BookDownloadTask> get completedTasks => _tasks.values
      .where((t) => t.status == BookDownloadStatus.completed)
      .toList();

  int get _runningCount => _tasks.values
      .where((t) => t.status == BookDownloadStatus.downloading)
      .length;

  /// 进度通知节流：多本并发下载时进度回调仍可能每秒数次 notify，
  /// 叠加 setState 全量重建淹没主线程消息队列。仅进度更新走节流，
  /// 状态变更（开始/完成/失败/暂停/取消）仍即时 notify。
  DateTime? _lastProgressNotify;
  Timer? _progressNotifyTimer;

  /// 本地导入自增序号：bookId 追加它，防多本连续导入同毫秒撞 id。
  int _localSeq = 0;

  /// 落盘节流：大批量下载时书籍频繁完成，避免每本都编码全任务写 prefs。
  DateTime? _lastPersist;
  Timer? _persistTrailingTimer;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kRecords);
      if (raw != null) {
        final list = jsonDecode(raw) as List;
        for (final item in list) {
          final t = BookDownloadTask.fromJson(item as Map<String, dynamic>);
          _tasks[t.bookId] = t;
        }
      }
      _log('已加载 ${_tasks.length} 条图书下载记录');
    } catch (e) {
      _log('加载记录失败: $e');
    }
    // 应用退出时正在下载(downloading)的任务已被中断，转回排队重新调度。
    // 图书为单一大文件，沿用"暂停->继续"的 HTTP Range 续传（resumeMode=true）
    // 从已下载字节接着下；queued 任务从未开始，保持从头下。
    var hasQueued = false;
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.downloading) {
        t
          ..status = BookDownloadStatus.queued
          ..resumeMode = true;
        hasQueued = true;
      } else if (t.status == BookDownloadStatus.queued) {
        hasQueued = true;
      }
    }
    notifyListeners();
    if (hasQueued) _schedule();
    // 补加历史已下载到"已下载的书"书架（幂等）
    await _syncDownloadedToShelf();
    // 预生成 PDF 默认封面：早期 PDF 与 TXT 共用 default_txt.png，书架显示时
    // 会重指到 default_pdf.png，此处确保文件就绪（旧数据兼容，幂等）。
    await _ensureDefaultCover('pdf');
  }

  /// 启动时把历史已下载图书补加到"已下载的书"书架（幂等）
  Future<void> _syncDownloadedToShelf() async {
    final items = <BookshelfItem>[];
    for (final t in _tasks.values) {
      if (t.status != BookDownloadStatus.completed) continue;
      if (t.isLocalImport) continue; // 本地导入的书已入"本地漫画/本地图书"书架，不重复入"已下载的书"
      final snapshot = Book(
        id: t.bookId,
        hash: t.hash,
        title: t.title,
        author: t.author,
        cover: t.cover,
        extension: t.extension,
      );
      items.add(
        BookshelfItem(
          bookshelfId: BookshelfService.presetDownloaded,
          itemId: t.bookId,
          type: BookshelfItemType.book,
          addedAt: DateTime.now().millisecondsSinceEpoch,
          meta: jsonEncode(snapshot.toJson()),
        ),
      );
    }
    if (items.isNotEmpty) {
      await BookshelfService().ensureItemsInShelf(items);
    }
  }

  Future<void> _persist() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final records = _tasks.values
          .where(
            (t) =>
                t.status == BookDownloadStatus.completed ||
                t.status == BookDownloadStatus.paused ||
                t.status == BookDownloadStatus.failed ||
                t.status == BookDownloadStatus.queued ||
                t.status == BookDownloadStatus.downloading,
          )
          .map((t) => t.toJson())
          .toList();
      await prefs.setString(_kRecords, jsonEncode(records));
    } catch (e) {
      _log('保存记录失败: $e');
    }
  }

  /// 节流版进度通知：最多每 150ms 触发一次，窗口内排尾随保证最终必刷新。
  void _notifyProgress() {
    final now = DateTime.now();
    if (_lastProgressNotify == null ||
        now.difference(_lastProgressNotify!) >=
            const Duration(milliseconds: 150)) {
      _lastProgressNotify = now;
      notifyListeners();
      return;
    }
    _progressNotifyTimer ??= Timer(const Duration(milliseconds: 150), () {
      _progressNotifyTimer = null;
      _lastProgressNotify = DateTime.now();
      notifyListeners();
    });
  }

  /// 节流版落盘：最多每 1s 一次，窗口内排尾随保证最终必落盘。
  /// 仅用于下载流程；用户主动操作仍直接调 _persist() 即时写入。
  void _schedulePersist() {
    final now = DateTime.now();
    if (_lastPersist == null ||
        now.difference(_lastPersist!) >= const Duration(seconds: 1)) {
      _lastPersist = now;
      _persist();
      return;
    }
    _persistTrailingTimer ??= Timer(const Duration(seconds: 1), () {
      _persistTrailingTimer = null;
      _lastPersist = DateTime.now();
      _persist();
    });
  }

  Future<Directory> _booksDir() async {
    final base = await SettingsService.downloadBaseDir();
    final dir = Directory('${base.path}/${CmbokConstants.bookDir}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 清理文件名非法字符并按 UTF-8 字节截断到 [maxBytes]（默认180）。
  /// 中文 UTF-8 每字 3 字节，Android ext4 单文件名 NAME_MAX=255 字节，
  /// 按字符数截断(100中文字=300字节)会超限致下载失败，故按字节截断，
  /// 并回退到多字节字符边界，避免截断半个字符产生乱码。
  String _sanitize(String s, {int maxBytes = 180}) {
    var name = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '').trim();
    name = name.replaceAll(RegExp(r'[. ]+$'), ''); // 去尾部点/空格
    final bytes = utf8.encode(name);
    if (bytes.length <= maxBytes) return name;
    int cut = maxBytes;
    while (cut > 0 && (bytes[cut] & 0xC0) == 0x80) {
      cut--; // 回退到多字节字符首字节
    }
    return utf8.decode(bytes.sublist(0, cut), allowMalformed: true);
  }

  /// 加入下载队列（立即返回，后台调度）。
  /// 名额在入队时预留（对应 cmbook 下载开始即 reserve）；失败/取消时释放。
  Future<BookDownloadResult> download(Book book) async {
    final existing = _tasks[book.id];
    if (existing != null &&
        existing.status != BookDownloadStatus.completed &&
        existing.status != BookDownloadStatus.failed) {
      return BookDownloadResult.alreadyDownloading;
    }

    final z = ZlibraryService();
    // 关闭内置账号且未登录：要求先登录
    if (!z.isLoggedIn && !SettingsService().useBuiltinAccount) {
      return BookDownloadResult.needLogin;
    }
    // 预留每日限额名额
    int? startIndex;
    bool reserved;
    if (z.isLoggedIn) {
      reserved = z.reserveLoggedDownload();
      startIndex = 0;
    } else {
      startIndex = z.reserveBuiltinDownload();
      reserved = startIndex != null;
    }
    if (!reserved) return BookDownloadResult.limitExceeded;

    final task = existing ?? BookDownloadTask.fromBook(book);
    // 同 bookId 不同来源（如分类页 dl slug vs eapi 6 位 hash）hash 可能不同，
    // 用本次下载的 book.hash 覆盖旧 task.hash，确保下载走对的来源路径。
    if (task.hash != book.hash) task.hash = book.hash;
    task
      ..status = BookDownloadStatus.queued
      ..progress = 0
      ..error = null
      ..startIndex = startIndex ?? 0
      ..reserved = true
      ..resumeMode = false
      ..cancelToken = null;
    _tasks[book.id] = task;
    notifyListeners();
    _persist(); // 立即持久化排队任务，退出软件不丢
    _schedule();
    return BookDownloadResult.started;
  }

  /// 导入本地图书文件：复制到 Books 目录，记为已完成任务（不占下载名额）。
  /// epub/mobi 提取内嵌封面，txt/pdf 生成默认封面，其余无封面。
  /// 返回新书 bookId；失败返回 null。供书架页"导入本地图书"使用。
  Future<String?> importLocalFile(
    File src, {
    required String title,
    required String extension,
  }) async {
    try {
      final dir = await _booksDir();
      final now = DateTime.now().millisecondsSinceEpoch;
      final bookId = 'local_${now}_${_localSeq++}';
      final ext = extension.toLowerCase();
      final suffix = '_$bookId.$ext';
      final dest = File(
        '${dir.path}/${_sanitize(title, maxBytes: 250 - suffix.length)}$suffix',
      );
      await src.copy(dest.path);

      // 封面：epub/mobi 提取内嵌封面，txt/pdf 用默认封面
      String? coverPath;
      if (ext == 'epub') {
        try {
          final coverBytes = await compute(BookParser.extractEpubCover, src);
          coverPath = await _saveCoverBytes(bookId, coverBytes);
        } catch (e) {
          _log('提取 epub 封面失败: $e');
        }
      } else if (ext == 'mobi' || ext == 'azw' || ext == 'azw3') {
        try {
          final coverBytes = await compute(BookParser.extractMobiCover, src);
          coverPath = await _saveCoverBytes(bookId, coverBytes);
        } catch (e) {
          _log('提取 mobi 封面失败: $e');
        }
      } else if (ext == 'txt' || ext == 'pdf') {
        coverPath = await _ensureDefaultCover(ext);
      }

      final task = BookDownloadTask(
        bookId: bookId,
        hash: '',
        title: title,
        extension: ext,
        status: BookDownloadStatus.completed,
        progress: 1,
        localPath: dest.path,
        downloadedAt: now,
        isLocalImport: true,
        cover: coverPath,
      );
      _tasks[bookId] = task;
      _persist();
      notifyListeners();
      _log('导入本地图书: $title');
      return bookId;
    } catch (e) {
      _log('导入本地图书失败: $e');
      return null;
    }
  }

  /// 封面图存放目录：下载目录下 `bookDir/covers` 子目录。
  Future<Directory> _coversDir() async {
    final base = await SettingsService.downloadBaseDir();
    final dir = Directory('${base.path}/${CmbokConstants.bookDir}/covers');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  /// 保存提取到的封面字节，返回路径；bytes 为空返回 null。
  Future<String?> _saveCoverBytes(String bookId, Uint8List? bytes) async {
    if (bytes == null || bytes.isEmpty) return null;
    try {
      final dir = await _coversDir();
      // 🔴 与 `book_content_cache_service._file` **同一类问题** ✗（今天一起发现的 ✓）：
      //   `bookId` **未净化**就拼进路径 ✓ —— 本项目图书 id 是 `book-<url>` ✓，
      //   URL 必然含 `/` ✓ → 封面会被写到 `covers/book-https://host/x.png` ✗；
      //   若 bookUrl 里带 `../` ✓✓ 则会**逃出 covers 目录** ✗✗（路径穿越 ✓）。
      // ✓ 净化：只保留 `[A-Za-z0-9_-]` ✓，其余换 `_` ✓，并限长 120 ✓
      //   （与 `book_content_cache_service` 保持**同一套写法** ✓，便于以后一起改 ✓）
      // ⚠️ 副作用（无害 ✓）：净化后文件名与旧封面不同 → 旧文件读不到 →
      //   会重新提取一次封面 ✓，不影响正确性 ✓
      final safe = bookId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
      final name = safe.length <= 120 ? safe : safe.substring(0, 120);
      final file = File('${dir.path}/$name.png');
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (e) {
      _log('保存封面失败: $e');
      return null;
    }
  }

  /// 确保默认封面文件存在（按 ext 首次生成，后续复用），返回路径；失败返回 null。
  /// txt/pdf 各一份（default_txt.png / default_pdf.png），配色与标识不同。
  Future<String?> _ensureDefaultCover(String ext) async {
    try {
      final dir = await _coversDir();
      final file = File('${dir.path}/default_$ext.png');
      if (await file.exists()) return file.path;
      final bytes = await CoverGenerator.generateDefaultCover(ext: ext);
      await file.writeAsBytes(bytes);
      return file.path;
    } catch (e) {
      _log('生成默认封面失败: $e');
      return null;
    }
  }

  /// 调度：按"同时下载量"并发启动排队任务
  void _schedule() {
    final max = SettingsService().maxConcurrentChapters;
    while (_runningCount < max) {
      final next = _nextQueued();
      if (next == null) break;
      _startTask(next);
    }
  }

  BookDownloadTask? _nextQueued() {
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.queued) return t;
    }
    return null;
  }

  void _startTask(BookDownloadTask task) {
    task.status = BookDownloadStatus.downloading;
    if (!task.resumeMode) {
      task.progress = 0;
    }
    task.cancelToken = CancelToken();
    notifyListeners();
    _downloadOne(task).whenComplete(_schedule);
  }

  Future<void> _downloadOne(BookDownloadTask task) async {
    final z = ZlibraryService();
    // 捕获本次下载的 CancelToken：重试延迟期间若被暂停后重试(resume)接管，
    // task.cancelToken 会被替换，据此识别并静默退出，避免并发写同一文件。
    final CancelToken? myToken = task.cancelToken;
    try {
      final link = await z.getDownloadLink(
        task.bookId,
        task.hash,
        startIndex: task.startIndex,
      );
      if (!_tasks.containsKey(task.bookId)) return; // 已取消
      if (task.status == BookDownloadStatus.paused) return; // 已暂停
      final dir = await _booksDir();
      final ext =
          (task.extension?.isNotEmpty == true ? task.extension! : 'epub')
              .toLowerCase();
      final suffix = '_${task.bookId}.$ext';
      final file = File(
        '${dir.path}/${_sanitize(task.title, maxBytes: 250 - suffix.length)}$suffix',
      );

      // 续传：从已下载字节数接着下（HTTP Range）
      int startByte = 0;
      if (task.resumeMode) {
        try {
          if (await file.exists()) startByte = await file.length();
        } catch (e) {
          _log('读取已下载大小失败: $e');
        }
        if (startByte > 0) _log('续传 ${task.title}：从 $startByte 字节继续');
      }

      // 实际下载：带自动续传重试，中途断网按已下载字节接着下
      await _downloadWithRetry(link, file, startByte, task, myToken);
      // 重试延迟期间可能被暂停后重试(resume)接管，此时静默退出
      if (!identical(task.cancelToken, myToken)) return;
      if (!_tasks.containsKey(task.bookId)) return; // 已取消
      if (task.status == BookDownloadStatus.paused) return; // 已暂停
      task
        ..status = BookDownloadStatus.completed
        ..progress = 1
        ..localPath = file.path
        ..downloadedAt = DateTime.now().millisecondsSinceEpoch;
      _schedulePersist();
      notifyListeners();
      AppToast.show('「${task.title}」', '下载成功');
      _log('下载完成: ${task.title}');
      // 自动加入"已下载的书"书架（幂等）
      final snapshot = Book(
        id: task.bookId,
        hash: task.hash,
        title: task.title,
        author: task.author,
        cover: task.cover,
        extension: task.extension,
      );
      await BookshelfService().addToBookshelf(
        BookshelfService.presetDownloaded,
        task.bookId,
        BookshelfItemType.book,
        meta: jsonEncode(snapshot.toJson()),
      );
      // 登录态：下载成功后刷新服务端已下载数，及时更新头像下方显示
      if (z.isLoggedIn) z.refreshUserProfile();
    } on ZlibraryException catch (e) {
      if (!_tasks.containsKey(task.bookId)) return; // 已取消，静默
      if (task.status == BookDownloadStatus.paused) return; // 已暂停，静默
      _releaseQuota(task, z);
      // 自登账号额度用完：拉取服务端真实值回写，使后续预约能正确拦截
      if (e.code == 'quota_exceeded' && z.isLoggedIn) {
        z.refreshUserProfile();
      }
      task
        ..status = BookDownloadStatus.failed
        ..error = _downloadErrorMsg(e);
      _schedulePersist();
      notifyListeners();
      AppToast.show('「${task.title}」', '下载失败', isError: true);
      _log('下载失败: ${task.title} - ${e.code}');
    } on DioException catch (e) {
      if (!_tasks.containsKey(task.bookId)) return; // 已取消，静默
      if (task.status == BookDownloadStatus.paused) return; // 已暂停，静默
      _releaseQuota(task, z);
      task
        ..status = BookDownloadStatus.failed
        ..error = _dioErrorMsg(e);
      _schedulePersist();
      notifyListeners();
      AppToast.show('「${task.title}」', '下载失败', isError: true);
      _log('下载失败: ${task.title} - ${_dioErrorBrief(e)}');
    } catch (e) {
      if (!_tasks.containsKey(task.bookId)) return; // 已取消，静默
      if (task.status == BookDownloadStatus.paused) return; // 已暂停，静默
      _releaseQuota(task, z);
      task
        ..status = BookDownloadStatus.failed
        ..error = '$e';
      _schedulePersist();
      notifyListeners();
      AppToast.show('「${task.title}」', '下载失败', isError: true);
      _log('下载失败: ${task.title} - $e');
    }
  }

  /// z-library 业务异常 -> 用户可读文案（对应 cmbook 下载状态码 -6/-7/-8 映射）。
  String _downloadErrorMsg(ZlibraryException e) {
    switch (e.code) {
      case 'quota_exceeded':
        return '账号今日下载额度已用完';
      case 'no_login':
        return '登录已失效，请重新登录';
      case 'unavailable':
        return '图书功能暂不可用，请等待恢复';
      case 'no_account':
        return '没有可用的内置账号';
      case 'rate_limited':
        return '请求过于频繁，请稍后再试';
      default:
        return e.message;
    }
  }

  /// 流式续传：带 Range 请求，206 则追加续传，200（服务端不支持 Range）则从头重下。
  /// 416 表示已下载字节已达全文大小（文件已完整），直接视为完成。
  Future<void> _downloadWithResume(
    DownloadLink link,
    File file,
    int startByte,
    BookDownloadTask task,
  ) async {
    final response = await _dio.get(
      link.url,
      options: Options(
        responseType: ResponseType.stream,
        headers: {
          ...link.headers,
          HttpHeaders.rangeHeader: 'bytes=$startByte-',
          // 避免压缩，保证 Range/追加操作的是原始字节
          HttpHeaders.acceptEncodingHeader: 'identity',
        },
        // 接受 416（已下载字节已达全文大小），交由下面判断
        validateStatus: (s) => s != null && (s < 300 || s == 416),
      ),
      cancelToken: task.cancelToken,
    );
    final status = response.statusCode ?? 200;
    if (status == 416) return; // 文件已完整，无需再下
    int total;
    int written;
    FileMode mode;
    if (status == 206) {
      // Content-Range: bytes start-end/total
      final cr = response.headers.value('content-range') ?? '';
      final m = RegExp(r'/(\d+)$').firstMatch(cr);
      total = m != null ? int.parse(m.group(1)!) : 0;
      written = startByte;
      mode = FileMode.append;
    } else {
      // 服务端忽略 Range，返回完整内容 -> 从头重下
      total = int.tryParse(response.headers.value('content-length') ?? '') ?? 0;
      written = 0;
      mode = FileMode.write;
    }
    final raf = await file.open(mode: mode);
    try {
      final body = response.data as ResponseBody;
      await for (final chunk in body.stream) {
        await raf.writeFrom(chunk);
        written += chunk.length;
        if (total > 0) {
          final p = written / total;
          if ((p - task.progress).abs() >= 0.01 || p >= 1) {
            task.progress = p;
            _notifyProgress();
          }
        }
      }
    } finally {
      await raf.close();
    }
  }

  /// 下载最大重试次数（可恢复的网络中断按已下载字节续传）。
  static const int _kDownloadMaxRetries = 3;

  /// 带自动续传的下载：遇到可恢复的网络中断（断连/超时/5xx）按已下载字节
  /// 续传重试，最多 [_kDownloadMaxRetries] 次；不可恢复或耗尽则向上抛出，
  /// 交由 [_downloadOne] 的 DioException 分支给出可读错误。
  /// [myToken] 为本次下载的 CancelToken；重试延迟期间若被暂停后重试(resume)
  /// 接管（token 已替换）则静默退出，避免与新的下载并发写同一文件。
  Future<void> _downloadWithRetry(
    DownloadLink link,
    File file,
    int startByte,
    BookDownloadTask task,
    CancelToken? myToken,
  ) async {
    for (var attempt = 0; ; attempt++) {
      if (!identical(task.cancelToken, myToken)) return; // 已被接管
      try {
        // 首次用传入的 startByte；重试时从磁盘已下载字节接着下
        final sb = attempt == 0
            ? startByte
            : (await file.exists() ? await file.length() : 0);
        if (sb > 0) {
          if (attempt > 0) _log('续传重试 ${task.title}：从 $sb 字节继续');
          await _downloadWithResume(link, file, sb, task);
        } else {
          await _dio.download(
            link.url,
            file.path,
            options: Options(headers: link.headers),
            cancelToken: myToken,
            deleteOnError: false, // 保留中断分片，供续传
            onReceiveProgress: (r, total) {
              if (total > 0) {
                final p = r / total;
                if ((p - task.progress).abs() >= 0.01 || p >= 1) {
                  task.progress = p;
                  _notifyProgress();
                }
              }
            },
          );
        }
        return; // 下载成功
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow; // 取消交外层静默
        if (_isTransientDioError(e) && attempt < _kDownloadMaxRetries - 1) {
          final wait = Duration(seconds: (attempt + 1) * 2); // 2s, 4s
          _log(
            '传输中断(${_dioErrorBrief(e)})，${wait.inSeconds}s 后第${attempt + 2}次续传重试',
          );
          await Future.delayed(wait);
          continue;
        }
        rethrow; // 不可恢复或重试耗尽
      }
    }
  }

  /// 是否为可恢复的传输错误：断连/超时/unknown 一律可恢复；
  /// badResponse 仅 5xx 可恢复（4xx 多为链接失效/鉴权，不重试）。
  bool _isTransientDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
      case DioExceptionType.unknown:
        return true;
      case DioExceptionType.badResponse:
        final s = e.response?.statusCode ?? 0;
        return s >= 500 && s < 600;
      case DioExceptionType.sendTimeout:
      case DioExceptionType.badCertificate:
      case DioExceptionType.transformTimeout:
      case DioExceptionType.cancel:
        return false;
    }
  }

  /// DioException -> 用户可读文案（替代裸 'DioException [unknown]: null'）。
  ///
  /// ✅ **用词与分类对齐 `utils/source_fail_text.dart`** ✓（网络不通 / 被拒绝 / 接口失效 / 转换超时 ✓），
  ///   并且**每句都给出下一步动作** ✓（检查网络 ✓ 换源 ✓ 更新书源 ✓ 重试 ✓）——
  ///   这正是"能看操作失败的原因"要的效果 ✓。
  /// ⚠️ 本函数按 `DioException.type` 判 ✓，比字符串匹配**更准** ✓，所以**有意不改成调统一表** ✗✓；
  ///   与统一表保持一致的是**分类口径与用词** ✓，不是实现方式 ✓。
  String _dioErrorMsg(DioException e) {
    final msg = e.message;
    final detail = (msg != null && msg.isNotEmpty)
        ? msg
        : (e.error != null ? e.error.toString() : '');
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.connectionError:
        return '网络不通：连接失败，请检查网络/代理后重试';
      case DioExceptionType.sendTimeout:
        return '网络不通：发送请求超时，请重试';
      case DioExceptionType.receiveTimeout:
        return '网络不通：接收数据超时，请重试';
      case DioExceptionType.badResponse:
        final s = e.response?.statusCode;
        if (s == 401 || s == 403) {
          return '该源拒绝了访问（HTTP $s）：可能需要登录或补请求头，请换源';
        }
        if (s == 404) return '该源地址已失效（HTTP 404）：请更新书源';
        return s != null
            ? '该源服务器出错（HTTP $s）：请稍后重试或换源'
            : '该源返回异常响应：请稍后重试或换源';
      case DioExceptionType.badCertificate:
        return '证书校验失败：请检查代理设置后重试';
      case DioExceptionType.transformTimeout:
        // ⚠️ 原来这里写「**数据解析失败**」✗ —— 但 `transformTimeout` 是**转换超时** ✓，
        //   与"书源规则解析不出来"是**两回事** ✗✓（那样写会把人引去改规则 ✗，方向错 ✓）。已改准 ✓。
        return '数据转换超时（网络较慢或文件较大）：请重试，或换源';
      case DioExceptionType.cancel:
        return '已取消';
      case DioExceptionType.unknown:
        return detail.isNotEmpty ? '网络不通：$detail' : '网络连接中断，请重试';
    }
  }

  /// DioException 简短摘要（仅用于日志）。
  String _dioErrorBrief(DioException e) {
    final s = e.response?.statusCode;
    return s != null ? '${e.type.name}/$s' : e.type.name;
  }

  void _releaseQuota(BookDownloadTask task, ZlibraryService z) {
    if (!task.reserved) return;
    task.reserved = false;
    if (z.isLoggedIn) {
      z.releaseLoggedDownload();
    } else {
      z.releaseBuiltinDownload();
    }
  }

  /// 暂停：排队/下载中 -> 已暂停（停止在传下载，名额保留）
  void pauseTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null) return;
    if (t.status != BookDownloadStatus.queued &&
        t.status != BookDownloadStatus.downloading) {
      return;
    }
    t.cancelToken?.cancel();
    t.status = BookDownloadStatus.paused;
    _persist();
    notifyListeners();
  }

  /// 继续：已暂停 -> 排队（续传：保留进度，从已下载字节接着下）
  void resumeTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null || t.status != BookDownloadStatus.paused) return;
    t
      ..status = BookDownloadStatus.queued
      ..resumeMode = true
      ..cancelToken = null;
    notifyListeners();
    _schedule();
  }

  /// 重试：失败 -> 排队（失败时已释放名额，需重新预留；从头重下）
  void retryTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null || t.status != BookDownloadStatus.failed) return;
    if (!t.reserved) {
      final z = ZlibraryService();
      // 关闭内置账号且未登录：要求先登录
      if (!z.isLoggedIn && !SettingsService().useBuiltinAccount) {
        t.error = '请先登录账号';
        notifyListeners();
        return;
      }
      int? startIndex;
      bool reserved;
      if (z.isLoggedIn) {
        reserved = z.reserveLoggedDownload();
        startIndex = 0;
      } else {
        startIndex = z.reserveBuiltinDownload();
        reserved = startIndex != null;
      }
      if (!reserved) {
        t.error = '今日下载已达上限';
        notifyListeners();
        return;
      }
      t
        ..startIndex = startIndex ?? 0
        ..reserved = true;
    }
    t
      ..status = BookDownloadStatus.queued
      ..progress = 0
      ..error = null
      ..resumeMode = false
      ..cancelToken = null;
    notifyListeners();
    _schedule();
  }

  /// 取消（排队/下载中/暂停/失败）：释放名额 + 移除
  void cancelTask(String bookId) {
    final t = _tasks[bookId];
    if (t == null) return;
    t.cancelToken?.cancel();
    _releaseQuota(t, ZlibraryService());
    _tasks.remove(bookId);
    _persist();
    notifyListeners();
  }

  /// 删除已下载任务（删文件 + 记录，不释放名额）
  Future<void> deleteTask(String bookId) async {
    final t = _tasks[bookId];
    if (t == null) return;
    if (t.localPath != null) {
      try {
        final f = File(t.localPath!);
        if (await f.exists()) await f.delete();
      } catch (e) {
        _log('删除文件失败: $e');
      }
    }
    _tasks.remove(bookId);
    await _persist();
    notifyListeners();
  }

  /// 批量删除多本已下载任务（删文件 + 记录，一次持久化 + 一次通知）
  Future<void> deleteBooks(Iterable<String> bookIds) async {
    final set = bookIds.toSet();
    if (set.isEmpty) return;
    for (final bookId in set) {
      final t = _tasks[bookId];
      if (t == null) continue;
      if (t.localPath != null) {
        try {
          final f = File(t.localPath!);
          if (await f.exists()) await f.delete();
        } catch (e) {
          _log('删除文件失败: $e');
        }
      }
      _tasks.remove(bookId);
    }
    await _persist();
    notifyListeners();
  }

  /// 本地导入书移出书架后：若已不在任何书架，删文件+记录（清理孤儿）。
  /// 非导入书或仍在书架中则不动。
  Future<void> cleanupOrphanedImport(String bookId) async {
    final t = _tasks[bookId];
    if (t == null || !t.isLocalImport) return;
    if (BookshelfService()
        .getBookshelvesForItem(bookId, BookshelfItemType.book)
        .isNotEmpty) {
      return;
    }
    await deleteTask(bookId);
    _log('清理导入书孤儿: ${t.title}');
  }

  void pauseAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.queued ||
          t.status == BookDownloadStatus.downloading) {
        t.cancelToken?.cancel();
        t.status = BookDownloadStatus.paused;
        changed = true;
      }
    }
    if (changed) {
      _persist();
      notifyListeners();
    }
  }

  /// 全部继续：已暂停 -> 排队（续传：保留进度）
  void resumeAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.paused) {
        t
          ..status = BookDownloadStatus.queued
          ..resumeMode = true
          ..cancelToken = null;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedule();
    }
  }

  /// 全部开始：已暂停 -> 排队（从头重新下载，重置进度）
  void restartAll() {
    var changed = false;
    for (final t in _tasks.values) {
      if (t.status == BookDownloadStatus.paused) {
        t
          ..status = BookDownloadStatus.queued
          ..progress = 0
          ..resumeMode = false
          ..cancelToken = null;
        changed = true;
      }
    }
    if (changed) {
      notifyListeners();
      _schedule();
    }
  }

  void retryAll() {
    final failedKeys = _tasks.entries
        .where((e) => e.value.status == BookDownloadStatus.failed)
        .map((e) => e.key)
        .toList();
    for (final key in failedKeys) {
      retryTask(key);
    }
  }

  void cancelAll() {
    final keys = _tasks.entries
        .where((e) => e.value.status != BookDownloadStatus.completed)
        .map((e) => e.key)
        .toList();
    if (keys.isEmpty) return;
    for (final key in keys) {
      final t = _tasks[key]!;
      t.cancelToken?.cancel();
      _releaseQuota(t, ZlibraryService());
      _tasks.remove(key);
    }
    _persist();
    notifyListeners();
  }
}
