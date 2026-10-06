// 配置驱动的漫画站点模型（对齐桌面端 comic_website 表字段 + app 搜索扩展）。
//
// 桌面端 default_sites（common/sqlite_util.py）定义 14 站取图配置，app 端迁移其中 11 站
// （排除「拷贝漫画 copy3000」-- CopyMangaSource 走 API；「咚漫」-- PC 章节不全；
//  「再漫画」-- API 驱动 SPA，由 ZaimanhuaSource 接管）。
// 桌面端无搜索字段，searchUrl 等为 app 新增，2b 逐站补。
//
// 内置站点数据已迁至 assets/config/sources.json（出厂默认）+ 文档目录 sources.json
// （远端更新覆盖层），代码侧只保留本模型（字段/fromJson/toJson），不再硬编码站点。

import '../utils/safe_num.dart';
import 'models.dart';

/// 单个漫画站点配置
class SiteConfig {
  final String name;
  final String? icon;
  final String url;

  // 详情页 DOM 选择器
  final String comicCoverDom;
  final String comicNameDom;
  final String comicAuthorDom;
  final String comicDescDom; // 简介（meta[property=...] 取 content，或普通元素取 text）
  // 🔴 **新增 3 个字段**（批次 3 补 ✓）—— 这 3 个键**内置源的 JSON 里本来就有** ✓：
  //   `comic_status_dom`（12 个源 ✓）· `comic_tags_dom`（12 个 ✓）· `comic_hot_dom`（3 个 ✓），
  //   但**模型里一直没有对应字段** ✗ → 引擎根本读不到 ✓ →
  //   **12 个内置源的状态/标签/热度恒为空** ✗（漫画源编辑页却能填它们 ✓ = 假开关 ✓）。
  //   ⚠️ 本轮只加"字段 + 构造参数"✓（**不改变任何行为** ✓，零回归 ✓）；
  //   下一步补 `fromJson` / `toJson`（否则导出会丢 ✓ —— 同今天 categories 那个坑 ✗）
  //   与 `config_manga_source` 的详情解析填值 ✓。
  final String comicStatusDom;
  final String comicTagsDom;
  final String comicHotDom;

  // ── ⚠️ 已知缺口：`img_decode_script` **本引擎不支持**（今天核实 ✓，未擅改 ✗）──
  //   本模型只认 `img_decode_regex` / `img_decode_key` / `img_decode_data_field` 三键 ✓，
  //   而 `assets/config/sources.json` 里有 **2 个源**用的是 `img_decode_script` ✗：
  //   · **追更漫画**（约 `:2831` ✓）：**只有** `img_decode_script`
  //     （内嵌一大段**纯 JS AES-128-CBC 解密器** ✓），**没有 `img_dom` / `img_script`**
  //     ✗ → **取图完全无路径** ✗✗ → 章节空白 ✓（这一条确实会空 ✓）。
  //   · **热辣漫画**（约 `:3161` ✓）：脚本用的是 Legado 专有
  //     `java.createSymmetricCrypto(...)` ✗（本引擎没有此 API ✓），但它
  //     **另有 `img_dom`**（`:3162` ✓）→ **有取图路径** ✓，只是拿到的可能是
  //     未解密的地址 ✓ → **不会全空** ✗（⚠️ 别把这两条当成同一个问题 ✗✓）。
  //   三种处置（**都需要产品决策** ✓，我未擅自选 ✗）：
  //     ① 给追更漫画**补 `img_dom`/`img_script`**（需逆向该站 ✓）
  //     ② 引擎**支持 `img_decode_script`**（需 JS 沙箱 + 加密库 ✗，大工程 ✓）
  //     ③ 把这 2 个源在列表中**标注"取图不可用"** ✓（诚实的降级 ✓）
  //   ⚠️ **但"改写做不到"这个说法我收回** ✗ —— 因为本模型**自己的文档**
  //     （见下面 `img_decode_regex/key/data_field` 那三行的注释 ✓，约 `:100-105` ✓）
  //     就把「**章节页 HTML 内嵌密文解密取图**」列为这条路径的用途 ✓，
  //     而且**举的例子正是「追更漫画」** ✓✓、连 AES 密钥都写出来了 ✓
  //     → 所以**很可能**把追更漫画改成 `img_decode_regex/key/data_field` 就能通 ✓，
  //       它的 `img_decode_script` 或许只是**同一件事的另一种（未被支持的）写法** ✓。
  //     ❗ 定论前必须先读那段脚本里的 **key / IV 推导方式** ✗（脚本约 2KB ✓，
  //        需确认它是"固定 key + 固定 IV"✓ 还是"随响应变化"✗ —— 后者才真的表达不了 ✓）。

