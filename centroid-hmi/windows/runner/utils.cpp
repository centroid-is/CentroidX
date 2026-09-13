#include "utils.h"

#include "log_rotation.h"
#include "path_utils.h"

#include <flutter_windows.h>
#include <fcntl.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <cstdlib>  // free, _wdupenv_s
#include <iostream>
#include <string>
#include <thread>
#include <vector>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

void RedirectIOToConsole() {
  FILE *fp;
  freopen_s(&fp, "CONOUT$", "w", stdout);
  freopen_s(&fp, "CONOUT$", "w", stderr);
  freopen_s(&fp, "CONIN$", "r", stdin);
  setvbuf(stdout, nullptr, _IONBF, 0);
  setvbuf(stderr, nullptr, _IONBF, 0);
  std::ios::sync_with_stdio();
  FlutterDesktopResyncOutputStreams();
}



bool RedirectIOToFile(const char* path) {
  // Open with FILE_SHARE_READ | FILE_SHARE_WRITE so Dart can also write to this file.
  // freopen_s does NOT expose sharing flags and defaults to exclusive access,
  // which blocks Dart's File.openSync() from appending to the same log file.
  int wlen = ::MultiByteToWideChar(CP_UTF8, 0, path, -1, nullptr, 0);
  if (wlen <= 0) return false;
  std::vector<wchar_t> wpath(wlen);
  ::MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath.data(), wlen);

  // FILE_APPEND_DATA rather than GENERIC_WRITE: every write goes to the end
  // of the file no matter where this handle's offset is. On a console-less
  // launch the Dart logger writes this same file through its own handle, so
  // the two would otherwise advance independently and the C++ side (notably
  // open62541, which logs straight to fd 1) would overwrite whatever Dart had
  // appended from the start of the file. CREATE_ALWAYS still truncates first,
  // so a run begins with an empty log.
  HANDLE hFile = ::CreateFileW(
      wpath.data(),
      FILE_APPEND_DATA | SYNCHRONIZE,
      FILE_SHARE_READ | FILE_SHARE_WRITE,
      nullptr,
      CREATE_ALWAYS,
      FILE_ATTRIBUTE_NORMAL,
      nullptr);
  if (hFile == INVALID_HANDLE_VALUE) return false;

  // If we already have a console (launched from a terminal or under an IDE
  // that attaches one), tee instead of redirecting.
  //
  // Redirecting takes the output away from whoever is watching it. That is
  // the wrong trade for the OPC UA stack in particular: open62541 logs
  // through UA_Log_Stdout, i.e. straight to this file descriptor and never
  // through Dart, so its session and channel messages are only ever visible
  // wherever fd 1 happens to point. Sending them to a file blinds the
  // operator; leaving them on the console blinds every tool. Tee gives both.
  HANDLE hConsole = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (hConsole != nullptr && hConsole != INVALID_HANDLE_VALUE &&
      ::GetFileType(hConsole) != FILE_TYPE_UNKNOWN) {
    // Take our own reference to the console/pipe before touching fd 1.
    //
    // fd 1 owns the handle GetStdHandle just returned, and the _dup2 below
    // closes fd 1. That frees the handle *value*, and Windows hands out the
    // lowest free value next -- which is the duplicate _dup2 immediately
    // creates for the pipe. `hConsole` then silently becomes a second write
    // end of the very pipe the pump reads from, and every line the pump
    // forwards arrives back at it: the same bytes are copied to the log
    // forever, at the speed of a memcpy loop.
    HANDLE hConsoleOwned = nullptr;
    if (!::DuplicateHandle(::GetCurrentProcess(), hConsole,
                           ::GetCurrentProcess(), &hConsoleOwned, 0, FALSE,
                           DUPLICATE_SAME_ACCESS)) {
      hConsoleOwned = nullptr;
    }

    HANDLE readEnd = nullptr, writeEnd = nullptr;
    SECURITY_ATTRIBUTES sa{sizeof(SECURITY_ATTRIBUTES), nullptr, TRUE};
    if (::CreatePipe(&readEnd, &writeEnd, &sa, 0)) {
      // Pump: everything written to fd 1/2 arrives here and is forwarded to
      // both sinks. Detached -- it ends when the process does.
      std::thread([readEnd, hConsoleOwned, hFile]() {
        char buf[4096];
        DWORD got = 0, put = 0;
        while (::ReadFile(readEnd, buf, sizeof(buf), &got, nullptr) && got > 0) {
          if (hConsoleOwned != nullptr) {
            ::WriteFile(hConsoleOwned, buf, got, &put, nullptr);
          }
          ::WriteFile(hFile, buf, got, &put, nullptr);
          ::FlushFileBuffers(hFile);
        }
      }).detach();

      int pipeFd = _open_osfhandle(reinterpret_cast<intptr_t>(writeEnd),
                                   _O_WRONLY | _O_TEXT);
      if (pipeFd != -1) {
        FILE* pipeFp = _fdopen(pipeFd, "w");
        if (pipeFp) {
          setvbuf(pipeFp, nullptr, _IONBF, 0);
          *stdout = *pipeFp;
          _dup2(pipeFd, 1);
          _dup2(pipeFd, 2);
          ::SetStdHandle(STD_OUTPUT_HANDLE, writeEnd);
          ::SetStdHandle(STD_ERROR_HANDLE, writeEnd);
          std::ios::sync_with_stdio(false);
          std::ios::sync_with_stdio(true);
          FlutterDesktopResyncOutputStreams();
          return true;
        }
        _close(pipeFd);
      }
      // Pipe setup failed part-way: fall through to the plain redirect
      // below rather than losing output entirely.
      ::CloseHandle(readEnd);
    }
    if (hConsoleOwned != nullptr) {
      ::CloseHandle(hConsoleOwned);
    }
  }

  // Associate the Win32 handle with a CRT file descriptor, then with stdout.
  int fd = _open_osfhandle(reinterpret_cast<intptr_t>(hFile),
                           _O_WRONLY | _O_APPEND | _O_TEXT);
  if (fd == -1) { ::CloseHandle(hFile); return false; }

  FILE *fp = _fdopen(fd, "w");
  if (!fp) { _close(fd); return false; }
  setvbuf(fp, nullptr, _IONBF, 0);

  // Wire fd 1 and fd 2 to the same file so Dart (which uses fd 1) can reach it.
  // _dup2 is what actually redirects; the struct copy that used to stand here
  // (*stdout = *fp) was the corruption, and it is not needed -- the CRT's
  // stdout writes through fd 1, which now points at hFile.
  _dup2(fd, 1);
  _dup2(fd, 2);

  // Sync Win32 standard handles (Dart uses GetStdHandle -> WriteFile).
  ::SetStdHandle(STD_OUTPUT_HANDLE, hFile);
  ::SetStdHandle(STD_ERROR_HANDLE, hFile);

  // Force std::cout/cerr to re-associate with the redirected CRT streams.
  std::ios::sync_with_stdio(false);
  std::ios::sync_with_stdio(true);

  // Point the *engine's* stdout/stderr at the new streams as well, but ONLY
  // when this process actually has a console.
  //
  // The engine's resync reopens stdout and stderr on CONOUT$ (its header says
  // to call it "after an AllocConsole call"). With no console attached that
  // reopen fails, leaves the stream closed, and the engine then duplicates
  // from the closed descriptor -- an invalid CRT parameter, which aborts the
  // process with 0xc0000409 inside flutter_windows.dll.
  //
  // Every launch from a shortcut, the Start menu or an MSIX tile has no
  // console, so the app died before its window ever appeared, leaving only a
  // zero-byte log; launching from a terminal has one, which is why it looked
  // fine in development and in every scripted run.
  //
  // The cost of skipping it is that Dart's print() output does not reach the
  // log file on a console-less launch -- the C++ side still does. Losing log
  // lines beats not starting.
  if (::GetConsoleWindow() == nullptr) {
    return false;
  }
  FlutterDesktopResyncOutputStreams();
  return true;
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // Sizing call includes the trailing null; tfc::Utf8LengthWithoutNul removes
  // it, and refuses to do so when the call failed. WC_ERR_INVALID_CHARS makes
  // failure reachable from a command line the user typed — an unpaired
  // surrogate is enough — and the naked `- 1` this replaces turned that into
  // an unsigned wrap and a four-gigabyte resize().
  size_t target_length = tfc::Utf8LengthWithoutNul(::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr));
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), (int)target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}

