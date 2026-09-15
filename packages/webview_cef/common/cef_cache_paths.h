// Copyright (c) Centroid. Part of CentroidX.
//
// Where CEF keeps its profile, and what a restart is allowed to reclaim from
// the run before it.
//
// CefSettings.root_cache_path was never set, so every start logged
//
//     Please customize CefSettings.root_cache_path for your application. Use
//     of the default value may lead to unintended process singleton behavior.
//
// and CEF fell back to the shared per-platform default — "~/.config/
// cef_user_data" on Linux, one directory for every CEF application on the box.
//
// That directory is Chromium's *user data directory*, and the user data
// directory is where the process singleton lives:
//
//     SingletonLock    a symlink whose target is "<hostname>-<pid>"
//     SingletonCookie  a symlink carrying a random value
//     SingletonSocket  a symlink to <temp>/org.chromium.Chromium.XXXXXX/
//                      SingletonSocket, the unix socket itself
//
// A starting instance decides whether an older one still owns the profile by
// connecting to that socket; if the connection fails it falls back to asking
// whether <pid> on <hostname> is still a browser process. Inside a container
// both inputs go ambiguous the moment the container is restarted rather than
// recreated: the filesystem — and therefore all three files — survives, the
// hostname is the container id and does not change, and pids start again from
// 1 and are handed straight back out. Whether the fallback then says "dead" or
// "still running" is a race against process start order, which is why one
// station painted nothing after every restart while another, on a different
// image tag, survived seven with the same warning in its log.
//
// Nothing deletes the socket directory either — Chromium's Cleanup() unlinks
// the three symlinks and leaves <temp>/org.chromium.Chromium.XXXXXX behind —
// so a box that runs for months accumulates one abandoned directory per start.
//
// So this module does two things:
//
//   * picks an application-specific root_cache_path, with a cache_path beneath
//     it (CEF requires cache_path to be root_cache_path or a child of it), so
//     the directory swept below is unambiguously ours and is not shared with
//     any other CEF application; and
//
//   * plans which leftover singleton files and which abandoned socket
//     directories a startup may delete — deciding "the previous owner is
//     dead" with the socket probe Chromium itself tries first, and never with
//     a pid, because a pid is the part a container recycles.
//
// Pure logic: no CEF, no filesystem, no sockets, no platform headers, so it
// builds and is tested on every host. The side that actually touches the disk
// is cef_cache_paths_host.h.

#ifndef WEBVIEW_CEF_CEF_CACHE_PATHS_H_
#define WEBVIEW_CEF_CEF_CACHE_PATHS_H_

#include <cstdint>
#include <functional>
#include <string>
#include <vector>

namespace webview_cef {

// The three platforms this file shapes paths for. Passed explicitly rather
// than resolved from #ifdefs so one test run covers all three. Only the Linux
// desktop and eLinux ports compile this module into the app — on macOS and
// Windows the HMI uses the OS webview, and this vendored plugin has no ports
// there — but the macOS and Windows rules are kept and pinned by the test
// binary, so the path table stays one checked whole instead of a Linux
// special case with untested branches.
enum class HostPlatform { kLinux, kMacOS, kWindows };

// The platform this translation unit was compiled for.
HostPlatform BuildHostPlatform();

// Reads an environment variable. Returns an empty string when it is unset or
// empty, so callers never have to distinguish the two.
using EnvLookup = std::function<std::string(const char* name)>;

// Answers whether a directory (and its missing parents) could be created and
// is writable afterwards.
using DirectoryProbe = std::function<bool(const std::string& path)>;

char PathSeparator(HostPlatform platform);
std::string JoinPath(const std::string& left,
                     const std::string& right,
                     HostPlatform platform);
bool IsAbsolutePath(const std::string& path, HostPlatform platform);

// An absolute path a station can point at a writable volume without a rebuild.
// The same reasoning as CENTROIDX_CEF_OZONE_PLATFORM: the flutter-elinux
// runner rejects command-line flags it does not know, so an environment
// variable is the only way in. Ignored unless it is absolute.
extern const char kRootCachePathEnvVar[];

// The temp directory Chromium would use, which is where it puts the process
// singleton's socket directory.
std::string TempDirectory(const EnvLookup& env, HostPlatform platform);

// What CefSettings gets. `cache` is always `root` or a child of it, which CEF
// requires — it refuses to initialize otherwise.
struct CachePaths {
  std::string root;   // CefSettings.root_cache_path
  std::string cache;  // CefSettings.cache_path

