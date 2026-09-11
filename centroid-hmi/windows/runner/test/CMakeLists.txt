cmake_minimum_required(VERSION 3.14)
project(runner_tests LANGUAGES CXX)

# Standalone project, deliberately NOT included by ../CMakeLists.txt: the
# Flutter Windows build should not have to build tests, and these tests should
# not need Windows. Everything under test here is platform-free, so this
# configures and runs on Linux and macOS too.
#
#   cmake -S . -B build && cmake --build build && ctest --test-dir build

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()

# crash_record_test races threads through the crash latch.
find_package(Threads REQUIRED)

add_executable(gpu_watchdog_test
  "gpu_watchdog_test.cpp"
  "../gpu_watchdog.cpp"
  # For ParseLossAction: the default policy is now part of what the watchdog
  # tests assert, and the parser that resolves CENTROID_GPU_ON_LOSS lives next
  # to the report rather than next to the state machine.
  "../gpu_diagnosis.cpp"
)
target_include_directories(gpu_watchdog_test PRIVATE "..")

add_executable(log_throttle_test
  "log_throttle_test.cpp"
  "../log_throttle.cpp"
)
target_include_directories(log_throttle_test PRIVATE "..")

add_executable(log_rotation_test
  "log_rotation_test.cpp"
  "../log_rotation.cpp"
)
target_include_directories(log_rotation_test PRIVATE "..")

add_executable(output_target_test
  "output_target_test.cpp"
  "../output_target.cpp"
)
target_include_directories(output_target_test PRIVATE "..")

add_executable(crash_record_test
  "crash_record_test.cpp"
  "../crash_record.cpp"
)
target_include_directories(crash_record_test PRIVATE "..")
target_link_libraries(crash_record_test PRIVATE Threads::Threads)

add_executable(gpu_diagnosis_test
  "gpu_diagnosis_test.cpp"
  "../gpu_diagnosis.cpp"
)
target_include_directories(gpu_diagnosis_test PRIVATE "..")

add_executable(path_utils_test
  "path_utils_test.cpp"
  "../path_utils.cpp"
)
target_include_directories(path_utils_test PRIVATE "..")

add_executable(egl_storm_detector_test
  "egl_storm_detector_test.cpp"
  "../egl_storm_detector.cpp"
)
target_include_directories(egl_storm_detector_test PRIVATE "..")

# The one detector that watches the Dart side rather than the renderer. Pure
# logic -- the method channel that feeds it lives in flutter_window.cpp, the
# thresholds and the wording it produces are tested here.
add_executable(dart_liveness_test
  "dart_liveness_test.cpp"
  "../dart_liveness.cpp"
)
target_include_directories(dart_liveness_test PRIVATE "..")

# When an RDP session change may rebuild the engine. The 3 s debounce it
# replaces could not collapse a disconnect/reconnect pair 35 s apart, and the
# teardown that resulted landed on an unfinished startup -- see the header.
add_executable(engine_rebuild_gate_test
  "engine_rebuild_gate_test.cpp"
  "../engine_rebuild_gate.cpp"
)
target_include_directories(engine_rebuild_gate_test PRIVATE "..")

# The drop-target reference-count model behind the 2026-09-02 crash. Pure
# logic, no Windows headers -- the one real RevokeDragDrop the fix needs lives
# in flutter_window.cpp, the reasoning it depends on is tested here.
add_executable(drag_drop_lifetime_test
  "drag_drop_lifetime_test.cpp"
  "../drag_drop_lifetime.cpp"
)
target_include_directories(drag_drop_lifetime_test PRIVATE "..")

# How the process ends: a closed window withdraws crash-restart, and nothing
# runs module teardown. Behind the 2026-09-11 loop where every close crashed in
# dcomp.dll and Windows relaunched the app -- see the header.
add_executable(shutdown_policy_test
  "shutdown_policy_test.cpp"
  "../shutdown_policy.cpp"
)
target_include_directories(shutdown_policy_test PRIVATE "..")

# The interposer is fd surgery on a real pipe; it only exists -- and is only
# testable -- on Windows. The detector logic it feeds is tested above on
# every platform.
if(WIN32)
  add_executable(stderr_interposer_test
    "stderr_interposer_test.cpp"
    "../stderr_interposer.cpp"
    "../egl_storm_detector.cpp"
  )
  target_include_directories(stderr_interposer_test PRIVATE "..")
  target_link_libraries(stderr_interposer_test PRIVATE Threads::Threads)
  # The test opens its capture file with plain _open/fopen; the *_s variants
  # buy nothing in a test that owns its own path.
  target_compile_definitions(stderr_interposer_test PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

set(RUNNER_TEST_TARGETS gpu_watchdog_test gpu_diagnosis_test log_rotation_test
    log_throttle_test output_target_test crash_record_test
    path_utils_test egl_storm_detector_test drag_drop_lifetime_test
    dart_liveness_test engine_rebuild_gate_test shutdown_policy_test)
if(WIN32)
  list(APPEND RUNNER_TEST_TARGETS stderr_interposer_test)
endif()
foreach(target IN LISTS RUNNER_TEST_TARGETS)
  if(MSVC)
    target_compile_options(${target} PRIVATE /W4)
  else()
    target_compile_options(${target} PRIVATE -Wall -Wextra)
  endif()
endforeach()

add_test(NAME gpu_watchdog COMMAND gpu_watchdog_test)
add_test(NAME log_rotation COMMAND log_rotation_test)
add_test(NAME log_throttle COMMAND log_throttle_test)
add_test(NAME output_target COMMAND output_target_test)
add_test(NAME crash_record COMMAND crash_record_test)
add_test(NAME path_utils COMMAND path_utils_test)
add_test(NAME gpu_diagnosis COMMAND gpu_diagnosis_test)
add_test(NAME egl_storm_detector COMMAND egl_storm_detector_test)
add_test(NAME drag_drop_lifetime COMMAND drag_drop_lifetime_test)
add_test(NAME dart_liveness COMMAND dart_liveness_test)
add_test(NAME engine_rebuild_gate COMMAND engine_rebuild_gate_test)
add_test(NAME shutdown_policy COMMAND shutdown_policy_test)
if(WIN32)
  add_test(NAME stderr_interposer COMMAND stderr_interposer_test)
endif()
