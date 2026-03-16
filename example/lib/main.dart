import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
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

  AmplitudeEvent _amplitude = const AmplitudeEvent(rms: 0, peak: 0);

  // Tier 2 state
  WaveformData? _waveform;
  LoudnessInfo? _loudness;
  SilenceInfo?  _silenceInfo;
  bool _analysisBusy = false;

  StreamSubscription<PlayerState>? _stateSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<BpmResult>? _bpmSub;
  StreamSubscription<AmplitudeEvent>? _ampSub;
  Timer? _positionTimer;

  @override
  void initState() {
    super.initState();
    _stateSub = _player.stateStream.listen(_onStateChange);
    _errorSub = _player.errorStream.listen(_onError);
    _ampSub   = _player.amplitudeStream.listen((a) {
      setState(() => _amplitude = a);
    });
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
    _ampSub?.cancel();
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
        _waveform = null;
        _loudness = null;
        _silenceInfo = null;
        _analysisBusy = false;
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

  Future<void> _runAnalysis() async {
    if (!_isReady || _analysisBusy) return;
    setState(() => _analysisBusy = true);
    try {
      final wf      = await _player.getWaveformData(resolution: 200);
      final loud    = await _player.getLoudness();
      final silence = await _player.detectSilence(thresholdDb: -60.0);
      setState(() {
        _waveform    = wf;
        _loudness    = loud;
        _silenceInfo = silence;
      });
    } catch (e) {
      _onError(e.toString());
    } finally {
      setState(() => _analysisBusy = false);
    }
  }

  Future<void> _trimSilence() async {
    try {
      await _player.trimSilence(thresholdDb: -60.0);
      final silence = await _player.detectSilence(thresholdDb: -60.0);
      setState(() {
        _loopStart   = silence.start;
        _loopEnd     = silence.end;
        _silenceInfo = silence;
      });
    } catch (e) {
      _onError(e.toString());
    }
  }

  Future<void> _normaliseLoudness() async {
    try {
      await _player.normaliseLoudness(targetLufs: -14.0);
      final loud = await _player.getLoudness();
      setState(() => _loudness = loud);
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

            // ── Amplitude Meter ────────────────────────────────────
            Text('Amplitude', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            _AmplitudeMeter(amplitude: _amplitude),

            const Divider(),

            // ── Fade Controls ──────────────────────────────────────
            Text('Fade', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton.icon(
                  onPressed: _isReady
                      ? () => _player.fadeIn(
                            duration: const Duration(milliseconds: 800))
                      : null,
                  icon: const Icon(Icons.trending_up, size: 16),
                  label: const Text('Fade In'),
                ),
                ElevatedButton.icon(
                  onPressed: _isReady
                      ? () => _player.fadeOut(
                            duration: const Duration(milliseconds: 800))
                      : null,
                  icon: const Icon(Icons.trending_down, size: 16),
                  label: const Text('Fade Out'),
                ),
                ElevatedButton.icon(
                  onPressed: _isReady
                      ? () => _player.fadeTo(0.5,
                            duration: const Duration(milliseconds: 600))
                      : null,
                  icon: const Icon(Icons.volume_down, size: 16),
                  label: const Text('Fade → 50%'),
                ),
              ],
            ),

            const Divider(),

            // ── Audio Analysis ──────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Audio Analysis', style: Theme.of(context).textTheme.titleSmall),
                ElevatedButton.icon(
                  onPressed: _isReady && !_analysisBusy ? _runAnalysis : null,
                  icon: _analysisBusy
                      ? const SizedBox(
                          width: 14, height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.analytics, size: 16),
                  label: const Text('Analyse'),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Waveform
            if (_waveform != null) ...[
              Text('Waveform (${_waveform!.resolution} pts)',
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 4),
              SizedBox(
                height: 60,
                child: CustomPaint(
                  painter: _WaveformPainter(
                    peaks: _waveform!.peaks,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 8),
            ],

            // Loudness
            if (_loudness != null) ...[
              Row(
                children: [
                  Text('Loudness: ${_loudness!.lufs.toStringAsFixed(1)} LUFS',
                      style: Theme.of(context).textTheme.bodySmall),
                  const SizedBox(width: 12),
                  TextButton(
                    onPressed: _isReady ? _normaliseLoudness : null,
                    child: const Text('Normalise to −14 LUFS'),
                  ),
                ],
              ),
            ],

            // Silence info
            if (_silenceInfo != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Non-silent: ${_silenceInfo!.start.toStringAsFixed(2)}s – '
                      '${_silenceInfo!.end.toStringAsFixed(2)}s '
                      '(${_silenceInfo!.duration.toStringAsFixed(2)}s)',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  TextButton(
                    onPressed: _isReady ? _trimSilence : null,
                    child: const Text('Trim Silence'),
                  ),
                ],
              ),
            ],

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

            const Divider(),

            // ── Master Controls ─────────────────────────────────────────
            const _MasterControlsCard(),

            const Divider(),

            // ── Metronome ──────────────────────────────────────────────
            const _MetronomeCard(),
          ],
        ),
      ),
    );
  }
}