  bool empty() const { return root.empty(); }
};

// The cache directory that belongs under `root`. Kept one level down so that
// discarding the HTTP cache can never reach the profile or the singleton
// files sitting next to it.
CachePaths CachePathsForRoot(const std::string& root, HostPlatform platform);

// The roots to try, most preferred first. Always ends with a temp-directory
// fallback: not durable, but writable wherever the app can run at all, and
// still ours alone — which is the property the sweep below depends on.
std::vector<std::string> RootCacheCandidates(const EnvLookup& env,
                                             HostPlatform platform);

// The first candidate `writable` accepts. Returns empty paths when none is,
// which leaves CEF on its default: worse, but no worse than before this
// module existed.
CachePaths ResolveCachePaths(const EnvLookup& env,
                             const DirectoryProbe& writable,
                             HostPlatform platform);

// ---------------------------------------------------------------------------
// Process-singleton state
//
// POSIX only in shape: Chromium's Windows process singleton is a named mutex
// and a hidden window, so there is nothing on disk to go stale and nothing in
// the temp directory to leak. The path helpers below therefore join with '/'.
// ---------------------------------------------------------------------------

inline constexpr char kSingletonLockName[] = "SingletonLock";
inline constexpr char kSingletonCookieName[] = "SingletonCookie";
inline constexpr char kSingletonSocketName[] = "SingletonSocket";

// base::CreateNewTempDirectory's template, which is what names the socket
// directories that pile up under the temp directory.
inline constexpr char kSocketDirPrefix[] = "org.chromium.Chromium.";

// A socket directory is only swept once it is this old. A live instance binds
// its socket within milliseconds of creating the directory, so the window this
// guards is tiny — but an instance starting alongside us is exactly the case
// where being wrong is expensive.
inline constexpr int64_t kAbandonedSocketDirGraceSeconds = 300;

// Chromium creates SingletonLock (and the cookie) BEFORE binding
// SingletonSocket, so an instance in the middle of starting up has files on
// disk and no socket answering — the same signature as a killed run. Files
// younger than this are therefore not judged at all. The window between lock
// and bind is milliseconds; a crashed run whose files really are this young
// just gets swept on the following start instead, once they are old enough
// to tell apart.
inline constexpr int64_t kFreshSingletonStateGraceSeconds = 10;

// What the root cache directory looks like at startup.
struct SingletonState {
  bool lock_present = false;
  bool cookie_present = false;
  bool socket_present = false;
  // Where <root>/SingletonSocket points, empty when it is absent or is not a
  // symlink.
  std::string socket_target;
  // Something accepted a connection on `socket_target`. This is the only
  // liveness evidence used; a pid is never consulted.
  bool socket_answers = false;
  // Age of the youngest of the three files, in seconds; 0 when none are
  // present. This is what keeps a sweep off the fresh files of an instance
  // that has created its lock but not yet bound its socket.
  int64_t age_seconds = 0;
};

// One <temp>/org.chromium.Chromium.XXXXXX directory found at startup.
struct AbandonedSocketDir {
  std::string path;
  bool socket_answers = false;
  int64_t age_seconds = 0;
};

// What a startup may delete.
struct SingletonSweep {
  // A live instance owns the root cache directory. Nothing under it is
  // touched: Chromium's own handoff is correct when the owner really is alive.
  bool owner_alive = false;
  std::vector<std::string> files;        // unlink
  std::vector<std::string> directories;  // remove recursively

  bool empty() const { return files.empty() && directories.empty(); }
};

// True when `path` is a direct child of `temp_dir` named with the Chromium
// socket-directory prefix. Every recursive delete this module plans is gated
// on this, and the deleter itself never follows a symlink (see RemoveTree in
// the host half), so a corrupt or hostile SingletonSocket link cannot aim
// the sweep at an unrelated directory.
bool IsChromiumSocketDir(const std::string& path, const std::string& temp_dir);

SingletonSweep PlanSingletonSweep(
    const std::string& root,
    const SingletonState& state,
    const std::string& temp_dir,
    const std::vector<AbandonedSocketDir>& socket_dirs);

}  // namespace webview_cef

#endif  // WEBVIEW_CEF_CEF_CACHE_PATHS_H_
