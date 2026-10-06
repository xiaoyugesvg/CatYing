/// 书源抓取中判定「需要浏览器验证」（Cloudflare 挑战 / 站点自建验证）时抛出，
/// 上层据此提示用户或切换处理方式，而不是把验证壳当正常内容解析。
class VerificationRequiredException implements Exception {
  final String url;
  final String body;
  final int? statusCode;

  const VerificationRequiredException({
    required this.url,
    this.body = '',
    this.statusCode,
  });

  @override
  String toString() =>
      'VerificationRequiredException(url: $url, statusCode: $statusCode)';
}
