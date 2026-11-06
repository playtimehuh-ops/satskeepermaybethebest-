class AppConfig {
  // Injected at build time with --dart-define (see .github/workflows/build-apps.yml).
  static const String apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'https://your-project.vercel.app',
  );
  static const String appKey = String.fromEnvironment('APP_KEY', defaultValue: '');
  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL', defaultValue: '');
  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY', defaultValue: '');

  static const String channelName = 'com.gaindeep/node';
  static const int reportIntervalSeconds = 60;
  static const int redeemCost = 5000;
  static const double pointsPerMb = 0.1;
  static const int stampCount = 20;
  static const List<String> countries = ['US', 'UK', 'EG', 'SA'];
}