  // 章节列表 DOM 选择器
  final String chapterNameDom;
  final String chapterLinkDom;
  // 章节链接 href 必须包含的片段（空=不过滤；如 mycomic 用 /cn/chapters/ 排除推荐等非章节链接）
  final String chapterUrlPattern;
  // 章节兜底链接选择器（单行本场景：无章节列表，只有「开始阅读」按钮时取其 href 作为唯一章节）
  final String chapterFallbackLinkDom;
  // 章节分页（PC 网页分页，空=不分页）
  final String chapterPagedUrl; // 模板 {base}&page={page}（{base}=基础URL，{page}=页码）
  final String
  chapterPagedBaseDom; // 基础URL选择器（如 meta[property="og:url"] 取 content）；空=用详情页URL
  final String chapterPageCountDom; // 总页数容器选择器（取内最大数字）；空=不分页

  // 取图配置
  final String imgDom;
  final int useFrame; // 0=直连(Dio+html) 1=iframe(WebView 注入)
  final String imgAttr; // 图片属性名（空=src）
  final String imgScript; // 取图 JS 片段（iframe 模式，桌面端用 ifr.contentWindow）
  final String
  chapterScript; // 章节列表 JS（详情页 WebView 内执行返回 {apiUrl,linkBase}；空=Dio 解析 chapterLinkDom）
  final String
  chapterJsonScript; // 章节 JSON 解析 JS（注入 json+linkBase 执行返回 [{name,url}]；配合 chapterScript 的 apiUrl）

