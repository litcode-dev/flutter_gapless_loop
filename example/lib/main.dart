import 'dart:async';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

void main() {
  runApp(const GaplessLoopApp());
}

class GaplessLoopApp extends StatelessWidget {
  const GaplessLoopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gapless Loop Demo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const GaplessLoopScreen(),
    );
  }
}

class GaplessLoopScreen extends StatefulWidget {
  const GaplessLoopScreen({super.key});

  @override
  State<GaplessLoopScreen> createState() => _GaplessLoopScreenState();
}

class _GaplessLoopScreenState extends State<GaplessLoopScreen> {
  final _player = LoopAudioPlayer();

  PlayerState _state = PlayerState.idle;
  double _duration = 0.0;
  double _position = 0.0;
  double _loopStart = 0.0;
  double _loopEnd = 0.0;
  double _crossfade = 0.0; // 0 to 0.5 seconds
  double _volume = 1.0;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<String>? _errorSub;
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    _stateSub = _player.stateStream.listen(_onStateChange);
    _errorSub = _player.errorStream.listen(_onError);
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _errorSub?.cancel();
    _positionTimer?.cancel();
    _player.dispose();
    super.dispose();
  }

  void _onStateChange(PlayerState state) {
    setState(() => _state = state);
    if (state == PlayerState.playing) {
      _startPositionTimer();
    } else {
      _stopPositionTimer();
    }
  }

  void _onError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Error: $message'), backgroundColor: Colors.red),
    );
  }

  void _startPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200), (_) async {
      if (!mounted) return;
      final pos = await _player.currentPosition;
      setState(() => _position = pos);
    });
  }

  void _stopPositionTimer() {
    _positionTimer?.cancel();
    _positionTimer = null;
  }

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['wav', 'aiff', 'aif', 'mp3', 'm4a'],
    );
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    try {
      await _player.loadFromFile(path);
      final dur = await _player.duration;
      setState(() {
        _duration = dur.inMilliseconds / 1000.0;
        _loopStart = 0.0;
        _loopEnd = _duration;
        _position = 0.0;
      });
    } catch (e) {
      _onError(e.toString());
    }
  }

  Future<void> _play() async {
    try {
      await _player.play();
    } catch (e) {
      _onError(e.toString());
    }
  }

  Future<void> _pause() async {
    try {
      await _player.pause();
    } catch (e) {
      _onError(e.toString());
    }
  }

  Future<void> _stop() async {
    try {
      await _player.stop();
      setState(() => _position = 0.0);
    } catch (e) {
      _onError(e.toString());
    }
  }

  Future<void> _setLoopRegion() async {
    if (_loopEnd <= _loopStart) return;
    try {
      await _player.setLoopRegion(_loopStart, _loopEnd);
    } catch (e) {
      _onError(e.toString());
    }
  }

  Future<void> _setCrossfade(double value) async {
    setState(() => _crossfade = value);
    try {
      await _player.setCrossfadeDuration(value);
    } catch (e) {
      _onError(e.toString());
    }
  }

  Future<void> _setVolume(double value) async {
    setState(() => _volume = value);
    try {
      await _player.setVolume(value);
    } catch (e) {
      _onError(e.toString());
    }
  }

  bool get _isReady =>
      _state != PlayerState.idle && _state != PlayerState.loading;

  String get _stateLabel {
    switch (_state) {
      case PlayerState.idle:    return 'Idle — pick a file to begin';
      case PlayerState.loading: return 'Loading...';
      case PlayerState.ready:   return 'Ready';
      case PlayerState.playing: return 'Playing';
      case PlayerState.paused:  return 'Paused';
      case PlayerState.stopped: return 'Stopped';
      case PlayerState.error:   return 'Error';
    }
  }

  String _fmt(double secs) => secs.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final progress = _duration > 0 ? (_position / _duration).clamp(0.0, 1.0) : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gapless Loop Demo'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── File picker + state label ──────────────────────────
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _pickFile,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Pick Audio File'),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    _stateLabel,
                    style: Theme.of(context).textTheme.bodyMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Progress bar ───────────────────────────────────────
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LinearProgressIndicator(value: progress, minHeight: 8),
                const SizedBox(height: 4),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(_fmt(_position), style: Theme.of(context).textTheme.bodySmall),
                    Text(_fmt(_duration), style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Transport controls ─────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton.icon(
                  onPressed: _isReady && _state != PlayerState.playing ? _play : null,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Play'),
                ),
                ElevatedButton.icon(
                  onPressed: _isReady && _state == PlayerState.playing ? _pause : null,
                  icon: const Icon(Icons.pause),
                  label: const Text('Pause'),
                ),
                ElevatedButton.icon(
                  onPressed: _isReady ? _stop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
              ],
            ),

            const SizedBox(height: 24),
            const Divider(),

            // ── Loop region ────────────────────────────────────────
            Text('Loop Region', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),

            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text('Start: ${_fmt(_loopStart)}s',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(
                  child: Slider(
                    value: _loopStart.clamp(0.0, _duration > 0 ? _duration : 1.0),
                    min: 0.0,
                    max: _duration > 0 ? _duration : 1.0,
                    divisions: _duration > 0 ? (_duration * 10).toInt().clamp(1, 1000) : 1,
                    onChanged: _isReady
                        ? (v) {
                            setState(() => _loopStart = v);
                          }
                        : null,
                    onChangeEnd: _isReady ? (_) => _setLoopRegion() : null,
                  ),
                ),
              ],
            ),

            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text('End: ${_fmt(_loopEnd)}s',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(
                  child: Slider(
                    value: _loopEnd.clamp(0.0, _duration > 0 ? _duration : 1.0),
                    min: 0.0,
                    max: _duration > 0 ? _duration : 1.0,
                    divisions: _duration > 0 ? (_duration * 10).toInt().clamp(1, 1000) : 1,
                    onChanged: _isReady
                        ? (v) {
                            setState(() => _loopEnd = v);
                          }
                        : null,
                    onChangeEnd: _isReady ? (_) => _setLoopRegion() : null,
                  ),
                ),
              ],
            ),

            const Divider(),

            // ── Crossfade ──────────────────────────────────────────
            Text('Crossfade', style: Theme.of(context).textTheme.titleSmall),
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text('${(_crossfade * 1000).toStringAsFixed(0)}ms',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(
                  child: Slider(
                    value: _crossfade,
                    min: 0.0,
                    max: 0.5,
                    divisions: 50,
                    onChanged: _isReady ? _setCrossfade : null,
                  ),
                ),
              ],
            ),

            const Divider(),

            // ── Volume ─────────────────────────────────────────────
            Text('Volume', style: Theme.of(context).textTheme.titleSmall),
            Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text(_volume.toStringAsFixed(2),
                      style: Theme.of(context).textTheme.bodySmall),
                ),
                Expanded(
                  child: Slider(
                    value: _volume,
                    min: 0.0,
                    max: 1.0,
                    divisions: 100,
                    onChanged: _isReady ? _setVolume : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
