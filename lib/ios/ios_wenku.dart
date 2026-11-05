import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/api.dart' show ApiException;
import '../core/store.dart';
import '../core/wenku.dart';
import '../core/wenku_models.dart';
import '../ui/motion.dart';
import 'ios_settings.dart' show SettingsPage;
import 'ios_theme.dart';
import 'ios_wenku_login.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  return '${t.month}月${t.day}日';
}

/// 账号同步：登录轻小说账号，把源站书架合并到本地。
///
/// 两种登录方式：
/// - 内置表单直接提交账号密码（Cloudflare 放行时可用）；
/// - 失败或要求人机验证时，改用应用内网页登录，登录后读回 Cookie。
/// 只保存登录凭证和账号名，不保存密码。
class IosWenkuPage extends StatefulWidget {
  const IosWenkuPage({super.key});

  @override
  State<IosWenkuPage> createState() => _IosWenkuPageState();
}

class _IosWenkuPageState extends State<IosWenkuPage> {
  final _svc = WenkuService.instance;
  final _store = LibraryStore.instance;
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();
  DateTime? _lastSync;
  int _shelfTotal = 0;
  int _shelfAdded = 0;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _user.text = _svc.username;
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  bool get _ready => _user.text.trim().isNotEmpty && _pass.text.isNotEmpty && !_busy;