  // JSON 章节 API 直连模式（声明式，无需 WebView；如热辣漫画 /api/v3/comic/.../chapters）：
  //   详情 URL 经 chapterUrlIdRegex 提取捕获组 -> 替换 chapterApiUrl 模板里
  //   非 {offset}/{page} 的占位（按出现顺序）-> Dio GET/POST -> 响应 JSON 按
  //   chapterListField 点路径取列表 -> chapterJsonFields 映射 name/url。
  //   模板含 {offset} 时按 chapterPageSize 翻页，直到结果数 < pageSize 或无新增。
  final String chapterApiUrl; // JSON 章节接口 URL 模板（{offset} 分页占位 + 捕获组占位）
  final String chapterUrlIdRegex; // 从详情 URL 提取捕获组的正则（组1..N 按序替换模板占位）
  final String chapterListField; // 结果列表点路径（如 results.list；空=响应本身是数组）
  final Map<String, String>? chapterJsonFields; // 章节字段映射：name/url（值=字段名/点路径/Field[0]/{Field} 模板）
  final int chapterPageSize; // 满页判定（>0 时结果数满页即有下一页）
  final String chapterApiMethod; // 请求方法（空/GET=GET，POST=POST JSON）
  /// ✅ **搜索请求方法**（本轮新增 ✓，兼容用 POST 搜索的 Legado 漫画源 ✓）：
  ///   空 / `GET` = 现状（GET ✓，向后兼容 ✓）；`POST` = 用 `searchPostBody` 作请求体发 POST ✓。
  ///   对应 Legado 书源的 `search_method` 键 ✓（与上一条 `chapter_api_method` 的写法**完全对称** ✓）。
  final String searchMethod;
  /// ✅ **搜索 POST 请求体**（本轮新增 ✓）—— 仅当 [searchMethod] 为 `POST` 时使用 ✓。
  ///   支持占位替换 ✓（`{{key}}` → 书名/页码等 ✓，与 GET 版共用同一套替换 ✓）。
  final String searchPostBody;
  /// ✅ **标签分隔符**（本轮新增 ✓ —— 实现 Legado 的 `tags_split` ✓）。
  /// 为什么需要 ✗：引擎收集标签靠 `querySelectorAll` ✓（命中**多个**元素就成列表 ✓），
  /// 而有的源把一串标签塞在**一个元素**里（如 `热血,冒险,战斗` ✓）→ 只命中 1 个 ✗，
  /// 列表就**只有 1 项** ✗（本该 3 项 ✓）。填上分隔符后，收集到的每一项会**再按它拆开** ✓✓。
  /// 留空 = **行为完全不变** ✓（向后兼容 ✓ 现有源一字不改 ✓）。
  final String tagsSplit;
  /// ✅ **状态兜底标签**（本轮新增 ✓ —— 对应编辑器的 `status_label` ✓）。
  /// 为什么需要 ✗：状态是从 `comic_status_dom` **抓自由文本** ✓（`config_manga_source:656-661` ✓），
  /// 站点**没给**状态时就是空 ✗（详情页那格空白 ✓）。填上这个键后：
  /// **抓不到状态时用该标签兜底** ✓（如源作者写「连载中」✓）。
  /// 留空 = **行为完全不变** ✓（向后兼容 ✓ 现有源一字不改 ✓）。
  final String statusLabel;
  /// ✅ **WebView 点击选择器**（本轮新增 ✓ —— 对应编辑器的 `chapter_click_dom` ✓）。
  /// 为什么需要 ✗：有些站在**详情页里不会直接渲染章节列表** ✗ ——
  /// 必须**先点一下**某个元素（「展开目录」/「连载」Tab 之类 ✓）列表才出现 ✓。
  /// 填上本选择器后，WebView 取章节那条路会：**等页面加载 ✓ → 点它 ✓ → 轮询等列表出现 ✓**。
  /// 留空 = **行为完全不变** ✓（向后兼容 ✓ 现有源一字不改 ✓）。
  final String chapterClickDom;
  /// ✅ **源级并发上限**（本轮新增 ✓ —— 对应编辑器的 `concurrent_rate` ✓）。
  /// 语义（**我实现的这一种，如实写明** ✓）：**同时进行的请求数上限** ✓。
  /// · `0`（默认）✓ → 用引擎原有默认（下标探测取图 **8** ✓ / AES 直下 **6** ✓）**行为完全不变** ✓
  /// · `> 0` ✓ → 用该值（并被**安全上限 `clamp(1, 8)`** 约束 ✓ —— 防止某个源把并发拉到几十
  ///   把站点打死、或把自己打死 ✓），同时按它建**信号量池** ✓
  /// ⚠️ Legado 里该键的语义可能还含"每秒请求数"之类 ✗ —— 我**只实现"同时并发数"这一种** ✓，
  ///   并在这里与编辑器 hint 里都**写清楚** ✓（不假装覆盖全部语义 ✗）。
  final int concurrentRate;
  final String imgReferer; // 图片 Referer（空=site.url，'none'=不发，其他=自定义值）
  final int imgLoadMode; // 1=滚动 2=滚到底 3=下一页
  final String nextPageSelector; // 下一页选择器（imgLoadMode=3）
  final String pageLabelSelector;

  final int chapterOrder; // 0=倒序 1=正序
  final bool chapterSortByOrder; // true=按 order(DOM顺序)排，跳过智能排序（更新时间序站点用）
  final int crossOrigin; // 0=同源 1=跨源
  final String restoreAlgorithm; // 图片还原算法名（如「腐漫」）
  final bool useBlobBase64; // blob 站走 base64 取图（如摸摸漫画），其余 blob 站用还原后真实 URL
  final String imgAesKey; // 章节图 AES-CBC 密钥（utf-8 前 32 字节；密文=前 16 字节 IV+密文）。
  // 非空时 Dio 直下密文本地解密落盘，不走 WebView 逐张解密（如漫蛙）

  // 章节页 HTML 内嵌密文解密取图（章节图 URL 列表加密，如追更漫画）：
  // 章节页 HTML 里嵌 base64(iv+密文) 变量，AES-CBC 解密出图片 URL 数组 JSON。
  //   imgDecodeRegex     —— 从章节页 HTML 提取密文变量的正则（第 1 组捕获 base64 串）
  //   imgDecodeKey       —— AES 密钥（utf-8，如追更漫画 '9S8$vJnU2ANeSRoF'）
  //   imgDecodeDataField —— 解密 JSON 的图片字段（空=JSON 本身是数组）
  final String imgDecodeRegex;
  final String imgDecodeKey;
  final String imgDecodeDataField;
  final String imgUrlPattern; // 章节图 URL 模板（{comicId}/{chapterNo}/{index} 占位）。
  // 非空时跳过 WebView，按序号直下到 404 为止（如摸摸 c2.2thewash.com）
  final String imgUrlIdRegex; // 从章节 URL 提取 comicId/chapterNo 的正则（两组捕获）
  final bool imgBodyBase64; // 章节图响应体是图片的 base64 文本（摸摸），下载后解码落盘
  final String
  coverUrlPattern; // 封面直连 URL 模板（{comicId} 占位，如摸摸 cover.2thewash.com）。
  // 非空时列表/详情封面一律按模板生成（渲染 DOM 里的 blob/_ipx 地址不可直连）
  final String
  coverIdRegex; // 从漫画 URL 提取 comicId 的正则（一组捕获，配 coverUrlPattern 用）

