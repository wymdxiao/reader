import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../core/api.dart';
import '../core/chapter_browser.dart';
import '../core/config.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../ui/icons.dart';
import '../ui/widgets.dart' show revealChapterRow;
import '../ui/zoomable_page.dart';
import '../ui/motion.dart';
import 'ios_app.dart';
import 'ios_detail.dart' show IosChapterRow;
import 'ios_theme.dart';

class IosReaderPage extends StatefulWidget {
  const IosReaderPage({super.key, required this.comic, required this.group, required this.chapterUuid, this.initialPage = 0});

  final ComicBrief comic;
  final String group;
  final String chapterUuid;
  final int initialPage;

  @override
  State<IosReaderPage> createState() => _IosReaderPageState();
}

class _IosReaderPageState extends State<IosReaderPage> {
  final _prefs = ReaderPrefs.instance;
  final _scroll = ScrollController();
  PageController? _pager;
  ChapterContent? _content;
  String? _error;
  bool _loading = true;
  bool _chrome = true;
  bool _advancing = false;
  int _page = 0;
  int _retry = 0;
  List<GlobalKey> _keys = const [];

  bool get _saver => _prefs.mangaSaver;
  List<String> get _images => [for (final u in _content?.images ?? const <String>[]) imageUrlFor(u, saver: _saver)];
  bool get _scrollMode => _prefs.mangaScroll;
  bool get _rtl => _prefs.mangaRtl;

  @override
  void initState() {
    super.initState();
    _prefs.addListener(_onPrefs);
    SystemChrome.setSystemUIOverlayStyle(kDarkChrome);
    _load(widget.chapterUuid, page: widget.initialPage);
  }

