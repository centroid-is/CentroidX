// Tests for where the window lands when it is not maximized.
//
// The bug these pin: a 1920x1080 window at (10, 10), both scaled by DPI, so on
// a 1920x1080 display at 125% the window was 2400x1350 and its bottom-right
// corner hung off the screen on every launch.

#include "../window_placement.h"

#include "test_harness.h"

namespace {

using tfc::PixelRect;
using tfc::RestoredWindowBounds;

PixelRect Rect(int left, int top, int right, int bottom) {
  PixelRect rect;
  rect.left = left;
  rect.top = top;
  rect.right = right;
  rect.bottom = bottom;
  return rect;
}

// A 1920x1080 display with a 48 px taskbar along the bottom.
PixelRect FullHdWorkArea() { return Rect(0, 0, 1920, 1032); }

bool Contains(const PixelRect& outer, const PixelRect& inner) {
  return inner.left >= outer.left && inner.top >= outer.top &&
         inner.right <= outer.right && inner.bottom <= outer.bottom;
}

}  // namespace

TEST(a_1080p_window_at_125_percent_stays_on_a_1080p_display) {
  // The exact launch that used to hang off the bottom-right corner.
  const PixelRect bounds =
      RestoredWindowBounds(FullHdWorkArea(), 1920, 1080, 1.25);

  CHECK(Contains(FullHdWorkArea(), bounds));
  CHECK_EQ(bounds.width(), 1920);
  CHECK_EQ(bounds.height(), 1032);
}

TEST(a_window_that_fits_is_scaled_and_centered) {
  const PixelRect bounds =
      RestoredWindowBounds(Rect(0, 0, 3840, 2160), 1280, 720, 1.5);

  CHECK_EQ(bounds.width(), 1920);
  CHECK_EQ(bounds.height(), 1080);
  CHECK_EQ(bounds.left, 960);
  CHECK_EQ(bounds.top, 540);
}

TEST(only_the_axis_that_overflows_is_shrunk) {
  // Wide enough, not tall enough: the width is kept as asked.
  const PixelRect bounds =
      RestoredWindowBounds(Rect(0, 0, 2560, 1040), 1920, 1080, 1.0);

  CHECK_EQ(bounds.width(), 1920);
  CHECK_EQ(bounds.height(), 1040);
  CHECK_EQ(bounds.left, 320);
  CHECK_EQ(bounds.top, 0);
}

TEST(a_work_area_that_does_not_start_at_the_origin_is_respected) {
  // A secondary monitor to the left of the primary, taskbar along its top.
  const PixelRect work_area = Rect(-1920, 40, 0, 1080);
  const PixelRect bounds = RestoredWindowBounds(work_area, 1920, 1080, 1.0);

  CHECK(Contains(work_area, bounds));
  CHECK_EQ(bounds.left, -1920);
  CHECK_EQ(bounds.top, 40);
}

TEST(a_nonsense_scale_factor_is_treated_as_100_percent) {
  const PixelRect bounds =
      RestoredWindowBounds(Rect(0, 0, 3840, 2160), 1920, 1080, 0.0);

  CHECK_EQ(bounds.width(), 1920);
  CHECK_EQ(bounds.height(), 1080);
}

int main() {
  std::printf("window_placement_test\n");
  return tfc_test::RunAll();
}
