# Host-buildable tests for the parts of the plugin that are neither Flutter nor
# CEF. The CEF distribution is a ~600 MB build-time download (see
# ../../third/download.cmake), so nothing here may include a CEF header; the
# code under test is deliberately free of them. Built standalone:
#
#   cmake -S common/test -B build/test && cmake --build build/test \
#     && ctest --test-dir build/test
#
# Same shape as packages/media_kit_video_elinux/elinux/test and
# centroid-hmi/windows/runner/test.
cmake_minimum_required(VERSION 3.15)
project(webview_cef_tests LANGUAGES CXX)

# The eLinux port builds at C++17; the Linux desktop port raises it to 20 for
# CEF's public headers. The lower bar is the one that has to hold here.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

enable_testing()

add_executable(webview_cef_tests
  test_main.cc
  cef_cache_paths_test.cc
  cef_cache_paths_host_test.cc
  ../cef_cache_paths.cc
  ../cef_cache_paths_host.cc
)
target_include_directories(webview_cef_tests PRIVATE ..)
if(MSVC)
  target_compile_options(webview_cef_tests PRIVATE /W4 /WX)
  # The host module calls _mkdir/_access/_stat, which MSVC's "secure CRT"
  # deprecation warnings object to; the *_s variants buy nothing here.
  target_compile_definitions(webview_cef_tests PRIVATE _CRT_SECURE_NO_WARNINGS
                                                      _CRT_NONSTDC_NO_DEPRECATE)
else()
  target_compile_options(webview_cef_tests PRIVATE -Wall -Wextra -Werror)
endif()

add_test(NAME webview_cef_tests COMMAND webview_cef_tests)
