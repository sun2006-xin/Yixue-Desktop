#ifndef RUNNER_SCREENSHOT_TRANSLATION_NATIVE_ORB_PLUGIN_H_
#define RUNNER_SCREENSHOT_TRANSLATION_NATIVE_ORB_PLUGIN_H_

#include <flutter/plugin_registry.h>

// Registers the lightweight native screenshot orb on the main Flutter engine.
// Child Flutter windows intentionally do not register this plugin.
void RegisterScreenshotTranslationNativeOrbPlugin(
    flutter::PluginRegistry* registry);

#endif  // RUNNER_SCREENSHOT_TRANSLATION_NATIVE_ORB_PLUGIN_H_
