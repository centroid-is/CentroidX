// Copyright (c) Centroid. Part of CentroidX.
//
// The half that touches the machine, against a real directory tree and a real
// unix socket. The interesting case is a *second* start: the first run of a
// freshly created container painted fine and every restart after it did not,
// because the process-singleton files survived the restart while the pid they
// named was handed out again.

#include "cef_cache_paths_host.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <string>
#include <vector>

#if defined(_WIN32)
#include <direct.h>
#endif

#if !defined(_WIN32)
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>
#endif

#include "test_support.h"

namespace {

#if !defined(_WIN32)

// A scratch tree under /tmp rather than $TMPDIR: on macOS $TMPDIR is a long
// per-user path and the socket paths built inside it would not fit in
// sockaddr_un::sun_path (108 bytes).
class Scratch {
 public:
  Scratch() {
    char pattern[] = "/tmp/wvcef_testXXXXXX";
    const char* made = mkdtemp(pattern);
    path_ = made != nullptr ? made : "";
  }
  ~Scratch() {
    if (!path_.empty()) {
      const std::string command = "rm -rf '" + path_ + "'";
      if (std::system(command.c_str()) != 0) {
        std::fprintf(stderr, "  note: could not remove %s\n", path_.c_str());
      }
    }
  }

  std::string at(const std::string& name) const { return path_ + "/" + name; }

 private:
  std::string path_;
};

bool Exists(const std::string& path) {
  struct stat info;
  return lstat(path.c_str(), &info) == 0;
}

void MakeDir(const std::string& path) { mkdir(path.c_str(), 0700); }

void MakeFile(const std::string& path) {
  FILE* file = std::fopen(path.c_str(), "w");
  if (file != nullptr) {
    std::fclose(file);
  }
}

void Backdate(const std::string& path, int seconds) {
  struct timeval times[2];
  const time_t when = time(nullptr) - seconds;
  times[0].tv_sec = when;
  times[0].tv_usec = 0;
  times[1].tv_sec = when;
  times[1].tv_usec = 0;
  utimes(path.c_str(), times);
}

// A bound, listening unix socket. Chromium's process singleton has one of
// these for as long as the instance that owns the profile is alive.
class ListeningSocket {
 public:
  explicit ListeningSocket(const std::string& path) : fd_(-1) {
    struct sockaddr_un address;
    std::memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (path.size() >= sizeof(address.sun_path)) {
      return;
    }
    std::memcpy(address.sun_path, path.c_str(), path.size());
    fd_ = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd_ < 0) {
      return;
    }
    if (bind(fd_, reinterpret_cast<struct sockaddr*>(&address),
             sizeof(address)) != 0 ||
        listen(fd_, 1) != 0) {
      close(fd_);
      fd_ = -1;
    }
  }
  ~ListeningSocket() {
    if (fd_ >= 0) {
      close(fd_);
    }
  }

  bool ok() const { return fd_ >= 0; }

 private:
  int fd_;
};

// Lays down exactly what a killed run leaves in the root cache directory: the
// three symlinks, and the socket directory the last of them names.
struct KilledRun {
  std::string root;
  std::string temp_dir;
  std::string socket_dir;

  void Create() {
    MakeDir(root);
    MakeDir(temp_dir);
    socket_dir = temp_dir + "/org.chromium.Chromium.aB3xY9";
    MakeDir(socket_dir);
    // Not a bound socket: the process that bound it is gone, the file is not.
    MakeFile(socket_dir + "/SingletonSocket");
    // The lock names the container's own hostname and a pid the restart hands
    // straight back out; neither is evidence of anything.
    symlink("container-7", (root + "/SingletonLock").c_str());
    symlink("4242424242424242424", (root + "/SingletonCookie").c_str());
    symlink((socket_dir + "/SingletonSocket").c_str(),
            (root + "/SingletonSocket").c_str());
  }
};

#endif  // !_WIN32

}  // namespace

TEST(EnsureWritableDirectoryCreatesEveryMissingParent) {
#if defined(_WIN32)
  const char* temp = std::getenv("TEMP");
  const std::string base = (temp != nullptr ? std::string(temp) : ".") +
                           "\\wvcef_test_dir";
  const std::string nested = base + "\\a\\b\\cache";
#else
  Scratch scratch;
  const std::string nested = scratch.at("a/b/cache");
#endif
  EXPECT_TRUE(webview_cef::EnsureWritableDirectory(nested));
  // Idempotent: a second start finds it already there.
  EXPECT_TRUE(webview_cef::EnsureWritableDirectory(nested));
#if defined(_WIN32)
  _rmdir(nested.c_str());
  _rmdir((base + "\\a\\b").c_str());
  _rmdir((base + "\\a").c_str());
  _rmdir(base.c_str());
#endif
}

#if !defined(_WIN32)

TEST(EnsureWritableDirectoryRefusesADirectoryItCannotWriteTo) {
  if (geteuid() == 0) {
    std::fprintf(stderr, "  note: running as root, permissions not enforced\n");
    return;
  }
  Scratch scratch;
  const std::string locked = scratch.at("locked");
  MakeDir(locked);
  chmod(locked.c_str(), 0500);
  EXPECT_FALSE(webview_cef::EnsureWritableDirectory(locked + "/cache"));
  chmod(locked.c_str(), 0700);
}

