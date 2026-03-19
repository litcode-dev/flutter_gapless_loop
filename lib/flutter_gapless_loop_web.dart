import 'dart:async';
import 'dart:js_interop';
import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;
import 'package:http/http.dart' as http;

/// Web implementation of the [FlutterGaplessLoop] plugin.
class FlutterGaplessLoopWeb {
  static void registerWith(Registrar registrar) {
    final plugin = FlutterGaplessLoopWeb();
    
    final methodChannel = MethodChannel(
      'flutter_gapless_loop',
      const StandardMethodCodec(),
      registrar,
    );
    methodChannel.setMethodCallHandler(plugin.handleMethodCall);

    final eventChannel = MethodChannel(
      'flutter_gapless_loop/events',
      const StandardMethodCodec(),
      registrar,
    );
    // Note: EventChannel on web is often handled via MethodChannel mocks 
    // or by overriding the binary messenger.
    plugin._eventSink = _WebEventSink(eventChannel);

    final metronomeChannel = MethodChannel(
      'flutter_gapless_loop/metronome',
      const StandardMethodCodec(),
      registrar,
    );
    metronomeChannel.setMethodCallHandler(plugin.handleMetronomeMethodCall);

    final metronomeEventChannel = MethodChannel(
      'flutter_gapless_loop/metronome/events',
      const StandardMethodCodec(),
      registrar,
    );
    plugin._metroEventSink = _WebEventSink(metronomeEventChannel);
  }

  late final _WebEventSink _eventSink;
  late final _WebEventSink _metroEventSink;

  final web.AudioContext _audioCtx = web.AudioContext();
  final Map<String, _WebPlayer> _players = {};
  final Map<String, _WebMetronome> _metronomes = {};

  Future<dynamic> handleMethodCall(MethodCall call) async {
    final args = call.arguments as Map<Object?, Object?>;
    final playerId = args['playerId'] as String?;

    switch (call.method) {
      case 'clearAll':
        for (final p in _players.values) { p.dispose(); }
        _players.clear();
        return null;
      
      case 'loadAsset':
        if (playerId == null) return null;
        final assetKey = args['assetKey'] as String;
        final player = _getOrCreatePlayer(playerId);
        await player.loadAsset(assetKey);
        return null;

      case 'load':
        if (playerId == null) return null;
        final path = args['path'] as String;
        final player = _getOrCreatePlayer(playerId);
        await player.loadUrl(path); // On web, paths are URLs
        return null;

      case 'loadUrl':
        if (playerId == null) return null;
        final url = args['url'] as String;
        final player = _getOrCreatePlayer(playerId);
        await player.loadUrl(url);
        return null;

      case 'loadFromBytes':
        if (playerId == null) return null;
        final bytes = args['bytes'] as Uint8List;
        final player = _getOrCreatePlayer(playerId);
        await player.loadData(bytes);
        return null;

      case 'play':
        await _players[playerId]?.play();
        return null;

      case 'pause':
        _players[playerId]?.pause();
        return null;

      case 'resume':
        _players[playerId]?.resume();
        return null;

      case 'stop':
        _players[playerId]?.stop();
        return null;

      case 'setVolume':
        final volume = (args['volume'] as num).toDouble();
        _players[playerId]?.setVolume(volume);
        return null;

      case 'setPan':
        final pan = (args['pan'] as num).toDouble();
        _players[playerId]?.setPan(pan);
        return null;

      case 'setLoopRegion':
        final start = (args['start'] as num).toDouble();
        final end = (args['end'] as num).toDouble();
        _players[playerId]?.setLoopRegion(start, end);
        return null;

      case 'setCrossfadeDuration':
        final duration = (args['duration'] as num).toDouble();
        _players[playerId]?.setCrossfadeDuration(duration);
        return null;

      case 'setPlaybackRate':
        final rate = (args['rate'] as num).toDouble();
        _players[playerId]?.setPlaybackRate(rate);
        return null;

      case 'seek':
        final position = (args['position'] as num).toDouble();
        _players[playerId]?.seek(position);
        return null;

      case 'getDuration':
        return _players[playerId]?.duration ?? 0.0;

      case 'getCurrentPosition':
        return _players[playerId]?.currentPosition ?? 0.0;

      case 'dispose':
        _players.remove(playerId)?.dispose();
        return null;

      default:
        throw PlatformException(
          code: 'Unimplemented',
          details: 'Method ${call.method} not implemented',
        );
    }
  }

