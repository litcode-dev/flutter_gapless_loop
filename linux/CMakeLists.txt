cmake_minimum_required(VERSION 3.14)
project(flutter_gapless_loop_plugin)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(PkgConfig REQUIRED)
pkg_check_modules(CURL REQUIRED libcurl)

set(PLUGIN_NAME flutter_gapless_loop_plugin)

add_library(${PLUGIN_NAME} SHARED
  flutter_gapless_loop_plugin.cpp
  loop_audio_engine.cpp
  audio_decoder.cpp
  bpm_detector.cpp
  metronome_engine.cpp
  miniaudio_impl.cpp
)

apply_standard_settings(${PLUGIN_NAME})

target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
  "${CMAKE_CURRENT_SOURCE_DIR}/third_party"
  ${CURL_INCLUDE_DIRS}
)

target_link_libraries(${PLUGIN_NAME} PUBLIC
  flutter_linux
  PkgConfig::CURL
  dl
  pthread
  m
)

target_compile_definitions(${PLUGIN_NAME} PRIVATE
  FLUTTER_PLUGIN_IMPL
)
