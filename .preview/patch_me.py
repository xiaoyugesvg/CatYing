# -*- coding: utf-8 -*-
"""我的页（me_page.dart）：
① import zlibrary_service + zlibrary_auth_page；
② 标题行下加账号卡（登录态：头像/邮箱/配额；未登录：登录引导+立即登录）；
③ 菜单末尾加「捐赠与支持」入口 + 弹窗。"""
import io

path = r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\reading\pages\me_page.dart'
with io.open(path, 'r', encoding='utf-8', newline='') as f:
    s = f.read()
eol = '\r\n' if '\r\n' in s else '\n'

def rep(old, new):
    global s
    n = s.count(old)
    assert n == 1, (old[:60], n)
    s = s.replace(old, new)

# 1) import
rep(
    "import '../services/settings_service.dart';" + eol +
    "import '../services/theme_switch.dart';",
    "import '../services/settings_service.dart';" + eol +
    "import '../services/theme_switch.dart';" + eol +
    "import '../services/zlibrary_service.dart';",
)
rep(
    "import 'book_source_repo_page.dart';" + eol +
    "import 'source_repo_page.dart';",
    "import 'book_source_repo_page.dart';" + eol +
    "import 'source_repo_page.dart';" + eol +
    "import 'zlibrary_auth_page.dart';",
)

# 2) 标题行后插入账号卡
rep(
    "                  _buildThemeToggle(isDark),\n"
    "                ],\n"
    "              ),\n"
    "            ),\n"
    "            LayoutBuilder(",
    "                  _buildThemeToggle(isDark),\n"
    "                ],\n"
    "              ),\n"
    "            ),\n"
    "            _buildAccountCard(isDark),\n"
    "            LayoutBuilder(",
)

# 3) 账号卡 + 捐赠弹窗方法（插在暗色模式切换注释前）
rep(
    "  // -------------------- 暗色模式切换 --------------------\n",
    "  /// 顶部账号卡：已登录显示头像/邮箱/配额；未登录显示登录引导（参考目标样式）\n"
    "  Widget _buildAccountCard(bool isDark) {\n"
    "    return ListenableBuilder(\n"
    "      listenable: ZlibraryService(),\n"
    "      builder: (context, _) {\n"
    "        final z = ZlibraryService();\n"
    "        final logged = z.isLoggedIn;\n"
    "        final limit = logged\n"
    "            ? (z.serverDownloadsLimit ?? ZlibraryService.loggedDailyLimit)\n"
    "            : ZlibraryService.builtinDailyLimit;\n"
    "        final used = logged ? z.loggedCountToday : z.builtinCountToday;\n"
    "        final fg = isDark ? Colors.white : JellyTheme.textPrimaryLight;\n"
    "        final sub = isDark\n"
    "            ? Colors.white.withValues(alpha: 0.55)\n"
    "            : JellyTheme.textSecondary;\n"
    "        return Padding(\n"
    "          padding: const EdgeInsets.only(bottom: 14),\n"
    "          child: Material(\n"
    "            color: isDark ? JellyTheme.cardDark : Colors.white,\n"
    "            borderRadius: BorderRadius.circular(20),\n"
    "            clipBehavior: Clip.antiAlias,\n"
    "            child: InkWell(\n"
    "              onTap: () => Navigator.push(\n"
    "                context,\n"
    "                MaterialPageRoute(\n"
    "                  builder: (_) => const ZlibraryAuthPage(),\n"
    "                ),\n"
    "              ),\n"
    "              child: Padding(\n"
    "                padding: const EdgeInsets.all(16),\n"
    "                child: Row(\n"
    "                  children: [\n"
    "                    // 头像\n"
    "                    Container(\n"
    "                      width: 52,\n"
    "                      height: 52,\n"
    "                      decoration: BoxDecoration(\n"
    "                        shape: BoxShape.circle,\n"
    "                        color: logged\n"
    "                            ? JellyTheme.primary\n"
    "                            : (isDark\n"
    "                                ? Colors.white.withValues(alpha: 0.10)\n"
    "                                : Colors.black.withValues(alpha: 0.05)),\n"
    "                      ),\n"
    "                      child: logged\n"
    "                          ? Image.asset(\n"
    "                              'assets/icons/user.png',\n"
    "                              width: 40,\n"
    "                              height: 40,\n"
    "                              fit: BoxFit.cover,\n"
    "                              errorBuilder: (_, _, _) => Icon(\n"
    "                                Icons.person_rounded,\n"
    "                                color: Colors.white,\n"
    "                                size: 24,\n"
    "                              ),\n"
    "                            )\n"
    "                          : Icon(\n"
    "                              Icons.person_outline_rounded,\n"
    "                              color: sub,\n"
    "                              size: 26,\n"
    "                            ),\n"
    "                    ),\n"
    "                    const SizedBox(width: 14),\n"
    "                    // 账号信息\n"
    "                    Expanded(\n"
    "                      child: Column(\n"
    "                        crossAxisAlignment: CrossAxisAlignment.start,\n"
    "                        children: [\n"
    "                          Text(\n"
    "                            logged ? z.email : '登录 / 注册',\n"
    "                            style: TextStyle(\n"
    "                              fontSize: 16,\n"
    "                              fontWeight: FontWeight.w700,\n"
    "                              color: fg,\n"
    "                            ),\n"
    "                            maxLines: 1,\n"
    "                            overflow: TextOverflow.ellipsis,\n"
    "                          ),\n"
    "                          const SizedBox(height: 4),\n"
    "                          Text(\n"
    "                            logged\n"
    "                                ? 'z-library 账号 · 点击管理'\n"
    "                                : '登录 z-library 账号，每日可下载 $limit 本',\n"
    "                            style: TextStyle(fontSize: 13, color: sub),\n"
    "                            maxLines: 1,\n"
    "                            overflow: TextOverflow.ellipsis,\n"
    "                          ),\n"
    "                        ],\n"
    "                      ),\n"
    "                    ),\n"
    "                    const SizedBox(width: 8),\n"
    "                    // 右侧：配额 / 立即登录\n"
    "                    logged\n"
    "                        ? Column(\n"
    "                            crossAxisAlignment: CrossAxisAlignment.end,\n"
    "                            children: [\n"
    "                              Text(\n"
    "                                '今日可下 $used/$limit 本',\n"
    "                                style: TextStyle(\n"
    "                                  fontSize: 13,\n"
    "                                  fontWeight: FontWeight.w600,\n"
    "                                  color: fg,\n"
    "                                ),\n"
    "                              ),\n"
    "                              const SizedBox(height: 4),\n"
    "                              Text(\n"
    "                                '点击管理账号',\n"
    "                                style: TextStyle(fontSize: 11, color: sub),\n"
    "                              ),\n"
    "                            ],\n"
    "                          )\n"
    "                        : Container(\n"
    "                            padding: const EdgeInsets.symmetric(\n"
    "                                horizontal: 14, vertical: 8),\n"
    "                            decoration: BoxDecoration(\n"
    "                              color: JellyTheme.primary,\n"
    "                              borderRadius: BorderRadius.circular(16),\n"
    "                            ),\n"
    "                            child: Text(\n"
    "                              '立即登录',\n"
    "                              style: TextStyle(\n"
    "                                fontSize: 13,\n"
    "                                fontWeight: FontWeight.w700,\n"
    "                                color: Colors.white,\n"
    "                              ),\n"
    "                            ),\n"
    "                          ),\n"
    "                  ],\n"
    "                ),\n"
    "              ),\n"
    "            ),\n"
    "          ),\n"
    "        );\n"
    "      },\n"
    "    );\n"
    "  }\n\n"
    "  /// 捐赠与支持弹窗（咸鱼店铺 · 微信/支付宝扫码）\n"
    "  Future<void> _showDonateSheet() async {\n"
    "    await showDialog<void>(\n"
    "      context: context,\n"
    "      builder: (ctx) => AlertDialog(\n"
    "        title: const Text('捐赠与支持'),\n"
    "        content: const Text(\n"
    "          '如果这个 App 对你有帮助，欢迎支持：\\n\\n'\n"
    "          '· 咸鱼店铺：New-Tv 周边\\n'\n"
    "          '· 微信 / 支付宝：扫描店铺二维码即可\\n\\n'\n"
    "          '每一份支持都会用来继续打磨功能。',\n"
    "        ),\n"
    "        actions: [\n"
    "          TextButton(\n"
    "            onPressed: () => Navigator.pop(ctx),\n"
    "            child: const Text('知道了'),\n"
    "          ),\n"
    "        ],\n"
    "      ),\n"
    "    );\n"
    "  }\n\n"
    "  // -------------------- 暗色模式切换 --------------------\n",
)

