cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "screenshot_window_activation_plugin.cpp"
  "screenshot_translation_native_orb_plugin.cpp"
  "wasapi_audio_capture_plugin.cpp"
  "wasapi_loopback_capture.cpp"
  "windows_screen_capture.cpp"
  "windows_screen_recording_plugin.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Runner sources include UTF-8 Chinese diagnostics and user-facing messages.
target_compile_options(${BINARY_NAME} PRIVATE /utf-8)
target_compile_definitions(${BINARY_NAME} PRIVATE
  "_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS"
)

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE
  flutter
  flutter_wrapper_app
  flutter_wrapper_plugin
)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "gdiplus.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "propsys.lib")
target_link_libraries(${BINARY_NAME} PRIVATE
  "d3d11.lib"
  "dxgi.lib"
  "mfplat.lib"
  "mfreadwrite.lib"
  "mfuuid.lib"
  "windowsapp.lib"
)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Focused native lifecycle contract tests are opt-in and never ship in the
# portable application bundle.
add_executable(yixue_process_lifecycle_tests EXCLUDE_FROM_ALL
  "tests/supervised_process_lifecycle_test.cpp"
)
target_compile_features(yixue_process_lifecycle_tests PRIVATE cxx_std_17)
target_compile_options(yixue_process_lifecycle_tests PRIVATE /W4 /WX /utf-8)
target_compile_definitions(yixue_process_lifecycle_tests PRIVATE NOMINMAX)

add_executable(yixue_native_method_exception_boundary_tests EXCLUDE_FROM_ALL
  "tests/native_method_exception_boundary_test.cpp"
)
target_include_directories(yixue_native_method_exception_boundary_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_native_method_exception_boundary_tests PRIVATE cxx_std_17)
target_compile_options(yixue_native_method_exception_boundary_tests PRIVATE /W4 /WX /utf-8)
target_compile_definitions(yixue_native_method_exception_boundary_tests PRIVATE NOMINMAX)

add_executable(yixue_wasapi_audio_callback_boundary_tests EXCLUDE_FROM_ALL
  "tests/wasapi_audio_callback_boundary_test.cpp"
)
target_include_directories(yixue_wasapi_audio_callback_boundary_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_wasapi_audio_callback_boundary_tests PRIVATE cxx_std_17)
target_compile_options(yixue_wasapi_audio_callback_boundary_tests PRIVATE
  /EHsc /W4 /WX /utf-8
)
target_compile_definitions(yixue_wasapi_audio_callback_boundary_tests PRIVATE NOMINMAX)

add_executable(yixue_screenshot_orb_drag_tests EXCLUDE_FROM_ALL
  "tests/screenshot_orb_drag_test.cpp"
)
target_include_directories(yixue_screenshot_orb_drag_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_screenshot_orb_drag_tests PRIVATE cxx_std_17)
target_compile_options(yixue_screenshot_orb_drag_tests PRIVATE /W4 /WX /utf-8)
target_compile_definitions(yixue_screenshot_orb_drag_tests PRIVATE NOMINMAX)

add_executable(yixue_screen_recording_operation_queue_tests EXCLUDE_FROM_ALL
  "tests/screen_recording_operation_queue_test.cpp"
)
target_include_directories(yixue_screen_recording_operation_queue_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_screen_recording_operation_queue_tests PRIVATE cxx_std_17)
target_compile_options(yixue_screen_recording_operation_queue_tests PRIVATE
  /EHsc /W4 /WX /utf-8
)
target_compile_definitions(yixue_screen_recording_operation_queue_tests PRIVATE NOMINMAX)

add_executable(yixue_wasapi_worker_lifecycle_tests EXCLUDE_FROM_ALL
  "tests/wasapi_worker_completion_test.cpp"
)
target_include_directories(yixue_wasapi_worker_lifecycle_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_wasapi_worker_lifecycle_tests PRIVATE cxx_std_17)
target_compile_options(yixue_wasapi_worker_lifecycle_tests PRIVATE /W4 /WX /utf-8)
target_compile_definitions(yixue_wasapi_worker_lifecycle_tests PRIVATE NOMINMAX)

add_executable(yixue_recording_operation_worker_tests EXCLUDE_FROM_ALL
  "tests/recording_operation_worker_test.cpp"
)
target_include_directories(yixue_recording_operation_worker_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_recording_operation_worker_tests PRIVATE cxx_std_17)
target_compile_options(yixue_recording_operation_worker_tests PRIVATE
  /EHsc /W4 /WX /utf-8
)
target_compile_definitions(yixue_recording_operation_worker_tests PRIVATE NOMINMAX)

add_executable(yixue_screen_capture_completion_drain_tests EXCLUDE_FROM_ALL
  "tests/screen_capture_completion_drain_test.cpp"
)
target_include_directories(yixue_screen_capture_completion_drain_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_screen_capture_completion_drain_tests PRIVATE cxx_std_17)
target_compile_options(yixue_screen_capture_completion_drain_tests PRIVATE
  /EHsc /W4 /WX /utf-8
)
target_compile_definitions(yixue_screen_capture_completion_drain_tests PRIVATE NOMINMAX)

add_executable(yixue_ui_cleanup_watchdog_state_tests EXCLUDE_FROM_ALL
  "tests/ui_cleanup_watchdog_state_test.cpp"
)
target_include_directories(yixue_ui_cleanup_watchdog_state_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_ui_cleanup_watchdog_state_tests PRIVATE cxx_std_17)
target_compile_options(yixue_ui_cleanup_watchdog_state_tests PRIVATE /W4 /WX /utf-8)
target_compile_definitions(yixue_ui_cleanup_watchdog_state_tests PRIVATE NOMINMAX)

add_executable(yixue_recording_time_anchor_tests EXCLUDE_FROM_ALL
  "tests/recording_time_anchor_test.cpp"
)
target_include_directories(yixue_recording_time_anchor_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
)
target_compile_features(yixue_recording_time_anchor_tests PRIVATE cxx_std_17)
target_compile_options(yixue_recording_time_anchor_tests PRIVATE /EHsc /W4 /WX /utf-8)
target_compile_definitions(yixue_recording_time_anchor_tests PRIVATE NOMINMAX)
