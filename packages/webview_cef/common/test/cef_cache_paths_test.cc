// Copyright (c) Centroid. Part of CentroidX.
//
// The decisions behind CefSettings.root_cache_path and the startup sweep of
// the process-singleton state a killed run leaves behind. No filesystem and no
// CEF: every platform's answer is checked on every CI host, because the file
// under test is compiled into the Linux desktop, eLinux, macOS and Windows
// builds and a fix aimed at a station must not move the others' directories.

#include "cef_cache_paths.h"

#include <map>
#include <string>
#include <vector>

#include "test_support.h"

namespace {

using webview_cef::AbandonedSocketDir;
using webview_cef::CachePaths;
using webview_cef::HostPlatform;
using webview_cef::SingletonState;
using webview_cef::SingletonSweep;

// A fake environment. Anything not in the map is unset.
webview_cef::EnvLookup Env(std::map<std::string, std::string> values) {
  return [values](const char* name) -> std::string {
    const auto it = values.find(name);
    return it == values.end() ? std::string() : it->second;
  };
}

bool Contains(const std::vector<std::string>& haystack,
              const std::string& needle) {
  for (const std::string& value : haystack) {
    if (value == needle) {
      return true;
    }
  }
  return false;
}

// The neutral stand-ins these tests use: a container-shaped Linux home owned
// by a non-root user, and a plain temp directory.
constexpr char kHome[] = "/home/appuser";
constexpr char kTempDir[] = "/tmp";

}  // namespace

// --- path primitives -------------------------------------------------------

TEST(JoinPathUsesThePlatformSeparator) {
  EXPECT_EQ(webview_cef::JoinPath("/a", "b", HostPlatform::kLinux),
            std::string("/a/b"));
  EXPECT_EQ(webview_cef::JoinPath("/a/", "/b", HostPlatform::kLinux),
            std::string("/a/b"));
  EXPECT_EQ(webview_cef::JoinPath("C:\\a", "b", HostPlatform::kWindows),
            std::string("C:\\a\\b"));
}

TEST(IsAbsolutePathKnowsEachPlatformsShape) {
  EXPECT_TRUE(webview_cef::IsAbsolutePath("/tmp", HostPlatform::kLinux));
  EXPECT_FALSE(webview_cef::IsAbsolutePath("tmp", HostPlatform::kLinux));
  EXPECT_TRUE(
      webview_cef::IsAbsolutePath("C:\\Users", HostPlatform::kWindows));
  EXPECT_TRUE(
      webview_cef::IsAbsolutePath("\\\\host\\share", HostPlatform::kWindows));
  // Drive-relative, so not absolute.
  EXPECT_FALSE(webview_cef::IsAbsolutePath("\\Users", HostPlatform::kWindows));
}

// --- the CEF constraint ----------------------------------------------------

TEST(CachePathIsAlwaysAChildOfTheRoot) {
  // CEF refuses to initialize when cache_path is not root_cache_path or a
  // child of it, so this holds for every root on every platform.
  for (const HostPlatform platform :
       {HostPlatform::kLinux, HostPlatform::kMacOS, HostPlatform::kWindows}) {
    const std::string root = platform == HostPlatform::kWindows
                                 ? "C:\\data\\webview_cef"
                                 : "/data/webview_cef";
    const CachePaths paths = webview_cef::CachePathsForRoot(root, platform);
    EXPECT_EQ(paths.root, root);
    EXPECT_TRUE(paths.cache.size() > paths.root.size());
    EXPECT_EQ(paths.cache.compare(0, paths.root.size(), paths.root), 0);
    EXPECT_EQ(paths.cache[paths.root.size()],
              webview_cef::PathSeparator(platform));
  }
}

TEST(CachePathsForAnEmptyRootStayEmpty) {
  const CachePaths paths =
      webview_cef::CachePathsForRoot("", HostPlatform::kLinux);
  EXPECT_TRUE(paths.empty());
  EXPECT_TRUE(paths.cache.empty());
}

// --- candidate roots -------------------------------------------------------