# 4) 菜单末尾加「捐赠与支持」
rep(
    "                    // 被隐藏导航 tab 入口（导航栏关闭某 tab 时，依次补在\"下载记录\"下方）\n"
    "                    for (var i = 0; i < hiddenTabs.length; i++)\n"
    "                      StaggeredEntrance(\n"
    "                        key: ValueKey(\n"
    "                          '${_session}_hidden_${hiddenTabs[i].name}',\n"
    "                        ),\n"
    "                        index: 9 + i,\n"
    "                        child: SizedBox(\n"
    "                          width: itemWidth,\n"
    "                          child: _buildHiddenTabItem(isDark, hiddenTabs[i]),\n"
    "                        ),\n"
    "                      ),\n"
    "                  ],",
    "                    // 被隐藏导航 tab 入口（导航栏关闭某 tab 时，依次补在\"下载记录\"下方）\n"
    "                    for (var i = 0; i < hiddenTabs.length; i++)\n"
    "                      StaggeredEntrance(\n"
    "                        key: ValueKey(\n"
    "                          '${_session}_hidden_${hiddenTabs[i].name}',\n"
    "                        ),\n"
    "                        index: 9 + i,\n"
    "                        child: SizedBox(\n"
    "                          width: itemWidth,\n"
    "                          child: _buildHiddenTabItem(isDark, hiddenTabs[i]),\n"
    "                        ),\n"
    "                      ),\n"
    "                    // 捐赠与支持（底部入口）\n"
    "                    StaggeredEntrance(\n"
    "                      key: ValueKey('${_session}_donate'),\n"
    "                      index: 9 + hiddenTabs.length,\n"
    "                      child: SizedBox(\n"
    "                        width: itemWidth,\n"
    "                        child: _buildMenuItem(\n"
    "                          isDark,\n"
    "                          icon: Icons.volunteer_activism_rounded,\n"
    "                          iconBg: JellyTheme.primary,\n"
    "                          title: '捐赠与支持',\n"
    "                          subtitle: '咸鱼店铺 · 微信 / 支付宝扫码',\n"
    "                          onTap: _showDonateSheet,\n"
    "                        ),\n"
    "                      ),\n"
    "                    ),\n"
    "                  ],",
)

with io.open(path, 'w', encoding='utf-8', newline='') as f:
    f.write(s)
print('DONE')