  // app 搜索扩展（可空，2b 逐站补）
  final String? searchUrl; // 搜索 URL 模板，{q} 占位
  final String? searchResultDom; // 搜索结果项选择器
  final String? searchTitleDom;
  final String? searchCoverDom;
  final String? searchMangaUrlDom; // 详情页相对 URL 选择器
  final String? searchEncoding; // 搜索关键词编码（默认 utf-8；Empire CMS 站=gb2312）
  final String? authorLabel; // 作者标签文本（详情页作者区「原著作者」等，取去 label 后剩余文本）
  final String? pageEncoding; // 页面响应编码（默认 utf-8；来漫画等 Empire CMS 站=gb2312）
  final bool
  useWebViewFetch; // true=搜索/分类/详情/章节走 WebView 抓 HTML（Cloudflare 防护站，Dio 被拦）

  // app 分类扩展（可空，2b 逐站补）
  // 新版：categories 是 Map<String, _CatGroup>，key 即 FilterGroup.key / URL 占位符名
  //   例："categories": {
  //     "theme":  { "title": "题材", "options": [{"value":"all","name":"全部"}, ...] },
  //     "status": { "title": "进度", "options": [...] },
  //     "sort":   { "title": "排序", "options": [...] }
  //   }
  //   URL 用 {theme}/{status}/{sort} 占位，显示顺序按 map 插入顺序
  // 旧版（兼容）：categories 是 List<FilterOption>，等价于 {"theme": {title:"题材", options:[...]}}
  final List<FilterOption>? categories; // 旧版兼容：等价于 theme 组
  final Map<String, List<FilterOption>>? categoryGroups; // 新版：多维度分组（内部归一化用）
  final Map<String, String>? categoryGroupTitles; // 新版：分组显示标题（key->title）
  final String? categoryUrl; // 分类第1页 URL 模板（{key名} 占位 + {page}）
  final String? categoryPageUrl; // 分类后续页 URL 模板（{key名} 占位 + {page}）
  final String? categoryListDom; // 分类列表项选择器
  final String? categoryCoverDom; // 分类项封面 img 选择器
  final String? categoryTitleDom; // 分类项标题选择器
  final String? categoryUrlDom; // 分类项详情链接选择器（取 href）
  final String? categoryNextPageDom; // 下一页链接选择器（hasNextPage 判断）
  final int categoryPageSize; // 计数式分页每页条数（>0 时满页即有下一页；来漫画用链接式留 0）
  final int
  categoryPageStart; // 分页页码起始偏移（{page}=page+此值；默认1，lmanhua pageN.html=第N+1页用0）
  final Map<String, String>?
  urlRewrites; // 图片 URL 子串替换（封面/章节图主机被防盗链或地理拦截时换可达主机，如 static-tw->cn）

  /// 归一化分类分组：新版 categoryGroups（Map）优先，旧版 categories（List）
  /// 退化为 {"theme": categories}。
  Map<String, List<FilterOption>> get normalizedCategoryGroups {
    if (categoryGroups != null && categoryGroups!.isNotEmpty) {
      return categoryGroups!;
    }
    if (categories != null && categories!.isNotEmpty) {
      return {'theme': categories!};
    }
    return const {};
  }

  /// 归一化分组标题：新版 categoryGroupTitles 优先，旧版退化为 {"theme": "题材"}。
  String categoryGroupTitle(String key) {
    if (categoryGroupTitles != null && categoryGroupTitles!.containsKey(key)) {
      return categoryGroupTitles![key]!;
    }
    if (key == 'theme') return '题材';
    return key;
  }