  /// 内置表单登录；被 Cloudflare 挡住时直接转去网页登录。
  Future<void> _login() async {
    if (!_ready) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _svc.login(_user.text, _pass.text);
      _pass.clear();
      await _sync();
      if (mounted) showIosToast(context, '已登录，书架新增 $_shelfAdded 部');
    } on WenkuBlocked {
      if (!mounted) return;
      setState(() => _error = '源站要求人机验证，改用网页登录');
      await _webLogin();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _webLogin() async {
    final ok = await Navigator.of(context).push<bool>(appRoute((_) => const WenkuWebLoginPage()));
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    await _sync();
    if (mounted) {
      setState(() => _busy = false);
      showIosToast(context, '已登录，书架新增 $_shelfAdded 部');
    }
  }

  Future<void> _sync() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final items = await _svc.shelf();
      final added = _store.mergeWenkuShelf([for (final i in items) (aid: i.aid, name: i.name, author: i.author, bookmark: i.bookmark)]);
      setState(() {
        _shelfTotal = items.length;
        _shelfAdded = added;
        _lastSync = DateTime.now();
      });
    } on ApiException catch (e) {
      _error = e.message;
      // 凭证失效时清掉，避免一直失败；本地书架不动。
      if (e is WenkuNeedLogin) await _svc.logout();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logout() async {
    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (dialog) => CupertinoAlertDialog(
        title: const Text('退出登录？'),
        content: const Text('只删除本机保存的登录凭证。已经同步到书架的作品和阅读位置会保留。'),
        actions: [
          CupertinoDialogAction(onPressed: () => Navigator.pop(dialog, false), child: const Text('取消')),
          CupertinoDialogAction(isDestructiveAction: true, onPressed: () => Navigator.pop(dialog, true), child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) {
      await _svc.logout();
      if (mounted) {
        setState(() {
          _shelfTotal = 0;
          _shelfAdded = 0;
          _lastSync = null;
        });
      }
    }
  }

  Widget _field(TextEditingController c, String placeholder, {bool secret = false, FocusNode? focus, TextInputAction? action, ValueChanged<String>? onSubmitted}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: CupertinoTextField(
      controller: c,
      focusNode: focus,
      placeholder: placeholder,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: !secret,
      autofillHints: [secret ? AutofillHints.password : AutofillHints.username],
      textInputAction: action,
      onSubmitted: onSubmitted,
      style: TextStyle(fontSize: 17, color: IosColors.ink),
      placeholderStyle: TextStyle(fontSize: 17, color: IosColors.muted),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
      decoration: const BoxDecoration(),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _svc,
    builder: (context, _) => SettingsPage(title: '轻小说账号', children: _svc.loggedIn ? _signedIn() : _signedOut()),
  );

  List<Widget> _signedOut() => [
    if (_error != null)
      Padding(
        padding: const EdgeInsets.fromLTRB(36, 4, 32, 0),
        child: Text(_error!, style: TextStyle(fontSize: 13, color: IosColors.accent)),
      ),
    InsetGroup(
      title: '轻小说账号',
      footer: '密码只用于这一次登录，不保存在本机。源站前面有人机验证，内置登录被拦截时会自动改为网页登录。',
      children: [
        AutofillGroup(
          child: Column(
            children: [
              _field(_user, '账号', action: TextInputAction.next, onSubmitted: (_) => _passFocus.requestFocus()),
              Divider(height: 1, thickness: .5, indent: 16, color: IosColors.line),
              _field(_pass, '密码', secret: true, focus: _passFocus, action: TextInputAction.go, onSubmitted: (_) => _login()),
            ],
          ),
        ),
      ],
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
      child: ListenableBuilder(
        listenable: Listenable.merge([_user, _pass]),
        builder: (context, _) => Opacity(
          opacity: _ready || _busy ? 1 : .45,
          child: Pressable(
            onTap: _ready ? _login : null,
            semanticLabel: '登录并同步',
            child: Container(
              height: 50,
              decoration: BoxDecoration(color: IosColors.accent, borderRadius: BorderRadius.circular(25)),
              child: Center(
                child: _busy
                    ? CupertinoActivityIndicator(color: IosColors.onAccent)
                    : Text(
                        '登录并同步',
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: IosColors.onAccent),
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
    Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Pressable(
        onTap: _busy ? null : _webLogin,
        child: Container(
          height: 50,
          decoration: BoxDecoration(
            border: Border.all(color: IosColors.line),
            borderRadius: BorderRadius.circular(25),
          ),
          child: Center(
            child: Text('在网页里登录', style: TextStyle(fontSize: 17, color: IosColors.ink)),
          ),
        ),
      ),
    ),
    const InsetGroup(
      title: '会同步什么',
      footer: '同步只从源站到reader：源站书架里的作品会加入书架，并补上没读过的作品上次读到哪一章。reader里的阅读记录不会上传。',
      children: [
        IosRow(icon: 'book', title: '书架', subtitle: '源站收藏的轻小说 → reader书架', chevron: false),
        IosRow(icon: 'history', title: '书签进度', subtitle: '源站记录的那一章 → 继续阅读', chevron: false),
      ],
    ),
  ];

  List<Widget> _signedIn() {
    final status = _busy
        ? '同步中…'
        : _error != null
        ? '同步失败：$_error'
        : _lastSync != null
        ? '上次同步 ${_ago(_lastSync!)}'
        : '还没有同步';
    return [
      InsetGroup(
        title: '轻小说账号',
        children: [IosRow(icon: 'person', title: _svc.username.isEmpty ? '已登录' : _svc.username, subtitle: '已登录 · 源站', chevron: false)],
      ),
      AnimatedSize(
        duration: Motion.of(context, 260),
        curve: Motion.ease,
        alignment: Alignment.topCenter,
        child: InsetGroup(
          title: '同步',
          footer: '同步只从源站到reader。源站没有全站阅读历史，阅读记录只保存在本机。',
          children: [
            IosRow(icon: 'refresh', title: '立即同步', subtitle: status, chevron: false, valueWidget: _busy ? const CupertinoActivityIndicator() : null, onTap: _busy ? null : _sync),
            if (_lastSync != null) ...[
              FadeSlideIn(
                key: ValueKey(_lastSync),
                dy: 5,
                from: 0,
                ms: 240,
                child: IosRow(icon: 'book', title: '源站书架', value: '$_shelfTotal 部 · 新增 $_shelfAdded', chevron: false),
              ),
            ],
          ],
        ),
      ),
      InsetGroup(
        children: [IosRow(title: '退出登录', destructive: true, chevron: false, onTap: _busy ? null : _logout)],
      ),
    ];
  }
}

/// 书架里显示轻小说时用：源站书架的走向。
String wenkuShelfSummary(WenkuShelfItem i) => i.bookmark.isEmpty ? '未开始' : '读到 ${i.bookmark}';

/// 打开轻小说登录：已经登录返回 true，否则转到网页登录，成功返回 true。
Future<bool> openWenkuLogin(BuildContext context) async {
  if (WenkuService.instance.loggedIn) return true;
  final ok = await Navigator.of(context).push<bool>(appRoute((_) => const WenkuWebLoginPage()));
  return ok == true;
}

/// 加入 / 移出源站书架，成功后同步到本地书架。没登录时先打开轻小说账号页。
/// 返回是否成功；失败原因直接用轻提示告诉用户。
Future<bool> wenkuSetOnShelf(BuildContext context, {required int aid, required String name, String author = '', required bool add}) async {
  final svc = WenkuService.instance;
  final store = LibraryStore.instance;
  if (!svc.loggedIn) {
    showIosToast(context, '先登录轻小说账号，才能同步源站书架');
    await Navigator.of(context).push(appRoute<void>((_) => const IosWenkuPage()));
    if (!svc.loggedIn) return false;
  }
  try {
    if (add) {
      final item = await svc.addBook(aid);
      store.mergeWenkuShelf([(aid: aid, name: item.name.isEmpty ? name : item.name, author: item.author.isEmpty ? author : item.author, bookmark: item.bookmark)]);
    } else {
      await svc.removeBook(aid);
      store.unfollow(wenkuIdOf(aid));
    }
    if (context.mounted) showIosToast(context, add ? '已加入书架，源站书架也已同步' : '已移出书架，源站书架也已同步');
    return true;
  } on ApiException catch (e) {
    if (context.mounted) showIosToast(context, e.message);
    return false;
  } catch (e) {
    // 意外错误也要收尾，否则按钮会一直转圈。
    if (context.mounted) showIosToast(context, '操作失败：$e');
    return false;
  }
}

/// 「加入书架 / 已在书架」胶囊按钮：搜索结果和阅读页共用。点「已在书架」会移出。
class WenkuShelfButton extends StatefulWidget {
  const WenkuShelfButton({super.key, required this.aid, required this.name, this.author = '', this.compact = false});

  final int aid;
  final String name;
  final String author;

  /// 紧凑版用在列表行尾。
  final bool compact;

  @override
  State<WenkuShelfButton> createState() => _WenkuShelfButtonState();
}

class _WenkuShelfButtonState extends State<WenkuShelfButton> {
  bool _busy = false;

  Future<void> _toggle(bool onShelf) async {
    if (onShelf) {
      final i = await showIosChoices(context, title: '《${widget.name}》已在书架', options: const ['移出书架（源站书架同步移出）'], destructiveIndex: 0);
      if (i != 0 || !mounted) return;
    }
    setState(() => _busy = true);
    await wenkuSetOnShelf(context, aid: widget.aid, name: widget.name, author: widget.author, add: !onShelf);
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: LibraryStore.instance,
    builder: (context, _) {
      final onShelf = LibraryStore.instance.isFollowed(wenkuIdOf(widget.aid));
      final h = widget.compact ? 32.0 : 40.0;
      return Pressable(
        onTap: _busy ? null : () => _toggle(onShelf),
        semanticLabel: onShelf ? '已在书架，点按移出' : '加入书架',
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: h,
          padding: EdgeInsets.symmetric(horizontal: widget.compact ? 14 : 20),
          decoration: BoxDecoration(
            color: onShelf ? Colors.transparent : IosColors.accentSoft,
            border: Border.all(color: onShelf ? IosColors.line : Colors.transparent),
            borderRadius: BorderRadius.circular(h / 2),
          ),
          child: Center(
            widthFactor: 1,
            child: _busy
                ? const CupertinoActivityIndicator(radius: 8)
                : Text(
                    onShelf ? '已在书架' : '加入书架',
                    style: TextStyle(fontSize: widget.compact ? 14 : 15, fontWeight: FontWeight.w600, color: onShelf ? IosColors.muted : IosColors.accent),
                  ),
          ),
        ),
      );
    },
  );
}