  @override
  void dispose() {
    _prefs.removeListener(_onPrefs);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(pageChrome);
    _pager?.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onPrefs() {
    if (mounted) setState(() {});
  }

  Future<void> _load(String uuid, {int page = 0}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final c = await MangaApi.instance.chapter(widget.comic.pathWord, uuid);
      if (!mounted) return;
      final start = c.images.isEmpty ? 0 : page.clamp(0, c.images.length - 1);
      _pager?.dispose();
      setState(() {
        _content = c;
        _loading = false;
        _advancing = false;
        _page = start;
        _pager = PageController(initialPage: start);
        _keys = List.generate(c.images.length, (_) => GlobalKey());
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      if (_scrollMode && start > 0) WidgetsBinding.instance.addPostFrameCallback((_) => _jumpScroll(start));
      _save();
      _precache(start);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _advancing = false;
          _error = e.toString();
        });
      }
    }
  }

  void _save() {
    final c = _content;
    if (c == null || c.images.isEmpty || c.isLock) return;
    final store = LibraryStore.instance;
    store.recordPosition(
      id: widget.comic.pathWord,
      create: () => ShelfEntry(id: widget.comic.pathWord, kind: ShelfKind.manga, name: widget.comic.name, cover: widget.comic.cover, author: widget.comic.authorText, followed: false),
      chapterUuid: c.chapter.uuid,
      chapterName: c.chapter.name,
      chapterIndex: c.chapter.index,
      group: c.chapter.groupPathWord.isEmpty ? widget.group : c.chapter.groupPathWord,
      page: _page,
      pageCount: c.images.length,
      progress: (_page + 1) / c.images.length,
    );
    if (_page >= c.images.length - 1) store.markRead(widget.comic.pathWord, c.chapter.uuid);
  }

  void _precache(int from) {
    final images = _images;
    for (var i = from + 1; i <= from + 3 && i < images.length; i++) {
      precacheImage(CachedNetworkImageProvider(images[i], headers: AppConfig.imageHeaders), context).ignore();
    }
  }

  void _onPage(int i) {
    final page = math.min(i, math.max(0, _images.length - 1));
    if (page == _page) return;
    setState(() => _page = page);
    _save();
    _precache(page);
  }

  void _setChrome(bool show) {
    setState(() => _chrome = show);
    SystemChrome.setEnabledSystemUIMode(show ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  void _onTapUp(TapUpDetails d) {
    final x = d.globalPosition.dx / MediaQuery.sizeOf(context).width;
    if (_scrollMode || (x > .3 && x < .7)) return _setChrome(!_chrome);
    final forward = _rtl ? x <= .3 : x >= .7;
    _goTo(_page + (forward ? 1 : -1), animate: true);
  }

  void _goTo(int page, {bool animate = false}) {
    final max = _images.length;
    page = page.clamp(0, _scrollMode ? max - 1 : max);
    if (_scrollMode) {
      _jumpScroll(page);
    } else if (_pager?.hasClients ?? false) {
      animate ? _pager!.animateToPage(page, duration: const Duration(milliseconds: 240), curve: Curves.easeOutCubic) : _pager!.jumpToPage(page);
    }
  }

  void _jumpScroll(int page) {
    final ctx = _keys.elementAtOrNull(page)?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx);
      return;
    }
    if (!_scroll.hasClients) return;
    final est = MediaQuery.sizeOf(context).width * 1.45;
    _scroll.jumpTo(math.min(page * est, _scroll.position.maxScrollExtent));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _keys.elementAtOrNull(page)?.currentContext;
      if (c != null) Scrollable.ensureVisible(c);
    });
  }

  /// 条漫：中线所在页为当前页；手指拖着越过底部才接下一话（惯性回弹不算）。
  bool _onScroll(ScrollNotification n) {
    final pulledPastEnd = n.metrics.pixels > n.metrics.maxScrollExtent + 72;
    final byFinger = (n is ScrollUpdateNotification && n.dragDetails != null) || (n is OverscrollNotification && n.dragDetails != null);
    if (byFinger && ((n is OverscrollNotification && n.overscroll > 0) || pulledPastEnd)) {
      final next = _content?.chapter.next;
      if (!_advancing && !_loading && next != null) {
        _advancing = true;
        HapticFeedback.lightImpact();
        _load(next);
      }
      return false;
    }
    if (n is! ScrollUpdateNotification || _keys.isEmpty) return false;
    final mid = MediaQuery.sizeOf(context).height / 2;
    var found = _page;
    final lo = math.max(0, _page - 6), hi = math.min(_keys.length - 1, _page + 6);
    for (var i = lo; i <= hi; i++) {
      final box = _keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.attached) continue;
      if (box.localToGlobal(Offset.zero).dy <= mid) found = i;
    }
    _onPage(found);
    return false;
  }

  void _openChapter(String? uuid) {
    if (uuid != null) _load(uuid);
  }

  @override
  Widget build(BuildContext context) {
    final c = _content;
    return Scaffold(
      backgroundColor: IosColors.dBg,
      body: Stack(
        children: [
          Positioned.fill(child: _body(c)),
          Positioned.fill(
            child: IgnorePointer(
              child: ColoredBox(color: Colors.black.withValues(alpha: (1 - _prefs.mangaBrightness) * .75)),
            ),
          ),
          _topBar(c),
          _bottomPanel(c),
          if (!_chrome && c != null && _images.isNotEmpty) _miniChip(c),
        ],
      ),
    );
  }

  Widget _body(ChapterContent? c) {
    if (_loading) return const Center(child: CupertinoActivityIndicator(color: IosColors.dMuted, radius: 12));
    if (_error != null) {
      return Center(
        child: Unavailable(
          dark: true,
          icon: 'wifiOff',
          title: '这一话没有载入',
          message: _error!,
          actions: [
            AccentButton(
              label: '重试',
              icon: 'refresh',
              onTap: () => _load(c?.chapter.uuid ?? widget.chapterUuid, page: _page),
            ),
          ],
        ),
      );
    }
    if (c == null) return const SizedBox();
    if (c.isLock || c.images.isEmpty) return _locked(c);
    final images = _images;
    if (_scrollMode) {
      return GestureDetector(
        onTap: () => _setChrome(!_chrome),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ListView.builder(
            controller: _scroll,
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            scrollCacheExtent: const ScrollCacheExtent.pixels(2400),
            itemCount: images.length + 1,
            itemBuilder: (context, i) => i == images.length ? _endCard(c, scroll: true) : KeyedSubtree(key: _keys[i], child: _image(images[i], fitWidth: true)),
          ),
        ),
      );
    }
    return PageView.builder(
      controller: _pager,
      reverse: _rtl,
      itemCount: images.length + 1,
      onPageChanged: _onPage,
      itemBuilder: (context, i) => i == images.length ? GestureDetector(onTap: () => _setChrome(!_chrome), child: _endCard(c)) : ZoomablePage(onTapUp: _onTapUp, child: _image(images[i])),
    );
  }

  Widget _image(String url, {bool fitWidth = false}) {
    final w = MediaQuery.sizeOf(context).width;
    return CachedNetworkImage(
      key: ValueKey('$url#$_retry'),
      imageUrl: url,
      httpHeaders: AppConfig.imageHeaders,
      fit: fitWidth ? BoxFit.fitWidth : BoxFit.contain,
      width: fitWidth ? w : null,
      fadeInDuration: const Duration(milliseconds: 120),
      progressIndicatorBuilder: (context, _, p) => SizedBox(
        height: fitWidth ? w * 1.4 : null,
        child: const Center(child: CupertinoActivityIndicator(color: IosColors.dMuted)),
      ),
      errorWidget: (context, _, _) => SizedBox(
        height: fitWidth ? w * 1.4 : null,
        child: Center(
          child: TextAction(
            label: '图片没有载入，点按重试',
            color: IosColors.dInk,
            onTap: () {
              CachedNetworkImage.evictFromCache(url);
              setState(() => _retry++);
            },
          ),
        ),
      ),
    );
  }

  Widget _topBar(ChapterContent? c) {
    final top = MediaQuery.paddingOf(context).top;
    return Positioned(
      top: top + 4,
      left: 16,
      right: 16,
      child: ChromeReveal(
        visible: _chrome,
        dy: -8,
        child: Row(
          children: [
            GlassButton(icon: 'chevronLeft', label: '返回', dark: true, onTap: () => Navigator.pop(context)),
            Expanded(
              child: Column(
                children: [
                  Text(
                    widget.comic.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, color: IosColors.dMuted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c?.chapter.name ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: IosColors.dInk),
                  ),
                ],
              ),
            ),
            GlassButton(icon: 'info', label: '作品详情', dark: true, onTap: () => iosOpenDetail(context, widget.comic)),
          ],
        ),
      ),
    );
  }

  Widget _bottomPanel(ChapterContent? c) {
    final n = _images.length;
    final hasPages = c != null && n > 0 && !c.isLock;
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 16,
      right: 16,
      bottom: (bottom > 0 ? bottom - 4 : 16),
      child: ChromeReveal(
        visible: _chrome,
        dy: 8,
        child: Glass(
          dark: true,
          radius: 28,
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        const TextSpan(text: '第 '),
                        TextSpan(
                          text: hasPages ? '${_page + 1}' : '—',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                        TextSpan(text: hasPages ? ' / $n 页' : ''),
                      ],
                    ),
                    style: const TextStyle(fontSize: 15, color: IosColors.dInk),
                  ),
                  const Spacer(),
                  Text(_scrollMode ? '条漫阅读' : (_rtl ? '单页 · 从右向左' : '单页 · 从左向右'), style: const TextStyle(fontSize: 13, color: IosColors.dMuted)),
                ],
              ),
              Row(
                children: [
                  _chapterArrow('chevronLeft', '上一话', c?.chapter.prev),
                  Expanded(
                    child: Directionality(
                      textDirection: _rtl && !_scrollMode ? TextDirection.rtl : TextDirection.ltr,
                      child: CupertinoSlider(
                        value: hasPages ? _page.toDouble() : 0,
                        max: hasPages ? math.max(1, n - 1).toDouble() : 1,
                        divisions: hasPages && n > 1 ? n - 1 : null,
                        activeColor: IosColors.dInk,
                        onChanged: hasPages && n > 1 ? (v) => setState(() => _page = v.round()) : null,
                        onChangeEnd: hasPages ? (v) => _goTo(v.round()) : null,
                      ),
                    ),
                  ),
                  _chapterArrow('chevronRight', '下一话', c?.chapter.next),
                ],
              ),
              const Divider(height: 1, thickness: .5, color: Color(0x33FFFFFF)),
              SizedBox(
                height: 60,
                child: Row(
                  children: [_tool('list', '目录', c == null ? null : () => _showCatalog(c)), _tool('settings', '阅读设置', _showSettings), _tool('info', '详情', () => iosOpenDetail(context, widget.comic))],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _chapterArrow(String icon, String label, String? uuid) => Pressable(
    onTap: uuid == null ? null : () => _openChapter(uuid),
    semanticLabel: label,
    child: SizedBox.square(
      dimension: 40,
      child: Center(child: AppIcon(icon, size: 18, color: IosColors.dInk, stroke: 2)),
    ),
  );

  Widget _tool(String icon, String label, VoidCallback? onTap) => Expanded(
    child: Pressable(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AppIcon(icon, size: 21, color: IosColors.dInk, stroke: 1.6),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12, color: IosColors.dInk)),
        ],
      ),
    ),
  );

  Widget _miniChip(ChapterContent c) => Positioned(
    left: 0,
    right: 0,
    bottom: MediaQuery.paddingOf(context).bottom + 12,
    child: IgnorePointer(
      child: Center(
        child: Glass(
          dark: true,
          radius: 15,
          shadow: false,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Text('${c.chapter.name} · ${_page + 1} / ${_images.length}', style: const TextStyle(fontSize: 12, color: IosColors.dMuted)),
        ),
      ),
    ),
  );

  /// 话末：阅读完成 + 下一条卡片 + 返回本话 / 目录。
  Widget _endCard(ChapterContent c, {bool scroll = false}) {
    final next = c.chapter.next;
    return Padding(
      padding: EdgeInsets.fromLTRB(24, scroll ? 48 : 0, 24, scroll ? 140 : 0),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: IosColors.dMuted, width: 1.2),
              ),
              child: const Center(child: AppIcon('check', size: 18, color: IosColors.dInk, stroke: 2)),
            ),
            const SizedBox(height: 14),
            const Text('阅读完成', style: TextStyle(fontSize: 13, color: IosColors.dMuted)),
            const SizedBox(height: 6),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: c.chapter.name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const TextSpan(
                    text: ' 完',
                    style: TextStyle(color: IosColors.dMuted),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 28, color: IosColors.dInk),
            ),
            const SizedBox(height: 6),
            Text('本话 ${_images.length} 页', style: const TextStyle(fontSize: 13, color: IosColors.dMuted)),
            const SizedBox(height: 28),
            if (next != null)
              Pressable(
                onTap: () => _openChapter(next),
                child: Glass(
                  dark: true,
                  radius: 22,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('下一条', style: TextStyle(fontSize: 13, color: IosColors.dMuted)),
                            SizedBox(height: 4),
                            Text(
                              '点按或继续滑动',
                              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: IosColors.dInk),
                            ),
                          ],
                        ),
                      ),
                      const Text('接着读', style: TextStyle(fontSize: 15, color: IosColors.dInk)),
                      const SizedBox(width: 4),
                      const AppIcon('chevronRight', size: 14, color: IosColors.dInk, stroke: 2),
                    ],
                  ),
                ),
              )
            else
              const Text('已经是最新一话', style: TextStyle(fontSize: 15, color: IosColors.dMuted)),
            if (scroll && next != null) ...[const SizedBox(height: 16), const Text('继续下滑，自动接上下一条', style: TextStyle(fontSize: 13, color: IosColors.dMuted))],
            const SizedBox(height: 24),
            Glass(
              dark: true,
              radius: 26,
              child: SizedBox(
                height: 52,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Pressable(
                      onTap: () => _goTo(0),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 22),
                        child: Row(
                          children: [
                            AppIcon('chevronLeft', size: 15, color: IosColors.dInk, stroke: 2),
                            SizedBox(width: 6),
                            Text('返回本话', style: TextStyle(fontSize: 15, color: IosColors.dInk)),
                          ],
                        ),
                      ),
                    ),
                    Container(width: .5, height: 22, color: const Color(0x40FFFFFF)),
                    Pressable(
                      onTap: () => _showCatalog(c),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 22),
                        child: Row(
                          children: [
                            AppIcon('list', size: 17, color: IosColors.dInk),
                            SizedBox(width: 6),
                            Text('目录', style: TextStyle(fontSize: 15, color: IosColors.dInk)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _locked(ChapterContent c) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 36),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Glass(
            dark: true,
            radius: 20,
            child: SizedBox.square(
              dimension: 72,
              child: Center(child: AppIcon('lock', size: 26, color: IosColors.dInk)),
            ),
          ),
          const SizedBox(height: 26),
          Text(
            '${widget.comic.name} · ${c.chapter.name}',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: IosColors.dMuted),
          ),
          const SizedBox(height: 8),
          Text(
            c.isLock ? '这一话需要会员' : '这一话暂时没有图片',
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: IosColors.dInk),
          ),
          const SizedBox(height: 10),
          Text(
            c.isLock ? '源站已将这一话标记为付费内容。\nreader不会请求本话的图片。' : '源站没有返回这一话的图片，可以换一话试试。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 15, height: 1.55, color: IosColors.dMuted),
          ),
          const SizedBox(height: 26),
          Pressable(
            onTap: () => _showCatalog(c),
            child: const Glass(
              dark: true,
              radius: 25,
              child: SizedBox(
                width: 220,
                height: 50,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      '回到目录',
                      style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: IosColors.dInk),
                    ),
                    SizedBox(width: 8),
                    AppIcon('list', size: 18, color: IosColors.dInk),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Pressable(
            onTap: () => Navigator.pop(context),
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon('chevronLeft', size: 15, color: IosColors.dInk, stroke: 2),
                  SizedBox(width: 6),
                  Text('返回', style: TextStyle(fontSize: 15, color: IosColors.dInk)),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );

  void _showSettings() => showAppSheet<void>(context, (_) => const _ReadingSettingsSheet());

  void _showCatalog(ChapterContent c) => showAppSheet<void>(
    context,
    (sheet) => _CatalogSheet(
      comic: widget.comic,
      group: c.chapter.groupPathWord.isEmpty ? widget.group : c.chapter.groupPathWord,
      current: c.chapter,
      page: _page,
      pageCount: _images.length,
      onPick: (uuid) {
        Navigator.pop(sheet);
        _load(uuid);
      },
    ),
  );
}

