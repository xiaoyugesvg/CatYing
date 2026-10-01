# -*- coding: utf-8 -*-
"""① 皎月白 → 宣纸色系（浅色背景统一宣纸米白，与水墨书香调色板一致）；
② theme.dart textSecondary/textTertiary 深浅两档透明度提高（列表/卡片文字对比度）。"""
import io

def patch(path, old, new):
    with io.open(path, 'r', encoding='utf-8', newline='') as f:
        s = f.read()
    assert s.count(old) == 1, (path, old[:60], s.count(old))
    s = s.replace(old, new)
    with io.open(path, 'w', encoding='utf-8', newline='') as f:
        f.write(s)

# ① 皎月白 → 宣纸色系（保持三档渐变结构）
patch(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\services\background_service.dart',
    """  /// 皎月白
  static const List<Color> _moonWhite = [
    Color(0xFFF7F4EF),
    Color(0xFFE8E4DC),
    Color(0xFFD9D4C8),
  ];""",
    """  /// 皎月白 —— 已统一为「宣纸色系」（跟随水墨书香调色板，浅色底色不再发灰）
  /// #F7F5F1 宣纸米白 → #F1EDE3 → #E9E3D6，与 JellyPalette.backgroundLight 同源观感。
  static const List<Color> _moonWhite = [
    Color(0xFFF7F5F1),
    Color(0xFFF1EDE3),
    Color(0xFFE9E3D6),
  ];""",
)

# ② 文字透明度提高（深浅两档）
patch(
    r'C:\Users\24647\AppData\Local\Temp\New-Tv\lib\common\theme.dart',
    """  /// 次要文字：原先是半透明黑/白；这里用调色板的中灰 + 同等的"弱化"强度
  static Color get textSecondary =>
      _palette.textSecondary.withValues(alpha: _light ? 0.85 : 0.75);
  static Color get textTertiary =>
      _palette.textSecondary.withValues(alpha: _light ? 0.55 : 0.50);""",
    """  /// 次要文字：原先是半透明黑/白；这里用调色板的中灰 + 同等的"弱化"强度。
  /// 2026-10-01 提高深浅两档透明度（列表/卡片文字对比度不足：深色下太暗、浅色宣纸底上太浅）
  static Color get textSecondary =>
      _palette.textSecondary.withValues(alpha: _light ? 0.92 : 0.84);
  static Color get textTertiary =>
      _palette.textSecondary.withValues(alpha: _light ? 0.68 : 0.64);""",
)

print('DONE')
