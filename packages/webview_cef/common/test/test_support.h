// Copyright (c) Centroid. Part of CentroidX.
//
// A variant of the three-macro harness packages/media_kit_video_elinux/
// elinux/test uses — this copy adds EXPECT_FALSE, and its EXPECT_EQ prints
// got/want (so compared types need an operator<<). Kept local for the same
// reason as there: these tests must build wherever the plugin does, including
// the eLinux toolchain image, which carries cmake and a compiler and nothing
// else. Twenty lines here beats a network fetch in CI.

#ifndef WEBVIEW_CEF_TEST_SUPPORT_H_
#define WEBVIEW_CEF_TEST_SUPPORT_H_

#include <functional>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>

namespace test_support {

struct Case {
  std::string name;
  std::function<void()> body;
};

inline std::vector<Case>& Cases() {
  static std::vector<Case> cases;
  return cases;
}

inline int& Failures() {
  static int failures = 0;
  return failures;
}

struct Registrar {
  Registrar(const std::string& name, std::function<void()> body) {
    Cases().push_back({name, std::move(body)});
  }
};

inline void Fail(const char* file, int line, const std::string& message) {
  ++Failures();
  std::cerr << "  FAIL " << file << ":" << line << ": " << message << "\n";
}

}  // namespace test_support

#define TEST(name)                                                \
  static void name();                                             \
  static ::test_support::Registrar registrar_##name(#name, name); \
  static void name()

#define EXPECT_TRUE(condition)                              \
  do {                                                      \
    if (!(condition)) {                                     \
      ::test_support::Fail(__FILE__, __LINE__, #condition); \
    }                                                       \
  } while (0)

#define EXPECT_FALSE(condition) EXPECT_TRUE(!(condition))

#define EXPECT_EQ(actual, expected)                            \
  do {                                                         \
    auto&& actual_value = (actual);                            \
    auto&& expected_value = (expected);                        \
    if (!(actual_value == expected_value)) {                   \
      std::ostringstream out;                                  \
      out << #actual << " == " << #expected << " (got \""      \
          << actual_value << "\", want \"" << expected_value   \
          << "\")";                                            \
      ::test_support::Fail(__FILE__, __LINE__, out.str());     \
    }                                                          \
  } while (0)

#endif  // WEBVIEW_CEF_TEST_SUPPORT_H_
