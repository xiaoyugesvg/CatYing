import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import '../source/global_proxy.dart';
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
    try {
      final resp = await _dio().put(
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
    }
  }

  /// 恢复：从 WebDAV 拉回书架 JSON。
  Future<({bool ok, String? error, String? json})> restoreBookshelf() async {
    if (!config.webdavReady) {
      return (ok: false, error: '请先在设置里填写 WebDAV 服务器与账号', json: null);
    }
    try {
      final resp = await _dio().get(_webdavFullUrl);
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
  Future<({bool ok, String? error})> _smtpSend(
    Socket socket, {
    required String from,
    required String to,
    required String subject,
    required String fileName,
    required List<int> fileBytes,
  }) async {
    final ctrl = StreamController<String>();
    socket.listen(
      (data) => ctrl.add(utf8.decode(data, allowMalformed: true)),
      onError: (_) {},
    );

    String? lastLine;
    Future<bool> expectCode(List<int> codes, String what) async {
      final buffer = StringBuffer();
      await for (final chunk in ctrl.stream) {
        buffer.write(chunk);
        final text = buffer.toString();
        if (text.contains('\n')) {
          lastLine = text.trim();
          final code = int.tryParse(text.trim().substring(0, 3)) ?? -1;
          if (codes.contains(code)) return true;
          if (code >= 500 || text.trim().length > 4) return false;
        }
      }
      return false;
    }

    void send(String line) => socket.write('$line\r\n');

    // 1) 欢迎
    if (!await expectCode([220], '欢迎')) {
      return (ok: false, error: 'SMTP 欢迎失败: $lastLine');
    }
    // 2) EHLO
    send('EHLO doubao');
    if (!await expectCode([250], 'EHLO')) {
      return (ok: false, error: 'EHLO 失败: $lastLine');
    }
    // 3) STARTTLS（587 模式；需在 TLS 前把 EHLO 再发一遍）
    if (config.useStartTls) {
      send('STARTTLS');
      if (!await expectCode([220], 'STARTTLS')) {
        return (ok: false, error: 'STARTTLS 失败: $lastLine');
      }
      await socket.flush();
      final upgraded = await SecureSocket.secure(socket,
          host: config.smtpHost.trim(), onBadCertificate: (_) => false);
      // 升级后重新监听 + 重发 EHLO
      final ctrl2 = StreamController<String>();
      upgraded.listen(
        (data) => ctrl2.add(utf8.decode(data, allowMalformed: true)),
        onError: (_) {},
      );
      upgraded.write('EHLO doubao\r\n');
      await upgraded.flush();
      final buf = StringBuffer();
      var ehloOk = false;
      await for (final chunk in ctrl2.stream) {
        buf.write(chunk);
        if (buf.toString().contains('\n')) {
          final code = int.tryParse(buf.toString().trim().substring(0, 3)) ?? -1;
          if (code == 250) {
            ehloOk = true;
            break;
          }
          if (code >= 500) break;
        }
      }
      if (!ehloOk) return (ok: false, error: 'TLS 后 EHLO 失败');
      return _smtpAuthAndSend(upgraded, from, to, subject, fileName, fileBytes);
    }
    return _smtpAuthAndSend(socket, from, to, subject, fileName, fileBytes);
  }

  Future<({bool ok, String? error})> _smtpAuthAndSend(
    Socket socket,
    String from,
    String to,
    String subject,
    String fileName,
    List<int> fileBytes,
  ) async {
    final ctrl = StreamController<String>();
    socket.listen(
      (data) => ctrl.add(utf8.decode(data, allowMalformed: true)),
      onError: (_) {},
    );

    String? lastLine;
    Future<bool> expectCode(List<int> codes) async {
      final buffer = StringBuffer();
      await for (final chunk in ctrl.stream) {
        buffer.write(chunk);
        final text = buffer.toString();
        if (text.contains('\n')) {
          lastLine = text.trim();
          final code = int.tryParse(text.trim().substring(0, 3)) ?? -1;
          if (codes.contains(code)) return true;
          if (code >= 500) return false;
        }
      }
      return false;
    }

    void send(String line) => socket.write('$line\r\n');

    // AUTH LOGIN
    send('AUTH LOGIN');
    if (!await expectCode([334])) return (ok: false, error: 'AUTH 失败: $lastLine');
    send(base64Encode(utf8.encode(config.smtpUser)));
    if (!await expectCode([334])) return (ok: false, error: '账号被拒: $lastLine');
    send(base64Encode(utf8.encode(config.smtpPass)));
    if (!await expectCode([235])) {
      return (ok: false, error: '密码被拒: $lastLine');
    }
    // MAIL / RCPT
    send('MAIL FROM:<${config.smtpUser}>');
    if (!await expectCode([250])) return (ok: false, error: 'MAIL FROM 失败: $lastLine');
    send('RCPT TO:<${config.kindleEmail}>');
    if (!await expectCode([250, 251])) {
      return (ok: false, error: 'RCPT TO 失败: $lastLine');
    }
    // DATA（MIME multipart，附件 base64）
    final boundary = '----dbtv${DateTime.now().millisecondsSinceEpoch}';
    final header = StringBuffer()
      ..writeln('From: ${config.smtpUser}')
      ..writeln('To: ${config.kindleEmail}')
      ..writeln('Subject: =?UTF-8?B?${base64Encode(utf8.encode(subject))}?=')
      ..writeln('MIME-Version: 1.0')
      ..writeln('Content-Type: multipart/mixed; boundary="$boundary"')
      ..writeln('');
    final body = StringBuffer()
      ..writeln('--$boundary')
      ..writeln('Content-Type: text/plain; charset=UTF-8')
      ..writeln('Content-Transfer-Encoding: 8bit')
      ..writeln('')
      ..writeln('从 Doubao 阅读推送的图书：$subject')
      ..writeln('')
      ..writeln('--$boundary')
      ..writeln('Content-Type: application/octet-stream; name="$fileName"')
      ..writeln('Content-Transfer-Encoding: base64')
      ..writeln('Content-Disposition: attachment; filename="$fileName"')
      ..writeln('')
      ..write(base64Encode(fileBytes))
      ..writeln('')
      ..writeln('--$boundary--')
      ..writeln('.');

    send('DATA');
    if (!await expectCode([354])) return (ok: false, error: 'DATA 失败: $lastLine');
    socket.write(header.toString());
    socket.write(body.toString());
    await socket.flush();
    if (!await expectCode([250])) {
      return (ok: false, error: '发送失败: $lastLine');
    }
    send('QUIT');
    try {
      socket.destroy();
    } catch (_) {}
    return (ok: true, error: null);
  }
}
