import 'package:flutter/material.dart';

import 'services.dart';
import 'theme.dart';

final RegExp _emailPattern = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  int _mode = 0; // 0 = log in, 1 = create account
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  bool _showPassword = false;
  bool _busy = false;
  String? _emailError;
  String? _passwordError;
  String? _confirmError;
  String? _formError;
  String? _info;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  void _setMode(int mode) {
    if (mode == _mode || _busy) return;
    setState(() {
      _mode = mode;
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
      _formError = null;
      _info = null;
      _confirm.clear();
    });
  }

  Future<void> _submit() async {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    final email = _email.text.trim();
    final password = _password.text;

    String? emailError;
    String? passwordError;
    String? confirmError;
    if (!_emailPattern.hasMatch(email)) emailError = 'Enter a valid email address.';
    if (password.isEmpty) {
      passwordError = 'Enter your password.';
    } else if (_mode == 1 && password.length < 8) {
      passwordError = 'Use at least 8 characters.';
    }
    if (_mode == 1 && password.isNotEmpty && _confirm.text != password) {
      confirmError = 'The passwords don\'t match.';
    }
    if (emailError != null || passwordError != null || confirmError != null) {
      setState(() {
        _emailError = emailError;
        _passwordError = passwordError;
        _confirmError = confirmError;
        _formError = null;
        _info = null;
      });
      return;
    }

    setState(() {
      _emailError = null;
      _passwordError = null;
      _confirmError = null;
      _formError = null;
      _info = null;
      _busy = true;
    });
    try {
      if (_mode == 0) {
        await AuthService.signIn(email, password);
      } else {
        final signedIn = await AuthService.signUp(email, password);
        if (!signedIn && mounted) {
          setState(() {
            _mode = 0;
            _confirm.clear();
            _info = 'Account created. Confirm your email, then log in.';
          });
        }
      }
    } on AuthException catch (e) {
      if (mounted) setState(() => _formError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _forgotPassword() async {
    final email = _email.text.trim();
    if (!_emailPattern.hasMatch(email)) {
      setState(() => _emailError = 'Enter your email first, then choose Forgot password.');
      return;
    }
    setState(() {
      _busy = true;
      _emailError = null;
      _formError = null;
      _info = null;
    });
    try {
      await AuthService.sendReset(email);
      if (mounted) setState(() => _info = 'If $email has an account, a reset link is on its way.');
    } on AuthException catch (e) {
      if (mounted) setState(() => _formError = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final signup = _mode == 1;
    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) => SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: box.maxHeight - 24),
              child: AutofillGroup(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 56),
                    Text(
                      'GainDeep',
                      style: T.title(c).copyWith(fontSize: 40, letterSpacing: -1.4),
                    ),
                    const SizedBox(height: 10),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 320),
                      child: Text(
                        'Share spare bandwidth. Redeem it for gift cards and mobile top-ups.',
                        style: T.body(c).copyWith(color: c.muted),
                      ),
                    ),
                    const SizedBox(height: 44),
                    TextTabs(
                      labels: const ['Log in', 'Create account'],
                      index: _mode,
                      onChanged: _setMode,
                    ),
                    const SizedBox(height: 28),
                    FieldLine(
                      label: 'Email',
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      action: TextInputAction.next,
                      autofillHints: const [AutofillHints.email],
                      error: _emailError,
                    ),
                    const SizedBox(height: 22),
                    FieldLine(
                      label: 'Password',
                      controller: _password,
                      obscure: !_showPassword,
                      action: signup ? TextInputAction.next : TextInputAction.done,
                      autofillHints: [signup ? AutofillHints.newPassword : AutofillHints.password],
                      onSubmitted: signup ? null : (_) => _submit(),
                      error: _passwordError,
                      suffix: Semantics(
                        button: true,
                        label: _showPassword ? 'Hide password' : 'Show password',
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _showPassword = !_showPassword),
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12, top: 6, bottom: 6),
                            child: Text(
                              _showPassword ? 'Hide' : 'Show',
                              style: T.small(c).copyWith(color: c.cobalt, fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                    ),
                    AnimatedSize(
                      duration: const Duration(milliseconds: 220),
                      curve: Curves.easeOut,
                      alignment: Alignment.topCenter,
                      child: signup
                          ? Padding(
                              padding: const EdgeInsets.only(top: 22),
                              child: FieldLine(
                                label: 'Confirm password',
                                controller: _confirm,
                                obscure: !_showPassword,
                                action: TextInputAction.done,
                                autofillHints: const [AutofillHints.newPassword],
                                onSubmitted: (_) => _submit(),
                                error: _confirmError,
                              ),
                            )
                          : const SizedBox(width: double.infinity),
                    ),
                    const SizedBox(height: 18),
                    if (_formError != null) Message(_formError!),
                    if (_info != null) Message(_info!, kind: MessageKind.info),
                    if (!signup)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: LinkButton(label: 'Forgot password?', onPressed: _busy ? null : _forgotPassword),
                      ),
                    const SizedBox(height: 14),
                    PrimaryButton(
                      label: signup ? 'Create account' : 'Log in',
                      busy: _busy,
                      onPressed: _submit,
                    ),
                    const SizedBox(height: 18),
                    Text(
                      signup
                          ? 'Nothing is shared until you switch it on in the next step.'
                          : 'New here? Choose Create account above.',
                      style: T.small(c),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