TEST(LinuxPrefersXdgConfigHomeThenHomeConfig) {
  const std::vector<std::string> candidates = webview_cef::RootCacheCandidates(
      Env({{"HOME", kHome}, {"XDG_CONFIG_HOME", "/config"}}),
      HostPlatform::kLinux);
  EXPECT_EQ(candidates.size(), size_t(3));
  EXPECT_EQ(candidates[0], std::string("/config/centroidx/webview_cef"));
  EXPECT_EQ(candidates[1],
            std::string("/home/appuser/.config/centroidx/webview_cef"));
}

TEST(LinuxWithoutXdgFallsBackToHomeConfig) {
  const std::vector<std::string> candidates = webview_cef::RootCacheCandidates(
      Env({{"HOME", kHome}}), HostPlatform::kLinux);
  EXPECT_EQ(candidates[0],
            std::string("/home/appuser/.config/centroidx/webview_cef"));
}

TEST(MacUsesApplicationSupport) {
  const std::vector<std::string> candidates = webview_cef::RootCacheCandidates(
      Env({{"HOME", "/Users/dev"}}), HostPlatform::kMacOS);
  EXPECT_EQ(
      candidates[0],
      std::string("/Users/dev/Library/Application Support/CentroidX/webview_cef"));
}

TEST(WindowsUsesLocalAppData) {
  const std::vector<std::string> candidates = webview_cef::RootCacheCandidates(
      Env({{"LOCALAPPDATA", "C:\\Users\\dev\\AppData\\Local"},
           {"TEMP", "C:\\Temp"}}),
      HostPlatform::kWindows);
  EXPECT_EQ(candidates[0],
            std::string("C:\\Users\\dev\\AppData\\Local\\CentroidX\\webview_cef"));
}

TEST(AnAbsoluteEnvironmentOverrideWinsEverywhere) {
  const std::vector<std::string> candidates = webview_cef::RootCacheCandidates(
      Env({{webview_cef::kRootCachePathEnvVar, "/mnt/state/cef"},
           {"HOME", kHome}}),
      HostPlatform::kLinux);
  EXPECT_EQ(candidates[0], std::string("/mnt/state/cef"));
}

TEST(ARelativeEnvironmentOverrideIsIgnored) {
  // CEF requires an absolute path; a relative one would be silently resolved
  // against whatever the working directory happens to be.
  const std::vector<std::string> candidates = webview_cef::RootCacheCandidates(
      Env({{webview_cef::kRootCachePathEnvVar, "cef-data"}, {"HOME", kHome}}),
      HostPlatform::kLinux);
  EXPECT_FALSE(Contains(candidates, "cef-data"));
  EXPECT_EQ(candidates[0],
            std::string("/home/appuser/.config/centroidx/webview_cef"));
}

TEST(AHomelessProcessStillGetsARootOfItsOwn) {
  // No HOME, no XDG_CONFIG_HOME — the case where falling back to CEF's shared
  // default would put us straight back into the collision.
  const std::vector<std::string> candidates =
      webview_cef::RootCacheCandidates(Env({}), HostPlatform::kLinux);
  EXPECT_EQ(candidates.size(), size_t(1));
  EXPECT_EQ(candidates[0], std::string("/tmp/centroidx-webview-cef"));
}

TEST(TheTempFallbackIsAlwaysLastAndEveryCandidateIsAbsolute) {
  for (const HostPlatform platform :
       {HostPlatform::kLinux, HostPlatform::kMacOS, HostPlatform::kWindows}) {
    const std::vector<std::string> candidates =
        webview_cef::RootCacheCandidates(
            Env({{"HOME", kHome},
                 {"LOCALAPPDATA", "C:\\Users\\dev\\AppData\\Local"},
                 {"TMPDIR", "/scratch"},
                 {"TEMP", "C:\\Temp"}}),
            platform);
    EXPECT_TRUE(!candidates.empty());
    for (const std::string& candidate : candidates) {
      EXPECT_TRUE(webview_cef::IsAbsolutePath(candidate, platform));
    }
    const std::string expected = webview_cef::JoinPath(
        webview_cef::TempDirectory(Env({{"TMPDIR", "/scratch"},
                                        {"TEMP", "C:\\Temp"}}),
                                   platform),
        "centroidx-webview-cef", platform);
    EXPECT_EQ(candidates.back(), expected);
  }
}