TEST(TheSocketProbeAnswersOnlyForALiveListener) {
  Scratch scratch;
  const std::string path = scratch.at("SingletonSocket");
  EXPECT_FALSE(webview_cef::UnixSocketAnswers(path));  // nothing there at all
  MakeFile(path);
  EXPECT_FALSE(webview_cef::UnixSocketAnswers(path));  // a file, not a socket
  unlink(path.c_str());
  ListeningSocket listener(path);
  EXPECT_TRUE(listener.ok());
  EXPECT_TRUE(webview_cef::UnixSocketAnswers(path));
}

TEST(TheSocketProbeSaysNoForAPathTooLongToHaveBeenBound) {
  EXPECT_FALSE(webview_cef::UnixSocketAnswers("/tmp/" + std::string(200, 'x')));
}

TEST(ARestartReclaimsTheStateAKilledRunLeftBehind) {
  Scratch scratch;
  KilledRun run{scratch.at("root"), scratch.at("tmp"), ""};
  run.Create();
  EXPECT_TRUE(Exists(run.root + "/SingletonLock"));

  const webview_cef::SingletonSweep sweep =
      webview_cef::ClearStaleSingletonState(run.root, run.temp_dir);

  EXPECT_FALSE(sweep.owner_alive);
  EXPECT_FALSE(Exists(run.root + "/SingletonLock"));
  EXPECT_FALSE(Exists(run.root + "/SingletonCookie"));
  EXPECT_FALSE(Exists(run.root + "/SingletonSocket"));
  EXPECT_FALSE(Exists(run.socket_dir));
  // The root itself, and therefore the disk cache under it, survives — that is
  // the whole reason for choosing a stable path over a fresh one per run.
  EXPECT_TRUE(Exists(run.root));

  // The next start has nothing left to do, which is what "and it stays fixed"
  // looks like.
  const webview_cef::SingletonSweep again =
      webview_cef::ClearStaleSingletonState(run.root, run.temp_dir);
  EXPECT_TRUE(again.empty());
}

TEST(EveryAbandonedSocketDirectoryFromEarlierRunsIsCollected) {
  // One directory per start, none of them ever removed, on a box that runs for
  // months.
  Scratch scratch;
  KilledRun run{scratch.at("root"), scratch.at("tmp"), ""};
  run.Create();
  std::vector<std::string> older;
  for (const char* suffix : {"run001", "run002", "run003"}) {
    const std::string dir =
        run.temp_dir + "/org.chromium.Chromium." + std::string(suffix);
    MakeDir(dir);
    MakeFile(dir + "/SingletonSocket");
    Backdate(dir, webview_cef::kAbandonedSocketDirGraceSeconds + 60);
    older.push_back(dir);
  }
  // Something else's temp directory, and a Chromium one that is too young to
  // judge.
  const std::string unrelated = run.temp_dir + "/some-other-app";
  MakeDir(unrelated);
  const std::string young = run.temp_dir + "/org.chromium.Chromium.young1";
  MakeDir(young);

  webview_cef::ClearStaleSingletonState(run.root, run.temp_dir);

  for (const std::string& dir : older) {
    EXPECT_FALSE(Exists(dir));
  }
  EXPECT_TRUE(Exists(unrelated));
  EXPECT_TRUE(Exists(young));
}

TEST(ALiveInstanceKeepsItsSingletonStateAndItsSocketDirectory) {
  Scratch scratch;
  KilledRun run{scratch.at("root"), scratch.at("tmp"), ""};
  run.Create();
  // Replace the dead socket file with a real listener: a second copy of the
  // app on a developer's desktop, not a restarted container.
  const std::string socket_path = run.socket_dir + "/SingletonSocket";
  unlink(socket_path.c_str());
  ListeningSocket listener(socket_path);
  EXPECT_TRUE(listener.ok());

  const webview_cef::SingletonSweep sweep =
      webview_cef::ClearStaleSingletonState(run.root, run.temp_dir);

  EXPECT_TRUE(sweep.owner_alive);
  EXPECT_TRUE(sweep.empty());
  EXPECT_TRUE(Exists(run.root + "/SingletonLock"));
  EXPECT_TRUE(Exists(run.root + "/SingletonSocket"));
  EXPECT_TRUE(Exists(run.socket_dir));
}

TEST(AHostileSingletonSocketLinkDeletesNothing) {
  Scratch scratch;
  KilledRun run{scratch.at("root"), scratch.at("tmp"), ""};
  run.Create();
  // Re-point the link at something outside the temp directory.
  const std::string keep = scratch.at("precious");
  MakeDir(keep);
  MakeFile(keep + "/data");
  unlink((run.root + "/SingletonSocket").c_str());
  symlink((keep + "/SingletonSocket").c_str(),
          (run.root + "/SingletonSocket").c_str());

  webview_cef::ClearStaleSingletonState(run.root, run.temp_dir);

  EXPECT_TRUE(Exists(keep));
  EXPECT_TRUE(Exists(keep + "/data"));
}

#endif  // !_WIN32
