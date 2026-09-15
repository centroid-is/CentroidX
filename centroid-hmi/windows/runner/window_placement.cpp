#include "window_placement.h"

#include <algorithm>

namespace tfc {

PixelRect RestoredWindowBounds(const PixelRect& work_area,
                               unsigned int logical_width,
                               unsigned int logical_height,
                               double scale_factor) {
  if (scale_factor <= 0) {
    scale_factor = 1.0;
  }
  const int available_width = std::max(work_area.width(), 0);
  const int available_height = std::max(work_area.height(), 0);

  const int width = std::min(
      static_cast<int>(logical_width * scale_factor), available_width);
  const int height = std::min(
      static_cast<int>(logical_height * scale_factor), available_height);

  PixelRect bounds;
  bounds.left = work_area.left + (available_width - width) / 2;
  bounds.top = work_area.top + (available_height - height) / 2;
  bounds.right = bounds.left + width;
  bounds.bottom = bounds.top + height;
  return bounds;
}

}  // namespace tfc
