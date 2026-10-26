import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// WebDAV + Kindle 推送 配置。
class SyncConfig {
  const SyncConfig({
    this.webdavUrl = '',
    this.webdavUser = '',
    this.webdavPass = '',
    this.webdavPath = 'NewTv/bookshelf_backup.json',
    this.smtpHost = '',
    this.smtpPort = 465,
    this.smtpUser = '',
    this.smtpPass = '',
    this.kindleEmail = '',
    this.useStartTls = false,
  });

  final String webdavUrl;
  final String webdavUser;
  final String webdavPass;
  final String webdavPath;
  final String smtpHost;
  final int smtpPort;
  final String smtpUser;
  final String smtpPass;
  final String kindleEmail;
  final bool useStartTls;

  bool get webdavReady =>
      webdavUrl.trim().isNotEmpty && webdavUser.trim().isNotEmpty;
  bool get smtpReady =>
      smtpHost.trim().isNotEmpty &&
      smtpUser.trim().isNotEmpty &&
      smtpPass.isNotEmpty &&
      kindleEmail.trim().isNotEmpty;

  SyncConfig copyWith({
    String? webdavUrl,
    String? webdavUser,
    String? webdavPass,
    String? webdavPath,
    String? smtpHost,
    int? smtpPort,
    String? smtpUser,
    String? smtpPass,
    String? kindleEmail,
    bool? useStartTls,
  }) =>
      SyncConfig(
        webdavUrl: webdavUrl ?? this.webdavUrl,
        webdavUser: webdavUser ?? this.webdavUser,
        webdavPass: webdavPass ?? this.webdavPass,
        webdavPath: webdavPath ?? this.webdavPath,
        smtpHost: smtpHost ?? this.smtpHost,
        smtpPort: smtpPort ?? this.smtpPort,
        smtpUser: smtpUser ?? this.smtpUser,
        smtpPass: smtpPass ?? this.smtpPass,
        kindleEmail: kindleEmail ?? this.kindleEmail,
        useStartTls: useStartTls ?? this.useStartTls,
      );

  Map<String, dynamic> toJson() => {
        'webdavUrl': webdavUrl,
        'webdavUser': webdavUser,
        'webdavPass': webdavPass,
        'webdavPath': webdavPath,
        'smtpHost': smtpHost,
        'smtpPort': smtpPort,
        'smtpUser': smtpUser,
        'smtpPass': smtpPass,
        'kindleEmail': kindleEmail,
        'useStartTls': useStartTls,
      };

  static SyncConfig fromJson(Map<String, dynamic> j) => SyncConfig(
        webdavUrl: (j['webdavUrl'] ?? '').toString(),
        webdavUser: (j['webdavUser'] ?? '').toString(),
        webdavPass: (j['webdavPass'] ?? '').toString(),
        webdavPath: (j['webdavPath'] ?? 'NewTv/bookshelf_backup.json').toString(),
        smtpHost: (j['smtpHost'] ?? '').toString(),
        smtpPort: (j['smtpPort'] as num?)?.toInt() ?? 465,
        smtpUser: (j['smtpUser'] ?? '').toString(),
        smtpPass: (j['smtpPass'] ?? '').toString(),
        kindleEmail: (j['kindleEmail'] ?? '').toString(),
        useStartTls: j['useStartTls'] == true,
      );
}

/// 备份/推送 统一入口。
///
/// WebDAV：把书架导出 JSON PUT 到网盘指定路径，GET 拉回恢复。
/// Kindle：纯 Dart SMTP（dart:io 原生 socket，不依赖第三方包），
/// 通过邮箱把图书文件作为附件推送到 Kindle 邮箱。
class SyncService {
  SyncService._();
  static final SyncService instance = SyncService._();

  static const _key = 'sync_config_v1';

  SyncConfig config = const SyncConfig();

