// Copyright (c) Centroid. Part of CentroidX.

#include "cef_cache_paths_host.h"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <sys/stat.h>
#include <sys/types.h>
#include <vector>

#if defined(_WIN32)
#include <direct.h>
#include <io.h>
#else
#include <dirent.h>
#include <pwd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#endif

namespace webview_cef {
namespace {

std::string EnvOrEmpty(const char* name) {
  const char* value = std::getenv(name);
  return (value != nullptr && value[0] != '\0') ? std::string(value)
                                                : std::string();
}

// getenv, except that an unset HOME falls back to the passwd entry. A
// container started with `USER <name>` does not necessarily export HOME, and
// Chromium's base::GetHomeDir() makes the same fallback — so without it we
// would resolve a different directory than the one CEF's own default landed
// in, for no reason.
std::string HostEnv(const char* name) {
  const std::string value = EnvOrEmpty(name);
#if !defined(_WIN32)
  if (value.empty() && std::strcmp(name, "HOME") == 0) {
    const struct passwd* entry = getpwuid(getuid());
    if (entry != nullptr && entry->pw_dir != nullptr &&
        entry->pw_dir[0] != '\0') {
      return std::string(entry->pw_dir);
    }
  }
#endif
  return value;
}

bool MakeOneDirectory(const std::string& path) {
#if defined(_WIN32)
  return _mkdir(path.c_str()) == 0 || errno == EEXIST;
#else
  return mkdir(path.c_str(), 0700) == 0 || errno == EEXIST;
#endif
}

bool DirectoryIsWritable(const std::string& path) {
#if defined(_WIN32)
  struct _stat info;
  if (_stat(path.c_str(), &info) != 0 || (info.st_mode & _S_IFDIR) == 0) {
    return false;
  }
  return _access(path.c_str(), 2 /* write */) == 0;
#else
  struct stat info;
  if (stat(path.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) {
    return false;
  }
  return access(path.c_str(), W_OK | X_OK) == 0;
#endif
}

#if !defined(_WIN32)

bool PathExists(const std::string& path) {
  struct stat info;
  return lstat(path.c_str(), &info) == 0;
}

// The target of `path` if it is a symlink, otherwise an empty string.
std::string ReadLinkTarget(const std::string& path) {
  char buffer[4096];
  const ssize_t length = readlink(path.c_str(), buffer, sizeof(buffer) - 1);
  if (length <= 0) {
    return std::string();
  }
  buffer[length] = '\0';
  return std::string(buffer);
}

int64_t SecondsSinceModified(const std::string& path) {
  struct stat info;
  if (stat(path.c_str(), &info) != 0) {
    return 0;
  }
  const int64_t age = static_cast<int64_t>(std::time(nullptr)) -
                      static_cast<int64_t>(info.st_mtime);
  return age > 0 ? age : 0;
}

// Depth-first unlink. Only ever called on a path IsChromiumSocketDir has
// already vouched for.
bool RemoveTree(const std::string& path) {
  DIR* dir = opendir(path.c_str());
  if (dir != nullptr) {
    while (const struct dirent* entry = readdir(dir)) {
      const std::string name(entry->d_name);
      if (name == "." || name == "..") {
        continue;
      }
      RemoveTree(path + "/" + name);
    }
    closedir(dir);
  }
  return rmdir(path.c_str()) == 0 || unlink(path.c_str()) == 0;
}

std::vector<AbandonedSocketDir> FindSocketDirs(const std::string& temp_dir) {
  std::vector<AbandonedSocketDir> found;
  DIR* dir = opendir(temp_dir.c_str());
  if (dir == nullptr) {
    return found;
  }
  const std::string prefix(kSocketDirPrefix);
  while (const struct dirent* entry = readdir(dir)) {
    const std::string name(entry->d_name);
    if (name.size() <= prefix.size() ||
        name.compare(0, prefix.size(), prefix) != 0) {
      continue;
    }
    const std::string path = temp_dir + "/" + name;
    struct stat info;
    if (stat(path.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) {
      continue;
    }
    AbandonedSocketDir candidate;
    candidate.path = path;
    candidate.age_seconds = SecondsSinceModified(path);
    candidate.socket_answers =
        UnixSocketAnswers(path + "/" + kSingletonSocketName);
    found.push_back(candidate);
  }
  closedir(dir);
  return found;
}

#endif  // !_WIN32

}  // namespace

bool EnsureWritableDirectory(const std::string& path) {
  if (path.empty()) {
    return false;
  }
  // Walk the separators and create each prefix. Failures on the way up are
  // ignored on purpose — "C:" and "/" are not creatable and do not need to be;
  // the writability check at the end is what decides.
  for (std::string::size_type i = 1; i < path.size(); ++i) {
    if (path[i] == '/' || path[i] == '\\') {
      MakeOneDirectory(path.substr(0, i));
    }
  }
  MakeOneDirectory(path);
  return DirectoryIsWritable(path);
}

#if !defined(_WIN32)

bool UnixSocketAnswers(const std::string& path) {
  if (path.empty()) {
    return false;
  }
  struct sockaddr_un address;
  std::memset(&address, 0, sizeof(address));
  address.sun_family = AF_UNIX;
  if (path.size() >= sizeof(address.sun_path)) {
    // Too long to have been bound in the first place, so nothing can be
    // listening on it.
    return false;
  }
  std::memcpy(address.sun_path, path.c_str(), path.size());

  const int fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (fd < 0) {
    return false;
  }
  const bool connected =
      connect(fd, reinterpret_cast<struct sockaddr*>(&address),
              sizeof(address)) == 0;
  close(fd);
  return connected;
}

SingletonSweep ClearStaleSingletonState(const std::string& root,
                                        const std::string& temp_dir) {
  SingletonState state;
  const std::string socket_path = root + "/" + kSingletonSocketName;
  state.lock_present = PathExists(root + "/" + kSingletonLockName);
  state.cookie_present = PathExists(root + "/" + kSingletonCookieName);
  state.socket_present = PathExists(socket_path);
  if (state.socket_present) {
    state.socket_target = ReadLinkTarget(socket_path);
    state.socket_answers = UnixSocketAnswers(
        state.socket_target.empty() ? socket_path : state.socket_target);
  }

  const SingletonSweep sweep =
      PlanSingletonSweep(root, state, temp_dir, FindSocketDirs(temp_dir));

  for (const std::string& file : sweep.files) {
    unlink(file.c_str());
  }
  for (const std::string& directory : sweep.directories) {
    // Belt and braces: the planner already refused anything that is not a
    // direct child of the temp directory carrying Chromium's prefix, and a
    // recursive delete is not a place to trust one check.
    if (IsChromiumSocketDir(directory, temp_dir)) {
      RemoveTree(directory);
    }
  }
  return sweep;
}

#endif  // !_WIN32

CachePaths PrepareCefCachePaths() {
  const HostPlatform platform = BuildHostPlatform();
  const CachePaths paths =
      ResolveCachePaths(HostEnv, EnsureWritableDirectory, platform);
  if (paths.empty()) {
    std::fprintf(stderr,
                 "[webview_cef] WARNING: no writable cache directory could be "
                 "created; CEF falls back to its shared default user data "
                 "directory. Set %s to a writable absolute path.\n",
                 kRootCachePathEnvVar);
    std::fflush(stderr);
    return paths;
  }

  // One line saying which directory CEF was actually given. The failure this
  // replaces looked, from the outside, like a tile stuck on "loading" with
  // nothing in the log but a warning about a setting nobody had set.
  std::fprintf(stderr, "[webview_cef] cache root: %s\n", paths.root.c_str());
  std::fflush(stderr);

#if !defined(_WIN32)
  const SingletonSweep sweep =
      ClearStaleSingletonState(paths.root, TempDirectory(HostEnv, platform));
  if (sweep.owner_alive) {
    std::fprintf(stderr,
                 "[webview_cef] another instance is live in %s; leaving its "
                 "process-singleton state alone\n",
                 paths.root.c_str());
    std::fflush(stderr);
  } else if (!sweep.empty()) {
    std::fprintf(stderr,
                 "[webview_cef] cleared process-singleton state left by a "
                 "killed run: %zu file(s), %zu socket directory(ies)\n",
                 sweep.files.size(), sweep.directories.size());
    std::fflush(stderr);
  }
#endif

  return paths;
}

}  // namespace webview_cef