/// Generates a short sine-burst as a raw WAV [Uint8List].
///
/// [freq] — frequency in Hz (e.g. 880 for click, 1760 for accent).
/// [durationMs] — length in milliseconds.
/// [amplitude] — peak amplitude 0.0–1.0.
Uint8List _generateSineWav({
  required double freq,
  required int durationMs,
  double amplitude = 0.8,
  int sampleRate = 44100,
}) {
  final numSamples = (sampleRate * durationMs / 1000).round();
  final pcm = Int16List(numSamples);
  for (var i = 0; i < numSamples; i++) {
    final t = i / sampleRate;
    // 5 ms fade-in, 20 ms fade-out to prevent clicks
    double env = 1.0;
    final fadeInFrames  = (sampleRate * 0.005).round();
    final fadeOutFrames = (sampleRate * 0.020).round();
    if (i < fadeInFrames) {
      env = i / fadeInFrames;
    } else if (i > numSamples - fadeOutFrames) {
      env = (numSamples - i) / fadeOutFrames;
    }
    pcm[i] = (amplitude * env * 32767 * math.sin(2 * math.pi * freq * t))
        .round()
        .clamp(-32768, 32767);
  }

  final dataBytes  = pcm.buffer.asUint8List();
  final totalBytes = 44 + dataBytes.length;
  final header     = ByteData(44)
    ..setUint32(0,  0x52494646, Endian.big)          // "RIFF"
    ..setUint32(4,  totalBytes - 8, Endian.little)
    ..setUint32(8,  0x57415645, Endian.big)          // "WAVE"
    ..setUint32(12, 0x666d7420, Endian.big)          // "fmt "
    ..setUint32(16, 16, Endian.little)               // chunk size
    ..setUint16(20, 1, Endian.little)                // PCM
    ..setUint16(22, 1, Endian.little)                // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)   // byte rate
    ..setUint16(32, 2, Endian.little)                // block align
    ..setUint16(34, 16, Endian.little)               // bits per sample
    ..setUint32(36, 0x64617461, Endian.big)          // "data"
    ..setUint32(40, dataBytes.length, Endian.little);

  return Uint8List.fromList([...header.buffer.asUint8List(), ...dataBytes]);
}

// ──────────────────────────────────────────────────────────────────────────────
// Metronome Card
// ──────────────────────────────────────────────────────────────────────────────

class _MetronomeCard extends StatefulWidget {
  const _MetronomeCard();

  @override
  State<_MetronomeCard> createState() => _MetronomeCardState();
}

class _MetronomeCardState extends State<_MetronomeCard> {
  final _metronome = MetronomePlayer();

  bool   _running     = false;
  double _bpm         = 100.0;
  int    _beatsPerBar = 4;
  int    _currentBeat = -1;

  StreamSubscription<int>? _beatSub;