namespace {

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int len = ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (len <= 0) return std::wstring();
  std::wstring wide(static_cast<size_t>(len) - 1, L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &wide[0], len);
  return wide;
}

std::string Utf8FromUtf16Str(const std::wstring& utf16) {
  if (utf16.empty()) return std::string();
  int len = ::WideCharToMultiByte(CP_UTF8, 0, utf16.c_str(), -1, nullptr, 0,
                                  nullptr, nullptr);
  if (len <= 0) return std::string();
  std::string utf8(static_cast<size_t>(len) - 1, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, utf16.c_str(), -1, &utf8[0], len, nullptr,
                        nullptr);
  return utf8;
}

}  // namespace

bool StdoutIsConnected() {
  HANDLE handle = ::GetStdHandle(STD_OUTPUT_HANDLE);
  if (handle == nullptr || handle == INVALID_HANDLE_VALUE) {
    return false;
  }
  // FILE_TYPE_CHAR is a console, FILE_TYPE_PIPE is `flutter run` or a shell
  // pipe, FILE_TYPE_DISK is a `> file` redirect. Only UNKNOWN means the handle
  // leads nowhere.
  return ::GetFileType(handle) != FILE_TYPE_UNKNOWN;
}

void ConfigureUnattendedOperation() {
  // ES_CONTINUOUS makes the request stick for the life of the process rather
  // than resetting one idle timer. ES_DISPLAY_REQUIRED is deliberately not
  // asked for: keeping the machine awake is the point, keeping a monitor lit
  // in an empty room is not, and on a station that runs headless overnight it
  // would be refused anyway.
  if (::SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) == 0) {
    std::cerr << "[startup] SetThreadExecutionState declined; the machine may "
                 "still sleep under the app"
              << std::endl;
  }

  // Opt out of EcoQoS. PROCESS_POWER_THROTTLING_EXECUTION_SPEED with the mask
  // set and the state bit clear means "explicitly not throttled" — different
  // from leaving it unmanaged, which lets Windows decide, and deciding is
  // exactly what goes wrong when the session is disconnected.
  //
  // Resolved at runtime: the API is Windows 10 1809 and later, and a station
  // on an older build should keep running rather than fail to load.
  using SetProcessInformationFn = BOOL(WINAPI*)(HANDLE, PROCESS_INFORMATION_CLASS,
                                                LPVOID, DWORD);
  if (HMODULE kernel32 = ::GetModuleHandleW(L"kernel32.dll")) {
    auto set_process_information = reinterpret_cast<SetProcessInformationFn>(
        ::GetProcAddress(kernel32, "SetProcessInformation"));
    if (set_process_information != nullptr) {
      PROCESS_POWER_THROTTLING_STATE state = {};
      state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
      state.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED;
      state.StateMask = 0;
      if (!set_process_information(::GetCurrentProcess(), ProcessPowerThrottling,
                                   &state, sizeof(state))) {
        std::cerr << "[startup] could not opt out of power throttling (error "
                  << ::GetLastError() << ")" << std::endl;
      }
    }
  }

  // Restart after a crash or a hang, but NOT after a reboot or a patch: those
  // are the two cases where coming back automatically would fight whoever is
  // deliberately servicing the machine. The command line is inherited.
  //
  // Nor after the operator closes the window: WithdrawCrashRestart takes this
  // back at that point. Without that, a crash during teardown reads to Windows
  // as any other crash, and on 2026-09-11 that turned every close into a
  // relaunch. See shutdown_policy.h.
  const HRESULT restart = ::RegisterApplicationRestart(
      nullptr, RESTART_NO_REBOOT | RESTART_NO_PATCH);
  if (FAILED(restart)) {
    std::cerr << "[startup] RegisterApplicationRestart failed (hr=0x"
              << std::hex << restart << std::dec << ")" << std::endl;
  }
}

