import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/tg_service.dart';
import 'package:tvbox/services/tg_title_filter.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/pages/settings/sub/tg_channel_page.dart';

/// 设置 → 订阅管理 → Telegram 源
///
/// 流程只有两步：
///   1. 点「生成二维码」，手机 Telegram 扫码（**不需要验证码**）
///   2. 选频道 / 手填群 ID → 出片
///
/// 应用凭据（api_id / api_hash）已内置，不用申请；只有想换成自己的
/// 身份时才在「高级设置」里填。
///
/// 这里**不碰协议**：数据全由内置 Node 的 `/tg` 返回。
class TgSourcePage extends StatefulWidget {
  const TgSourcePage({super.key});

  @override
  State<TgSourcePage> createState() => _TgSourcePageState();
}

class _TgSourcePageState extends State<TgSourcePage> {
  final TgService _tg = TgService.instance;

  final _apiIdCtrl = TextEditingController();
  final _apiHashCtrl = TextEditingController();
  final _proxyHostCtrl = TextEditingController();
  final _proxyPortCtrl = TextEditingController();
  final _peerCtrl = TextEditingController();
  final _pubCtrl = TextEditingController();
  final _filterCtrl = TextEditingController();

  bool _booting = true;
  bool _busy = false;
  /// 默认展开：代理（含内置代理测速）藏起来用户根本找不到
  bool _showAdvanced = true;

  /// 正在跑内置代理测速（30 个 × 8 秒超时、6 并发 ⇒ 十几秒）
  bool _probeBusy = false;

  /// 正在测 t.me 连通（3~12 秒）
  bool _netTesting = false;

  Map<String, dynamic> _st = {};
  Map<String, dynamic> _qr = {};
  List<Map<String, dynamic>> _saved = [];

  /// 登录账号里的**所有**群/频道（最多 150），用户从中勾选要显示的
  List<Map<String, dynamic>> _allDialogs = [];
  bool _loadingDialogs = false;

  Timer? _pollTimer;

  bool get _configured => _st['configured'] == true;
  bool get _authorized => _st['authorized'] == true;
  String get _phase => (_qr['phase'] ?? 'idle') as String;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _apiIdCtrl.dispose();
    _apiHashCtrl.dispose();
    _proxyHostCtrl.dispose();
    _proxyPortCtrl.dispose();
    _peerCtrl.dispose();
    _pubCtrl.dispose();
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _boot() async {
    await _tg.loadSettings();
    await TgTitleFilter.instance.ensureLoaded();
    _apiIdCtrl.text = _tg.apiId;
    _apiHashCtrl.text = _tg.apiHash;
    _proxyHostCtrl.text = _tg.proxyHost;
    _proxyPortCtrl.text = _tg.proxyPort;
    await _tg.pushConfig();
    await _refreshStatus();
    // 自动真握手（用户 2026-10-25：「切换一次，就是点击测试一次登录」）：
    // tgStatus 只读缓存，会话有没有真通要 tgPing 才知道。
    // 这里进页面静默补一次，会话有效就直接进已登录，不用每次手动点「测试连接」。
    // 握手失败只保留 status 快照（configured/connected 不能丢，否则界面会误跳「未配置」）。
    if (mounted && _authorized != true) {
      final r = await _tg.ping();
      if (!mounted) return;
      if (r['ok'] == true) {
        setState(() => _st = r);
        if (r['authorized'] == true) {
          _loadSaved();
          _loadDialogs();
        }
      }
    }
    // 首次进入塞一个内置公开频道（与 TG 分类页共用同一份收藏）
    await _tg.seedDefaults();
    final saved = await _tg.channels();
    if (mounted) {
      setState(() {
        _saved = saved;
        _booting = false;
      });
    }
    if (_authorized) {
      _loadSaved();
      _loadDialogs();
    }
  }

  /// 重新读「我添加的频道」（登录/公开两种模式都在这里）
  Future<void> _loadSaved() async {
    final s = await _tg.channels();
    if (!mounted) return;
    setState(() => _saved = s);
  }

