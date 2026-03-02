## 0.0.1

* Initial release.
* Sample-accurate gapless looping on iOS via AVAudioEngine and Android via AudioTrack.
* `load(assetPath)` — load audio from a Flutter asset key.
* `loadFromFile(filePath)` — load audio from an absolute file system path.
* Supported formats: WAV, AIFF, MP3, M4A.
* `play()`, `pause()`, `resume()`, `stop()` — transport controls.
* `setLoopRegion(start, end)` — restrict looping to a time region (seconds).
* `setCrossfadeDuration(seconds)` — optional crossfade between loop iterations (0–0.5 s).
* `setVolume(volume)` — volume control (0.0–1.0).
* `seek(seconds)` — seek to a position within the loaded file.
* `duration` — returns total file duration as a `Duration`.
* `currentPosition` — returns current playback position in seconds.
* `stateStream` — broadcasts `PlayerState` changes from the native layer.
* `errorStream` — broadcasts error messages from the native layer.
* `routeChangeStream` — broadcasts `RouteChangeEvent` when the audio output route changes (e.g. headphones unplugged).
* `dispose()` — releases all native resources.