TEST(NoCandidateIsCefsSharedDefault) {
  // The whole point: never ~/.config/cef_user_data, which every CEF
  // application on the box would share.
  const std::vector<std::string> candidates = webview_cef::RootCacheCandidates(
      Env({{"HOME", kHome}}), HostPlatform::kLinux);
  for (const std::string& candidate : candidates) {
    EXPECT_TRUE(candidate.find("cef_user_data") == std::string::npos);
  }
}

// --- resolution ------------------------------------------------------------

TEST(ResolutionSkipsRootsItCannotWrite) {
  // The station container runs as a non-root user from a directory it does not
  // own. A root that is not writable must be stepped over, not used and then
  // silently failed on.
  const std::string usable = "/home/appuser/.config/centroidx/webview_cef";
  const CachePaths paths = webview_cef::ResolveCachePaths(
      Env({{"XDG_CONFIG_HOME", "/etc/xdg"}, {"HOME", kHome}}),
      [&usable](const std::string& path) {
        return path.compare(0, usable.size(), usable) == 0;
      },
      HostPlatform::kLinux);
  EXPECT_EQ(paths.root, usable);
  EXPECT_EQ(paths.cache, usable + "/cache");
}

TEST(ResolutionProbesTheCacheDirectorySoTheRootIsCreatedWithIt) {
  std::vector<std::string> probed;
  webview_cef::ResolveCachePaths(
      Env({{"HOME", kHome}}),
      [&probed](const std::string& path) {
        probed.push_back(path);
        return true;
      },
      HostPlatform::kLinux);
  EXPECT_EQ(probed.size(), size_t(1));
  EXPECT_EQ(probed[0],
            std::string("/home/appuser/.config/centroidx/webview_cef/cache"));
}

TEST(ResolutionYieldsNothingWhenNoRootIsWritable) {
  const CachePaths paths = webview_cef::ResolveCachePaths(
      Env({{"HOME", kHome}}),
      [](const std::string&) { return false; }, HostPlatform::kLinux);
  EXPECT_TRUE(paths.empty());
}

// --- socket-directory guard ------------------------------------------------

TEST(OnlyDirectChildrenOfTheTempDirWithChromiumsPrefixCountAsSocketDirs) {
  EXPECT_TRUE(webview_cef::IsChromiumSocketDir(
      "/tmp/org.chromium.Chromium.aB3xY9", kTempDir));
  // Not a child of the temp dir.
  EXPECT_FALSE(webview_cef::IsChromiumSocketDir(
      "/var/org.chromium.Chromium.aB3xY9", kTempDir));
  // Nested deeper.
  EXPECT_FALSE(webview_cef::IsChromiumSocketDir(
      "/tmp/org.chromium.Chromium.aB3xY9/nested", kTempDir));
  // The prefix with nothing after it, and the temp dir itself.
  EXPECT_FALSE(
      webview_cef::IsChromiumSocketDir("/tmp/org.chromium.Chromium.", kTempDir));
  EXPECT_FALSE(webview_cef::IsChromiumSocketDir(kTempDir, kTempDir));
  // Somebody else's directory.
  EXPECT_FALSE(webview_cef::IsChromiumSocketDir("/tmp/other", kTempDir));
  // Traversal out of the temp dir.
  EXPECT_FALSE(webview_cef::IsChromiumSocketDir(
      "/tmp/org.chromium.Chromium.x/../../etc", kTempDir));
}

// --- the sweep -------------------------------------------------------------

namespace {

// The state a container restart leaves behind: all three symlinks still there,
// pointing at a socket nobody is listening on.
SingletonState KilledRunState() {
  SingletonState state;
  state.lock_present = true;
  state.cookie_present = true;
  state.socket_present = true;
  state.socket_target = "/tmp/org.chromium.Chromium.aB3xY9/SingletonSocket";
  state.socket_answers = false;
  return state;
}

}  // namespace

TEST(AFirstRunHasNothingToSweep) {
  const SingletonSweep sweep = webview_cef::PlanSingletonSweep(
      "/root/cef", SingletonState(), kTempDir, {});
  EXPECT_TRUE(sweep.empty());
  EXPECT_FALSE(sweep.owner_alive);
}