  /// 拉取账号里**所有**群/频道（最多 150），供用户勾选
  Future<void> _loadDialogs() async {
    if (!_authorized) return;
    setState(() => _loadingDialogs = true);
    final r = await _tg.dialogs();
    if (!mounted) return;
    setState(() {
      _allDialogs = ((r['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
      _loadingDialogs = false;
    });
  }

  Future<void> _refreshStatus() async {
    final r = await _tg.status();
    if (!mounted) return;
    setState(() => _st = r);
  }

  /// 真握手（会走网络）：用来验证 api / 代理 / 会话是否真的可用
  Future<void> _ping() async {
    setState(() => _busy = true);
    final r = await _tg.ping();
    if (!mounted) return;
    setState(() {
      _busy = false;
      // 握手失败不覆盖完整状态（configured/connected 还在 status 里，
      // 否则界面会误跳成「未配置」）
      if (r['ok'] == true) _st = r;
    });
    if (r['ok'] != true) {
      AppToast.message(r['error']?.toString() ?? '连接失败');
    } else {
      AppToast.message(r['authorized'] == true ? '已登录' : '连接正常，请扫码登录');
    }
    if (r['authorized'] == true) {
      _loadSaved();
      _loadDialogs();
    }
  }

  Future<void> _saveConfig() async {
    // 凭据已内置：留空就走内置那组，不再拦着用户
    setState(() => _busy = true);
    await _tg.saveSettings(
      apiId: _apiIdCtrl.text,
      apiHash: _apiHashCtrl.text,
      proxyHost: _proxyHostCtrl.text,
      proxyPort: _proxyPortCtrl.text,
    );
    await _tg.pushConfig();
    await _refreshStatus();
    if (mounted) setState(() => _busy = false);
  }

  /// 内置代理池：拉列表 + 测速（Node 侧做），选一个写进上面的 SOCKS5 两栏
  ///
  /// [autoPick] 为真时直接取最快的那个（开关刚打开、还没选过节点）。
  Future<void> _probeProxy({bool autoPick = false}) async {
    setState(() => _probeBusy = true);
    final r = await _tg.probeProxies();
    if (!mounted) return;
    setState(() => _probeBusy = false);
    final items = ((r['items'] as List?) ?? const [])
        .whereType<Map>()
        .map((e) => e.cast<String, dynamic>())
        .toList();
    if (items.isEmpty) {
      AppToast.message('没测到可用代理：${r['error'] ?? '全部超时，稍后再试'}');
      // 没有可用节点 ⇒ 开关回落到关，别让用户以为"开了却没生效"
      await _tg.setProxyOn(false);
      if (mounted) setState(() {});
      return;
    }
    if (autoPick) {
      await _applyProxy('${items.first['host']}', '${items.first['port']}');
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      ),
      builder: (c) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    Text('可用代理（${items.length}）',
                        style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: AppTheme.textPrimary)),
                    const Spacer(),
                    Text('按延迟排序',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textTertiary)),
                  ],
                ),
              ),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: items.length,
                  itemBuilder: (_, i) {
                    final p = items[i];
                    final host = '${p['host'] ?? ''}';
                    final port = '${p['port'] ?? ''}';
                    final ms = (p['ms'] as num?)?.toInt() ?? 0;
                    final note = '${p['note'] ?? ''}';
                    return ListTile(
                      dense: true,
                      leading: Icon(
                        ms <= 400
                            ? Icons.network_ping
                            : Icons.signal_cellular_alt_2_bar,
                        size: 18,
                        color: ms <= 400
                            ? AppTheme.accentOnSurface
                            : AppTheme.textTertiary,
                      ),
                      title: Text('$host:$port',
                          style: TextStyle(
                              fontSize: 13, color: AppTheme.textPrimary)),
                      subtitle: Text(
                        note.isEmpty ? 'socks5' : note,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textTertiary),
                      ),
                      trailing: Text('${ms}ms',
                          style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textSecondary)),
                      onTap: () => Navigator.pop(c, p),
                    );
                  },
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    await _applyProxy('${picked['host']}', '${picked['port']}');
  }

  /// 「内置代理池」开关：打开才启用代理；关掉立即回到直连
  Future<void> _togglePool(bool on) async {
    await _tg.setProxyOn(on);
    if (!mounted) return;
    setState(() {});
    if (!on) {
      await _applyProxy('', ''); // 清节点 + 推 null ⇒ Node 直连
      return;
    }
    final host = _proxyHostCtrl.text.trim();
    final port = _proxyPortCtrl.text.trim();
    if (host.isNotEmpty && port.isNotEmpty) {
      // 之前选过节点 ⇒ 直接复用
      await _applyProxy(host, port);
      return;
    }
    // 还没节点 ⇒ 自动测速挑最快的一个
    await _probeProxy(autoPick: true);
  }

  /// 写入代理并推给 Node（不要求先填 api_id —— 只刷公开频道也能用代理）
  Future<void> _applyProxy(String host, String port) async {
    if (!mounted) return;
    // 选了节点就自动把开关打开；清空则关掉（避免"填了但不生效"的糊涂账）
    await _tg.setProxyOn(host.isNotEmpty);
    setState(() {
      _proxyHostCtrl.text = host;
      _proxyPortCtrl.text = port;
    });
    await _tg.saveSettings(
      apiId: _apiIdCtrl.text,
      apiHash: _apiHashCtrl.text,
      proxyHost: host,
      proxyPort: port,
    );
    final r = await _tg.pushConfig();
    if (!mounted) return;
    if (r['ok'] != true) {
      AppToast.message(r['error']?.toString() ?? '代理没生效');
      return;
    }
    AppToast.message(host.isEmpty
        ? '已关闭代理（直连，登录态保留）'
        : '已启用代理 $host:$port（登录态保留）');
    await _refreshStatus();
  }

  /// 「测 t.me 连通」：按**当前**设置打一次频道页，直接回答
  /// 「现在为什么看不了」——比"代理测速通过"更贴近播放链路。
  Future<void> _testTme() async {
    setState(() => _netTesting = true);
    final r = await _tg.netTest();
    if (!mounted) return;
    setState(() => _netTesting = false);
    final viaProxy = r['proxy'] == true;
    final where = viaProxy ? '内置代理' : '直连（含系统 VPN）';
    if (r['ok'] == true) {
      AppToast.message('t.me 可访问（$where）：${r['ms']} ms');
    } else {
      final why = (r['error'] ?? '').toString();
      AppToast.error('t.me 连不上（$where，${r['ms']} ms）：'
          '${why.isEmpty ? '未知原因' : why}');
    }
  }

  Future<void> _startQr() async {
    setState(() {
      _busy = true;
      _qr = {'phase': 'waiting'};
    });
    final r = await _tg.startQr();
    if (!mounted) return;
    setState(() {
      _qr = r;
      _busy = false;
    });
    if (r['ok'] == false) {
      AppToast.message(r['error']?.toString() ?? '二维码获取失败');
      return;
    }
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 1500), (t) async {
      if (!mounted) return;
      final r = await _tg.pollQr();
      if (!mounted) return;
      setState(() => _qr = r);
      final phase = r['phase'];
      if (phase == 'done') {
        t.cancel();
        await _refreshStatus();
        await _loadSaved();
        await _loadDialogs();
        AppToast.message('登录成功');
      } else if (phase == 'error') {
        t.cancel();
      }
    });
  }

  Future<void> _submitPassword(String pw) async {
    final r = await _tg.submitPassword(pw);
    if (r['ok'] != true) AppToast.message(r['error']?.toString() ?? '提交失败');
  }

  Future<void> _logout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('退出 Telegram'),
        content: const Text('会删除本地会话，下次需要重新扫码。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('退出', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _tg.logout();
    _qr = {};
    setState(() {});
    await _refreshStatus();
  }

  // ── UI ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: 'TG 设置',
      children: [
        _section('连接'),
        _statusCard(),
        // 代理常显：登录之后也找得到（用户 2026-10-25）
        _section('代理'),
        _proxyCard(),
        if (!_configured) _configCard(),
        if (_configured && !_authorized) ...[
          _section('登录（可选）'),
          _loginCard(),
        ],
        if (_authorized) ...[
          _section('我的频道'),
          _manualCard(),
          _channelsCard(),
        ],
        _section('标题筛选'),
        _filterCard(),
        _section('公开频道'),
        _savedCard(),
        _hintCard(),
      ],
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(t,
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 11.5)),
      );

  Widget _card(Widget child) =>
      Padding(padding: const EdgeInsets.only(bottom: 10), child: child);

  Widget _statusCard() {
    final name = (_st['me'] as Map?)?['name']?.toString() ?? '';
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Icon(
              _authorized ? Icons.verified_user : Icons.telegram,
              color: _authorized ? Colors.green : AppTheme.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _authorized ? (name.isEmpty ? '已登录' : name) : '未登录',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _booting
                        ? '正在读取…'
                        : (_st['connected'] == true
                            ? '已连接 Telegram'
                            : '未连接（需要代理时请填写）'),
                    style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (_authorized)
              TextButton(onPressed: _logout, child: const Text('退出')),
            if (!_authorized)
              TextButton(
                onPressed: _busy ? null : _ping,
                child: Text(_busy ? '连接中…' : '测试连接'),
              ),
            IconButton(
              tooltip: '高级设置',
              onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
              icon: Icon(Icons.settings_outlined,
                  color: AppTheme.textTertiary, size: 20),
            ),
          ],
        ),
      ),
    ));
  }

  /// 代理卡：**常显**（用户 2026-10-25：「TG 内置代理的开关呢？」）——
  /// 原来它藏在「扫码登录」卡的高级设置里，而且 `_configured` 之后整张卡都不显示，
  /// 登录过的用户就再也找不到代理开关了。
  Widget _proxyCard() {
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('内置代理池',
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text(
                        '打开才走代理（自动挑最快的节点）；关闭一律直连',
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: 11,
                            height: 1.4),
                      ),
                    ],
                  ),
                ),
                AppSwitch(
                  value: _tg.proxyOn,
                  onChanged: _probeBusy ? null : _togglePool,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _field(_proxyHostCtrl, 'SOCKS5 地址（可空）')),
              const SizedBox(width: 8),
              SizedBox(
                  width: 96,
                  child: _field(_proxyPortCtrl, '端口',
                      keyboard: TextInputType.number)),
            ]),
            const SizedBox(height: 6),
            Text(
              '手机开着「全局 VPN」（Shadowrocket / Surge / QuantumultX 的 VPN 模式）时，'
              '这里留空、开关关闭即可 —— App 和内置 Node 的请求都会自动走系统 VPN；'
              '只有「Wi-Fi 设置里填的 HTTP 代理」Node 读不到，那种才需要在这里填 SOCKS5。',
              style: TextStyle(
                  color: AppTheme.textTertiary, fontSize: 11, height: 1.5),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _probeBusy ? null : () => _probeProxy(),
                    icon: _probeBusy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.bolt_rounded, size: 16),
                    label: Text(_probeBusy ? '测速中，约 20 秒…' : '内置代理 · 自动测速'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _probeBusy ? null : () => _applyProxy('', ''),
                  child: const Text('不用代理'),
                ),
              ],
            ),
            const SizedBox(height: 2),
            // 直接回答"现在到底能不能看公开频道"：
            // 按当前设置（内置代理开关 + 系统 VPN）打一次 t.me
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _netTesting ? null : _testTme,
                icon: _netTesting
                    ? const SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering_rounded, size: 16),
                label: Text(_netTesting ? '正在测 t.me…' : '测 t.me 连通（公开频道要用）'),
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '内置列表来自 watchttvv/free-proxy-list（gh-proxy 加速）。选好后：'
              '公开频道的网页抓取、封面、播放中转都会走这个代理。',
              style: TextStyle(
                  color: AppTheme.textTertiary, fontSize: 11, height: 1.5),
            ),
          ],
        ),
      ),
    ));
  }

  /// 标题筛选卡（用户 2026-10-25：「不要写死，加个筛选功能」）——
  /// 内置一条「去掉带表情符号的名称」，其余排除词由用户自己填；
  /// 公开频道 / 登录频道共用这一套规则。
  Widget _filterCard() {
    return ListenableBuilder(
      listenable: TgTitleFilter.instance,
      builder: (context, _) {
        final f = TgTitleFilter.instance;
        return _card(AppCard(
          dense: true,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('去掉带表情符号的名称',
                              style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('内置规则：标题里带 emoji 的整条隐藏',
                              style: TextStyle(
                                  color: AppTheme.textTertiary,
                                  fontSize: 11,
                                  height: 1.4)),
                        ],
                      ),
                    ),
                    AppSwitch(
                      value: f.blockEmoji,
                      onChanged: (v) => f.setBlockEmoji(v),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text('自定义排除词（名称包含任一词就隐藏）',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: _field(_filterCtrl, '例如：贷款 / 博彩 / 国际 / 信誉'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () async {
                        await f.addWord(_filterCtrl.text);
                        _filterCtrl.clear();
                      },
                      child: const Text('添加'),
                    ),
                  ],
                ),
                if (f.words.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      for (final w in f.words)
                        InputChip(
                          label: Text(w, style: const TextStyle(fontSize: 12)),
                          onDeleted: () => f.removeWord(w),
                          deleteIcon: const Icon(Icons.close, size: 14),
                          backgroundColor: AppTheme.backgroundTertiary,
                          side: BorderSide(
                              color: AppTheme.borderLight, width: 0.6),
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 8),
                Text('只影响列表显示，不改动频道里的原帖。',
                    style: TextStyle(
                        color: AppTheme.textTertiary, fontSize: 11)),
              ],
            ),
          ),
        ));
      },
    );
  }

  Widget _configCard() {
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('扫码登录',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '直接点下面的「生成二维码」，用手机 Telegram 扫一下就登录，'
              '不需要验证码、也不需要自己申请应用。',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12, height: 1.5),
            ),
            if (_showAdvanced) ...[
              const SizedBox(height: 14),
              Text('应用凭据（已内置，可留空）',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                '只有想把登录身份换成自己的才需要填：'
                'my.telegram.org → API development tools 创建应用。',
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: 11, height: 1.5),
              ),
              const SizedBox(height: 8),
              _field(_apiIdCtrl, 'api_id（纯数字，留空用内置）',
                  keyboard: TextInputType.number),
              const SizedBox(height: 8),
              _field(_apiHashCtrl, 'api_hash（32 位，留空用内置）'),
              const SizedBox(height: 12),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: _busy ? null : _saveConfig,
                child: Text(_busy ? '保存中…' : '保存并测试'),
              ),
            ),
          ],
        ),
      ),
    ));
  }

  Widget _loginCard() {
    final png = TgService.decodeQr((_qr['png'] ?? '') as String);
    final needPw = _phase == 'need_password';
    final waiting = _phase == 'waiting';
    final error = (_qr['error'] ?? '') as String;

    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('手机扫码登录',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(
              '手机 Telegram → 设置 → 设备 → 链接桌面设备 → 扫下面的码。'
              '不需要验证码，也不需要用主号。',
              style: TextStyle(color: AppTheme.textTertiary, fontSize: 12, height: 1.5),
            ),
            const SizedBox(height: 14),
            Center(
              child: png == null
                  ? FilledButton.icon(
                      onPressed: _busy ? null : _startQr,
                      icon: const Icon(Icons.qr_code_2),
                      label: Text(_busy ? '生成中…' : '生成二维码'),
                    )
                  : Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Image.memory(
                        Uint8List.fromList(png),
                        width: 220,
                        height: 220,
                        gaplessPlayback: true,
                        errorBuilder: (_, __, ___) => const SizedBox(
                            width: 220,
                            height: 220,
                            child: Center(child: Text('二维码渲染失败'))),
                      ),
                    ),
            ),
            if (waiting) ...[
              const SizedBox(height: 10),
              Center(
                child: Text('等待扫码…（过期会自动刷新）',
                    style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
              ),
            ],
            if (needPw) ...[
              const SizedBox(height: 14),
              _PasswordBox(onSubmit: _submitPassword),
            ],
            if (error.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(error,
                  style: const TextStyle(color: Colors.orangeAccent, fontSize: 12)),
              const SizedBox(height: 8),
              Center(
                child: TextButton(
                  onPressed: _startQr,
                  child: const Text('重试'),
                ),
              ),
            ],
          ],
        ),
      ),
    ));
  }

  Widget _manualCard() {
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('直接填群 / 频道',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _field(_peerCtrl, '@用户名 或 -100xxxxxxxxxx'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final p = _normalizePeer(_peerCtrl.text);
                    if (p.isEmpty) {
                      AppToast.message('先填群 ID 或用户名');
                      return;
                    }
                    // 存进「我添加的登录频道」—— 用户 2026-10-25：
                    // 只显示自己填过的，不再把账号里的群全列出来
                    await _tg.addChannel(p, title: p, mode: 'login');
                    if (!mounted) return;
                    _peerCtrl.clear();
                    final s = await _tg.channels();
                    if (!mounted) return;
                    setState(() => _saved = s);
                    Get.to(() => TgChannelPage(peer: p, title: p, mode: 'login'));
                  },
                  child: const Text('添加'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text('频道的 @用户名、t.me 链接、或 -100 开头的数字 ID 都行。',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 11)),
          ],
        ),
      ),
    ));
  }

  /// 公开频道收藏（登录模式的那批由 [_channelsCard] 单独显示，
  /// 避免同一个频道在两处重复出现）
  List<Map<String, dynamic>> get _publicSaved => _saved
      .where((c) => (c['mode'] ?? 'public').toString() != 'login')
      .toList();

  /// 已选的登录频道 peer 集合（用于 checkbox 回显）
  Set<String> get _loginPeerSet => _saved
      .where((c) => (c['mode'] ?? 'public').toString() == 'login')
      .map((c) => (c['peer'] ?? '').toString())
      .toSet();

  /// 勾选 / 取消勾选一个群/频道
  Future<void> _toggleLoginChannel(Map<String, dynamic> d) async {
    final peer = (d['peer'] ?? '').toString();
    if (peer.isEmpty) return;
    final title = (d['title'] ?? peer).toString();
    if (_loginPeerSet.contains(peer)) {
      await _tg.removeChannel(peer);
    } else {
      await _tg.addChannel(peer, title: title, mode: 'login');
    }
    await _loadSaved();
  }

  Widget _channelsCard() {
    // 登录后自动加载账号里所有群/频道，用户勾选要哪些（2026-10-26 改回）
    final mine = _saved
        .where((c) => (c['mode'] ?? 'public').toString() == 'login')
        .toList();
    return _card(AppCard(
      dense: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '我的群 / 频道',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: _loadingDialogs ? null : _loadDialogs,
                  icon: _loadingDialogs
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh, size: 15),
                  label: Text('刷新${_allDialogs.isNotEmpty ? '（${_allDialogs.length}）' : ''}',
                      style: const TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ),
          if (_loadingDialogs && _allDialogs.isEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: CircularProgressIndicator()),
            ),
          ] else if (_allDialogs.isEmpty) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: Text('没拉到群/频道，点右上角刷新',
                    style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
              ),
            ),
          ] else ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                '勾选要显示的频道（已选 ${mine.length} 个）',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 11),
              ),
            ),
            const SizedBox(height: 4),
            // 一行两个的**卡片**（用户 2026-10-27：这一列竖排太长，改成网格）
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
              child: _dialogGrid(_allDialogs),
            ),
          ],
          if (mine.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Text('已选频道（点击播放）',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: _savedGrid(mine),
            ),
          ],
        ],
      ),
    ));
  }

  /// 公开频道 / 收藏频道管理
  ///
  /// 公开频道**不需要登录**：贴 @用户名 就能在「TG」分类里看。
  /// 这里同时管登录模式收藏（只有标题/删除，不能再改模式）。
  Widget _savedCard() {
    return _card(AppCard(
      dense: true,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('不需要登录，贴频道名即可',
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _field(_pubCtrl, '@频道名 或 t.me/频道名')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final p = _normalizePeer(_pubCtrl.text);
                    if (p.isEmpty) {
                      AppToast.message('先填频道名');
                      return;
                    }
                    await _tg.addChannel(p, title: p, mode: 'public');
                    _pubCtrl.clear();
                    await _loadSaved();
                  },
                  child: const Text('添加'),
                ),
              ],
            ),
            if (_publicSaved.isEmpty) ...[
              const SizedBox(height: 12),
              Text('还没有收藏的频道',
                  style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
            ] else ...[
              const SizedBox(height: 8),
              _savedGrid(_publicSaved),
            ],
          ],
        ),
      ),
    ));
  }

  Widget _savedRow(Map<String, dynamic> c) {
    final peer = (c['peer'] ?? '').toString();
    final mode = (c['mode'] ?? 'public').toString();
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        // 登录频道的播放走 MTProto，没扫码时点进去只会转圈（日志里的 500）
        if (mode == 'login' && !_authorized) {
          AppToast.message('这是登录频道：先扫码登录再打开');
          return;
        }
        Get.to(() => TgChannelPage(
          peer: peer,
          title: (c['title'] ?? peer).toString(),
          mode: mode,
        ));
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: AppTheme.borderLight.withValues(alpha: 0.6), width: 0.6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(mode == 'login' ? Icons.lock_outline : Icons.public,
                    size: 14, color: AppTheme.textTertiary),
                const Spacer(),
                InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () async {
                    await _tg.removeChannel(peer);
                    await _loadSaved();
                  },
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Icon(Icons.close_rounded,
                        size: 14, color: AppTheme.textTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              (c['title'] ?? peer).toString(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 1),
            Text('@$peer',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  /// 频道收藏的**两列卡片网格**（用户 2026-10-25：「添加源要一行两列网格式」）
  Widget _savedGrid(List<Map<String, dynamic>> list) {
    return GridView.count(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      crossAxisCount: 2,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.35,
      children: [for (final c in list) _savedRow(c)],
    );
  }

  /// 「我的群 / 频道」勾选用的单张卡片
  ///
  /// 用户 2026-10-27：这串 CheckboxListTile 竖排一长条太难找，也改成一行两个。
  Widget _dialogCard(Map<String, dynamic> d) {
    final peer = (d['peer'] ?? '').toString();
    final title = (d['title'] ?? peer).toString();
    final on = _loginPeerSet.contains(peer);
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => _toggleLoginChannel(d),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: on
              ? AppTheme.accentOnSurface.withValues(alpha: 0.14)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on
                ? AppTheme.accentOnSurface
                : AppTheme.borderLight.withValues(alpha: 0.6),
            width: on ? 1 : 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(on ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 15,
                    color:
                        on ? AppTheme.accentOnSurface : AppTheme.textTertiary),
                const Spacer(),
                Icon(Icons.lock_outline,
                    size: 12, color: AppTheme.textTertiary),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12.5,
                  fontWeight: on ? FontWeight.w600 : FontWeight.w500),
            ),
            const SizedBox(height: 1),
            Text('@$peer',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 10)),
          ],
        ),
      ),
    );
  }

  /// 「我的群 / 频道」的**两列卡片网格**
  Widget _dialogGrid(List<Map<String, dynamic>> list) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        mainAxisExtent: 72,
      ),
      itemCount: list.length,
      itemBuilder: (_, i) => _dialogCard(list[i]),
    );
  }

  String _normalizePeer(String raw) {
    var p = raw.trim();
    p = p.replaceAll(RegExp(r'^https?://'), '');
    p = p.replaceAll(RegExp(r'^(www\.)?(t|telegram)\.me/'), '');
    p = p.replaceAll(RegExp(r'^s/'), '');
    p = p.replaceAll(RegExp(r'^@'), '');
    p = p.replaceAll(RegExp(r'[/?#].*$'), '');
    return p;
  }

  Widget _hintCard() {
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 20),
      child: Text(
        '说明：只使用你自己的账号与已加入的频道；内容由频道决定。'
        '播放走本机回环代理，支持拖动进度条。',
        style: TextStyle(color: AppTheme.textTertiary, fontSize: 11, height: 1.6),
      ),
    );
  }

  Widget _field(TextEditingController c, String hint,
      {TextInputType? keyboard}) {
    return TextField(
      controller: c,
      keyboardType: keyboard,
      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
        isDense: true,
        filled: true,
        fillColor: AppTheme.backgroundTertiary,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

/// 两步验证密码输入（只在账号强制 2FA 时出现）
class _PasswordBox extends StatefulWidget {
  const _PasswordBox({required this.onSubmit});
  final Future<void> Function(String) onSubmit;

  @override
  State<_PasswordBox> createState() => _PasswordBoxState();
}

class _PasswordBoxState extends State<_PasswordBox> {
  final _c = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('该账号启用了两步验证，请输入密码',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 12)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _c,
                obscureText: _obscure,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                decoration: InputDecoration(
                  hintText: '两步验证密码',
                  hintStyle:
                      TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                  isDense: true,
                  filled: true,
                  fillColor: AppTheme.backgroundTertiary,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(
                        _obscure ? Icons.visibility_off : Icons.visibility,
                        size: 18,
                        color: AppTheme.textTertiary),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: () => widget.onSubmit(_c.text),
              child: const Text('提交'),
            ),
          ],
        ),
      ],
    );
  }
}