bool WithdrawCrashRestart() {
  return SUCCEEDED(::UnregisterApplicationRestart());
}

void EndProcessWithoutTeardown(int exit_code) {
  std::cout.flush();
  std::cerr.flush();
  std::fflush(nullptr);
  // TerminateProcess, not ExitProcess: ExitProcess runs every DLL's
  // DLL_PROCESS_DETACH, and with it the static destructors that crash.
  ::TerminateProcess(::GetCurrentProcess(), static_cast<UINT>(exit_code));
  // Terminating the current process does not return. If it somehow did,
  // waiting is still better than falling through into the teardown this
  // exists to avoid.
  for (;;) {
    ::Sleep(INFINITE);
  }
}

std::string DefaultLogPath() {
  wchar_t* local_app_data = nullptr;
  size_t len = 0;
  if (_wdupenv_s(&local_app_data, &len, L"LOCALAPPDATA") != 0 ||
      local_app_data == nullptr) {
    return std::string();
  }
  std::wstring dir(local_app_data);
  free(local_app_data);

  // CreateDirectoryW does not create intermediate levels, so build the two
  // levels we need in order. Both may already exist; that is not an error.
  dir += L"\\centroid-hmi";
  ::CreateDirectoryW(dir.c_str(), nullptr);
  dir += L"\\logs";
  ::CreateDirectoryW(dir.c_str(), nullptr);

  DWORD attributes = ::GetFileAttributesW(dir.c_str());
  if (attributes == INVALID_FILE_ATTRIBUTES ||
      !(attributes & FILE_ATTRIBUTE_DIRECTORY)) {
    return std::string();
  }

  return Utf8FromUtf16Str(dir + L"\\hmi.log");
}

void RotateLogs(const std::string& path, int max_archives) {
  if (path.empty()) return;

  tfc::LogRotationPlan plan = tfc::PlanRotation(path, max_archives);

  for (const std::string& doomed : plan.deletes) {
    ::DeleteFileW(Utf16FromUtf8(doomed).c_str());
  }
  for (const auto& rename : plan.renames) {
    // MOVEFILE_REPLACE_EXISTING for safety: a leftover destination from an
    // interrupted rotation must not stop the chain.
    ::MoveFileExW(Utf16FromUtf8(rename.first).c_str(),
                  Utf16FromUtf8(rename.second).c_str(),
                  MOVEFILE_REPLACE_EXISTING);
  }
}
