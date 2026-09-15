// Copyright (c) Centroid. Part of CentroidX.
//
// The half of cef_cache_paths.h that touches the machine: reading the
// environment, creating directories, probing a unix socket, and deleting what
// the plan says may go. Everything that makes a decision lives next door and
// is tested without any of this.

#ifndef WEBVIEW_CEF_CEF_CACHE_PATHS_HOST_H_
#define WEBVIEW_CEF_CEF_CACHE_PATHS_HOST_H_

#include <string>

#include "cef_cache_paths.h"

namespace webview_cef {

// Chooses the cache directories, creates them, and clears any process-
// singleton state a killed previous run left behind. Call once from the
// browser process, before CefInitialize.
//
// Returns empty paths only when no candidate directory could be created, in
// which case the caller should leave CefSettings alone and let CEF use its
// default — the behaviour that produced the warning, but still a running app.
CachePaths PrepareCefCachePaths();

// Creates `path` and every missing parent (0700 where the platform has modes)
// and reports whether it is writable afterwards. Exposed for tests.
bool EnsureWritableDirectory(const std::string& path);

#if !defined(_WIN32)
// True when a process is accepting connections on the unix socket at `path`.
// This is the same question Chromium asks first, and unlike its pid fallback
// it cannot be fooled by a container handing the same pid out again. Exposed
// for tests.
bool UnixSocketAnswers(const std::string& path);

// Reads the singleton state under `root` and the socket directories under
// `temp_dir`, plans the sweep, and carries it out. Returns what it deleted.
// Exposed for tests; PrepareCefCachePaths calls it with the real temp
// directory.
SingletonSweep ClearStaleSingletonState(const std::string& root,
                                        const std::string& temp_dir);
#endif

}  // namespace webview_cef

#endif  // WEBVIEW_CEF_CEF_CACHE_PATHS_HOST_H_
