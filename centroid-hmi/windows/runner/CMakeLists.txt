cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "crash_handler.cpp"
  "dart_liveness.cpp"
  "egl_storm_detector.cpp"
  "stderr_interposer.cpp"
  "crash_record.cpp"
  "flutter_window.cpp"
  "gpu_device_probe.cpp"
  "gpu_diagnosis.cpp"
  "gpu_watchdog.cpp"
  "log_rotation.cpp"
  "log_throttle.cpp"
  "main.cpp"
  "output_target.cpp"
  "path_utils.cpp"
  "runner_log.cpp"
  "engine_rebuild_gate.cpp"
  "session_rebuild_policy.cpp"
  "shutdown_policy.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

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
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# WTSRegisterSessionNotification — the GPU watchdog uses RDP session changes as
# a hint that the display adapter (and with it the D3D device) was swapped.
target_link_libraries(${BINARY_NAME} PRIVATE "wtsapi32.lib")
# MiniDumpWriteDump — linked rather than LoadLibrary'd, so the crash handler
# needs no loader activity at the moment it runs.
target_link_libraries(${BINARY_NAME} PRIVATE "dbghelp.lib")
# D3D11CreateDevice / IDXGIAdapter::GetDesc — the sentinel device the GPU
# loss report asks GetDeviceRemovedReason(). See gpu_device_probe.h.
target_link_libraries(${BINARY_NAME} PRIVATE "d3d11.lib" "dxgi.lib")
# RegisterEventSource / ReportEvent — a crash record has to reach somewhere
# that outlives the app's own log file.
target_link_libraries(${BINARY_NAME} PRIVATE "advapi32.lib")
# RevokeDragDrop — DestroyController returns the Flutter child window to a clean
# OLE drag-and-drop state before the engine tears its plugins down, so
# desktop_drop's IDropTarget reference count stays balanced across engine
# rebuilds. See the crash note in flutter_window.cpp DestroyController().
target_link_libraries(${BINARY_NAME} PRIVATE "ole32.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
