import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reader/core/models.dart';
import 'package:reader/core/store.dart';
import 'package:reader/ui/format.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> fixture(String name, {bool envelope = true}) {
  final j = jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map<String, dynamic>;
  return envelope ? j['results'] as Map<String, dynamic> : j;
}

ComicDetail detailWith(int count, {String status = '連載中', String last = '第16话'}) {
  final j = fixture('detail.json', envelope: false);
  final comic = Map<String, dynamic>.from(j['comic'] as Map)
    ..['status'] = {'value': 0, 'display': status}
    ..['last_chapter'] = {'uuid': 'x', 'name': last};
  return ComicDetail.fromJson({
    ...j,
    'comic': comic,
    'groups': {
      'default': {'path_word': 'default', 'name': '默認', 'count': count},
    },
  });
}

void main() {
  group('章节', () {
    test('特别篇与公告标签（名称不改）', () {
      expect(chapterTag('第245话'), '');
      expect(chapterTag('R48话'), '');
      expect(chapterTag('第12话后篇'), '');
      expect(chapterTag('第01卷'), '');
      expect(chapterTag('2024龙年贺图'), '特别篇');
      expect(chapterTag('人气投票'), '特别篇');
      expect(chapterTag('休刊通知'), '公告');
      expect(chapterTag('新245话 第二次重画'), '重绘');
    });

    test('每 100 条一段', () {
      expect(chapterRanges(305), [(0, 100), (100, 100), (200, 100), (300, 5)]);
      expect(chapterRanges(100), [(0, 100)]);
      expect(chapterRanges(0), isEmpty);
    });
  });

  group('模型', () {
    test('详情：章节总数、完结状态、别名', () {
      final d = detailWith(16);
      expect(d.chapterCount, 16);
      expect(d.finished, isFalse);
      expect(detailWith(16, status: '已完結').finished, isTrue);
      expect(d.aliases, isNot(contains(d.comic.name)));
    });

    test('排行：sort_last 为 0 是新上榜', () {
      final r = RankItem.fromJson({
        'sort': 3,
        'sort_last': 0,
        'comic': {'name': 'a', 'path_word': 'a', 'cover': ''},
      });
      expect(r.isNew, isTrue);
      final up = RankItem.fromJson({
        'sort': 5,
        'sort_last': 7,
        'comic': {'name': 'b', 'path_word': 'b', 'cover': ''},
      });
      expect(up.isNew, isFalse);
      expect(up.rise, 2);
    });

    test('搜索结果：只显示明显不同的别名', () {
      expect(const ComicBrief(name: '魔王但丁', pathWord: 'x', cover: '', alias: 'Demon Lord Dante,魔王但丁').distinctAlias, 'Demon Lord Dante');
      expect(const ComicBrief(name: '魔王交換!!', pathWord: 'x', cover: '', alias: '魔王交换!!').distinctAlias, isNull);
    });

    test('省流画质替换图片尺寸', () {
      const url = 'https://sn.mangafunb.fun/n/a/1.jpg.h1500x.jpg';
      expect(imageUrlFor(url, saver: true), 'https://sn.mangafunb.fun/n/a/1.jpg.h800x.jpg');
      expect(imageUrlFor(url, saver: false), url);
    });
  });

  group('追更', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await initStores();
    });

    test('追更后同步到新章节，显示新 N 话；阅读后清零', () {
      final store = LibraryStore.instance;
      final pw = detailWith(16).comic.pathWord;
      store.follow(detailWith(16));
      expect(store.entry(pw)!.newCount, 0);

      store.applyRemote(detailWith(18, last: '第18话'));
      final e = store.entry(pw)!;
      expect(e.hasUpdate, isTrue);
      expect(e.newCount, 2);
      expect(e.latestChapter, '第18话');

      store.recordPosition(id: pw, create: () => e, chapterUuid: 'u', chapterName: '第17话', chapterIndex: 16, page: 3, pageCount: 10, progress: .4);
      expect(store.entry(pw)!.hasUpdate, isFalse);
      expect(store.entry(pw)!.chapterIndex, 16);
    });

    test('旧数据第一次同步不会把整部作品当成新话', () {
      final store = LibraryStore.instance;
      final d = detailWith(221);
      store.put(ShelfEntry(id: d.comic.pathWord, kind: ShelfKind.manga, name: d.comic.name, cover: '', author: ''));
      store.applyRemote(d);
      expect(store.entry(d.comic.pathWord)!.hasUpdate, isFalse);
    });

    test('打开详情（seen）清掉更新标记', () {
      final store = LibraryStore.instance;
      final pw = detailWith(16).comic.pathWord;
      store.follow(detailWith(16));
      store.applyRemote(detailWith(20));
      expect(store.entry(pw)!.newCount, 4);
      store.applyRemote(detailWith(20), seen: true);
      expect(store.entry(pw)!.newCount, 0);
    });

    test('清除阅读记录保留书架和追更状态', () {
      final store = LibraryStore.instance;
      final d = detailWith(16);
      store.follow(d);
      store.recordPosition(id: d.comic.pathWord, create: () => store.entry(d.comic.pathWord)!, chapterUuid: 'u', chapterName: '第1话', progress: 1);
      store.markRead(d.comic.pathWord, 'u');
      expect(store.readChapterCount, 1);
      store.clearHistory();
      final e = store.entry(d.comic.pathWord)!;
      expect(e.started, isFalse);
      expect(e.latestCount, 16);
      expect(store.readChapterCount, 0);
    });

    test('阅读只记位置，不会自动追更', () {
      final store = LibraryStore.instance;
      final d = detailWith(16);
      final pw = d.comic.pathWord;
      ShelfEntry create() => ShelfEntry(id: pw, kind: ShelfKind.manga, name: d.comic.name, cover: '', author: '', followed: false);
      store.recordPosition(id: pw, create: create, chapterUuid: 'u', chapterName: '第3话', chapterIndex: 2, page: 4, pageCount: 10, progress: .5);
      expect(store.entry(pw)!.page, 4);
      expect(store.isFollowed(pw), isFalse);
      expect(store.entries, isEmpty);

      // 读过之后再追更：保留阅读位置。
      store.follow(d);
      expect(store.isFollowed(pw), isTrue);
      expect(store.entries.single.chapterName, '第3话');

      // 取消追更：移出书架，但还记得读到哪。
      store.unfollow(pw);
      expect(store.entries, isEmpty);
      expect(store.entry(pw)!.chapterName, '第3话');

      // 清除阅读记录：没追更的作品整条删掉。
      store.clearHistory();
      expect(store.entry(pw), isNull);
    });

    test('没读过的作品取消追更后不留记录；旧数据默认已追更', () {
      final store = LibraryStore.instance;
      final d = detailWith(16);
      store.follow(d);
      store.unfollow(d.comic.pathWord);
      expect(store.entry(d.comic.pathWord), isNull);
      expect(ShelfEntry.fromJson({'id': 'x', 'kind': 'manga', 'name': 'x'}).followed, isTrue);
    });

    test('搜索历史去重、最多 8 条、新的在前', () {
      final p = ReaderPrefs.instance;
      for (final q in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'b']) {
        p.addSearch(q);
      }
      expect(p.searchHistory.first, 'b');
      expect(p.searchHistory.length, 8);
      expect(p.searchHistory.where((s) => s == 'b').length, 1);
    });
  });

  group('格式', () {
    final now = DateTime(2026, 11, 3, 12);
    test('日期', () {
      expect(formatDay('2026-11-03', now: now), '今天');
      expect(formatDay('2026-11-02', now: now), '昨天');
      expect(formatDay('2026-10-08', now: now), '10月8日');
      expect(formatDay('2025-01-05', now: now), '2025年1月');
    });

    test('人气与大小', () {
      expect(formatPopular(15487239), '1549万');
      expect(formatPopular(128300), '12.8万');
      expect(formatPopular(552), '552');
      expect(formatBytes(19293798), '18.4 MB');
    });
  });
}
