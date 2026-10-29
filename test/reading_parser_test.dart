import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tvbox/reading/models/book_content.dart';
import 'package:tvbox/reading/services/book_parser.dart';

/// 阅读解析管线的真实验证。
///
/// 为什么必须测：阅读器能不能打开一本书，全看 `BookParser` 能否把
/// TXT / EPUB 正确解成 `BookContent`（章节 + 内容块）。
/// 中文 TXT 大量是 **GBK** 编码 —— 解错就是满屏乱码。
void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('book_parser_test'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 把一个章节的内容块拼成纯文本，便于断言
  String textOf(BookChapter c) => c.blocks
      .whereType<ParagraphBlock>()
      .map((b) => b.text)
      .join('\n');

  test('TXT(UTF-8)：一行一段，全部内容不丢', () {
    const raw = '''
第一章 起点
这是第一章的正文。
有好几行。

第二章 转折
第二章的正文在这里。
''';
    final c = BookParser.buildTxtContent((raw, '测试书'));

    // ⚠️ cmbok 的设计：TXT **不按「第N章」切章**，整本作单章，
    // 每行一个 ParagraphBlock，靠分页器浏览。
    // （所以这里断言的是"内容完整"，不是"切出 N 章"。）
    expect(c.chapters.length, 1, reason: 'TXT 按设计是单章');
    expect(c.title, '测试书');

    final all = textOf(c.chapters.first);
    // 每一行都要保留（空行会被跳过，这是预期的）
    expect(all, contains('第一章 起点'));
    expect(all, contains('这是第一章的正文。'));
    expect(all, contains('第二章 转折'));
    expect(all, contains('第二章的正文在这里。'));

    // 段落数 = 非空行数（每行一段，空行跳过）
    // 注意整串开头有个换行会被 trim 掉，所以实际是 5 段
    final paras = c.chapters.first.blocks.whereType<ParagraphBlock>().length;
    expect(paras, 5, reason: '5 行非空文本 → 5 段');
  });

  test('TXT 解码：合法 UTF-8 正常，非法字节回落 GBK 不崩', () {
    // 合法 UTF-8
    final utf8Bytes = Uint8List.fromList(utf8.encode('第一章 测试\n中文正文内容。'));
    final s = BookParser.decodeTxtBytes(utf8Bytes);
    expect(s, contains('第一章'));
    expect(s, contains('中文正文内容'));

    // 「第一章」的 GBK 字节（非法 UTF-8）→ 必须走 GBK 回落，不能抛
    final gbkBytes = Uint8List.fromList(
        [0xB5, 0xDA, 0xD2, 0xBB, 0xD5, 0xC2, 0x0A]);
    final r = BookParser.decodeTxtBytes(gbkBytes);
    expect(r, isNotEmpty, reason: 'GBK 回落应产出内容而非空串');
    // 正确解出来应当是「第一章」
    expect(r.trim(), '第一章', reason: 'GBK 解码结果应正确');
  });

  test('EPUB：真实 zip 结构能解析出章节（含内嵌图片）', () async {
    final epub = File('${tmp.path}/mini.epub');
    epub.writeAsBytesSync(_buildMinimalEpub());

    final c = BookParser.parseEpubBytes(Uint8List.fromList(epub.readAsBytesSync()));

    expect(c.title, isNotEmpty, reason: '应从 OPF 读到书名');
    expect(c.chapters.length, 2, reason: '应解析出 2 章');
    expect(c.chapters[0].title, contains('第一章'));
    expect(textOf(c.chapters[0]), contains('EPUB 第一章正文'));
    expect(textOf(c.chapters[1]), contains('EPUB 第二章正文'));
    // 内嵌图片应被收集
    expect(c.images.isNotEmpty, isTrue, reason: '内嵌图片应进 images 表');
  });

  test('MOBI：明确抛「不支持」而不是静默返回空', () {
    // MOBI 支持已按硬约束移除（kindle_unpack 是额外依赖）。
    // 关键是不能静默失败 —— 否则用户看到空白页却不知原因。
    final f = File('${tmp.path}/x.mobi')..writeAsBytesSync([1, 2, 3]);
    expect(
      () => BookParser.parseMobiWithRatios(f),
      throwsA(isA<UnsupportedError>()),
    );
  });
}

/// 手工构造一个最小合法 EPUB（zip 结构），用于离线验证解析器。
///
/// 结构：
///   mimetype
///   META-INF/container.xml     → 指向 OPF
///   OEBPS/content.opf          → 元数据 + manifest + spine
///   OEBPS/ch1.xhtml / ch2.xhtml → 两章正文
///   OEBPS/cover.png            → 一张 1x1 PNG（验证图片收集）
List<int> _buildMinimalEpub() {
  final archive = Archive();

  void addText(String path, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(path, bytes.length, bytes));
  }

  addText('mimetype', 'application/epub+zip');

  addText('META-INF/container.xml', '''
<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''');

  addText('OEBPS/content.opf', '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>最小测试书</dc:title>
    <dc:creator>测试作者</dc:creator>
  </metadata>
  <manifest>
    <item id="ch1" href="ch1.xhtml" media-type="application/xhtml+xml"/>
    <item id="ch2" href="ch2.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover" href="cover.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="ch1"/>
    <itemref idref="ch2"/>
  </spine>
</package>
''');

  addText('OEBPS/ch1.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第一章</title></head>
<body><h1>第一章 开始</h1><p>EPUB 第一章正文</p></body></html>
''');

  addText('OEBPS/ch2.xhtml', '''
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>第二章</title></head>
<body><h1>第二章 结束</h1><p> EPUB 第二章正文</p></body></html>
''');

  // 1x1 透明 PNG
  final png = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ]);
  archive.addFile(ArchiveFile('OEBPS/cover.png', png.length, png));

  return ZipEncoder().encode(archive) ?? const [];
}