TEST(ARestartClearsWhatTheKilledRunLeftBehind) {
  const SingletonSweep sweep = webview_cef::PlanSingletonSweep(
      "/root/cef", KilledRunState(), kTempDir, {});
  EXPECT_FALSE(sweep.owner_alive);
  EXPECT_EQ(sweep.files.size(), size_t(3));
  EXPECT_TRUE(Contains(sweep.files, "/root/cef/SingletonLock"));
  EXPECT_TRUE(Contains(sweep.files, "/root/cef/SingletonCookie"));
  EXPECT_TRUE(Contains(sweep.files, "/root/cef/SingletonSocket"));
  // The orphaned socket directory goes with the link that named it, whatever
  // its age: its owner is provably gone and we are dropping the last reference.
  EXPECT_EQ(sweep.directories.size(), size_t(1));
  EXPECT_EQ(sweep.directories[0],
            std::string("/tmp/org.chromium.Chromium.aB3xY9"));
}

TEST(ALiveOwnerKeepsItsSingletonState) {
  // Two copies on one desktop: the socket answered, so the other instance
  // really is running and Chromium's own handoff is the correct behaviour.
  SingletonState state = KilledRunState();
  state.socket_answers = true;
  const SingletonSweep sweep =
      webview_cef::PlanSingletonSweep("/root/cef", state, kTempDir, {});
  EXPECT_TRUE(sweep.owner_alive);
  EXPECT_TRUE(sweep.empty());
}

TEST(ALiveOwnersSocketDirectoryIsNeverRemoved) {
  AbandonedSocketDir live;
  live.path = "/tmp/org.chromium.Chromium.live01";
  live.socket_answers = true;
  live.age_seconds = 60 * 60 * 24;
  const SingletonSweep sweep = webview_cef::PlanSingletonSweep(
      "/root/cef", SingletonState(), kTempDir, {live});
  EXPECT_TRUE(sweep.empty());
}

TEST(AbandonedSocketDirectoriesAreSweptOnceTheyAreOldEnough) {
  AbandonedSocketDir old_dir;
  old_dir.path = "/tmp/org.chromium.Chromium.old001";
  old_dir.age_seconds = webview_cef::kAbandonedSocketDirGraceSeconds;
  AbandonedSocketDir young;
  young.path = "/tmp/org.chromium.Chromium.new001";
  young.age_seconds = webview_cef::kAbandonedSocketDirGraceSeconds - 1;

  const SingletonSweep sweep = webview_cef::PlanSingletonSweep(
      "/root/cef", SingletonState(), kTempDir, {old_dir, young});
  EXPECT_EQ(sweep.directories.size(), size_t(1));
  EXPECT_EQ(sweep.directories[0],
            std::string("/tmp/org.chromium.Chromium.old001"));
}

TEST(TheOrphanedDirectoryIsNotListedTwice) {
  AbandonedSocketDir same;
  same.path = "/tmp/org.chromium.Chromium.aB3xY9";
  same.age_seconds = 60 * 60;
  const SingletonSweep sweep = webview_cef::PlanSingletonSweep(
      "/root/cef", KilledRunState(), kTempDir, {same});
  EXPECT_EQ(sweep.directories.size(), size_t(1));
}

TEST(TheSweepNeverReachesOutsideTheTempDirectory) {
  // A SingletonSocket link is attacker-shaped input: it is a symlink whose
  // target is whatever was on disk. A recursive delete must not follow it
  // anywhere but a Chromium socket directory.
  for (const char* target : {"/etc/passwd", "/tmp/../etc/hosts",
                             "/tmp/org.chromium.Chromium.x/../../SingletonSocket",
                             "relative/SingletonSocket", "/SingletonSocket"}) {
    SingletonState state = KilledRunState();
    state.socket_target = target;
    const SingletonSweep sweep =
        webview_cef::PlanSingletonSweep("/root/cef", state, kTempDir, {});
    EXPECT_TRUE(sweep.directories.empty());
    // The links themselves are still cleared: they are inside our own root.
    EXPECT_EQ(sweep.files.size(), size_t(3));
  }
}

TEST(AnEmptyRootPlansNoFileDeletes) {
  // Resolution failed and CEF is on its default. That directory is shared with
  // every other CEF application on the box, so it is not ours to sweep.
  const SingletonSweep sweep =
      webview_cef::PlanSingletonSweep("", KilledRunState(), kTempDir, {});
  EXPECT_TRUE(sweep.files.empty());
}