  void _log(String msg) => debugPrint('[Sync] $msg');

  Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key);
      if (raw == null || raw.isEmpty) return;
      final j = jsonDecode(raw);
      if (j is Map) config = SyncConfig.fromJson(j.cast<String, dynamic>());
    } catch (e) {
      _log('配置加载失败: $e');
    }
  }

  Future<void> save(SyncConfig c) async {
    config = c;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, jsonEncode(c.toJson()));
    } catch (e) {
      _log('配置保存失败: $e');
    }
  }

  // ── WebDAV ──────────────────────────────────────────────────

  /// ✅ **WebDAV 同步也走「网络代理」**（本轮接上 ✓）—— 这处**一改覆盖两条路** ✓✓：
  ///   下面的 `put`（**立即备份** ✓）与 `get`（**从云端恢复** ✓）**都用这个 getter** ✓
  ///   ⇒ 所以只改这里，备份与恢复**同时**受代理开关控制 ✓✓（性价比最高的一处 ✓）。
  /// 手法 ✓：原来是**表达式体** `=> Dio(...)` ✗（没法"先构造再调用"✓）→ 改成**块体** ✓，
  ///   与 `zlibrary_service._createDio()` / `download_service._createImageDio()` 同款 ✓ 不发明机制 ✗。
  /// ℹ️ 安全依据 ✓（**已读源码确认** ✓）：本处**无自定义适配器** ✗✓，只有超时 + 鉴权头 ✓
  ///   （`Authorization` 在 **Dio 选项层** ✓，与 socket 层适配器互不干扰 ✓ 不会丢 ✓）。
  /// · 代理**关闭** ✓ → 返回 false ✓ **一字不改** ✓（与从前完全一致 ✓✓）
  Dio _dio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        headers: {
          'Authorization':
              'Basic ${base64Encode(utf8.encode('${config.webdavUser}:${config.webdavPass}'))}',
        },
      ),
    );
    applyGlobalProxy(dio);
    return dio;
  }

  String get _webdavFullUrl {
    var base = config.webdavUrl.trim();
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    final path = config.webdavPath.trim().replaceAll(RegExp(r'^/+'), '');
    return '$base/$path';
  }

  /// 备份：把书架全量 JSON PUT 到 WebDAV。
  Future<({bool ok, String? error})> backupBookshelf(String json) async {
    if (!config.webdavReady) {
      return (ok: false, error: '请先在设置里填写 WebDAV 服务器与账号');
    }
    final dio = _dio();
    try {
      final resp = await dio.put(
        _webdavFullUrl,
        data: json,
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      if (resp.statusCode! >= 200 && resp.statusCode! < 300) {
        return (ok: true, error: null);
      }
      return (ok: false, error: 'HTTP ${resp.statusCode}');
    } catch (e) {
      return (ok: false, error: _short(e));
    } finally {
      // `_dio()` 每次新建实例（其中含独立的 HttpClient 连接池），
      // 用完必须关闭，否则反复「备份/恢复」会持续泄漏连接池。
      dio.close(force: true);
    }
  }

  /// 恢复：从 WebDAV 拉回书架 JSON。
  Future<({bool ok, String? error, String? json})> restoreBookshelf() async {
    if (!config.webdavReady) {
      return (ok: false, error: '请先在设置里填写 WebDAV 服务器与账号', json: null);
    }
    final dio = _dio();
    try {
      final resp = await dio.get(_webdavFullUrl);
      if (resp.statusCode == 200) {
        return (ok: true, error: null, json: resp.data?.toString());
      }
      return (
        ok: false,
        error: 'HTTP ${resp.statusCode}',
        json: null,
      );
    } catch (e) {
      return (ok: false, error: _short(e), json: null);
    } finally {
      dio.close(force: true);
    }
  }

  String _short(Object e) {
    if (e is DioException) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        return '网络超时';
      }
      if (e.type == DioExceptionType.connectionError) {
        return '无法连接服务器（地址/网络）';
      }
      return e.message ?? e.toString();
    }
    return e.toString();
  }

  // ── Kindle 推送（SMTP）──────────────────────────────────────

  /// 推送本地图书文件到 Kindle 邮箱。
  ///
  /// [fileName]/[fileBytes]：附件内容（epub/txt/mobi 等）。
  /// [title]：邮件标题里的书名。
  Future<({bool ok, String? error})> pushToKindle({
    required String fileName,
    required List<int> fileBytes,
    required String title,
  }) async {
    if (!config.smtpReady) {
      return (ok: false, error: '请先配置发件邮箱与 Kindle 收件邮箱');
    }
    if (fileBytes.isEmpty) {
      return (ok: false, error: '文件为空，无法推送');
    }
    try {
      final socket = await _connectSmtp();
      if (socket == null) {
        return (ok: false, error: '无法连接 SMTP 服务器');
      }
      final result = await _smtpSend(
        socket,
        from: config.smtpUser,
        to: config.kindleEmail,
        subject: title,
        fileName: fileName,
        fileBytes: fileBytes,
      );
      return result;
    } catch (e) {
      return (ok: false, error: e.toString());
    }
  }

  Future<Socket?> _connectSmtp() async {
    final host = config.smtpHost.trim();
    final port = config.smtpPort;
    if (config.useStartTls) {
      // 587 STARTTLS：先明文连接，再升级 TLS
      final plain = await Socket.connect(host, port,
          timeout: const Duration(seconds: 15));
      plain.timeout(const Duration(seconds: 20));
      return plain;
    }
    // 465 SSL：直接加密连接
    final secure = await SecureSocket.connect(host, port,
        timeout: const Duration(seconds: 15));
    secure.timeout(const Duration(seconds: 20));
    return secure;
  }

  /// SMTP 会话：读欢迎 → EHLO → STARTTLS(如需要) → AUTH LOGIN →
  /// MAIL/RCPT/DATA → 发送 MIME multipart → QUIT。
  ///
  /// ⚠️ 2026-10-15 重写：原实现对**同一个 socket** `listen` 两次
  ///   （本方法里一次、`_smtpAuthAndSend` 里又一次），并且对**单订阅**的
  ///   `ctrl.stream` 在每一次 `expectCode` 里 `await for` 一次 —— 单订阅流
  ///   第二次监听必抛 `Bad state: Stream has already been listened to`，
  ///   于是 Kindle 推送**必然失败**（异常被 `pushToKindle` 的 catch 吞成
  ///   `(ok:false)`，界面上只显示"推送失败"，看不出原因）。
  ///   现在改为一个**单订阅的读行器** [_SmtpReader]：全程只监听一次，
  ///   可被反复 `readReply` 消费（并且能正确识别 `250-xxx` 多行响应）。
  Future<({bool ok, String? error})> _smtpSend(
    Socket socket, {
    required String from,
    required String to,
    required String subject,
    required String fileName,
    required List<int> fileBytes,
  }) async {
    var active = socket;
    var reader = _SmtpReader(socket);
    void send(String line) => active.write('$line\r\n');

    Future<bool> expect(List<int> codes) async {
      final line = await reader.readReply();
      return codes.contains(reader.codeOf(line));
    }

    try {
      // 1) 欢迎
      if (!await expect([220])) {
        return (ok: false, error: 'SMTP 欢迎失败: ${reader.lastLine}');
      }
      // 2) EHLO
      send('EHLO newtv');
      if (!await expect([250])) {
        return (ok: false, error: 'EHLO 失败: ${reader.lastLine}');
      }
      // 3) STARTTLS（587 模式；升级后要重新 EHLO）
      if (config.useStartTls) {
        send('STARTTLS');
        if (!await expect([220])) {
          return (ok: false, error: 'STARTTLS 失败: ${reader.lastLine}');
        }
        await active.flush();
        // 升级前必须先退订旧 socket：否则老订阅还挂在同一个 fd 上
        await reader.dispose();
        active = await SecureSocket.secure(socket,
            host: config.smtpHost.trim(), onBadCertificate: (_) => false);
        reader = _SmtpReader(active);
        active.write('EHLO newtv\r\n');
        await active.flush();
        if (!await expect([250])) {
          return (ok: false, error: 'TLS 后 EHLO 失败: ${reader.lastLine}');
        }
      }
      return await _smtpAuthAndSend(
        reader,
        active,
        from: from,
        to: to,
        subject: subject,
        fileName: fileName,
        fileBytes: fileBytes,
      );
    } catch (e) {
      return (ok: false, error: e.toString());
    } finally {
      await reader.dispose();
      try {
        active.destroy();
      } catch (_) {}
    }
  }

  Future<({bool ok, String? error})> _smtpAuthAndSend(
    _SmtpReader reader,
    Socket socket, {
    required String from,
    required String to,
    required String subject,
    required String fileName,
    required List<int> fileBytes,
  }) async {
    void send(String line) => socket.write('$line\r\n');

    Future<bool> expect(List<int> codes) async {
      final line = await reader.readReply();
      return codes.contains(reader.codeOf(line));
    }

    // AUTH LOGIN
    send('AUTH LOGIN');
    if (!await expect([334])) {
      return (ok: false, error: 'AUTH 失败: ${reader.lastLine}');
    }
    send(base64Encode(utf8.encode(config.smtpUser)));
    if (!await expect([334])) {
      return (ok: false, error: '账号被拒: ${reader.lastLine}');
    }
    send(base64Encode(utf8.encode(config.smtpPass)));
    if (!await expect([235])) {
      return (ok: false, error: '密码被拒: ${reader.lastLine}');
    }
    // MAIL / RCPT
    send('MAIL FROM:<$from>');
    if (!await expect([250])) {
      return (ok: false, error: 'MAIL FROM 失败: ${reader.lastLine}');
    }
    send('RCPT TO:<$to>');
    if (!await expect([250, 251])) {
      return (ok: false, error: 'RCPT TO 失败: ${reader.lastLine}');
    }
    // DATA（MIME multipart，附件 base64）
    final boundary = '----newtv${DateTime.now().millisecondsSinceEpoch}';
    final header = StringBuffer()
      ..writeln('From: $from')
      ..writeln('To: $to')
      ..writeln('Subject: =?UTF-8?B?${base64Encode(utf8.encode(subject))}?=')
      ..writeln('MIME-Version: 1.0')
      ..writeln('Content-Type: multipart/mixed; boundary="$boundary"')
      ..writeln('');
    final body = StringBuffer()
      ..writeln('--$boundary')
      ..writeln('Content-Type: text/plain; charset=UTF-8')
      ..writeln('Content-Transfer-Encoding: 8bit')
      ..writeln('')
      ..writeln('从阅读模块推送的图书：$subject')
      ..writeln('')
      ..writeln('--$boundary')
      ..writeln('Content-Type: application/octet-stream; name="$fileName"')
      ..writeln('Content-Transfer-Encoding: base64')
      ..writeln('Content-Disposition: attachment; filename="$fileName"')
      ..writeln('')
      ..write(base64Encode(fileBytes))
      ..writeln('')
      ..writeln('--$boundary--');

    send('DATA');
    if (!await expect([354])) {
      return (ok: false, error: 'DATA 失败: ${reader.lastLine}');
    }
    socket.write(header.toString());
    socket.write(body.toString());
    // 结束符必须**独占一行**（base64 字母表不含 '.'，无需 dot-stuffing）
    socket.write('.\r\n');
    await socket.flush();
    if (!await expect([250])) {
      return (ok: false, error: '发送失败: ${reader.lastLine}');
    }
    send('QUIT');
    return (ok: true, error: null);
  }
}

