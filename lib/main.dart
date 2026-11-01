import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'auth_screen.dart';
import 'home.dart';
import 'services.dart';
import 'theme.dart';

final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthService.init();
  runApp(const SatsKeeperApp());
}

class SatsKeeperApp extends StatelessWidget {
  const SatsKeeperApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navKey,
      title: 'SatsKeeper',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: ThemeMode.system,
      builder: (context, child) {
        final dark = MediaQuery.platformBrightnessOf(context) == Brightness.dark;
        final colors = dark ? AppColors.dark : AppColors.light;
        final icons = dark ? Brightness.light : Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: icons,
            systemNavigationBarColor: colors.ground,
            systemNavigationBarIconBrightness: icons,
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const Gate(),
    );
  }
}

/// Shows the login screen or the signed-in flow, depending on the account session.
class Gate extends StatelessWidget {
  const Gate({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AuthSession?>(
      valueListenable: AuthService.session,
      builder: (context, session, _) {
        if (session == null) {
          // A session can end while sub-screens are open (expired login, log out).
          WidgetsBinding.instance.addPostFrameCallback((_) {
            navKey.currentState?.popUntil((route) => route.isFirst);
          });
          return const AuthScreen();
        }
        return SignedInFlow(key: ValueKey<String>(session.userId), session: session);
      },
    );
  }
}

class SignedInFlow extends StatefulWidget {
  final AuthSession session;
  const SignedInFlow({super.key, required this.session});

  @override
  State<SignedInFlow> createState() => _SignedInFlowState();
}

class _SignedInFlowState extends State<SignedInFlow> {
  late bool _opted = LocalState.optedIn;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      child: _opted
          ? DashboardScreen(
              key: const ValueKey<String>('dashboard'),
              email: widget.session.email,
              onStopped: () => setState(() => _opted = false),
            )
          : ConsentScreen(
              key: const ValueKey<String>('consent'),
              onEnabled: () => setState(() => _opted = true),
            ),
    );
  }
}
