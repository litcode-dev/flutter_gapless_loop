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
  double _pan = 0.0;

  // BPM controls
  double _detectedBpm = 0.0; // auto-detected; used as rate base
  double _manualBpm = 0.0;
  final _bpmController = TextEditingController();
  final List<DateTime> _tapTimes = [];
  Timer? _bpmRepeatTimer;
  bool _longPressActive = false;

  BpmResult? _bpmResult;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<BpmResult>? _bpmSub;
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    _stateSub = _player.stateStream.listen(_onStateChange);
    _errorSub = _player.errorStream.listen(_onError);
    _bpmSub = _player.bpmStream.listen((r) {
      setState(() {
        _bpmResult = r;
        if (r.bpm > 0) {
          _detectedBpm = r.bpm;
          _manualBpm = r.bpm;
          _bpmController.text = r.bpm.toStringAsFixed(1);
        }
      });
      // Rate is 1.0 when manualBpm == detectedBpm, so nothing changes on detection.
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _errorSub?.cancel();
    _bpmSub?.cancel();
    _positionTimer?.cancel();
    _bpmRepeatTimer?.cancel();
    _bpmController.dispose();
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
      _tapTimes.clear();
      await _player.setPlaybackRate(1.0);
      setState(() {
        _duration = dur.inMilliseconds / 1000.0;
        _loopStart = 0.0;
        _loopEnd = _duration;
        _position = 0.0;
        _bpmResult = null; // cleared until bpmStream fires
        _detectedBpm = 0.0;
        _manualBpm = 0.0;
        _bpmController.text = '';
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

  void _applyPlaybackRate() {
    if (_detectedBpm <= 0 || !_isReady) return;
    final rate = _manualBpm / _detectedBpm;
    _player.setPlaybackRate(rate).catchError((_) {});
  }

  void _adjustBpm(double delta) {
    setState(() {
      _manualBpm = (_manualBpm + delta).clamp(20.0, 300.0).toDouble();
      _bpmController.text = _manualBpm.toStringAsFixed(1);
    });
    _applyPlaybackRate();
  }

  void _onTapTempo() {
    final now = DateTime.now();
    if (_tapTimes.isNotEmpty &&
        now.difference(_tapTimes.last).inMilliseconds > 3000) {
      _tapTimes.clear();
    }
    _tapTimes.add(now);
    if (_tapTimes.length > 8) _tapTimes.removeAt(0);
    if (_tapTimes.length >= 2) {
      final intervals = <double>[];
      for (int i = 1; i < _tapTimes.length; i++) {
        intervals.add(
            _tapTimes[i].difference(_tapTimes[i - 1]).inMilliseconds / 1000.0);
      }
      final avg = intervals.reduce((a, b) => a + b) / intervals.length;
      setState(() {
        _manualBpm = (60.0 / avg).clamp(20.0, 300.0).toDouble();
        _bpmController.text = _manualBpm.toStringAsFixed(1);
      });
      _applyPlaybackRate();
    }
  }

  void _snapToBeat() {
    if (_manualBpm <= 0 || !_isReady) return;
    final beatPeriod = 60.0 / _manualBpm;
    var newStart = (_loopStart / beatPeriod).round() * beatPeriod;
    var newEnd   = (_loopEnd   / beatPeriod).round() * beatPeriod;
    newStart = newStart.clamp(0.0, _duration);
    newEnd   = newEnd.clamp(0.0, _duration);
    if (newStart >= newEnd) return;
    setState(() {
      _loopStart = newStart;
      _loopEnd   = newEnd;
    });
    _setLoopRegion();
  }

  Future<void> _setPan(double value) async {
    setState(() => _pan = value);
    try {
      await _player.setPan(value);
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

            const Divider(),

            // ── BPM Detection ──────────────────────────────────────
            Text('BPM Detection', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _BpmCard(result: _bpmResult, isReady: _isReady),

            const Divider(),

            // ── BPM Controls ──────────────────────────────────────────
            Text('BPM Controls', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Row(
              children: [
                // Decrement button with long-press repeat
                GestureDetector(
                  onLongPressStart: (_) {
                    _longPressActive = true;
                    _bpmRepeatTimer = Timer(const Duration(milliseconds: 400), () {
                      if (!_longPressActive) return;
                      _bpmRepeatTimer = Timer.periodic(
                          const Duration(milliseconds: 100), (_) => _adjustBpm(-1.0));
                    });
                  },
                  onLongPressEnd: (_) {
                    _longPressActive = false;
                    _bpmRepeatTimer?.cancel();
                    _bpmRepeatTimer = null;
                  },
                  child: IconButton(
                    icon: const Icon(Icons.remove),
                    onPressed: _isReady ? () => _adjustBpm(-1.0) : null,
                  ),
                ),
                // Manual BPM text field
                Expanded(
                  child: TextField(
                    controller: _bpmController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      labelText: 'BPM',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    enabled: _isReady,
                    onSubmitted: (v) {
                      final parsed = double.tryParse(v);
                      if (parsed != null) {
                        setState(() {
                          _manualBpm = parsed.clamp(20.0, 300.0).toDouble();
                          _bpmController.text = _manualBpm.toStringAsFixed(1);
                        });
                        _applyPlaybackRate();
                      } else {
                        _bpmController.text = _manualBpm > 0 ? _manualBpm.toStringAsFixed(1) : '';
                      }
                    },
                  ),
                ),
                // Increment button with long-press repeat
                GestureDetector(
                  onLongPressStart: (_) {
                    _longPressActive = true;
                    _bpmRepeatTimer = Timer(const Duration(milliseconds: 400), () {
                      if (!_longPressActive) return;
                      _bpmRepeatTimer = Timer.periodic(
                          const Duration(milliseconds: 100), (_) => _adjustBpm(1.0));
                    });
                  },
                  onLongPressEnd: (_) {
                    _longPressActive = false;
                    _bpmRepeatTimer?.cancel();
                    _bpmRepeatTimer = null;
                  },
                  child: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: _isReady ? () => _adjustBpm(1.0) : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _isReady ? _onTapTempo : null,
                  icon: const Icon(Icons.touch_app),
                  label: const Text('Tap Tempo'),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _isReady && _manualBpm > 0 ? _snapToBeat : null,
                  icon: const Icon(Icons.grid_on),
                  label: const Text('Snap to Beat'),
                ),
              ],
            ),
            if (_detectedBpm > 0 && _manualBpm > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Speed: ×${(_manualBpm / _detectedBpm).toStringAsFixed(2)}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
              ),

            const Divider(),

            // ── Panning ────────────────────────────────────────────────
            Text('Panning', style: Theme.of(context).textTheme.titleSmall),
            Row(
              children: [
                const SizedBox(width: 24, child: Text('L', textAlign: TextAlign.center)),
                Expanded(
                  child: Slider(
                    value: _pan,
                    min: -1.0,
                    max: 1.0,
                    divisions: 200,
                    onChanged: _isReady ? _setPan : null,
                  ),
                ),
                const SizedBox(width: 24, child: Text('R', textAlign: TextAlign.center)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  _pan == 0.0
                      ? 'Centre'
                      : _pan < 0
                          ? 'L ${(-_pan * 100).toStringAsFixed(0)}%'
                          : 'R ${(_pan * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BpmCard extends StatelessWidget {
  const _BpmCard({required this.result, required this.isReady});

  final BpmResult? result;
  final bool isReady;

  @override
  Widget build(BuildContext context) {
    if (!isReady) {
      return const Text('Load a file to see BPM detection results.',
          style: TextStyle(color: Colors.grey));
    }
    if (result == null) {
      return const Row(
        children: [
          SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Detecting BPM...'),
        ],
      );
    }
    final r = result!;
    if (r.bpm == 0.0) {
      return const Text('No BPM detected (audio too short or silent).',
          style: TextStyle(color: Colors.grey));
    }
    final confidencePct = (r.confidence * 100).toStringAsFixed(0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${r.bpm.toStringAsFixed(1)} BPM',
          style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
        const SizedBox(height: 4),
        Text('Confidence: $confidencePct%  ·  ${r.beats.length} beats detected',
            style: Theme.of(context).textTheme.bodySmall),
      ],
    );
  }
}