  const SiteConfig({
    required this.name,
    this.icon,
    required this.url,
    this.comicCoverDom = '',
    this.comicNameDom = '',
    this.comicAuthorDom = '',
    this.comicDescDom = '',
    this.chapterNameDom = '',
    this.chapterLinkDom = '',
    this.chapterUrlPattern = '',
    this.chapterFallbackLinkDom = '',
    this.chapterPagedUrl = '',
    this.chapterPagedBaseDom = '',
    this.chapterPageCountDom = '',
    this.imgDom = '',
    this.useFrame = 1,
    this.imgAttr = '',
    this.imgScript = '',
    this.chapterScript = '',
    this.chapterJsonScript = '',
    this.chapterApiUrl = '',
    this.chapterUrlIdRegex = '',
    this.chapterListField = '',
    this.chapterJsonFields,
    this.chapterPageSize = 0,
    this.chapterApiMethod = '',
    this.searchMethod = '',
    this.searchPostBody = '',
    this.tagsSplit = '',
    this.statusLabel = '',
    this.chapterClickDom = '',
    this.concurrentRate = 0,
    this.imgReferer = '',
    this.imgLoadMode = 1,
    this.nextPageSelector = '',
    this.pageLabelSelector = '',
    this.chapterOrder = 1,
    this.chapterSortByOrder = false,
    this.crossOrigin = 0,
    this.restoreAlgorithm = '',
    this.useBlobBase64 = false,
    this.imgAesKey = '',
    this.imgDecodeRegex = '',
    this.imgDecodeKey = '',
    this.imgDecodeDataField = '',
    this.imgUrlPattern = '',
    this.imgUrlIdRegex = r'comics/(\d+)/(\d+)',
    this.imgBodyBase64 = false,
    this.coverUrlPattern = '',
    this.coverIdRegex = r'comics/(\d+)',
    this.searchUrl,
    this.searchResultDom,
    this.searchTitleDom,
    this.searchCoverDom,
    this.searchMangaUrlDom,
    this.searchEncoding,
    this.authorLabel,
    this.pageEncoding,
    this.useWebViewFetch = false,
    this.categories,
    this.categoryGroups,
    this.categoryGroupTitles,
    this.categoryUrl,
    this.categoryPageUrl,
    this.categoryListDom,
    this.categoryCoverDom,
    this.categoryTitleDom,
    this.categoryUrlDom,
    this.categoryNextPageDom,
    this.categoryPageSize = 0,
    this.categoryPageStart = 1,
    this.urlRewrites,
    // 同上（批次 3 ✓）：默认空串 ✓ —— 与消费方的约定一致（引擎"为空即跳过" ✓），
    // 因此**不传这 3 个参数的既有调用点完全不受影响** ✓（零回归 ✓）
    this.comicStatusDom = '',
    this.comicTagsDom = '',
    this.comicHotDom = '',
  });

