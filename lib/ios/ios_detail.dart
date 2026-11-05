import 'package:flutter/material.dart';

import '../core/api.dart';
import '../core/chapter_browser.dart';
import '../core/models.dart';
import '../core/store.dart';
import '../ui/format.dart' show formatPopular;
import '../ui/icons.dart';
import '../ui/motion.dart';
import '../ui/widgets.dart' show CoverImage, revealChapterRow;
import 'ios_app.dart';
import 'ios_discover.dart' show IosNetworkError;
import 'ios_theme.dart';

class IosDetailPage extends StatefulWidget {
  const IosDetailPage({super.key, required this.comic});

  final ComicBrief comic;

  @override
  State<IosDetailPage> createState() => _IosDetailPageState();
}

class _IosDetailPageState extends State<IosDetailPage> {
  final _store = LibraryStore.instance;
  late final _browser = ChapterBrowser(widget.comic.pathWord);
  final _currentKey = GlobalKey();
  final _firstKey = GlobalKey();
  ComicDetail? _detail;
  String? _error;
  bool _briefOpen = false;
  bool _pendingLocate = false;

  String get _pw => widget.comic.pathWord;
  ComicBrief get _comic => _detail?.comic ?? widget.comic;

  @override
  void initState() {
    super.initState();
    _store.addListener(_refresh);
    _browser.addListener(_onBrowser);
    _load();
  }

