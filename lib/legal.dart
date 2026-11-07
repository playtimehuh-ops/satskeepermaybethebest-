import 'package:flutter/material.dart';
import 'theme.dart';

class LegalScreen extends StatelessWidget {
  final String title;
  final List<(String, String)> sections;
  const LegalScreen({super.key, required this.title, required this.sections});

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            TopBar(title: title, back: true),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                children: [
                  Text(title, style: T.title(c)),
                  const SizedBox(height: 8),
                  Text('GainDeep · Last updated 7 November 2026', style: T.small(c)),
                  const SizedBox(height: 20),
                  for (final section in sections) ...[
                    Text(section.$1, style: T.heading(c)),
                    const SizedBox(height: 6),
                    Text(section.$2, style: T.body(c).copyWith(color: c.muted)),
                    const SizedBox(height: 20),
                  ],
                  Text('Questions or account requests: contact GainDeep support using the contact details published in the app listing.', style: T.small(c)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});
  @override
  Widget build(BuildContext context) => const LegalScreen(
    title: 'Terms of Service',
    sections: [
      ('1. Using GainDeep', 'By creating an account, you agree to use the app lawfully, provide accurate information, protect your sign-in details, and follow these terms. You must meet the minimum age and eligibility requirements that apply where you live. If a network-sharing provider requires operators to be adults, do not activate that feature unless you meet that requirement.'),
      ('2. Network sharing', 'Network sharing is optional. When enabled, some network requests may leave through your internet connection and IP address and may use your mobile or home data allowance. Only enable it on a connection and plan that permit this use. You can pause sharing in the app.'),
      ('3. Points and rewards', 'Points are in-app reward units, not money, cryptocurrency, deposits, or an investment. Points have no guaranteed cash value and cannot be transferred or sold. Earning depends on server checks and may be delayed, rejected, or unavailable.'),
      ('4. Gift-card requests', 'Store items are a GainDeep-managed catalogue. A displayed item is not a guarantee of regional stock or delivery. Requests are manually reviewed; the app may reserve points while a request is pending. If a request cannot be fulfilled, points should be returned according to the request status. Check your email and in-app account for updates.'),
      ('5. Memberships', 'Memberships are purchased only with points. Each paid membership lasts 30 days, does not renew automatically, and expires to Free. Membership features do not increase point earning rates or redemption value. Upgrades during an active membership charge the difference in listed point costs.'),
      ('6. Daily wheel', 'The wheel permits one spin every 24 hours. The server selects the prize. Published prize odds are 0 points (10%), 5 (30%), 10 (30%), 15 (20%), 25 (8%), and 50 (2%).'),
      ('7. Fair use and suspension', 'Do not manipulate traffic measurements, automate requests, exploit bugs, interfere with other users, or attempt to bypass limits. We may pause or restrict accounts where abuse, fraud, safety, or legal concerns arise.'),
      ('8. Availability and liability', 'Features, catalogue items, and providers may change or be unavailable. The app is provided without a promise of uninterrupted service, specific earnings, or guaranteed reward delivery. Nothing in these terms removes rights that cannot legally be excluded.'),
      ('9. Changes', 'We may update these terms when the app changes or legal requirements change. Continued use after an updated version is presented means you accept the revised terms.'),
    ],
  );
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context) => const LegalScreen(
    title: 'Privacy Policy',
    sections: [
      ('Information we use', 'GainDeep may process your account email and authentication identifier, selected country, points balance, reward requests and their status, and app activity needed to operate the service.'),
      ('Network and device information', 'When sharing is enabled, the app and service may process traffic-volume measurements, service status, timestamps, technical logs, and device identifiers needed for security, accounting, and troubleshooting. The app does not promise that these measurements identify only one specific provider process.'),
      ('How information is used', 'Information is used to sign you in, operate the app, calculate points, prevent abuse, process manual reward requests, provide support, and maintain service security.'),
      ('Reward fulfilment', 'If you submit a reward request, the payout email and selected reward details are used to review and fulfil that request. Do not submit an email address unless you are authorised to use it.'),
      ('Sharing and service providers', 'Information may be processed by infrastructure providers that host authentication, databases, application APIs, or notifications. We do not claim that data is never processed by service providers.'),
      ('Retention and security', 'Records may be retained as needed for account operation, reward accounting, fraud prevention, legal obligations, and dispute handling. Reasonable safeguards are used, but no online service can guarantee absolute security.'),
      ('Your choices', 'You can pause network sharing, sign out, and contact support to ask about access or deletion of personal information, subject to records that must be retained for legal, security, or accounting reasons.'),
      ('Children and eligibility', 'The service is not intended to override age restrictions imposed by local law or third-party providers. Do not use features for which you do not meet the applicable age requirements.'),
      ('Policy updates', 'This policy may be updated as the service changes. The latest version will be shown in the app.'),
    ],
  );
}