/// 阅读设置：阅读方式、翻页方向、图片画质、页面亮度集中在一个面板。
class _ReadingSettingsSheet extends StatelessWidget {
  const _ReadingSettingsSheet();

  @override
  Widget build(BuildContext context) {
    final p = ReaderPrefs.instance;
    Widget label(String t) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Text(t, style: TextStyle(fontSize: 13, color: IosColors.muted)),
    );
    return ListenableBuilder(
      listenable: p,
      builder: (context, _) => Padding(
        padding: EdgeInsets.fromLTRB(10, 0, 10, MediaQuery.paddingOf(context).bottom + 8),
        child: Glass(
          radius: 32,
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(bottom: 8),
                  decoration: BoxDecoration(color: const Color(0x33000000), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              Row(
                children: [
                  Text(
                    '阅读设置',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: IosColors.ink),
                  ),
                  const Spacer(),
                  TextAction(label: '完成', onTap: () => Navigator.pop(context)),
                ],
              ),
              label('阅读方式'),
              IosSegmented(options: const ['单页', '条漫'], selected: p.mangaScroll ? 1 : 0, onChanged: (i) => p.mangaScroll = i == 1),
              label('翻页方向'),
              IosSegmented(options: const ['从右向左', '从左向右'], selected: p.mangaRtl ? 0 : 1, onChanged: (i) => p.mangaRtl = i == 0),
              label('图片画质'),
              IosSegmented(options: const ['省流', '标准'], selected: p.mangaSaver ? 0 : 1, onChanged: (i) => p.mangaSaver = i == 0),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                decoration: BoxDecoration(color: IosColors.surface, borderRadius: BorderRadius.circular(18)),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Text('页面亮度', style: TextStyle(fontSize: 15, color: IosColors.ink)),
                        const Spacer(),
                        Text('${(p.mangaBrightness * 100).round()}%', style: TextStyle(fontSize: 15, color: IosColors.muted)),
                      ],
                    ),
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoSlider(value: p.mangaBrightness, min: .3, max: 1, activeColor: IosColors.accent, onChanged: (v) => p.mangaBrightness = v),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: EdgeInsets.fromLTRB(4, 10, 4, 0),
                child: Text('源站只提供 800px（省流）和 1500px（标准）两种画质。页面亮度只调暗画面，不改变系统亮度。', style: TextStyle(fontSize: 13, height: 1.45, color: IosColors.muted)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 阅读中的目录：深色面板，分组、条目区间、排序与定位。
class _CatalogSheet extends StatefulWidget {
  const _CatalogSheet({required this.comic, required this.group, required this.current, required this.page, required this.pageCount, required this.onPick});

  final ComicBrief comic;
  final String group;
  final Chapter current;
  final int page;
  final int pageCount;
  final ValueChanged<String> onPick;

  @override
  State<_CatalogSheet> createState() => _CatalogSheetState();
}

class _CatalogSheetState extends State<_CatalogSheet> {
  late final _browser = ChapterBrowser(widget.comic.pathWord)..init(preferGroup: widget.group, locateIndex: widget.current.index);
  final _currentKey = GlobalKey();
  final _firstKey = GlobalKey();
  bool _located = false;

  @override
  void initState() {
    super.initState();
    _browser.addListener(_onBrowser);
  }

  void _onBrowser() {
    if (!_located && !_browser.loading && _browser.items != null) {
      _located = true;
      final index = _browser.items!.indexWhere((c) => c.uuid == widget.current.uuid);
      if (index >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => revealChapterRow(firstKey: _firstKey, targetKey: _currentKey, index: index, rowExtent: 52));
      }
    }
  }

  void _locate() {
    _located = false;
    _browser.locate(widget.current.index, inGroup: widget.group);
    _onBrowser();
  }

  @override
  void dispose() {
    _browser.removeListener(_onBrowser);
    _browser.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: MediaQuery.sizeOf(context).height * .74,
    child: Glass(
      dark: true,
      radius: 32,
      child: ListenableBuilder(
        listenable: _browser,
        builder: (context, _) {
          final items = _browser.items ?? const <Chapter>[];
          final ranges = _browser.ranges;
          final current = ShelfEntry(id: '', kind: ShelfKind.manga, name: '', cover: '', author: '', page: widget.page, pageCount: widget.pageCount);
          return Column(
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 5,
                  margin: const EdgeInsets.only(top: 8),
                  decoration: BoxDecoration(color: const Color(0x4DFFFFFF), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 10, 16, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '目录',
                            style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: IosColors.dInk),
                          ),
                          Text(
                            widget.comic.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13, color: IosColors.dMuted),
                          ),
                        ],
                      ),
                    ),
                    GlassButton(icon: 'locate', label: '定位到在读', dark: true, onTap: _locate),
                    const SizedBox(width: 10),
                    GlassButton(icon: 'xmark', label: '关闭', dark: true, onTap: () => Navigator.pop(context)),
                  ],
                ),
              ),
              if (_browser.groups.length > 1)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
                  child: IosSegmented(
                    dark: true,
                    options: [for (final g in _browser.groups) g.name],
                    counts: [for (final g in _browser.groups) g.count],
                    selected: _browser.groups.indexWhere((g) => g.pathWord == _browser.group).clamp(0, _browser.groups.length - 1),
                    onChanged: (i) => _browser.selectGroup(_browser.groups[i].pathWord),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 14, 14, 4),
                child: Row(
                  children: [
                    const Text('条目序号', style: TextStyle(fontSize: 13, color: IosColors.dMuted)),
                    const Spacer(),
                    Pressable(
                      onTap: _browser.toggleOrder,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const AppIcon('sort', size: 15, color: IosColors.dInk, stroke: 1.9),
                            const SizedBox(width: 4),
                            Text(_browser.descending ? '降序' : '升序', style: const TextStyle(fontSize: 13, color: IosColors.dInk)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (ranges.length > 1)
                SizedBox(
                  height: 46,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
                    itemCount: ranges.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, i) {
                      final idx = _browser.rangeOrder[i];
                      final on = idx == _browser.rangeIndex.clamp(0, ranges.length - 1);
                      return Pressable(
                        haptic: true,
                        onTap: () => _browser.selectRange(idx),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          decoration: BoxDecoration(
                            color: on ? IosColors.dInk : Colors.transparent,
                            borderRadius: BorderRadius.circular(21),
                            border: on ? null : Border.all(color: IosColors.dLine),
                          ),
                          child: Center(
                            widthFactor: 1,
                            child: Text(
                              ChapterBrowser.rangeLabel(ranges[idx]),
                              style: TextStyle(fontSize: 14, color: on ? IosColors.dBg : IosColors.dInk, fontWeight: on ? FontWeight.w700 : FontWeight.w400),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              Expanded(
                child: _browser.error != null
                    ? Center(
                        child: TextAction(label: '目录加载失败，点按重试', color: IosColors.dInk, onTap: _browser.retry),
                      )
                    : (_browser.loading || _browser.items == null)
                    ? const Center(child: CupertinoActivityIndicator(color: IosColors.dMuted))
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 30),
                        itemCount: items.length,
                        itemBuilder: (context, i) {
                          final ch = items[i];
                          final isCurrent = ch.uuid == widget.current.uuid;
                          return KeyedSubtree(
                            key: i == 0 ? _firstKey : null,
                            child: IosChapterRow(
                              key: isCurrent ? _currentKey : null,
                              dark: true,
                              first: i == 0,
                              chapter: ch,
                              read: LibraryStore.instance.isRead(widget.comic.pathWord, ch.uuid),
                              current: isCurrent ? current : null,
                              onTap: () => widget.onPick(ch.uuid),
                            ),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    ),
  );
}