/// SMTP 响应的**单订阅读行器**。
///
/// 只对 socket `listen` 一次，把字节流按 `\n` 切成完整行放进队列；
/// 调用方可以反复 [readReply] 逐条消费，并支持 `250-xxx` 多行响应。
///
/// ⚠️ 存在的意义：`Socket` / `SecureSocket` 都是**单订阅流**，
///   原来"每次 `expectCode` 都 `await for (ctrl.stream)`"的写法在第二次
///   调用时必抛 StateError —— 这是 Kindle 推送长期 100% 失败的根因。
class _SmtpReader {
  _SmtpReader(this._socket) {
    _sub = _socket.listen(_onData, onError: (Object _) {}, cancelOnError: false);
  }

  final Socket _socket;
  late final StreamSubscription<List<int>> _sub;

  final List<String> _lines = [];
  final List<Completer<String?>> _waiters = [];
  final StringBuffer _buffer = StringBuffer();

  /// 最近一条完整响应行（拼错误文案用）
  String? lastLine;

  bool _disposed = false;

  void _onData(List<int> data) {
    _buffer.write(utf8.decode(data, allowMalformed: true));
    var text = _buffer.toString();
    var idx = text.indexOf('\n');
    while (idx >= 0) {
      var line = text.substring(0, idx);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      text = text.substring(idx + 1);
      if (_waiters.isNotEmpty) {
        final c = _waiters.removeAt(0);
        if (!c.isCompleted) c.complete(line);
      } else {
        _lines.add(line);
      }
      idx = text.indexOf('\n');
    }
    _buffer
      ..clear()
      ..write(text);
  }

