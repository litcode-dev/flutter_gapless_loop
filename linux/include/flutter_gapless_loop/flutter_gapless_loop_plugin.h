#pragma once
#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

#ifdef FLUTTER_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __attribute__((visibility("default")))
#else
#define FLUTTER_PLUGIN_EXPORT
#endif

typedef struct _FlutterGaplessLoopPlugin      FlutterGaplessLoopPlugin;
typedef struct _FlutterGaplessLoopPluginClass FlutterGaplessLoopPluginClass;

FLUTTER_PLUGIN_EXPORT GType flutter_gapless_loop_plugin_get_type();

FLUTTER_PLUGIN_EXPORT void flutter_gapless_loop_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);

G_END_DECLS
