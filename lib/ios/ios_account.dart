import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../core/account.dart';
import '../core/api.dart' show ApiException;
import '../core/wenku.dart';
import '../ui/motion.dart';
import 'ios_settings.dart' show SettingsPage;
import 'ios_theme.dart';
import 'ios_wenku.dart';

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return '刚刚';
  if (d.inHours < 1) return '${d.inMinutes} 分钟前';
  if (d.inDays < 1) return '${d.inHours} 小时前';
  return '${t.month}月${t.day}日';
}

/// 账号同步：登录拷贝漫画账号，把源站书架和浏览历史合并到本地。
class IosAccountPage extends StatefulWidget {
  const IosAccountPage({super.key});

  @override
  State<IosAccountPage> createState() => _IosAccountPageState();
}

class _IosAccountPageState extends State<IosAccountPage> {
  final _account = AccountService.instance;
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _passFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    _user.text = _account.username;
  }

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  bool get _ready => _user.text.trim().isNotEmpty && _pass.text.isNotEmpty && !_account.busy;

  Future<void> _login() async {
    if (!_ready) return;
    FocusScope.of(context).unfocus();
    try {
      await _account.login(_user.text, _pass.text);
      _pass.clear();
      if (mounted) showIosToast(context, _account.error == null ? '已登录并同步' : '已登录，同步失败：${_account.error}');
    } on ApiException catch (e) {
      if (mounted) showIosToast(context, e.message);
    }
  }

  Future<void> _sync() async {
    final ok = await _account.sync();
    if (!mounted) return;
    final r = _account.lastReport;
    showIosToast(context, ok && r != null ? '书架新增 ${r.shelfAdded} 部，补上 ${r.historyFilled} 条阅读位置' : '同步失败：${_account.error}');
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
    if (ok == true) await _account.logout();
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
    listenable: _account,
    builder: (context, _) => SettingsPage(title: '账号同步', children: _account.loggedIn ? _signedIn() : _signedOut()),
  );

  List<Widget> _signedOut() => [
    if (_account.error != null)
      Padding(
        padding: const EdgeInsets.fromLTRB(36, 4, 32, 0),
        child: Text(_account.error!, style: TextStyle(fontSize: 13, color: IosColors.accent)),
      ),
    InsetGroup(
      title: '拷贝漫画账号',
      footer: '密码只用于这一次登录，不保存在本机；登录后只保存登录凭证。短时间内反复登录会被源站暂时限制，请不要连续尝试。',
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
          opacity: _ready || _account.busy ? 1 : .45,
          child: Pressable(
            onTap: _ready ? _login : null,
            semanticLabel: '登录并同步',
            child: Container(
              height: 50,
              decoration: BoxDecoration(color: IosColors.accent, borderRadius: BorderRadius.circular(25)),
              child: Center(
                child: _account.busy
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
    const InsetGroup(
      title: '会同步什么',
      footer: '同步只从拷贝漫画到reader：源站书架里的作品会加入追更，浏览历史会补上本机没有的阅读位置。reader里的追更暂时不能写回源站。',
      children: [
        IosRow(icon: 'book', title: '书架', subtitle: '源站收藏的漫画 → reader追更', chevron: false),
        IosRow(icon: 'history', title: '浏览历史', subtitle: '最后看到的那一话 → 继续阅读', chevron: false),
      ],
    ),
    _wenkuGroup(context),
  ];

  List<Widget> _signedIn() {
    final r = _account.lastReport;
    final status = _account.busy
        ? '同步中…'
        : _account.error != null
        ? '同步失败：${_account.error}'
        : _account.lastSync != null
        ? '上次同步 ${_ago(_account.lastSync!)}'
        : '还没有同步';
    return [
      InsetGroup(
        title: '拷贝漫画账号',
        children: [IosRow(icon: 'person', title: _account.displayName, subtitle: _account.username != _account.displayName ? _account.username : '已登录', chevron: false)],
      ),
      AnimatedSize(
        duration: Motion.of(context, 260),
        curve: Motion.ease,
        alignment: Alignment.topCenter,
        child: InsetGroup(
          title: '同步',
          footer: '打开应用时会自动同步（30 分钟内同步过就跳过）。同步只从源站到reader，reader里的追更暂时不能写回源站。',
          children: [
            IosRow(icon: 'refresh', title: '立即同步', subtitle: status, chevron: false, valueWidget: _account.busy ? const CupertinoActivityIndicator() : null, onTap: _account.busy ? null : _sync),
            if (r != null) ...[
              FadeSlideIn(
                key: ValueKey(('shelf', r.at)),
                dy: 5,
                from: 0,
                ms: 240,
                child: IosRow(icon: 'book', title: '源站书架', value: '${r.shelfTotal} 部 · 新增 ${r.shelfAdded}', chevron: false),
              ),
              FadeSlideIn(
                key: ValueKey(('history', r.at)),
                dy: 5,
                from: 0,
                ms: 240,
                child: IosRow(icon: 'history', title: '浏览历史', value: '${r.historyTotal} 条 · 补上 ${r.historyFilled}', chevron: false),
              ),
            ],
          ],
        ),
      ),
      InsetGroup(
        children: [IosRow(title: '退出登录', destructive: true, chevron: false, onTap: _account.busy ? null : _logout)],
      ),
      _wenkuGroup(context),
    ];
  }

  /// 轻小说账号：设计稿里「我的」只保留三行入口，所以把它放在账号同步页末尾，
  /// 和拷贝漫画账号用同样的样式，不新增一级入口。
  Widget _wenkuGroup(BuildContext context) {
    final svc = WenkuService.instance;
    return InsetGroup(
      title: '轻小说账号',
      footer: 'Wenku8 官方站直连：正文需要登录，源站前面有人机验证时改用网页登录。只保存登录凭证，不保存密码。',
      children: [
        IosRow(
          icon: 'book',
          title: svc.loggedIn ? (svc.username.isEmpty ? '已登录' : svc.username) : '登录 Wenku8',
          subtitle: svc.loggedIn ? '已登录 · 书架可同步' : '登录后可以读正文、同步源站书架',
          onTap: () => Navigator.of(context).push(appRoute<void>((_) => const IosWenkuPage())),
        ),
      ],
    );
  }
}