  factory SiteConfig.fromJson(Map<String, dynamic> j) => SiteConfig(
    // 🔴 name/url 原来是**硬 `as String` 强转** ✗ —— 字段缺失（null）或类型不对
    // （如 `"name": 123`）时直接抛 TypeError，让**整份源列表解析失败** ✗。
    // 这两个字段又是**必需**的：name 参与 `config:${name}` 派生 id（currentSourceId
    // 持久化靠它一致），url 决定请求打到哪个站。
    // → 改用 safe_num 的宽容写法（该文件头注释明确禁止裸 `as`）✓：
    //   name 统一取字符串、url 取字符串后可判空；类型不对时降级成空串，
    //   **由上层 SourceManager 的 per-item try/catch 决定是否跳过这一条** ✓，
    //   而不是让一条坏数据把其余源一起带走 ✗。
    name: asStr(j['name']),
    icon: j['icon'] as String?,
    url: asStr(j['url']),
    comicCoverDom: (j['comic_cover_dom'] as String?) ?? '',
    comicNameDom: (j['comic_name_dom'] as String?) ?? '',
    comicAuthorDom: (j['comic_author_dom'] as String?) ?? '',
    comicDescDom: (j['comic_desc_dom'] as String?) ?? '',
    // 🔴 **批次 3 补** ✓：这 3 个键**内置源的 JSON 里本来就有** ✓
    //   （`comic_status_dom` 12 个源 · `comic_tags_dom` 12 个 · `comic_hot_dom` 3 个 ✓），
    //   只是模型一直**没读**它们 ✗ → 引擎拿不到 → 12 个内置源的
    //   **状态/标签/热度恒为空** ✗（而编辑页还能填 ✓ = 假开关 ✓）。
    //   ⚠️ 与下面的 `toJson`（`:366` 那片 ✓）**必须成对** ✓ ——
    //      只读不写 = 导出/分享时**丢掉**这几个字段 ✗（同 `categories` 那个坑 ✗）
    comicStatusDom: (j['comic_status_dom'] as String?) ?? '',
    comicTagsDom: (j['comic_tags_dom'] as String?) ?? '',
    comicHotDom: (j['comic_hot_dom'] as String?) ?? '',
    chapterNameDom: (j['chapter_name_dom'] as String?) ?? '',
    chapterLinkDom: (j['chapter_link_dom'] as String?) ?? '',
    chapterUrlPattern: (j['chapter_url_pattern'] as String?) ?? '',
    chapterFallbackLinkDom: (j['chapter_fallback_link_dom'] as String?) ?? '',
    chapterPagedUrl: (j['chapter_paged_url'] as String?) ?? '',
    chapterPagedBaseDom: (j['chapter_paged_base_dom'] as String?) ?? '',
    chapterPageCountDom: (j['chapter_page_count_dom'] as String?) ?? '',
    imgDom: (j['img_dom'] as String?) ?? '',
    useFrame: (j['use_frame'] as num?)?.toInt() ?? 1,
    imgAttr: (j['img_attr'] as String?) ?? '',
    imgScript: (j['img_script'] as String?) ?? '',
    chapterScript: (j['chapter_script'] as String?) ?? '',
    chapterJsonScript: (j['chapter_json_script'] as String?) ?? '',
    chapterApiUrl: (j['chapter_api_url'] as String?) ?? '',
    chapterUrlIdRegex: (j['chapter_url_id_regex'] as String?) ?? '',
    chapterListField: (j['chapter_list_field'] as String?) ?? '',
    chapterJsonFields: (j['chapter_json_fields'] is Map)
        ? (j['chapter_json_fields'] as Map).map(
            (k, v) => MapEntry(k.toString(), v.toString()),
          )
        : null,
    chapterPageSize: (j['chapter_page_size'] as num?)?.toInt() ?? 0,
    chapterApiMethod: (j['chapter_api_method'] as String?) ?? '',
    searchMethod: (j['search_method'] as String?) ?? '',
    searchPostBody: (j['search_post_body'] as String?) ?? '',
    tagsSplit: (j['tags_split'] as String?) ?? '',
    statusLabel: (j['status_label'] as String?) ?? '',
    chapterClickDom: (j['chapter_click_dom'] as String?) ?? '',
    // ⚠️ 这是 **int** ✓（不是 String ✓）—— 兼容 JSON 里写 `3` 或 `"3"` 两种 ✓；
    //   取不到 / 非法 → `0` ✓ = 用引擎默认 ✓（**行为不变** ✓）
    concurrentRate: (j['concurrent_rate'] as num?)?.toInt() ?? 0,
    imgReferer: (j['img_referer'] as String?) ?? '',
    imgLoadMode: (j['img_load_mode'] as num?)?.toInt() ?? 1,
    nextPageSelector: (j['next_page_selector'] as String?) ?? '',
    pageLabelSelector: (j['page_label_selector'] as String?) ?? '',
    chapterOrder: (j['chapter_order'] as num?)?.toInt() ?? 1,
    chapterSortByOrder: (j['chapter_sort_by_order'] as bool?) ?? false,
    crossOrigin: (j['cross_origin'] as num?)?.toInt() ?? 0,
    restoreAlgorithm: (j['restore_algorithm'] as String?) ?? '',
    useBlobBase64: (j['use_blob_base64'] as bool?) ?? false,
    imgAesKey: (j['img_aes_key'] as String?) ?? '',
    imgDecodeRegex: (j['img_decode_regex'] as String?) ?? '',
    imgDecodeKey: (j['img_decode_key'] as String?) ?? '',
    imgDecodeDataField: (j['img_decode_data_field'] as String?) ?? '',
    imgUrlPattern: (j['img_url_pattern'] as String?) ?? '',
    imgUrlIdRegex: (j['img_url_id_regex'] as String?) ?? r'comics/(\d+)/(\d+)',
    imgBodyBase64: (j['img_body_base64'] as bool?) ?? false,
    coverUrlPattern: (j['cover_url_pattern'] as String?) ?? '',
    coverIdRegex: (j['cover_id_regex'] as String?) ?? r'comics/(\d+)',
    searchUrl: j['search_url'] as String?,
    searchResultDom: j['search_result_dom'] as String?,
    searchTitleDom: j['search_title_dom'] as String?,
    searchCoverDom: j['search_cover_dom'] as String?,
    searchMangaUrlDom: j['search_manga_url_dom'] as String?,
    searchEncoding: j['search_encoding'] as String?,
    authorLabel: j['author_label'] as String?,
    pageEncoding: j['page_encoding'] as String?,
    useWebViewFetch: (j['use_webview_fetch'] as bool?) ?? false,
    categories: (j['categories'] is List)
        ? (j['categories'] as List)
              .map(
                (e) => FilterOption(
                  value: e['value'] as String,
                  name: e['name'] as String,
                  isAll: (e['isAll'] as bool?) ?? false,
                ),
              )
              .toList()
        : null,
    categoryGroups: (j['categories'] is Map)
        ? (j['categories'] as Map).map((k, v) {
            // 🔴 **旧导出（List 形状）兼容** ✗ —— 今天补上 ✓：
            //   本类以前 `toJson` 写的是 `{k: [ {value,name,isAll}, … ]}` ✓，
            //   而这里读的是 `(v as Map)['options']` ✗ → **旧备份 / 别人分享的旧文件
            //   一导入就抛类型异常** ✓。✓ 现在两种形状都认：
            //   · Map（新格式 ✓）→ 取 `options`
            //   · List（旧格式 ✓）→ 它本身就是选项表
            final optionsRaw = (v is Map ? v['options'] : v) as List?;
            if (optionsRaw == null) {
              return MapEntry(k as String, <FilterOption>[]);
            }
            final options = optionsRaw
                .map(
                  (e) => FilterOption(
                    value: e['value'] as String,
                    name: e['name'] as String,
                    isAll: (e['isAll'] as bool?) ?? false,
                  ),
                )
                .toList();
            return MapEntry(k as String, options);
          })
        : null,
    categoryGroupTitles: (j['categories'] is Map)
        ? (j['categories'] as Map).map(
            (k, v) => MapEntry(
              k as String,
              // 同样兼容旧形状 ✓：旧 List 里没有 `title` → 退回 key ✓
              //（与原来 `?? k` 的行为一致 ✓，旧数据不会因此报错 ✓）
              // ⚠️ 注意 ✓：这里**不能**写 `k as String` ✗ —— `k` 在
              // `(j['categories'] as Map).map((k, v) => …)` 里本来就被推断成
              // `String` 了 ✓，多写一个 `as` 会被 analyze 判为
              // `unnecessary_cast` ✗（我今天就是这么引入 warning 又当场去掉的 ✓）
              (v is Map ? (v['title'] as String?) : null) ?? k,
            ),
          )
        : null,
    categoryUrl: j['category_url'] as String?,
    categoryPageUrl: j['category_page_url'] as String?,
    categoryListDom: j['category_list_dom'] as String?,
    categoryCoverDom: j['category_cover_dom'] as String?,
    categoryTitleDom: j['category_title_dom'] as String?,
    categoryUrlDom: j['category_url_dom'] as String?,
    categoryNextPageDom: j['category_next_page_dom'] as String?,
    categoryPageSize: (j['category_page_size'] as num?)?.toInt() ?? 0,
    categoryPageStart: (j['category_page_start'] as num?)?.toInt() ?? 1,
    urlRewrites: (j['url_rewrites'] as Map?)?.map(
      (k, v) => MapEntry(k.toString(), v.toString()),
    ),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'icon': icon,
    'url': url,
    'comic_cover_dom': comicCoverDom,
    'comic_name_dom': comicNameDom,
    'comic_author_dom': comicAuthorDom,
    'comic_desc_dom': comicDescDom,
    // ✅ 与上面 `fromJson`（`:245` 那片 ✓）**成对** ✓（批次 3 补 ✓）——
    //   不加这三行，导出/分享就会**静默丢掉**状态/标签/热度选择器 ✗
    'comic_status_dom': comicStatusDom,
    'comic_tags_dom': comicTagsDom,
    'comic_hot_dom': comicHotDom,
    'chapter_name_dom': chapterNameDom,
    'chapter_link_dom': chapterLinkDom,
    'chapter_url_pattern': chapterUrlPattern,
    'chapter_fallback_link_dom': chapterFallbackLinkDom,
    'chapter_paged_url': chapterPagedUrl,
    'chapter_paged_base_dom': chapterPagedBaseDom,
    'chapter_page_count_dom': chapterPageCountDom,
    'img_dom': imgDom,
    'use_frame': useFrame,
    'img_attr': imgAttr,
    'img_script': imgScript,
    'chapter_script': chapterScript,
    'chapter_json_script': chapterJsonScript,
    'chapter_api_url': chapterApiUrl,
    'chapter_url_id_regex': chapterUrlIdRegex,
    'chapter_list_field': chapterListField,
    'chapter_json_fields': chapterJsonFields,
    'chapter_page_size': chapterPageSize,
    'chapter_api_method': chapterApiMethod,
    'search_method': searchMethod,
    'search_post_body': searchPostBody,
    'tags_split': tagsSplit,
    'status_label': statusLabel,
    'chapter_click_dom': chapterClickDom,
    'concurrent_rate': concurrentRate,
    'img_referer': imgReferer,
    'img_load_mode': imgLoadMode,
    'next_page_selector': nextPageSelector,
    'page_label_selector': pageLabelSelector,
    'chapter_order': chapterOrder,
    'chapter_sort_by_order': chapterSortByOrder,
    'cross_origin': crossOrigin,
    'restore_algorithm': restoreAlgorithm,
    'use_blob_base64': useBlobBase64,
    'img_aes_key': imgAesKey,
    'img_decode_regex': imgDecodeRegex,
    'img_decode_key': imgDecodeKey,
    'img_decode_data_field': imgDecodeDataField,
    'img_url_pattern': imgUrlPattern,
    'img_url_id_regex': imgUrlIdRegex,
    'img_body_base64': imgBodyBase64,
    'cover_url_pattern': coverUrlPattern,
    'cover_id_regex': coverIdRegex,
    'search_url': searchUrl,
    'search_result_dom': searchResultDom,
    'search_title_dom': searchTitleDom,
    'search_cover_dom': searchCoverDom,
    'search_manga_url_dom': searchMangaUrlDom,
    'search_encoding': searchEncoding,
    'author_label': authorLabel,
    'page_encoding': pageEncoding,
    'use_webview_fetch': useWebViewFetch,
    'categories': categoryGroups != null
        ? categoryGroups!.map(
            (k, v) => MapEntry(
              k,
              // 🔴 原来这里写的是**裸 List** ✗：`{k: [ {value,name,isAll}, … ]}`
              //   而 `fromJson` 的**两个读者都要求外层是 Map** ✓：
              //     · `:295-308` 读 `(v as Map)['options']` ✓
              //     · `:310-314` 读 `(v as Map)['title'] ?? k` ✓
              //   → **导出后再导入会当场抛类型转换异常** ✗✗（比"标题丢失"严重 ✓）；
              //   而且 `title` **从来没被写出去** ✓ → 重新导入后退化成英文 key ✗。
              // ✓ 现在按两个读者共同期望的形状写：`{title, options}` ✓；
              //   `title` 取 `categoryGroupTitle(k)` ✓（它自带 `theme → 题材` 兜底 ✓）
              // ⚠️ 遗留（下一步 ✓）：**旧导出**（List 形状）在导入时仍会抛 ✗ ——
              //   要让两个读者也**容忍旧 List**（读不到 `options` 时按 List 兜底 ✓）
              <String, dynamic>{
                'title': categoryGroupTitle(k),
                'options': v
                    .map((e) => {'value': e.value, 'name': e.name, 'isAll': e.isAll})
                    .toList(),
              },
            ),
          )
        : categories
              ?.map((e) => {'value': e.value, 'name': e.name, 'isAll': e.isAll})
              .toList(),
    'category_url': categoryUrl,
    'category_page_url': categoryPageUrl,
    'category_list_dom': categoryListDom,
    'category_cover_dom': categoryCoverDom,
    'category_title_dom': categoryTitleDom,
    'category_url_dom': categoryUrlDom,
    'category_next_page_dom': categoryNextPageDom,
    'category_page_size': categoryPageSize,
    'category_page_start': categoryPageStart,
    if (urlRewrites != null) 'url_rewrites': urlRewrites,
  };
}
