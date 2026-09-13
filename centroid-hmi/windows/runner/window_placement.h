#ifndef RUNNER_WINDOW_PLACEMENT_H_
#define RUNNER_WINDOW_PLACEMENT_H_

// Where the window goes when the app starts.
//
// The runner used to create a 1920x1080 window at (10, 10) and scale BOTH by
// the monitor's DPI. On a 1920x1080 display at 125% that is a 2400x1350 window
// starting at (12, 12): the title bar is on screen, the bottom and right edges
// are not, and every launch had to be dragged back by hand.
//
// The window now opens maximized (see Win32Window::Show). What is computed
// here is its *restored* rectangle -- where it lands when someone un-maximizes
// it -- which must also fit the display, or the old bug is one click away.

namespace tfc {

// A rectangle in physical pixels, right and bottom exclusive, as Win32 RECT.
struct PixelRect {
  int left = 0;
  int top = 0;
  int right = 0;
  int bottom = 0;

  int width() const { return right - left; }
  int height() const { return bottom - top; }
};

// The requested logical size scaled to the monitor's DPI, shrunk to fit the
// monitor's work area (the screen minus the taskbar), and centered in it.
PixelRect RestoredWindowBounds(const PixelRect& work_area,
                               unsigned int logical_width,
                               unsigned int logical_height,
                               double scale_factor);

}  // namespace tfc

#endif  // RUNNER_WINDOW_PLACEMENT_H_
