// Copyright 2021 Sony Corporation. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include <webview_cef/webview_cef_plugin.h>

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <iostream>
#include <memory>
#include <string>

#include "flutter_embedder_options.h"
#include "flutter_window.h"

int main(int argc, char** argv) {
  // Must come first, before the embedder touches anything.
  //
  // CEF spawns no helper binaries of its own on Linux — it re-executes *this*
  // binary with a --type= argument to be its render, GPU and utility children.
  // initCEFProcesses returns >= 0 when this process is one of those children,
  // and the only correct thing to do then is exit with that code: a child that
  // carried on would start a second HMI, open a second window and connect to
  // the PLC a second time.
  //
  // Without this call the Web page asset finds no browser and falls back to
  // its placeholder — which is also what a build with no CEF at all looks
  // like. See WebViewSurfaceAvailability in
  // lib/page_creator/assets/web_view.dart.
  int cef_exit_code = initCEFProcesses(argc, argv);
  if (cef_exit_code >= 0) {
    return cef_exit_code;
  }

  FlutterEmbedderOptions options;
  if (!options.Parse(argc, argv)) {
    return 0;
  }

  // Creates the Flutter project.
  const auto bundle_path = options.BundlePath();
  const std::wstring fl_path(bundle_path.begin(), bundle_path.end());
  flutter::DartProject project(fl_path);
  auto command_line_arguments = std::vector<std::string>();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  flutter::FlutterViewController::ViewProperties view_properties = {};
  view_properties.width = options.WindowWidth();
  view_properties.height = options.WindowHeight();
  view_properties.view_mode = options.WindowViewMode();
  view_properties.view_rotation = options.WindowRotation();
  view_properties.title = options.WindowTitle();
  view_properties.app_id = options.WindowAppID();
  view_properties.use_mouse_cursor = options.IsUseMouseCursor();
  view_properties.use_onscreen_keyboard = options.IsUseOnscreenKeyboard();
  view_properties.use_window_decoration = options.IsUseWindowDecoraation();
  view_properties.text_scale_factor = options.TextScaleFactor();
  view_properties.enable_high_contrast = options.EnableHighContrast();
  view_properties.force_scale_factor = options.IsForceScaleFactor();
  view_properties.scale_factor = options.ScaleFactor();
  view_properties.enable_vsync = options.EnableVsync();

  // The Flutter instance hosted by this window.
  FlutterWindow window(view_properties, project);
  if (!window.OnCreate()) {
    return 0;
  }
  window.Run();
  window.OnDestroy();

  return 0;
}
