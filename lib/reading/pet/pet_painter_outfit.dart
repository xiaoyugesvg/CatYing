part of 'pet_view.dart';

/// 矢量宠物「穿戴」绘制 —— 适配层（2026-10-27）。
///
/// 换装收敛成三类（节日头饰 / 眼镜 / 衣服）后，真正的绘制逻辑统一挪到
/// `PetOutfitPainter`（位置全部由 `BlobGeo` 从椭圆反解，保证贴轮廓）。
/// 这个 mixin 只剩一件事：把水墨画笔的 100×100 坐标系（企鹅头中心 ≈ (50,46)、
/// 身子 24~86）近似成一颗圆团，再交给 `PetOutfitPainter` 画。
///
/// ⚠️ 水墨画笔目前**不可达**：`PetSpecies.pets` 只有 6 只圆团，
/// `PetService.load` 会把其它物种一律迁到小Q（见 pet_service.dart）。
/// 保留它只是为了编译完整 + 万一以后要恢复；真要瘦身，整块
/// `pet_painter.dart` / `pet_painter_body.dart` / 本文件（约 1000 行）可以直接删。
mixin _PetOutfitPaint on _InkPetPainterBase {
  void _drawOutfits(Canvas c, Color main, Color light, Color accent) {
    if (outfits.isEmpty) return;
    // 头中心 (50,46) + 身子到 86 ⇒ 近似一颗中心 (50,60)、宽 62、高 58 的团子。
    // 1 单位 = 1 像素，所以直接 translate 到团子中心即可。
    const geo = BlobGeo(w: 62, h: 58, y: 10);
    c.save();
    c.translate(50, 50);
    PetOutfitPainter(outfits: outfits, geo: geo).paintAll(c);
    c.restore();
  }
}
