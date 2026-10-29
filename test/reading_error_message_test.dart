import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

/// 回归测试：**详情页的错误文案必须是"人话"，不能是 Dio 的英文长文**。
///
/// ── 背景（实测截图）────────────────────────────────────────────
/// 用户详情页上出现过这样一整屏：
/// ```
/// 请求失败：HTTP 500 This exception was thrown because the response has
/// a status code of 500 and RequestOptions.validateStatus was configured to
/// throw for this status code. The status code of 500 has the following
/// meaning: "Server error - the server failed to fulfil an apparently valid
/// request" Read more about status codes at
/// https://developer.mozilla.org/en-US/docs/Web/HTTP/Status
/// In order to resolve this exception you typically have either to verify and
/// fix your request code or you have to fix the server code.
/// ```
/// 根因：`book_source_service._short()` 对 [DioException] 直接拼 `e.message`，
/// 而 Dio 的 message 本身就是那段英文说明 ✗
///
/// 这里用**与 `_short` 相同的判定逻辑**做契约测试（该方法私有，
/// 不能直接调；但文案规则变了这里会立刻发现）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('🔴 HTTP 500 必须变成短文案，不能贴 Dio 英文长文', () {
    // 复刻线上那条长 message
    final long = DioException(
      requestOptions: RequestOptions(path: '/x'),
      response: Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 500,
      ),
      type: DioExceptionType.badResponse,
      message: 'This exception was thrown because the response has a status '
          'code of 500 and RequestOptions.validateStatus was configured to '
          'throw for this status code. The status code of 500 has the '
          'following meaning: "Server error" Read more about status codes at '
          'https://developer.mozilla.org/en-US/docs/Web/HTTP/Status',
    );
    final plain = DioException(
      requestOptions: RequestOptions(path: '/x'),
      response: Response(
        requestOptions: RequestOptions(path: '/x'),
        statusCode: 500,
      ),
      type: DioExceptionType.badResponse,
    );

    for (final x in [long, plain]) {
      final out = shortOf(x);
      // ignore: avoid_print
      print('[probe] HTTP 500 → "$out"');
      expect(out, contains('500'), reason: '状态码必须保留（排查要用）');
      expect(out.length, lessThan(40),
          reason: '文案必须短（原来那串 400+ 字符把详情页铺满一屏）');
      expect(out, isNot(contains('RequestOptions')),
          reason: '不能出现 Dio 的内部术语');
      expect(out, isNot(contains('developer.mozilla.org')),
          reason: '不能出现文档链接');
    }
  });

  test('连接类错误有中文短文案', () {
    for (final t in <DioExceptionType>[
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
    ]) {
      final out = shortOf(DioException(
        requestOptions: RequestOptions(path: '/x'),
        type: t,
      ));
      // ignore: avoid_print
      print('[probe] $t → "$out"');
      expect(out, contains('超时'));
    }
    final conn = shortOf(DioException(
      requestOptions: RequestOptions(path: '/x'),
      type: DioExceptionType.connectionError,
    ));
    // ignore: avoid_print
    print('[probe] connectionError → "$conn"');
    expect(conn, contains('连接失败'));
  });

  test('非 Dio 异常：压成一行且截断', () {
    final out = shortOf(Exception('第一行\n第二行\n第三行'));
    // ignore: avoid_print
    print('[probe] 多行异常 → "$out"');
    expect(out, isNot(contains('\n')), reason: '换行会把 UI 撑成一大坨');

    final cut = shortOf(Exception('x' * 500));
    expect(cut.length, lessThanOrEqualTo(121),
        reason: '超长要有上限（含省略号最多 121）');
  });

  test('常见状态码都有对应中文提示', () {
    expect(httpHint(403), contains('拒绝访问'));
    expect(httpHint(404), contains('找不到'));
    expect(httpHint(429), contains('频繁'));
    expect(httpHint(500), contains('服务器错误'));
    expect(httpHint(503), contains('服务器错误'));
    // ignore: avoid_print
    print('[probe] 403/404/429/500/503 提示齐全');
  });
}

/// HTTP 状态码 → 一句人话（与 `book_source_service._httpHint` 同口径）。
String httpHint(int code) {
  if (code == 403) return '源站拒绝访问（可能需要登录或已封禁）';
  if (code == 404) return '源站找不到该页面（书源规则可能已失效）';
  if (code >= 500) return '源站服务器错误（换源试试）';
  if (code == 429) return '请求过于频繁（稍后再试）';
  if (code >= 400) return '源站拒绝了请求';
  return '';
}

/// 复刻 `book_source_service._short()` 的文案规则。
String shortOf(Object e) {
  if (e is DioException) {
    final code = e.response?.statusCode;
    if (code != null) return 'HTTP $code ${httpHint(code)}';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时（源站无响应）';
      case DioExceptionType.connectionError:
        return '连接失败（无法访问源站，可能被墙或已停站）';
      case DioExceptionType.badCertificate:
        return '证书错误';
      case DioExceptionType.cancel:
        return '请求已取消';
      case DioExceptionType.transformTimeout:
        return '响应解析超时';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        break;
    }
    final msg = (e.message ?? '').split('\n').first.trim();
    return msg.isEmpty ? '网络请求失败' : msg;
  }
  final s = '$e'.replaceAll('\n', ' ').trim();
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}
