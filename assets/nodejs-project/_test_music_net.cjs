/**
 * 音乐接口真实实现体检。
 *
 * ── 为什么调真实实现而不是自己拼 URL ──────────────────────────
 * 上一版我手拼 URL 去测，结果测出 3 个"失败"，其中 2 个是我 URL 拼错了
 * （比如 artistSongs 实际是 /api/v1/artist/<id>，我写成了 /artist/songs?id=）。
 * **测实现的真实调用路径才有意义** —— 否则是在测自己的测试脚本。
 *
 * music_source.js 是 ESM，这里直接 import 它（Node 22 支持）。
 */
(async () => {
  const m = await import('file://' + __dirname.replace(/\\/g, '/') + '/src/music_source.js');

  // 注意：这里只测 music_source.js 真正导出的 action。
  // 例如"搜索建议"**不在**引擎里 —— Dart 侧 MusicApi.searchSuggest 是用
  // hotSearch 的结果做前缀过滤实现的（见 music_api.dart），
  // 所以它不该出现在这个 Node 侧体检里（写进来会误报"接口不可用"）。
  const CASES = [
    ['搜索', () => m.search('周杰伦', 5, 0)],
    ['热门搜索', () => m.hotSearch()],
    ['歌手搜索', () => m.searchArtists('周杰伦', 3)],
    ['专辑搜索', () => m.searchAlbums('叶惠美', 3)],
    ['歌手歌曲', () => m.artistSongs(6452, 5)],
    ['歌手专辑', () => m.artistAlbums(6452, 5)],
    ['专辑歌曲', () => m.albumSongs(34720827)],
    ['排行榜列表', () => m.topLists()],
    ['推荐歌单', () => m.personalized(6)],
    ['歌单广场', () => m.playlistSquare(6)],
    ['歌单分类', () => m.playlistCatlist()],
    ['歌单详情', () => m.playlistDetail('3778678')],
    ['新歌速递', () => m.newSongs(5)],
    ['相似歌曲', () => m.simiSongs(186016, 5)],
    ['评论', () => m.comments(186016, 5, 0)],
    ['歌词', () => m.lyric('186016')],
    ['歌曲URL', () => m.songUrl('186016')],
  ];

  let pass = 0;
  for (const [name, fn] of CASES) {
    let line;
    try {
      const r = await fn();
      const ok = r && r.ok !== false;
      if (ok) pass++;
      let d = '';
      if (r) {
        if (Array.isArray(r.list)) d = r.list.length + ' 条';
        else if (r.songs) d = r.songs.length + ' 条';
        else if (r.lyric) d = '歌词 ' + String(r.lyric.lyric || '').length + ' 字符';
        else if (r.playable !== undefined) d = 'playable=' + r.playable + (r.qualityText ? ' ' + r.qualityText : '');
        else if (r.error) d = r.error;
        else d = 'ok';
      }
      line = (ok ? '  [OK]   ' : '  [FAIL] ') + name.padEnd(12) + ' ' + d;
    } catch (e) {
      line = '  [ERR]  ' + name.padEnd(12) + ' ' + String(e.message).slice(0, 70);
    }
    console.log(line);
  }
  console.log('');
  console.log('  结果: ' + pass + '/' + CASES.length
    + (pass === CASES.length ? '  ✅ 音乐接口全部可用' : '  ⚠️ 有接口不可用'));
  process.exit(0);
})();
