cmake_minimum_required(VERSION 3.10)

cmake_policy(SET CMP0074 NEW)

set(PROJECT_NAME "webview_cef")
project(${PROJECT_NAME} LANGUAGES CXX C)
set(CMAKE_CXX_STANDARD 17)

# Setup CEF
include(${CMAKE_CURRENT_SOURCE_DIR}/../third/download.cmake)
prepare_prebuilt_files(${CMAKE_CURRENT_SOURCE_DIR}/../third/cef)

# Explicitly set PROJECT_ARCH for CEF before find_package
if(CMAKE_SYSTEM_PROCESSOR STREQUAL "aarch64" OR
   CMAKE_SYSTEM_PROCESSOR STREQUAL "arm64" OR
   CMAKE_CXX_COMPILER_TARGET MATCHES "aarch64" OR
   CMAKE_CXX_COMPILER_TARGET MATCHES "arm64")
    set(PROJECT_ARCH "arm64")
elseif(CMAKE_SIZEOF_VOID_P MATCHES 8)
    set(PROJECT_ARCH "x86_64")
else()
    set(PROJECT_ARCH "x86")
endif()

set(CEF_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third/cef")
set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CEF_ROOT}/cmake")
find_package(CEF REQUIRED)

set(PLUGIN_NAME "webview_cef_plugin")

add_library(${PLUGIN_NAME} SHARED
  "webview_cef_plugin.cc"
  "webview_cef_texture.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_app.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_app.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_handler.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_handler.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_plugin.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_plugin.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_value.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_value.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_js_handler.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_js_handler.h"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_cookieVisitor.cc"
  "${CMAKE_CURRENT_SOURCE_DIR}/../common/webview_cookieVisitor.h"
)

# The flutter-elinux tool provides the embedder headers and the C++ client
# wrapper as the `flutter` and `flutter_wrapper_plugin` targets, the same way
# packages/media_kit_video_elinux consumes them.
#
# Upstream instead hardcoded "../example/elinux/flutter/ephemeral/..." here and
# compiled standard_codec.cc / plugin_registrar.cc / engine_method_result.cc
# out of it by hand. That path only exists inside webview_cef's own example app
# after a build, so the published package cannot compile in a consuming app at
# all -- which is one of the reasons this is vendored rather than depended on.

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_link_libraries(${PLUGIN_NAME} PRIVATE
  flutter
  flutter_wrapper_plugin
  libcef_dll_wrapper
  ${CEF_LIB_DEPS}
)
# The flutter target here refers to the library provided by the elinux toolchain
# which is automatically configured in the example/elinux build.
# Note: GTK and X11 dependencies are removed to support DRM/GBM/Wayland.

target_include_directories(${PLUGIN_NAME} PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/../common")

#########################################cef#########################################
set(CEF_TARGET ${PLUGIN_NAME})
ADD_LOGICAL_TARGET("libcef_lib" "${CEF_LIB_DEBUG}" "${CEF_LIB_RELEASE}")
SET_CEF_TARGET_OUT_DIR()
add_subdirectory(${CEF_LIBCEF_DLL_WRAPPER_PATH} libcef_dll_wrapper)

SET_EXECUTABLE_TARGET_PROPERTIES(${CEF_TARGET})
add_dependencies(${CEF_TARGET} libcef_dll_wrapper)
target_link_libraries(${CEF_TARGET} PUBLIC libcef_lib libcef_dll_wrapper ${CEF_STANDARD_LIBS})

set_target_properties(${CEF_TARGET} PROPERTIES INSTALL_RPATH "$ORIGIN")
set_target_properties(${CEF_TARGET} PROPERTIES BUILD_WITH_INSTALL_RPATH TRUE)
set_target_properties(${CEF_TARGET} PROPERTIES RUNTIME_OUTPUT_DIRECTORY ${CEF_TARGET_OUT_DIR})

set(cef_library_list "")
foreach(FILE ${CEF_BINARY_FILES})
  list(APPEND cef_library_list ${CEF_BINARY_DIR}/${FILE})
endforeach()

foreach(FILE ${CEF_RESOURCE_FILES})
  if(NOT IS_DIRECTORY "${CEF_RESOURCE_DIR}/${FILE}")
    list(APPEND cef_library_list "${CEF_RESOURCE_DIR}/${FILE}")
  endif()
endforeach(FILE)
#######################################cef end#######################################

# CEF's locales/ directory. Chromium CHECKs for a <locale>.pak at startup in
# every process, so without one the browser and both zygotes die on int3 the
# moment the first Web page tile opens, and take the HMI with them. The only
# trace is "locale_file_path.empty() for locale" in the log. Seen on a station
# 2026-09-11.
#
# It cannot ride webview_cef_bundled_libraries, which installs flat files into
# lib/. Nor can it be an ordinary install() here: the flutter-elinux app
# template requires CMake 3.15, so CMP0082 runs this subdirectory's install
# rules where include(flutter/generated_plugins.cmake) sits, which is BEFORE
# the template's install(CODE "file(REMOVE_RECURSE bundle/)") that then deletes
# them. Upstream's install(DIRECTORY) and its POST_BUILD copy both died that
# way. (The Linux desktop template requires 3.13, CMP0082 OLD, so linux/ is
# unaffected.)
#
# So the install() is deferred to the end of the top-level directory, after
# the wipe. DEFER evaluates its arguments when it runs, in the top-level scope
# where none of our variables exist, so EVAL bakes the source path in now and
# leaves INSTALL_BUNDLE_LIB_DIR to be read then. That variable is the
# template's own lib/, where libcef.so lands and where CEF looks for locales/.
if(CMAKE_VERSION VERSION_LESS 3.19)
  message(FATAL_ERROR
    "webview_cef (elinux) needs CMake >= 3.19 for cmake_language(DEFER) to "
    "ship CEF's locales; found ${CMAKE_VERSION}")
endif()
cmake_language(EVAL CODE "
  cmake_language(DEFER DIRECTORY \"${CMAKE_SOURCE_DIR}\" CALL install
    DIRECTORY \"${CEF_RESOURCE_DIR}/locales/\"
    DESTINATION \"\${INSTALL_BUNDLE_LIB_DIR}/locales\"
    COMPONENT Runtime)
")

set(webview_cef_bundled_libraries
  ""
  ${cef_library_list}
  PARENT_SCOPE
)