  Future<dynamic> handleMetronomeMethodCall(MethodCall call) async {
    final args = call.arguments as Map<Object?, Object?>;
    final playerId = args['playerId'] as String?;

    switch (call.method) {
      case 'clearAll':
        for (final m in _metronomes.values) { m.dispose(); }
        _metronomes.clear();
        return null;

      case 'start':
        if (playerId == null) return null;
        final bpm = (args['bpm'] as num).toDouble();
        final beatsPerBar = args['beatsPerBar'] as int;
        final click = args['click'] as Uint8List;
        final accent = args['accent'] as Uint8List;
        final metro = _getOrCreateMetronome(playerId);
        await metro.start(bpm, beatsPerBar, click, accent);
        return null;

      case 'stop':
        _metronomes[playerId]?.stop();
        return null;

      case 'setBpm':
        final bpm = (args['bpm'] as num).toDouble();
        _metronomes[playerId]?.setBpm(bpm);
        return null;

      case 'setBeatsPerBar':
        final beatsPerBar = args['beatsPerBar'] as int;
        _metronomes[playerId]?.setBeatsPerBar(beatsPerBar);
        return null;

      case 'setVolume':
        final volume = (args['volume'] as num).toDouble();
        _metronomes[playerId]?.setVolume(volume);
        return null;

      case 'setPan':
        final pan = (args['pan'] as num).toDouble();
        _metronomes[playerId]?.setPan(pan);
        return null;

      case 'dispose':
        _metronomes.remove(playerId)?.dispose();
        return null;

      default:
        throw PlatformException(
          code: 'Unimplemented',
          details: 'Method ${call.method} not implemented',
        );
    }
  }

  _WebPlayer _getOrCreatePlayer(String id) {
    return _players.putIfAbsent(id, () => _WebPlayer(id, _audioCtx, _eventSink));
  }

  _WebMetronome _getOrCreateMetronome(String id) {
    return _metronomes.putIfAbsent(id, () => _WebMetronome(id, _audioCtx, _metroEventSink));
  }
}

class _WebEventSink {
  final String channelName;
  _WebEventSink(MethodChannel channel) : channelName = channel.name;

  void success(Map<String, dynamic> event) {
    const codec = StandardMethodCodec();
    final data = codec.encodeSuccessEnvelope(event);
    ServicesBinding.instance.defaultBinaryMessenger.send(channelName, data);
  }
}

class _WebPlayer {
  final String id;
  final web.AudioContext ctx;
  final _WebEventSink sink;

  web.AudioBuffer? _buffer;
  web.AudioBufferSourceNode? _source;
  final web.GainNode _gain;
  final web.StereoPannerNode _panner;

  double _loopStart = 0.0;
  double _loopEnd = 0.0;
  double _playbackRate = 1.0;

  // Playback position tracking
  double _playStartTime = 0.0; // ctx.currentTime when source.start() was called
  double _seekOffset = 0.0;    // buffer position when source.start() was called
  double _pauseOffset = 0.0;   // buffer position saved on pause
  bool _isPlaying = false;

  _WebPlayer(this.id, this.ctx, this.sink) 
    : _gain = ctx.createGain(),
      _panner = ctx.createStereoPanner() {
    _gain.connect(_panner);
    _panner.connect(ctx.destination);
  }

  Future<void> loadAsset(String key) async {
    // Asset keys are already the correct relative URL path in Flutter web
    // (e.g. 'assets/loop.wav' → served at 'assets/loop.wav').
    // Do NOT prefix with 'assets/' — that would produce 'assets/assets/loop.wav'.
    final response = await http.get(Uri.parse(key));
    await loadData(response.bodyBytes);
  }

  Future<void> loadUrl(String url) async {
    final response = await http.get(Uri.parse(url));
    await loadData(response.bodyBytes);
  }

  Future<void> loadData(Uint8List data) async {
    _emitState('loading');
    _buffer = await ctx.decodeAudioData(data.buffer.toJS).toDart;
    _loopStart = 0;
    _loopEnd = _buffer!.duration;
    _pauseOffset = 0;
    _emitState('ready');
  }

  Future<void> play() async {
    if (_buffer == null) return;
    // Resume the AudioContext if it was suspended by the browser's autoplay
    // policy. A user gesture (tap/click) is required before audio can start.
    if (ctx.state == 'suspended') {
      await ctx.resume().toDart;
    }
    _stopSource();
    _createSource();
    _seekOffset = _loopStart;
    _playStartTime = ctx.currentTime;
    _source!.start(0, _loopStart);
    _isPlaying = true;
    _emitState('playing');
  }

  void pause() {
    _pauseOffset = currentPosition;
    _stopSource();
    _isPlaying = false;
    _emitState('paused');
  }

  void resume() {
    if (_buffer == null) return;
    _stopSource();
    _createSource();
    _seekOffset = _pauseOffset;
    _playStartTime = ctx.currentTime;
    _source!.start(0, _pauseOffset);
    _isPlaying = true;
    _emitState('playing');
  }

  void stop() {
    _pauseOffset = _loopStart;
    _stopSource();
    _isPlaying = false;
    _emitState('stopped');
  }

  void _createSource() {
    _source = ctx.createBufferSource();
    _source!.buffer = _buffer;
    _source!.loop = true;
    _source!.loopStart = _loopStart;
    _source!.loopEnd = _loopEnd;
    _source!.playbackRate.value = _playbackRate;
    _source!.connect(_gain);
  }

