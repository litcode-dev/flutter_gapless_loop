#include "include/flutter_gapless_loop/flutter_gapless_loop_plugin.h"
#include <flutter_linux/flutter_linux.h>

struct _FlutterGaplessLoopPlugin { GObject parent_instance; };
G_DEFINE_TYPE(FlutterGaplessLoopPlugin, flutter_gapless_loop_plugin, G_TYPE_OBJECT)

static void flutter_gapless_loop_plugin_class_init(FlutterGaplessLoopPluginClass*) {}
static void flutter_gapless_loop_plugin_init(FlutterGaplessLoopPlugin*)             {}

void flutter_gapless_loop_plugin_register_with_registrar(FlPluginRegistrar*) {}