  Future<String?> _nextLine(Duration timeout) {
    if (_lines.isNotEmpty) return Future.value(_lines.removeAt(0));
    if (_disposed) return Future.value(null);
    final c = Completer<String?>();
    _waiters.add(c);
    return c.future.timeout(timeout, onTimeout: () {
      _waiters.remove(c);
      return null;
    });
  }

  /// 读一条完整 SMTP 响应（`250-xxx` 多行会读到 `250 xxx` 为止）；
  /// 超时或连接断开返回 null。
  Future<String?> readReply(
      {Duration timeout = const Duration(seconds: 20)}) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remain = deadline.difference(DateTime.now());
      if (remain.isNegative) return null;
      final line = await _nextLine(remain);
      if (line == null) return null;
      lastLine = line;
      // 第 4 个字符是 '-' → 这条响应还有后续行
      if (line.length >= 4 && line[3] == '-') continue;
      return line;
    }
  }

  /// 取响应码；解析不出返回 -1
  int codeOf(String? line) {
    if (line == null || line.length < 3) return -1;
    return int.tryParse(line.substring(0, 3)) ?? -1;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final c in _waiters) {
      if (!c.isCompleted) c.complete(null);
    }
    _waiters.clear();
    try {
      await _sub.cancel();
    } catch (_) {}
  }
}
