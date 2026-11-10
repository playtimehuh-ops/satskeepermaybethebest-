import 'package:flutter/material.dart';
import 'services.dart';
import 'theme.dart';

class StreamHubScreen extends StatefulWidget {
  const StreamHubScreen({super.key});
  @override
  State<StreamHubScreen> createState() => _StreamHubScreenState();
}

class _StreamHubScreenState extends State<StreamHubScreen> {
  final _name = TextEditingController();
  final _reason = TextEditingController();
  Map<String, dynamic> _data = <String, dynamic>{};
  bool _loading = true, _sending = false;
  String? _error, _notice;

  @override
  void initState() { super.initState(); _load(); }
  @override
  void dispose() { _name.dispose(); _reason.dispose(); super.dispose(); }

  Future<void> _load() async {
    try {
      final data = await Api.streams();
      if (!mounted) return;
      setState(() { _data = data; _loading = false; _error = null; });
    } on ApiException catch (e) {
      if (mounted) setState(() { _loading = false; _error = e.message; });
    }
  }

  Future<void> _apply() async {
    if (_name.text.trim().length < 3 || _reason.text.trim().length < 20) {
      setState(() => _error = 'Enter a display name and at least 20 characters about your stream.');
      return;
    }
    setState(() { _sending = true; _error = null; _notice = null; });
    try {
      await Api.applyForCreator(_name.text.trim(), _reason.text.trim());
      if (!mounted) return;
      setState(() { _notice = 'Creator application submitted for review.'; _name.clear(); _reason.clear(); });
      await _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally { if (mounted) setState(() => _sending = false); }
  }

  Future<void> _donate(Map<String, dynamic> stream) async {
    final controller = TextEditingController(text: '10');
    final points = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Donate points'),
        content: TextField(controller: controller, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Points (10–10,000, multiples of 10)')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: () {
            final value = int.tryParse(controller.text.trim());
            if (value != null && value >= 10 && value <= 10000 && value % 10 == 0) Navigator.pop(context, value);
          }, child: const Text('Continue')),
        ],
      ),
    );
    controller.dispose();
    if (points == null) return;
    setState(() { _sending = true; _error = null; _notice = null; });
    try {
      final result = await Api.donateToStream(stream['id'].toString(), points);
      if (!mounted) return;
      setState(() => _notice = 'Donation sent: ${result['creator_points']} points to creator and ${result['platform_points']} points to GainDeep.');
      await _load();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally { if (mounted) setState(() => _sending = false); }
  }

  Future<void> _report(Map<String, dynamic> stream) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) {
        String value = 'Inappropriate or unsafe content';
        return StatefulBuilder(builder: (context, setDialogState) => AlertDialog(
          title: const Text('Report stream'),
          content: DropdownButtonFormField<String>(
            value: value,
            items: const [
              DropdownMenuItem(value: 'Inappropriate or unsafe content', child: Text('Inappropriate content')),
              DropdownMenuItem(value: 'Harassment or bullying', child: Text('Harassment or bullying')),
              DropdownMenuItem(value: 'Spam or scam', child: Text('Spam or scam')),
              DropdownMenuItem(value: 'Other safety concern', child: Text('Other safety concern')),
            ],
            onChanged: (next) { if (next != null) setDialogState(() => value = next); },
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(context, value), child: const Text('Submit report')),
          ],
        ));
      },
    );
    if (reason == null) return;
    try {
      await Api.reportStream(stream['id'].toString(), reason);
      if (mounted) setState(() => _notice = 'Report sent to the moderation queue.');
    } on ApiException catch (e) { if (mounted) setState(() => _error = e.message); }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.c;
    final streams = (_data['streams'] is List ? _data['streams'] as List : const [])
        .whereType<Map>().map((item) => Map<String, dynamic>.from(item)).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Live streaming')),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text('Live community', style: T.title(c)),
          const SizedBox(height: 8),
          Text('Creator applications, live listings, community safety and points support.', style: T.body(c)),
          const SizedBox(height: 16),
          Container(padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: c.surface, borderRadius: BorderRadius.circular(14), border: Border.all(color: c.rule)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Video provider setup pending', style: T.strong(c)),
              const SizedBox(height: 5),
              Text('Live video cannot start until the account owner configures and verifies an approved streaming provider. This screen does not claim a stream is broadcasting.', style: T.small(c)),
            ])),
          if (_notice != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_notice!, style: T.body(c).copyWith(color: c.ok))),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: T.body(c).copyWith(color: c.danger))),
          const SizedBox(height: 24),
          Row(children: [Expanded(child: Text('Live now', style: T.heading(c))), IconButton(onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))]),
          if (_loading) const Center(child: Padding(padding: EdgeInsets.all(20), child: CircularProgressIndicator()))
          else if (streams.isEmpty) Text('No approved live streams are available yet.', style: T.body(c))
          else ...streams.map((stream) => Card(child: Padding(padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text((stream['title'] ?? 'Live stream').toString(), style: T.strong(c)),
              Text('Creator: ${stream['creator_name'] ?? 'GainDeep creator'}', style: T.small(c)),
              const SizedBox(height: 8),
              Text('Video player will appear after provider setup is complete.', style: T.small(c)),
              Row(children: [
                TextButton(onPressed: _sending ? null : () => _donate(stream), child: const Text('Donate points')),
                const Spacer(),
                IconButton(tooltip: 'Report stream', onPressed: () => _report(stream), icon: const Icon(Icons.flag_outlined)),
              ]),
            ])))),
          const SizedBox(height: 28),
          Text('Become a creator', style: T.heading(c)),
          const SizedBox(height: 8),
          Text('Applications are reviewed before creator access is enabled.', style: T.small(c)),
          const SizedBox(height: 12),
          TextField(controller: _name, maxLength: 32, decoration: const InputDecoration(labelText: 'Creator display name')),
          const SizedBox(height: 8),
          TextField(controller: _reason, minLines: 3, maxLines: 5, maxLength: 500, decoration: const InputDecoration(labelText: 'What will you stream?')),
          const SizedBox(height: 12),
          FilledButton(onPressed: _sending ? null : _apply,
            child: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Apply to become a creator')),
          const SizedBox(height: 24),
          Text('Safety tools', style: T.heading(c)),
          const SizedBox(height: 6),
          Text('Report harassment, scams, or unsafe content. Creator access and reports require human review.', style: T.small(c)),
        ]),
      ),
    );
  }
}