  // Pre-generate click and accent WAV bytes once (static, reused across rebuilds).
  static final _clickBytes  = _generateSineWav(freq: 880,  durationMs: 40);
  static final _accentBytes = _generateSineWav(freq: 1760, durationMs: 50, amplitude: 1.0);

  @override
  void dispose() {
    _beatSub?.cancel();
    _metronome.dispose();
    super.dispose();
  }

  Future<void> _toggleMetronome() async {
    if (_running) {
      await _metronome.stop();
      _beatSub?.cancel();
      setState(() { _running = false; _currentBeat = -1; });
    } else {
      await _metronome.start(
        bpm: _bpm,
        beatsPerBar: _beatsPerBar,
        click: _clickBytes,
        accent: _accentBytes,
      );
      _beatSub = _metronome.beatStream.listen((beat) {
        if (mounted) setState(() => _currentBeat = beat);
      });
      setState(() => _running = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Metronome', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 12),

        // ── Beat indicator dots ────────────────────────────────
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(_beatsPerBar, (i) {
            final isActive = _running && i == _currentBeat;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 80),
              margin: const EdgeInsets.symmetric(horizontal: 6),
              width: 28, height: 28,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive
                    ? (i == 0 ? Colors.orange : Colors.blue)
                    : Colors.grey.shade300,
              ),
            );
          }),
        ),
        const SizedBox(height: 16),

        // ── BPM slider ─────────────────────────────────────────
        Row(
          children: [
            const SizedBox(width: 50, child: Text('BPM')),
            Expanded(
              child: Slider(
                value: _bpm,
                min: 40, max: 240,
                divisions: 200,
                label: _bpm.round().toString(),
                onChanged: (v) async {
                  setState(() => _bpm = v);
                  if (_running) await _metronome.setBpm(v);
                },
              ),
            ),
            SizedBox(width: 36, child: Text(_bpm.round().toString())),
          ],
        ),

        // ── Time signature ─────────────────────────────────────
        Row(
          children: [
            const SizedBox(width: 50, child: Text('Time')),
            DropdownButton<int>(
              value: _beatsPerBar,
              items: [2, 3, 4, 5, 6, 7]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n/4')))
                  .toList(),
              onChanged: (v) async {
                if (v == null) return;
                setState(() { _beatsPerBar = v; _currentBeat = -1; });
                if (_running) await _metronome.setBeatsPerBar(v);
              },
            ),
          ],
        ),
        const SizedBox(height: 12),

        // ── Start / Stop button ────────────────────────────────
        Center(
          child: ElevatedButton.icon(
            onPressed: _toggleMetronome,
            icon: Icon(_running ? Icons.stop : Icons.play_arrow),
            label: Text(_running ? 'Stop' : 'Start'),
            style: ElevatedButton.styleFrom(
              backgroundColor: _running ? Colors.red : Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Master Controls Card
// ──────────────────────────────────────────────────────────────────────────────

class _MasterControlsCard extends StatefulWidget {
  const _MasterControlsCard();

  @override
  State<_MasterControlsCard> createState() => _MasterControlsCardState();
}

class _MasterControlsCardState extends State<_MasterControlsCard> {
  double _loopVol  = 1.0;
  double _loopPan  = 0.0;
  double _metroVol = 1.0;
  double _metroPan = 0.0;

  Future<void> _resetAll() async {
    await LoopAudioMaster.reset();
    await MetronomeMaster.reset();
    setState(() {
      _loopVol  = LoopAudioMaster.volume;
      _loopPan  = LoopAudioMaster.pan;
      _metroVol = MetronomeMaster.volume;
      _metroPan = MetronomeMaster.pan;
    });
  }

  String _panLabel(double v) => v == 0.0
      ? 'C'
      : v < 0
          ? 'L ${(-v * 100).toStringAsFixed(0)}%'
          : 'R ${(v * 100).toStringAsFixed(0)}%';

  @override
  Widget build(BuildContext context) {
    final labelStyle = Theme.of(context)
        .textTheme
        .labelMedium
        ?.copyWith(color: Colors.grey.shade600);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Master Controls',
                style: Theme.of(context).textTheme.titleSmall),
            TextButton.icon(
              onPressed: _resetAll,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Reset All'),
            ),
          ],
        ),
        const SizedBox(height: 4),

        // ── Loop Player Master ──────────────────────────────────
        Text('Loop Player', style: labelStyle),
        _MasterSliderRow(
          label: 'Vol',
          value: _loopVol,
          min: 0.0,
          max: 1.0,
          display: _loopVol.toStringAsFixed(2),
          onChanged: (v) {
            setState(() => _loopVol = v);
            LoopAudioMaster.setVolume(v);
          },
        ),
        _MasterSliderRow(
          label: 'Pan',
          value: _loopPan,
          min: -1.0,
          max: 1.0,
          display: _panLabel(_loopPan),
          onChanged: (v) {
            setState(() => _loopPan = v);
            LoopAudioMaster.setPan(v);
          },
        ),

        const SizedBox(height: 8),

        // ── Metronome Master ────────────────────────────────────
        Text('Metronome', style: labelStyle),
        _MasterSliderRow(
          label: 'Vol',
          value: _metroVol,
          min: 0.0,
          max: 1.0,
          display: _metroVol.toStringAsFixed(2),
          onChanged: (v) {
            setState(() => _metroVol = v);
            MetronomeMaster.setVolume(v);
          },
        ),
        _MasterSliderRow(
          label: 'Pan',
          value: _metroPan,
          min: -1.0,
          max: 1.0,
          display: _panLabel(_metroPan),
          onChanged: (v) {
            setState(() => _metroPan = v);
            MetronomeMaster.setPan(v);
          },
        ),
      ],
    );
  }
}

