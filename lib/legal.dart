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
                  Text('GainDeep · Pre-launch draft · 7 November 2026', style: T.small(c)),
                  const SizedBox(height: 14),
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: c.punch.withAlpha(45),
                      border: Border.all(color: c.rule),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      'DRAFT — These documents are not final or effective yet. The eligible adult legal operator, public support contact, governing law, provider contracts, and exact data-retention schedule must be confirmed before public launch.',
                      style: T.small(c).copyWith(color: c.ink),
                    ),
                  ),
                  const SizedBox(height: 20),
                  for (final section in sections) ...[
                    Text(section.$1, style: T.heading(c)),
                    const SizedBox(height: 6),
                    Text(section.$2, style: T.body(c).copyWith(color: c.muted)),
                    const SizedBox(height: 20),
                  ],
                  Text(
                    'The public legal drafts are also available at /launch/legal.html. A monitored support and privacy contact will be added after the operator confirms it.',
                    style: T.small(c),
                  ),
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
      ('1. Using GainDeep', 'GainDeep is a pre-launch service. Before public launch, its legal operator, contact details, governing law, and effective date must be published. Users may use only features for which they meet local law, app-store, internet-provider, and third-party eligibility rules. Never use another person’s identity to bypass an age or provider requirement.'),
      ('2. Network sharing', 'Network sharing is optional. When enabled, other people’s network requests may use your connection and public IP address and may consume your mobile or home data. Only enable it on a connection and plan that permit this use. Some providers require an adult operator. Network sharing must not be offered for public commercial use until provider permission, operator eligibility, and technical safeguards are confirmed.'),
      ('3. Points and rewards', 'Points are internal service units, not a bank balance, deposit, investment, cryptocurrency, or guaranteed income. Points cannot be sold or transferred. Earning may be delayed, rejected, paused, or adjusted to correct errors or abuse. No earning rate or monetary value is guaranteed.'),
      ('4. Gift-card requests', 'Reward requests are manually reviewed and do not guarantee stock or delivery. The user must confirm the beneficiary email and selected item before submitting. The stated 0–48 hour period is an estimate, not a guarantee. If an item cannot be fulfilled, the request will be handled according to its status and applicable law.'),
      ('5. Memberships', 'Memberships are purchased with points only, last 30 days, and do not renew automatically. Benefits and prices are those shown in the app. Memberships do not increase earning rates or guarantee redemption value.'),
      ('6. Daily wheel', 'The wheel allows one spin every 24 hours and the server selects the result. Configured odds are 0 points (10%), 5 (30%), 10 (30%), 15 (20%), 25 (8%), and 50 (2%). The feature may be unavailable or changed before launch.'),
      ('7. Fair use and suspension', 'Do not falsify measurements, exploit bugs, automate abuse, interfere with other users, route unlawful traffic, or bypass provider restrictions. Access may be restricted to protect users, infrastructure, or legal compliance.'),
      ('8. Availability and liability', 'Features, catalogue items, and providers may change or be unavailable. The service does not promise uninterrupted access, specific earnings, network performance, or reward delivery. Rights and liabilities that cannot legally be excluded remain unaffected.'),
      ('9. Changes and disputes', 'Terms must be dated and presented before taking effect. Governing law, dispute forum, mandatory consumer rights, and formal notices remain subject to the legal operator’s review and must be completed before public launch.'),
      ('10. Contact', 'A monitored public support contact and the legal operator’s required details will be added before public launch. These details are intentionally not invented.'),
    ],
  );
}

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});
  @override
  Widget build(BuildContext context) => const LegalScreen(
    title: 'Privacy Policy',
    sections: [
      ('1. Data controller', 'The responsible legal operator has not yet been identified. Its identity and a working privacy contact must be published before public launch.'),
      ('2. Information processed', 'The app may process account email and authentication identifier; points balance, streaks, opt-in state and timestamps; membership and wheel records; reward item, country, value, beneficiary email and request status; and network-sharing status, measured byte counts, request identifiers, and technical logs. Hosting or validation providers may process IP address and user-agent metadata.'),
      ('3. Purposes', 'Information is used to authenticate accounts, operate requested features, record points and reward requests, prevent abuse, troubleshoot failures, secure the service, and meet legal or accounting obligations.'),
      ('4. Service providers', 'The current software integrates with Supabase for authentication and database services and Vercel for hosting and API execution. Depending on enabled features, it may also interact with Mysterium-related network services, Bitrefill catalogue services, Gmail notifications, and CryptoRefills validation. These providers have their own privacy terms.'),
      ('5. Network-sharing disclosure', 'When network sharing is enabled, other people’s requests may pass through the user’s connection and appear to destination services as coming from the user’s public IP address. Provider systems may separately process traffic and account metadata.'),
      ('6. International processing', 'The current Supabase project is configured in Australia (Sydney). Other providers may process data in additional countries. The operator must confirm applicable international-transfer requirements before launch.'),
      ('7. Retention and deletion', 'Records may be retained for service operation, reward accounting, fraud prevention, disputes, and legal obligations. A precise retention schedule and verified account-deletion workflow have not yet been confirmed and must be completed before public launch. Deleting the app does not necessarily delete server-side records.'),
      ('8. Security', 'The project uses server-side authentication checks, restricted database access, and transactional controls for selected reward operations. No online service can guarantee absolute security, and this project has not yet passed an independent security audit.'),
      ('9. Choices and rights', 'Users can turn off network sharing and sign out. Rights to access, correct, delete, restrict, or object to processing depend on applicable law. A monitored privacy contact and request-handling process must be published before launch.'),
      ('10. Children and eligibility', 'Age requirements vary by country, feature, app store, and provider. Some network-sharing providers require adult operators. The service must not be used to bypass those restrictions.'),
      ('11. Website and updates', 'The current launch page uses a same-origin status request and does not intentionally load third-party analytics or advertising scripts. Hosting providers may process technical request logs. This notice must be updated if cookies, analytics, or additional providers are introduced.'),
    ],
  );
}