  @override
  void dispose() {
    _store.removeListener(_refresh);
    _browser.removeListener(_onBrowser);
    _browser.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _onBrowser() {
    _refresh();
    if (_pendingLocate && !_browser.loading && _browser.items != null) {
      _pendingLocate = false;
      final uuid = _store.entry(_pw)?.chapterUuid;
      final index = _browser.items!.indexWhere((c) => c.uuid == uuid);
      if (index >= 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) => revealChapterRow(firstKey: _firstKey, targetKey: _currentKey, index: index, rowExtent: 52));
      }
    }
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final d = await MangaApi.instance.detail(_pw);
      if (!mounted) return;
      _store.applyRemote(d, seen: true);
      final e = _store.entry(_pw);
      _pendingLocate = e?.chapterIndex != null;
      setState(() => _detail = d);
      _browser.setGroups(d.groups, preferGroup: e?.group, locateIndex: e?.chapterIndex);
    } catch (err) {
      if (mounted) setState(() => _error = err.toString());
    }
  }

  void _toggleFollow() {
    final d = _detail;
    if (d == null) return;
    if (_store.isFollowed(_pw)) {
      _store.unfollow(_pw);
      showIosToast(context, '已取消追更');
    } else {
      _store.follow(d);
      showIosToast(context, '已追更，有新话会提醒');
    }
  }

  void _locate() {
    final e = _store.entry(_pw);
    if (e?.chapterIndex == null) {
      showIosToast(context, '还没有开始读这部作品');
      return;
    }
    _pendingLocate = true;
    _browser.locate(e!.chapterIndex!, inGroup: e.group);
  }

  Future<void> _resume() async {
    final e = _store.entry(_pw);
    if (e?.chapterUuid != null) {
      return iosOpenReader(context, comic: _comic, group: e!.group ?? _browser.group, chapterUuid: e.chapterUuid!, initialPage: e.page);
    }
    try {
      final page = await MangaApi.instance.chapters(_pw, _browser.group, limit: 1);
      final first = page.list.firstOrNull;
      if (first != null && mounted) iosOpenReader(context, comic: _comic, group: _browser.group, chapterUuid: first.uuid);
    } catch (err) {
      if (mounted) showIosToast(context, '$err');
    }
  }

  Future<void> _menu() async {
    final following = _store.isFollowed(_pw);
    final i = await showIosChoices(context, title: _comic.name, options: ['刷新', following ? '取消追更' : '追更'], destructiveIndex: following ? 1 : null);
    if (i == 0) _load();
    if (i == 1) _toggleFollow();
  }

  @override
  Widget build(BuildContext context) {
    final entry = _store.entry(_pw);
    final d = _detail;
    final top = MediaQuery.paddingOf(context).top;
    return Scaffold(
      body: Stack(children: [
        Positioned.fill(
          child: CustomScrollView(physics: const BouncingScrollPhysics(), slivers: [
            SliverToBoxAdapter(child: SizedBox(height: top + 60)),
            SliverToBoxAdapter(child: _header(d, entry)),
            if (d == null)
              SliverToBoxAdapter(child: _error != null ? IosNetworkError(message: _error!, onRetry: _load) : const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator.adaptive())))
            else ...[
              SliverToBoxAdapter(child: _meta(d)),
              SliverToBoxAdapter(child: _catalogHeader(d)),
              _chapterList(entry, d.isLock),
              SliverToBoxAdapter(child: _listStatus()),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ]),
        ),
        // 顶部渐隐 + 玻璃按钮
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: top + 64,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [IosColors.bg, IosColors.bg.withValues(alpha: .85), IosColors.bg.withValues(alpha: 0)], stops: const [0, .7, 1]),
              ),
            ),
          ),
        ),
        Positioned(
          top: top + 4,
          left: 16,
          right: 16,
          child: Row(children: [
            GlassButton(icon: 'chevronLeft', label: '返回', onTap: () => Navigator.pop(context)),
            Expanded(child: Text('作品详情', textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: IosColors.ink))),
            GlassButton(icon: 'ellipsis', label: '更多操作', onTap: _detail == null ? null : _menu),
          ]),
        ),
        if (d != null) _resumeBar(entry, d.isLock),
      ]),
    );
  }

  Widget _header(ComicDetail? d, ShelfEntry? entry) {
    final following = entry != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), boxShadow: const [BoxShadow(color: Color(0x2E1A1A28), blurRadius: 14, offset: Offset(0, 6))]),
          child: CoverImage(url: _comic.cover, title: _comic.name, width: 112, height: 156, radius: 6),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (d != null) Text([d.status, d.region].where((s) => s.isNotEmpty).join(' · '), style: TextStyle(fontSize: 13, color: d.finished ? IosColors.muted : IosColors.accent)),
            const SizedBox(height: 6),
            Text(_comic.name, maxLines: 3, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 26, height: 1.2, fontWeight: FontWeight.w700, color: IosColors.ink)),
            const SizedBox(height: 8),
            Text(_comic.authorText, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, color: IosColors.muted)),
            if (d != null) ...[
              const SizedBox(height: 4),
              Text('人气 ${formatPopular(d.comic.popular)}', style: TextStyle(fontSize: 15, color: IosColors.muted)),
              const SizedBox(height: 10),
              Pressable(
                haptic: true,
                onTap: _toggleFollow,
                semanticLabel: following ? '取消追更' : '追更',
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    BounceOnChange(value: following, child: AppIcon(following ? 'bookmarkFilled' : 'bookmark', size: 19, color: IosColors.accent, stroke: 1.8)),
                    const SizedBox(width: 6),
                    Text(following ? '已追更' : '追更', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: IosColors.ink)),
                  ]),
                ),
              ),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _meta(ComicDetail d) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (d.themes.isNotEmpty)
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in d.themes)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(color: IosColors.faint, borderRadius: BorderRadius.circular(8)),
                  child: Text(t, style: TextStyle(fontSize: 13, color: IosColors.ink)),
                ),
            ]),
          const SizedBox(height: 16),
          Row(children: [
            Text('更新至 ', style: TextStyle(fontSize: 15, color: IosColors.muted)),
            Expanded(child: Text(d.lastChapter, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: IosColors.ink))),
            Text(d.comic.updated, style: TextStyle(fontSize: 13, color: IosColors.muted)),
          ]),
          if (d.aliases.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('又名 ${d.aliases.join(' · ')}', maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: IosColors.muted)),
          ],
          if (d.brief.isNotEmpty) ...[
            const SizedBox(height: 18),
            Row(children: [
              Text('简介', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: IosColors.ink)),
              const Spacer(),
              Pressable(
                onTap: () => setState(() => _briefOpen = !_briefOpen),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(_briefOpen ? '收起' : '展开', style: TextStyle(fontSize: 15, color: IosColors.accent)),
                  const SizedBox(width: 2),
                  AnimatedRotation(turns: _briefOpen ? .5 : 0, duration: const Duration(milliseconds: 180), child: AppIcon('down', size: 13, color: IosColors.accent, stroke: 2)),
                ]),
              ),
            ]),
            const SizedBox(height: 8),
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              alignment: Alignment.topCenter,
              child: Text(d.brief,
                  maxLines: _briefOpen ? null : 2,
                  overflow: _briefOpen ? null : TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 15, height: 1.6, color: IosColors.muted)),
            ),
          ],
        ]),
      );

  Widget _catalogHeader(ComicDetail d) {
    final ranges = _browser.ranges;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 28, 20, 0),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('目录', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: IosColors.ink)),
          const SizedBox(width: 8),
          Text('共 ${d.chapterCount} 条', style: TextStyle(fontSize: 13, color: IosColors.muted)),
          const Spacer(),
          Pressable(
            onTap: _browser.toggleOrder,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AppIcon('sort', size: 16, color: IosColors.accent, stroke: 1.9),
                const SizedBox(width: 4),
                Text(_browser.descending ? '降序' : '升序', style: TextStyle(fontSize: 15, color: IosColors.accent)),
              ]),
            ),
          ),
          Pressable(
            onTap: _locate,
            child: Padding(
              padding: EdgeInsets.all(8),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                AppIcon('locate', size: 16, color: IosColors.accent, stroke: 1.9),
                SizedBox(width: 4),
                Text('定位', style: TextStyle(fontSize: 15, color: IosColors.accent)),
              ]),
            ),
          ),
        ]),
        if (d.groups.length > 1) ...[
          const SizedBox(height: 4),
          UnderlineTabs(
            padding: EdgeInsets.zero,
            options: [for (final g in d.groups) g.name],
            counts: [for (final g in d.groups) g.count],
            selected: d.groups.indexWhere((g) => g.pathWord == _browser.group).clamp(0, d.groups.length - 1),
            onChanged: (i) => _browser.selectGroup(d.groups[i].pathWord),
          ),
        ],
        if (ranges.length > 1) ...[
          const SizedBox(height: 14),
          Text('条目序号', style: TextStyle(fontSize: 13, color: IosColors.muted)),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: ranges.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final idx = _browser.rangeOrder[i];
                final on = idx == _browser.rangeIndex.clamp(0, ranges.length - 1);
                return Pressable(
                  haptic: true,
                  onTap: () => _browser.selectRange(idx),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(color: on ? IosColors.accentSoft : Colors.transparent, borderRadius: BorderRadius.circular(12)),
                    child: Center(
                      widthFactor: 1,
                      child: Text(ChapterBrowser.rangeLabel(ranges[idx]), style: TextStyle(fontSize: 15, color: on ? IosColors.accent : IosColors.muted, fontWeight: on ? FontWeight.w700 : FontWeight.w400)),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 10),
      ]),
    );
  }

  Widget _chapterList(ShelfEntry? entry, bool locked) {
    final items = _browser.items;
    if (_browser.loading || items == null) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      sliver: DecoratedSliver(
        decoration: BoxDecoration(color: IosColors.surface, borderRadius: BorderRadius.circular(18)),
        sliver: SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, i) {
            final ch = items[i];
            final current = entry?.chapterUuid == ch.uuid;
            return KeyedSubtree(
              key: i == 0 ? _firstKey : null,
              child: IosChapterRow(
                key: current ? _currentKey : null,
                chapter: ch,
                read: _store.isRead(_pw, ch.uuid),
                current: current ? entry : null,
                locked: locked,
                first: i == 0,
                onTap: locked ? null : () => iosOpenReader(context, comic: _comic, group: _browser.group, chapterUuid: ch.uuid, initialPage: current ? entry!.page : 0),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _listStatus() {
    if (_browser.error != null) return Center(child: TextAction(label: '目录加载失败，点按重试', onTap: _browser.retry));
    if (_browser.loading) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(children: [for (var i = 0; i < 5; i++) const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Redacted(height: 22))]),
      );
    }
    if (_detail?.isLock ?? false) {
      return Padding(
        padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
        child: Text('源站把这部作品标记为付费或会员内容，reader不提供绕过方式。', style: TextStyle(fontSize: 13, color: IosColors.accent)),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _resumeBar(ShelfEntry? entry, bool locked) {
    final started = entry?.chapterUuid != null;
    final title = started ? entry!.chapterName ?? '' : (locked ? '暂不可读' : '还没有开始读');
    final sub = started
        ? (entry!.pageCount > 0 ? '上次读到 ${entry.page + 1} / ${entry.pageCount} 页' : '上次读到这一话')
        : (locked ? '源站标记为付费内容' : '从第一条开始');
    final bottom = MediaQuery.paddingOf(context).bottom;
    return Positioned(
      left: 16,
      right: 16,
      bottom: bottom > 0 ? bottom - 6 : 16,
      // 左边说明读到哪，右边是唯一的主操作按钮。
      child: Glass(
        radius: 32,
        padding: const EdgeInsets.fromLTRB(20, 10, 10, 10),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: IosColors.ink)),
              const SizedBox(height: 2),
              Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: IosColors.muted)),
            ]),
          ),
          const SizedBox(width: 12),
          Opacity(
            opacity: locked ? .4 : 1,
            child: Pressable(
              onTap: locked ? null : _resume,
              child: Container(
                height: 48,
                padding: const EdgeInsets.symmetric(horizontal: 26),
                decoration: BoxDecoration(color: IosColors.accent, borderRadius: BorderRadius.circular(24)),
                child: Center(
                  widthFactor: 1,
                  child: Text(started ? '继续阅读' : '开始阅读', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: IosColors.onAccent)),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// 一条章节：条目序号、话名、标签（重绘 / 特别篇 / 公告）、已读勾；在读那条高亮并显示页码。
class IosChapterRow extends StatelessWidget {
  const IosChapterRow({super.key, required this.chapter, required this.read, required this.onTap, this.current, this.locked = false, this.dark = false, this.first = false});

  final Chapter chapter;
  final bool read;
  final VoidCallback? onTap;
  final ShelfEntry? current;
  final bool locked;
  final bool dark;
  final bool first;

  @override
  Widget build(BuildContext context) {
    final tag = chapterTag(chapter.name);
    final ink = dark ? IosColors.dInk : IosColors.ink;
    final muted = dark ? IosColors.dMuted : IosColors.muted;
    final isCurrent = current != null;
    final e = current;
    return Pressable(
      onTap: onTap,
      child: Container(
        margin: isCurrent ? const EdgeInsets.symmetric(horizontal: 6, vertical: 3) : EdgeInsets.zero,
        decoration: isCurrent
            ? BoxDecoration(color: dark ? IosColors.dFaint : IosColors.accentSoft, borderRadius: BorderRadius.circular(14))
            : BoxDecoration(border: first ? null : Border(top: BorderSide(color: dark ? const Color(0x1FFFFFFF) : IosColors.line, width: .5))),
        padding: EdgeInsets.symmetric(horizontal: isCurrent ? 10 : 16),
        height: 52,
        child: Row(children: [
          SizedBox(width: 40, child: Text('${chapter.index + 1}', style: TextStyle(fontSize: 13, color: isCurrent ? (dark ? IosColors.dAccent : IosColors.accent) : muted))),
          Expanded(
            child: Text(chapter.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 17, color: read && !isCurrent ? muted : ink, fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w400)),
          ),
          if (tag.isNotEmpty && !isCurrent) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(color: dark ? IosColors.dFaint : IosColors.faint, borderRadius: BorderRadius.circular(6)),
              child: Text(tag, style: TextStyle(fontSize: 12, color: muted)),
            ),
          ],
          const SizedBox(width: 8),
          if (isCurrent)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: dark ? const Color(0xFF4A4B53) : IosColors.surface, borderRadius: BorderRadius.circular(8)),
              child: Text(e!.pageCount > 0 ? '在读 ${e.page + 1}/${e.pageCount}' : '在读', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: dark ? IosColors.dInk : IosColors.accent)),
            )
          else if (locked)
            AppIcon('lock', size: 15, color: muted)
          else if (read)
            AppIcon('check', size: 15, color: muted, stroke: 2)
          else
            AppIcon('right', size: 13, color: muted, stroke: 2),
        ]),
      ),
    );
  }
}
