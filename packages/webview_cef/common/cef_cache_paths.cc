// Copyright (c) Centroid. Part of CentroidX.

#include "cef_cache_paths.h"

#include <algorithm>
#include <cctype>

namespace webview_cef {
namespace {

// Lower case on Linux, where the surrounding directories are; capitalised on
// macOS and Windows, where "~/Library/Application Support" and "AppData\Local"
// are full of product names.
constexpr char kVendorDirLower[] = "centroidx";
constexpr char kVendorDirTitle[] = "CentroidX";
constexpr char kAppDirName[] = "webview_cef";
constexpr char kCacheDirName[] = "cache";
// The last-resort root, under the temp directory. Flat rather than nested so
// it is obvious in a directory listing what left it there.
constexpr char kTempRootName[] = "centroidx-webview-cef";

bool IsSeparator(char c) { return c == '/' || c == '\\'; }

std::string StripTrailingSeparators(const std::string& path) {
  std::string out = path;
  while (out.size() > 1 && IsSeparator(out.back())) {
    out.pop_back();
  }
  return out;
}

// The directory holding `path`, or an empty string when `path` has no parent.
std::string ParentDirectory(const std::string& path) {
  const std::string trimmed = StripTrailingSeparators(path);
  const std::string::size_type slash = trimmed.find_last_of("/\\");
  if (slash == std::string::npos || slash == 0) {
    return std::string();
  }
  return trimmed.substr(0, slash);
}

std::string VendorDir(HostPlatform platform) {
  return platform == HostPlatform::kLinux ? kVendorDirLower : kVendorDirTitle;
}

void AppendIfAbsolute(std::vector<std::string>* out,
                      const std::string& path,
                      HostPlatform platform) {
  if (!path.empty() && IsAbsolutePath(path, platform)) {
    out->push_back(StripTrailingSeparators(path));
  }
}

}  // namespace

const char kRootCachePathEnvVar[] = "CENTROIDX_CEF_ROOT_CACHE_PATH";

HostPlatform BuildHostPlatform() {
#if defined(_WIN32)
  return HostPlatform::kWindows;
#elif defined(__APPLE__)
  return HostPlatform::kMacOS;
#else
  return HostPlatform::kLinux;
#endif
}

char PathSeparator(HostPlatform platform) {
  return platform == HostPlatform::kWindows ? '\\' : '/';
}

std::string JoinPath(const std::string& left,
                     const std::string& right,
                     HostPlatform platform) {
  if (left.empty()) {
    return right;
  }
  if (right.empty()) {
    return left;
  }
  std::string out = StripTrailingSeparators(left);
  out.push_back(PathSeparator(platform));
  std::string::size_type start = 0;
  while (start < right.size() && IsSeparator(right[start])) {
    ++start;
  }
  out.append(right, start, std::string::npos);
  return out;
}

bool IsAbsolutePath(const std::string& path, HostPlatform platform) {
  if (path.empty()) {
    return false;
  }
  if (platform != HostPlatform::kWindows) {
    return path[0] == '/';
  }
  // "\\server\share" as well as "C:\dir". A bare "\dir" is drive-relative on
  // Windows, so it does not count.
  if (path.size() >= 2 && IsSeparator(path[0]) && IsSeparator(path[1])) {
    return true;
  }
  return path.size() >= 3 && std::isalpha(static_cast<unsigned char>(path[0])) &&
         path[1] == ':' && IsSeparator(path[2]);
}

std::string TempDirectory(const EnvLookup& env, HostPlatform platform) {
  if (platform == HostPlatform::kWindows) {
    for (const char* name : {"TMP", "TEMP"}) {
      const std::string value = env(name);
      if (!value.empty()) {
        return StripTrailingSeparators(value);
      }
    }
    // No %TEMP% at all is close to unheard of; the current directory is at
    // least somewhere the process can usually write.
    return ".";
  }
  const std::string tmpdir = env("TMPDIR");
  if (!tmpdir.empty()) {
    return StripTrailingSeparators(tmpdir);
  }
  return "/tmp";
}

CachePaths CachePathsForRoot(const std::string& root, HostPlatform platform) {
  if (root.empty()) {
    return CachePaths();
  }
  CachePaths paths;
  paths.root = StripTrailingSeparators(root);
  paths.cache = JoinPath(paths.root, kCacheDirName, platform);
  return paths;
}

std::vector<std::string> RootCacheCandidates(const EnvLookup& env,
                                             HostPlatform platform) {
  std::vector<std::string> candidates;

  // A station's own choice wins over everything.
  AppendIfAbsolute(&candidates, env(kRootCachePathEnvVar), platform);

  const std::string vendor = VendorDir(platform);
  switch (platform) {
    case HostPlatform::kWindows: {
      // Where CEF's own default lives (AppData\Local\CEF\User Data), minus the
      // sharing.
      const std::string local = env("LOCALAPPDATA");
      if (!local.empty()) {
        AppendIfAbsolute(
            &candidates,
            JoinPath(JoinPath(local, vendor, platform), kAppDirName, platform),
            platform);
      }
      break;
    }
    case HostPlatform::kMacOS: {
      const std::string home = env("HOME");
      if (!home.empty()) {
        const std::string support = JoinPath(
            JoinPath(home, "Library", platform), "Application Support",
            platform);
        AppendIfAbsolute(
            &candidates,
            JoinPath(JoinPath(support, vendor, platform), kAppDirName,
                     platform),
            platform);
      }
      break;
    }
    case HostPlatform::kLinux: {
      // ~/.config, for the same reason CEF defaults to ~/.config/cef_user_data
      // and Chromium to ~/.config/google-chrome: this holds the profile, not
      // just a cache. The disk cache underneath it is size-capped by Chromium.
      // On a station that is /home/<app user>/.config — owned by the non-root
      // user the container runs as, and writable without any volume of its
      // own.
      const std::string xdg = env("XDG_CONFIG_HOME");
      if (!xdg.empty()) {
        AppendIfAbsolute(
            &candidates,
            JoinPath(JoinPath(xdg, vendor, platform), kAppDirName, platform),
            platform);
      }
      const std::string home = env("HOME");
      if (!home.empty()) {
        const std::string config = JoinPath(home, ".config", platform);
        AppendIfAbsolute(
            &candidates,
            JoinPath(JoinPath(config, vendor, platform), kAppDirName, platform),
            platform);
      }
      break;
    }
  }

  // Last resort. A read-only or absent home directory is the one case where
  // falling back to CEF's shared default would put us straight back into the
  // collision this module exists to remove.
  AppendIfAbsolute(&candidates,
                   JoinPath(TempDirectory(env, platform), kTempRootName,
                            platform),
                   platform);

  return candidates;
}

CachePaths ResolveCachePaths(const EnvLookup& env,
                             const DirectoryProbe& writable,
                             HostPlatform platform) {
  for (const std::string& root : RootCacheCandidates(env, platform)) {
    const CachePaths paths = CachePathsForRoot(root, platform);
    // Creating the cache directory creates the root as its parent, so one
    // probe settles both — and it settles them the only way that matters,
    // which is by actually writing.
    if (writable(paths.cache)) {
      return paths;
    }
  }
  return CachePaths();
}

bool IsChromiumSocketDir(const std::string& path, const std::string& temp_dir) {
  if (path.empty() || temp_dir.empty()) {
    return false;
  }
  const std::string parent = StripTrailingSeparators(temp_dir);
  const std::string candidate = StripTrailingSeparators(path);
  const std::string prefix =
      JoinPath(parent, kSocketDirPrefix, HostPlatform::kLinux);
  if (candidate.size() <= prefix.size()) {
    return false;
  }
  if (candidate.compare(0, prefix.size(), prefix) != 0) {
    return false;
  }
  // A direct child only: the suffix Chromium appends is a mkdtemp template,
  // never a path.
  return candidate.find_first_of("/\\", prefix.size()) == std::string::npos;
}

SingletonSweep PlanSingletonSweep(
    const std::string& root,
    const SingletonState& state,
    const std::string& temp_dir,
    const std::vector<AbandonedSocketDir>& socket_dirs) {
  SingletonSweep sweep;
  sweep.owner_alive = state.socket_present && state.socket_answers;

  if (!root.empty() && !sweep.owner_alive) {
    // Chromium unlinks all three on a clean exit, so finding any of them means
    // the previous run was killed — which is what a container restart does.
    // The socket proved nobody is listening, and a live instance could not
    // have got this far without binding one.
    if (state.lock_present) {
      sweep.files.push_back(
          JoinPath(root, kSingletonLockName, HostPlatform::kLinux));
    }
    if (state.cookie_present) {
      sweep.files.push_back(
          JoinPath(root, kSingletonCookieName, HostPlatform::kLinux));
    }
    if (state.socket_present) {
      sweep.files.push_back(
          JoinPath(root, kSingletonSocketName, HostPlatform::kLinux));
    }
    // The socket directory the dead link named goes with it, whatever its age:
    // its owner is gone and we are about to drop the only reference to it.
    const std::string orphan = ParentDirectory(state.socket_target);
    if (IsChromiumSocketDir(orphan, temp_dir)) {
      sweep.directories.push_back(StripTrailingSeparators(orphan));
    }
  }

  for (const AbandonedSocketDir& dir : socket_dirs) {
    if (dir.socket_answers) {
      continue;  // somebody's live instance, ours or another application's
    }
    if (dir.age_seconds < kAbandonedSocketDirGraceSeconds) {
      continue;  // may be an instance that has not bound its socket yet
    }
    const std::string path = StripTrailingSeparators(dir.path);
    if (!IsChromiumSocketDir(path, temp_dir)) {
      continue;
    }
    if (std::find(sweep.directories.begin(), sweep.directories.end(), path) ==
        sweep.directories.end()) {
      sweep.directories.push_back(path);
    }
  }

  return sweep;
}

}  // namespace webview_cef