class _MasterSliderRow extends StatelessWidget {
  const _MasterSliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.display,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String display;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(
          child: Slider(
            value: value,
            min: min,
            max: max,
            divisions: 200,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 54,
          child: Text(display,
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.right),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Amplitude Meter
// ──────────────────────────────────────────────────────────────────────────────

class _AmplitudeMeter extends StatelessWidget {
  const _AmplitudeMeter({required this.amplitude});

  final AmplitudeEvent amplitude;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final labelStyle  = Theme.of(context).textTheme.bodySmall;

    return Column(
      children: [
        _LevelRow(
          label: 'RMS',
          value: amplitude.rms,
          color: colorScheme.primary,
          labelStyle: labelStyle,
        ),
        const SizedBox(height: 6),
        _LevelRow(
          label: 'Peak',
          value: amplitude.peak,
          color: colorScheme.error,
          labelStyle: labelStyle,
        ),
      ],
    );
  }
}

class _LevelRow extends StatelessWidget {
  const _LevelRow({
    required this.label,
    required this.value,
    required this.color,
    required this.labelStyle,
  });

  final String label;
  final double value;
  final Color color;
  final TextStyle? labelStyle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 36, child: Text(label, style: labelStyle)),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 12,
              backgroundColor: Colors.grey.shade200,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 40,
          child: Text(
            value.toStringAsFixed(3),
            style: labelStyle,
            textAlign: TextAlign.right,
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────────────────────
// Waveform Painter
// ──────────────────────────────────────────────────────────────────────────────

class _WaveformPainter extends CustomPainter {
  const _WaveformPainter({required this.peaks, required this.color});

  final List<double> peaks;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (peaks.isEmpty) return;
    final paint = Paint()
      ..color = color.withOpacity(0.8)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;

    final midY    = size.height / 2;
    final barW    = size.width / peaks.length;

    for (int i = 0; i < peaks.length; i++) {
      final x   = i * barW + barW / 2;
      final half = peaks[i] * midY;
      canvas.drawLine(Offset(x, midY - half), Offset(x, midY + half), paint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) => old.peaks != peaks;
}

// ──────────────────────────────────────────────────────────────────────────────

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
        if (r.beatsPerBar > 0) ...[
          const SizedBox(height: 2),
          Text(
            '${r.beatsPerBar}/4 time  ·  ${r.bars.length} bars',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ],
    );
  }
}
