// Copyright (c) Centroid. Part of CentroidX.

#include <iostream>

#include "test_support.h"

int main() {
  for (const auto& test_case : test_support::Cases()) {
    const int before = test_support::Failures();
    std::cout << "RUN  " << test_case.name << "\n";
    test_case.body();
    if (test_support::Failures() == before) {
      std::cout << "  ok\n";
    }
  }
  if (test_support::Failures() > 0) {
    std::cerr << test_support::Failures() << " assertion(s) failed\n";
    return 1;
  }
  std::cout << test_support::Cases().size() << " test(s) passed\n";
  return 0;
}