  void _stopSource() {
    try {
      _source?.stop();
    } catch (_) {
      // AudioBufferSourceNode.stop() throws InvalidStateError if the node
      // has already ended naturally — safe to ignore.
    }
    _source = null;
  }

  void setVolume(double v) {
    _gain.gain.value = v;
  }

  void setPan(double p) {
    _panner.pan.value = p;
  }

  void setLoopRegion(double s, double e) {
    _loopStart = s;
    _loopEnd = e;
    if (_source != null) {
      _source!.loopStart = s;
      _source!.loopEnd = e;
    }
  }

  void setCrossfadeDuration(double d) {
    // Crossfade requires a custom AudioWorklet for sample-accurate equal-power
    // crossfade at the loop boundary, which is not supported on web.
    throw UnsupportedError(
      'setCrossfadeDuration is not supported on web. '
      'Crossfade requires a custom AudioWorklet for sample-accurate '
      'loop-boundary processing.',
    );
  }

  void setPlaybackRate(double r) {
    _playbackRate = r;
    if (_source != null) {
      _source!.playbackRate.value = r;
    }
  }

  void seek(double p) {
    if (_buffer == null) return;
    final wasPlaying = _isPlaying;
    _stopSource();
    _pauseOffset = p;
    if (wasPlaying) {
      _createSource();
      _seekOffset = p;
      _playStartTime = ctx.currentTime;
      _source!.start(0, p);
      _isPlaying = true;
    }
  }

  double get duration => _buffer?.duration ?? 0.0;

  double get currentPosition {
    if (_buffer == null) return 0.0;
    if (!_isPlaying) return _pauseOffset;
    final loopDuration = _loopEnd - _loopStart;
    if (loopDuration <= 0) return _seekOffset;
    final elapsed = ctx.currentTime - _playStartTime;
    return _loopStart + (_seekOffset - _loopStart + elapsed) % loopDuration;
  }

  void dispose() {
    _stopSource();
    _buffer = null;
    _gain.disconnect();
    _panner.disconnect();
  }

  void _emitState(String state) {
    sink.success({
      'playerId': id,
      'type': 'stateChange',
      'state': state,
    });
  }
}

class _WebMetronome {
  final String id;
  final web.AudioContext ctx;
  final _WebEventSink sink;

  web.AudioBuffer? _clickBuffer;
  web.AudioBuffer? _accentBuffer;
  final web.GainNode _gain;
  final web.StereoPannerNode _panner;

  double _bpm = 120.0;
  int _beatsPerBar = 4;
  bool _isPlaying = false;

  _WebMetronome(this.id, this.ctx, this.sink)
    : _gain = ctx.createGain(),
      _panner = ctx.createStereoPanner() {
    _gain.connect(_panner);
    _panner.connect(ctx.destination);
  }

  Future<void> start(double bpm, int beatsPerBar, Uint8List click, Uint8List accent) async {
    _bpm = bpm;
    _beatsPerBar = beatsPerBar;
    _clickBuffer = await ctx.decodeAudioData(click.buffer.toJS).toDart;
    _accentBuffer = await ctx.decodeAudioData(accent.buffer.toJS).toDart;
    
    _isPlaying = true;
    _scheduleTicks(ctx.currentTime);
  }

  void _scheduleTicks(double startTime) {
    if (!_isPlaying) return;
    
    final secondsPerBeat = 60.0 / _bpm;

    // Note: setBpm/setBeatsPerBar take effect at the next bar boundary —
    // already-scheduled nodes for the current bar complete at the original tempo.
    for (int i = 0; i < _beatsPerBar; i++) {
      final time = startTime + i * secondsPerBeat;
      final source = ctx.createBufferSource();
      source.buffer = (i == 0) ? _accentBuffer : _clickBuffer;
      source.connect(_gain);
      source.start(time);
      
      // Emit beat event
      Timer(Duration(milliseconds: ((time - ctx.currentTime) * 1000).toInt()), () {
        if (_isPlaying) {
          sink.success({
            'playerId': id,
            'type': 'beatTick',
            'beat': i,
          });
        }
      });
    }

    // Schedule next bar
    Timer(Duration(milliseconds: ((_beatsPerBar * secondsPerBeat - 0.05) * 1000).toInt()), () {
      if (_isPlaying) {
        _scheduleTicks(startTime + _beatsPerBar * secondsPerBeat);
      }
    });
  }

  void stop() {
    _isPlaying = false;
  }

  void setBpm(double bpm) {
    _bpm = bpm;
  }

  void setBeatsPerBar(int beatsPerBar) {
    _beatsPerBar = beatsPerBar;
  }

  void setVolume(double v) {
    _gain.gain.value = v;
  }

  void setPan(double p) {
    _panner.pan.value = p;
  }

  void dispose() {
    stop();
    _gain.disconnect();
    _panner.disconnect();
  }
}
