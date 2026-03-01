/// Flutter plugin for true sample-accurate gapless audio looping on iOS.
///
/// Primary entry point is [LoopAudioPlayer].
///
/// ## Quick Start
///
/// ```dart
/// import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
///
/// final player = LoopAudioPlayer();
/// await player.loadFromFile('/absolute/path/to/loop.wav');
/// await player.play();
/// // ... later
/// await player.dispose();
/// ```
library;

export 'src/loop_audio_player.dart';
export 'src/loop_audio_state.dart';
