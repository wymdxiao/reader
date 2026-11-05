import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reader/ui/novel_pages.dart';

const _style = TextStyle(fontSize: 19, height: 1.85, letterSpacing: .3);

String _para(int n) => List.generate(40, (i) => '第$n段第${i + 1}行，这一句用来把段落撑长，让分页真的需要切开正文。').join('');

String _textOf(NovelPage p) => p.blocks.whereType<NovelTextBlock>().map((b) => b.text).join();

void main() {
  test('短正文只有一页，且不丢字', () {
    final pages = paginateNovel(['第一段。', '第二段。'], style: _style, width: 320, height: 600);
    expect(pages.length, 1);
    expect(_textOf(pages.first), '第一段。第二段。');
  });

  test('长正文分成多页，拼回去与原文一致（不丢字、不重复）', () {
    final paras = [_para(1), _para(2), _para(3)];
    final pages = paginateNovel(paras, style: _style, width: 320, height: 500);
    expect(pages.length, greaterThan(2));
    expect(pages.map(_textOf).join(), paras.join());
  });

  test('每页内容高度不超过可用高度', () {
    const h = 500.0;
    final pages = paginateNovel([_para(1), _para(2), _para(3), _para(4)], style: _style, width: 320, height: h);
    final tp = TextPainter(textDirection: TextDirection.ltr, textScaler: TextScaler.noScaling);
    final gap = 19 * .9;
    for (final page in pages) {
      var used = 0.0;
      for (final b in page.blocks) {
        if (b is NovelTextBlock) {
          tp.text = TextSpan(text: b.text, style: _style);
          tp.textAlign = TextAlign.justify;
          tp.layout(maxWidth: 320);
          used += tp.height;
          if (b.paragraphEnd) used += gap;
        }
      }
      expect(used, lessThanOrEqualTo(h + .01 + gap));
    }
    tp.dispose();
  });

  test('段落被切开：只有首片段标记 paragraphStart，尾片段标记 paragraphEnd', () {
    final pages = paginateNovel([_para(1)], style: _style, width: 320, height: 400);
    expect(pages.length, greaterThan(1));
    final first = pages.first.blocks.whereType<NovelTextBlock>().toList();
    expect(first.first.paragraphStart, isTrue);
    expect(first.last.paragraphEnd, isFalse); // 被切开了
    final second = pages[1].blocks.whereType<NovelTextBlock>().toList();
    expect(second.first.paragraphStart, isFalse); // 续页不再缩进
  });

  test('插图占一个图片槽位，且不跨页切断', () {
    final pages = paginateNovel(
      ['一段。', const NovelImageBlock('https://a/1.jpg'), '又一段。'],
      style: _style,
      width: 320,
      height: 700,
    );
    final imgs = pages.expand((p) => p.blocks).whereType<NovelImageBlock>().toList();
    expect(imgs.length, 1);
    expect(imgs.first.url, 'https://a/1.jpg');
  });

  test('页数放得下时图片和前后文同页', () {
    final pages = paginateNovel(
      ['一段。', const NovelImageBlock('https://a/1.jpg'), '又一段。'],
      style: _style,
      width: 320,
      height: 900,
    );
    expect(pages.length, 1);
    expect(pages.first.blocks.length, 3);
  });

  test('先把 [插图] 占位换成图片，多的占位直接丢掉', () {
    final blocks = novelBlocksOf(['甲', kNovelImagePlaceholder, '乙', kNovelImagePlaceholder], ['u1']);
    expect(blocks, ['甲', isA<NovelImageBlock>(), '乙']);
  });

  test('空正文不会崩，也不产生空页', () {
    expect(paginateNovel([], style: _style, width: 320, height: 500), isEmpty);
    final pages = paginateNovel(['', '   ', '有效文字'], style: _style, width: 320, height: 500);
    expect(pages.length, 1);
    expect(_textOf(pages.first), '有效文字');
  });

  test('字号变大后页数变多', () {
    final paras = [_para(1), _para(2)];
    final small = paginateNovel(paras, style: _style, width: 320, height: 500);
    final big = paginateNovel(paras, style: _style.copyWith(fontSize: 26, height: 2.0), width: 320, height: 500);
    expect(big.length, greaterThan(small.length));
  });
}
