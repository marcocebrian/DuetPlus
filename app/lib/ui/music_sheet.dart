import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/session.dart';
import '../core/sources.dart';
import 'theme.dart';

void showMusicSheet(BuildContext context, HostSession host) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => FractionallySizedBox(heightFactor: 0.88, child: _MusicSheet(host: host)),
  );
}

class _MusicSheet extends StatefulWidget {
  final HostSession host;
  const _MusicSheet({required this.host});
  @override
  State<_MusicSheet> createState() => _MusicSheetState();
}

class _MusicSheetState extends State<_MusicSheet> {
  final _q = TextEditingController();
  List<YtResult> _results = [];
  bool _loading = false;
  bool _music = true; // YouTube Music (songs) vs YouTube (videos)
  String? _error;

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Pasted link? Play exactly that.
      final linkId = YouTubeSource.idFromLink(q);
      final r = linkId != null
          ? [await YouTubeSource.I.lookup(linkId)]
          : (_music ? await YouTubeSource.I.searchMusic(q) : await YouTubeSource.I.searchVideos(q));
      setState(() => _results = r);
    } catch (e) {
      setState(() => _error = 'Search failed: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _pick(QueueItem item, {required bool now}) {
    widget.host.enqueue(item, playNow: now);
    Navigator.pop(context);
    if (!now && widget.host.track != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Queued "${item.meta.title}"')));
    }
  }

  Future<void> _pickFile() async {
    final r = await FilePicker.pickFiles(type: FileType.audio);
    final f = r.isEmpty ? null : r.first;
    if (f?.path == null) return;
    if (!mounted) return;
    _pick(fileItem(f!.path!, f.name), now: true);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: 18, right: 18, bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        const Text('Add music', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
        const SizedBox(height: 14),
        TextField(
          controller: _q,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: InputDecoration(
            hintText: _music ? 'Search songs, or paste a link' : 'Search videos, or paste a link',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: _loading
                ? const Padding(padding: EdgeInsets.all(14), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : IconButton(icon: const Icon(Icons.arrow_forward_rounded), onPressed: _search),
          ),
        ),
        const SizedBox(height: 10),
        SegmentedButton<bool>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: true, label: Text('YouTube Music'), icon: Icon(Icons.music_note_rounded)),
            ButtonSegment(value: false, label: Text('YouTube'), icon: Icon(Icons.smart_display_rounded)),
          ],
          selected: {_music},
          onSelectionChanged: (s) {
            setState(() => _music = s.first);
            if (_q.text.trim().isNotEmpty) _search();
          },
        ),
        if (!YouTubeSource.I.canFetch)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
                'Playing from YouTube needs an Android phone in the party (it runs yt-dlp). '
                'Search works now; songs will play once an Android phone joins.',
                style: TextStyle(color: AppColors.warn, fontSize: 12.5, height: 1.35)),
          ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: _SourceTile(
              icon: Icons.folder_open_rounded,
              title: 'Phone files',
              sub: 'MP3 · FLAC · WAV · WebM',
              onTap: _pickFile,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _SourceTile(
              icon: Icons.graphic_eq_rounded,
              title: 'Sync test beat',
              sub: 'Clicks make offsets audible',
              onTap: () => _pick(demoItem(), now: true),
            ),
          ),
        ]),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: AppColors.bad))),
        const SizedBox(height: 8),
        Expanded(
          child: _results.isEmpty
              ? Center(
                  child: Text(_loading ? '' : 'Search YouTube Music or YouTube, or paste a link.\nThe song is fetched once and sent to every phone.',
                      textAlign: TextAlign.center, style: const TextStyle(color: AppColors.dim)))
              : ListView.separated(
                  itemCount: _results.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 4),
                  itemBuilder: (_, i) {
                    final r = _results[i];
                    final d = r.duration;
                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      leading: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: Image.network(r.thumb, width: r.music ? 52 : 64, height: r.music ? 52 : 48, fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(width: r.music ? 52 : 64, height: r.music ? 52 : 48, color: AppColors.surface2)),
                      ),
                      title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5)),
                      subtitle: Text('${r.author}${d != null ? ' · ${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}' : ''}',
                          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: AppColors.dim, fontSize: 12.5)),
                      trailing: widget.host.track == null
                          ? null
                          : IconButton(
                              tooltip: 'Add to queue',
                              icon: const Icon(Icons.playlist_add_rounded),
                              onPressed: () => _pick(YouTubeSource.I.item(r), now: false),
                            ),
                      onTap: () => _pick(YouTubeSource.I.item(r), now: true),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class _SourceTile extends StatelessWidget {
  final IconData icon;
  final String title, sub;
  final VoidCallback onTap;
  const _SourceTile({required this.icon, required this.title, required this.sub, required this.onTap});
  @override
  Widget build(BuildContext context) => Material(
        color: AppColors.surface2,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ShaderMask(shaderCallback: (r) => AppColors.grad.createShader(r), child: Icon(icon, color: Colors.white, size: 28)),
              const SizedBox(height: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(sub, style: const TextStyle(fontSize: 11.5, color: AppColors.dim)),
            ]),
          ),
        ),
      );
}
