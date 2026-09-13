#include <webview_cef/webview_cef_plugin.h>

#include "my_application.h"

int main(int argc, char** argv) {
  // Must come first, before GTK or Flutter touch anything.
  //
  // CEF does not spawn helper binaries of its own on Linux — it re-executes
  // *this* binary with a --type= argument to be its render, GPU and utility
  // children. initCEFProcesses returns >= 0 when this process is one of those
  // children, and the only correct thing to do then is exit with that code:
  // a child that carried on would start a second HMI, connect a second time to
  // the PLC, and open a second window.
  //
  // Without this call the Web page asset finds no browser and falls back to
  // its placeholder. That is why WebViewSurfaceAvailability treats "CEF
  // missing" and "initCEFProcesses never ran" as one state — from Dart they
  // are indistinguishable, and the remedy is here either way.
  int cef_exit_code = initCEFProcesses(argc, argv);
  if (cef_exit_code >= 0) {
    return cef_exit_code;
  }

  g_autoptr(MyApplication) app = my_application_new();
  return g_application_run(G_APPLICATION(app), argc, argv);
}
