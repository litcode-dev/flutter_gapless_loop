#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_gapless_loop.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_gapless_loop'
  s.version          = '0.0.6'
  s.summary          = 'True sample-accurate gapless audio looping for iOS and macOS using AVAudioEngine.'
  s.description      = <<-DESC
Achieves zero-gap, zero-click audio loop playback using AVAudioEngine scheduleBuffer with .loops
option. Supports loop regions, crossfade, BPM detection, metronome, and automatic click prevention
via micro-fades.
                       DESC
  s.homepage         = 'https://github.com/litcode-dev/flutter_gapless_loop'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'flutter_gapless_loop' => 'plugin@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.frameworks = 'AVFoundation'
  s.ios.deployment_target = '14.0'
  s.osx.deployment_target = '11.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
