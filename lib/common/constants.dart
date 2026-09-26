/// 应用常量和配置键 - 对应 Swift HawkConfig

/// mpv 磁盘缓存根目录（main() 启动时异步预取, Player 创建同步读取）
String gMpvCacheDir = '';

class AppConstants {
  // 配置键
  static const String apiUrl = 'api_url';
  static const String homeApi = 'home_api';
  static const String searchHistory = 'search_history';
  static const String playType = 'play_type';
  static const String playTypeVod = 'play_type_vod';
  static const String dohUrl = 'doh_url';
  static const String playScale = 'play_scale';
  static const String playSpeed = 'play_speed';
  static const String disclaimerAccepted = 'disclaimer_accepted';

  // 默认值
  static const String defaultUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
}
