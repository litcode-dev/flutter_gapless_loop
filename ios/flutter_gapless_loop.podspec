#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_gapless_loop.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'flutter_gapless_loop'
  s.version          = '0.0.1'
  s.summary          = 'True sample-accurate gapless audio looping for iOS using AVAudioEngine.'
  s.description      = <<-DESC
Achieves zero-gap, zero-click audio loop playback using AVAudioEngine scheduleBuffer with .loops option. Supports loop regions, crossfade, and automatic click prevention via micro-fades.
                       DESC
  s.homepage         = 'https://github.com/example/flutter_gapless_loop'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'flutter_gapless_loop' => 'plugin@example.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks = 'AVFoundation'
  s.platform = :ios, '13.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_gapless_loop_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
