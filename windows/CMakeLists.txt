cmake_minimum_required(VERSION 3.14)
project(flutter_gapless_loop_library VERSION 0.0.1)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Target Windows 10+ for XAudio2 2.9 and MediaFoundation
add_compile_definitions(
  _WIN32_WINNT=0x0A00
  WINVER=0x0A00
  INITGUID               # Defines GUIDs declared with DEFINE_GUID inline
)

set(PLUGIN_NAME flutter_gapless_loop_plugin)

add_library(${PLUGIN_NAME} SHARED
  flutter_gapless_loop_plugin.cpp
  loop_audio_engine.cpp
  audio_decoder.cpp
  bpm_detector.cpp
  metronome_engine.cpp
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME}
  INTERFACE "${CMAKE_CURRENT_SOURCE_DIR}/include"
  PRIVATE   "${CMAKE_CURRENT_SOURCE_DIR}"
)

target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  # MediaFoundation — audio file decoding
  mf.lib
  mfplat.lib
  mfuuid.lib
  mfreadwrite.lib
  # COM (required by XAudio2 and MediaFoundation)
  ole32.lib
  oleaut32.lib
  # Audio device enumeration — IMMNotificationClient
  Mmdevapi.lib
  # URL download — URLDownloadToFileW
  urlmon.lib
)
