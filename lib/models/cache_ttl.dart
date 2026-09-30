/// 缓存有效期（TTL）集中管理
///
/// 原来 6 个 `const Duration(...)` 散落在 4 个文件里，想统一调一次策略要翻遍
/// 代码。这里按「数据多久会变」归类，改策略只动这一个文件。
///
/// ⚠️ TTL 只决定「用户什么都不做时，数据能旧多久」——用户手动下拉刷新
/// （`refresh()`）会无视 TTL 直接联网。所以 TTL 应按数据变化速度配，
/// 而不是按「希望它多新」配，否则只会白白多打网络请求。
class CacheTtl {
  const CacheTtl._();

  /// 首页轮播（`home_videos:<源>`）：新片上线就会变，是首页最显眼的内容。
  /// 每个源只有 1 条，联网成本低，保持较快刷新。
  static const Duration homeVideos = Duration(hours: 12);

  /// 首页分类列表（`cat_videos:<源>:<分类>:<筛选>`）：条目多、占磁盘大头，
  /// 但体积由 CacheStore 的条目上限控制，与 TTL 无关。12h ≈ 一天刷两次。
  static const Duration categoryList = Duration(hours: 12);

  /// TMDB 刮削（`tmdb:<片名>_<年份>`）：评分/演员/类似作品几乎恒定，
  /// 而每次刮削要 3~5 次请求，是**最贵**的一类缓存 → 给最长 TTL。
  static const Duration tmdb = Duration(days: 60);

  /// HLS 清晰度档位（`quality:<md5(剧集URL)>`）：编码时就定死了，几乎永不改变，
  /// 且 key 按剧集 URL（一部剧只有几条）→ 无需频繁重取 master.m3u8。
  static const Duration quality = Duration(days: 30);

  /// 兜底默认值（`getJsonCache` / `getJsonListCache` 未显式传 ttl 时）
  static const Duration fallback = Duration(hours: 6);
}
