#include "crash_handler.h"

#include "crash_record.h"

#include <windows.h>
// dbghelp.h must follow windows.h.
#include <dbghelp.h>
// _CrtSetReportMode / _CrtSetReportFile, used in the debug block below.
#include <crtdbg.h>

#include <csignal>   // signal, SIGABRT
#include <cstdint>   // uintptr_t, in the invalid-parameter handler signature
#include <cstdio>    // fputs, fflush, snprintf
#include <cstdlib>   // _set_abort_behavior, _set_purecall_handler
#include <cstring>   // strlen, strrchr
#include <exception> // set_terminate

namespace tfc {
namespace {

// The exception code MSVC raises for `throw`. Not in any Windows header —
// it is "msc" with the high byte set, and every debugger hardcodes it too.
constexpr DWORD kCppExceptionCode = 0xE06D7363;

// Where minidumps go. Captured at install time because the handlers cannot
// take arguments and must not allocate.
char g_dump_dir[MAX_PATH] = {0};

// The log file, written to directly rather than through stderr.
//
// A packaged, console-less launch — which is how the plant actually runs this
// — produced logs containing not one line from the runner: no [startup], no
// [crash], no GPU watchdog record, while Dart's own output (written through
// Dart's own handle) was all there. The crash record had been formatted; it
// just never reached the file. Whatever the redirect does under MSIX, a crash
// record is the one line that must not depend on it, so it goes to the file
// through a handle of its own.
char g_log_path[MAX_PATH] = {0};

// Appends one line straight to the log file. Opened and closed per record: a
// crash writes a handful of lines, and holding a handle open for the life of
// the process is one more thing to be wrong at the moment it matters.
// FILE_APPEND_DATA writes at the end of the file whatever this handle's offset
// is, so it interleaves safely with Dart's writer instead of overwriting it.
void AppendToLogFile(const char* line) {
  if (g_log_path[0] == '\0' || line == nullptr) {
    return;
  }
  HANDLE file = ::CreateFileA(g_log_path, FILE_APPEND_DATA | SYNCHRONIZE,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  ::WriteFile(file, line, static_cast<DWORD>(std::strlen(line)), &written,
              nullptr);
  ::WriteFile(file, "\r\n", 2, &written, nullptr);
  ::CloseHandle(file);
}

// Mirrors a crash record into the Windows event log.
//
// The log file can be missing, full, or on a disk that just went away, and a
// crash is exactly when that is most likely. The event log is the one place a
// Windows admin looks by reflex, and it survives the app's own storage.
//
// No message DLL is registered, so Event Viewer prints its "description not
// found" preamble before our text. That is a cosmetic wart on an otherwise
// complete record; registering a message table needs a writable HKLM key,
// which an MSIX app does not have.
void ReportToEventLog(const char* line) {
  if (line == nullptr) {
    return;
  }
  HANDLE source = ::RegisterEventSourceW(nullptr, L"CentroidX");
  if (source == nullptr) {
    return;
  }
  const char* strings[1] = {line};
  ::ReportEventA(source, EVENTLOG_ERROR_TYPE, 0, 0, nullptr, 1, 0, strings,
                 nullptr);
  ::DeregisterEventSource(source);
}

// A crash inside a crash handler must not recurse forever, and two threads can
// fault simultaneously. Constant-initialised, so it is armed before any static
// constructor could fault.
CrashLatch g_latch;

// Writes straight to stderr, which the runner has redirected to the log file.
// Deliberately avoids std::string and iostreams: this runs after things like
// bad_alloc and stack corruption, where allocation may be exactly what failed.
void WriteRecord(const char* line) {
  std::fputs(line, stderr);
  std::fputs("\n", stderr);
  std::fflush(stderr);
  // The one that actually survives a packaged launch, where stderr above
  // reaches nobody.
  AppendToLogFile(line);
  // Also visible to a debugger or DebugView when no log file is configured.
  ::OutputDebugStringA(line);
  ::OutputDebugStringA("\n");
}

// The C++ type carried by an 0xE06D7363 exception, or null when it cannot be
// recovered.
//
// An MSVC throw passes its type through the exception record: [0] is a magic
// number, [2] points at the ThrowInfo, and on x64 [3] is the base the RVAs
// inside it are relative to. Following that chain turns "a C++ exception
// killed it" into "std::bad_alloc killed it", which is the difference between
// a mystery and a memory leak.
//
// Every dereference is a pointer supplied by a process that is already dying,
// so the whole walk sits under __try: a fault here must produce "unknown",
// never a second crash. Nothing in this function needs unwinding, which is
// what lets __try coexist with C++ in the same translation unit.
const char* DescribeCppExceptionType(const EXCEPTION_RECORD* record,
                                     char* buffer, size_t buffer_len) {
  if (record == nullptr || record->NumberParameters < 3) {
    return nullptr;
  }
  struct ThrowInfo {
    DWORD attributes;
    DWORD unwind;
    DWORD forward_compat;
    DWORD catchable_type_array;
  };
  struct CatchableTypeArray {
    int count;
    DWORD types[1];
  };
  struct CatchableType {
    DWORD properties;
    DWORD descriptor;
  };
  struct TypeDescriptor {
    const void* vftable;
    void* spare;
    char name[1];
  };

  __try {
    const ULONG_PTR base =
        record->NumberParameters >= 4 ? record->ExceptionInformation[3] : 0;
    const auto* info =
        reinterpret_cast<const ThrowInfo*>(record->ExceptionInformation[2]);
    if (info == nullptr || base == 0 || info->catchable_type_array == 0) {
      return nullptr;
    }
    const auto* array = reinterpret_cast<const CatchableTypeArray*>(
        base + info->catchable_type_array);
    if (array->count <= 0) {
      return nullptr;
    }
    // The first entry is the thrown type itself; the rest are its bases.
    const auto* catchable =
        reinterpret_cast<const CatchableType*>(base + array->types[0]);
    if (catchable->descriptor == 0) {
      return nullptr;
    }
    const auto* descriptor =
        reinterpret_cast<const TypeDescriptor*>(base + catchable->descriptor);
    if (descriptor->name[0] == '\0') {
      return nullptr;
    }
    return CleanTypeName(buffer, buffer_len, descriptor->name);
  } __except (EXCEPTION_EXECUTE_HANDLER) {
    return nullptr;
  }
}

// Writes the captured stack as "module+offset" lines.
//
// The minidump remains the authoritative artefact, but it needs a debugger and
// matching symbols to read. These lines make the log alone enough to say which
// component died, which is what triage actually starts from.
//
// CaptureStackBackTrace is used rather than StackWalk64 because it neither
// allocates nor takes the dbghelp lock — both of which can be exactly what is
// broken by the time we are here.
void WriteStackTrace() {
  void* frames[32];
  const USHORT captured =
      ::CaptureStackBackTrace(0, ARRAYSIZE(frames), frames, nullptr);
  if (captured == 0) {
    WriteRecord("[crash]   <no stack captured>");
    return;
  }
  for (USHORT i = 0; i < captured; ++i) {
    char module_name[MAX_PATH] = {0};
    const char* basename = nullptr;
    unsigned long long offset = 0;

    HMODULE module = nullptr;
    if (::GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                                 GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                             reinterpret_cast<LPCWSTR>(frames[i]), &module) &&
        module != nullptr) {
      if (::GetModuleFileNameA(module, module_name, ARRAYSIZE(module_name)) >
          0) {
        const char* slash = std::strrchr(module_name, '\\');
        basename = slash != nullptr ? slash + 1 : module_name;
      }
      offset = static_cast<unsigned long long>(
          reinterpret_cast<uintptr_t>(frames[i]) -
          reinterpret_cast<uintptr_t>(module));
    }

    char line[MAX_PATH + 96];
    FormatFrameLine(line, sizeof(line), i, basename, offset, frames[i]);
    WriteRecord(line);
  }
}

CrashTime NowUtc() {
  SYSTEMTIME st;
  ::GetSystemTime(&st);
  CrashTime time;
  time.year = st.wYear;
  time.month = st.wMonth;
  time.day = st.wDay;
  time.hour = st.wHour;
  time.minute = st.wMinute;
  time.second = st.wSecond;
  return time;
}

// Writes a minidump and reports where it went. |pointers| may be null, which
// still yields usable thread stacks.
void WriteMinidump(EXCEPTION_POINTERS* pointers, const char* timestamp) {
  char path[MAX_PATH];
  if (!FormatMinidumpPath(path, sizeof(path), g_dump_dir, timestamp,
                          ::GetCurrentProcessId())) {
    WriteRecord("[crash] no usable dump path — minidump skipped");
    return;
  }

  HANDLE file = ::CreateFileA(path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    char line[MAX_PATH + 64];
    std::snprintf(line, sizeof(line),
                  "[crash] could not create minidump %s (error %lu)", path,
                  ::GetLastError());
    WriteRecord(line);
    return;
  }

  MINIDUMP_EXCEPTION_INFORMATION info;
  info.ThreadId = ::GetCurrentThreadId();
  info.ExceptionPointers = pointers;
  info.ClientPointers = FALSE;

  // Stacks alone are not enough. A C++ throw carries its type in a descriptor
  // that lives in the throwing module's read-only data, and with MiniDumpNormal
  // that memory is absent — which is how two 0xE06D7363 crashes were recorded
  // in full without either one naming the exception. DataSegs brings in module
  // data, IndirectlyReferencedMemory brings in what the stacks point at (the
  // thrown object included). Both cost a few hundred KB more, against a dump
  // that could not answer the only question it was written to answer.
  const MINIDUMP_TYPE type = static_cast<MINIDUMP_TYPE>(
      MiniDumpNormal | MiniDumpWithThreadInfo | MiniDumpWithHandleData |
      MiniDumpWithDataSegs | MiniDumpWithIndirectlyReferencedMemory |
      MiniDumpWithUnloadedModules);

  BOOL ok = ::MiniDumpWriteDump(::GetCurrentProcess(), ::GetCurrentProcessId(),
                                file, type, pointers ? &info : nullptr, nullptr,
                                nullptr);
  ::CloseHandle(file);

  char line[MAX_PATH + 64];
  if (ok) {
    std::snprintf(line, sizeof(line), "[crash] minidump written: %s", path);
  } else {
    std::snprintf(line, sizeof(line),
                  "[crash] MiniDumpWriteDump failed (error %lu)",
                  ::GetLastError());
  }
  WriteRecord(line);
}

// Common tail: record what happened, dump, and end the process. Does not
// return. Uses TerminateProcess rather than abort() so we cannot re-enter the
// SIGABRT handler, and so no second dialog appears.
[[noreturn]] void ReportAndDie(const char* kind, const char* detail,
                               EXCEPTION_POINTERS* pointers, UINT exit_code) {
  if (g_latch.Enter()) {
    char timestamp[32];
    FormatTimestamp(timestamp, sizeof(timestamp), NowUtc());

    char line[1024];
    FormatCrashRecord(line, sizeof(line), kind, ::GetCurrentThreadId(),
                      timestamp, detail);
    WriteRecord(line);
    // Mirrored where an admin looks first, and where it survives the log file
    // being unwritable.
    ReportToEventLog(line);
    WriteStackTrace();

    WriteMinidump(pointers, timestamp);
  }
  ::TerminateProcess(::GetCurrentProcess(), exit_code);
  // TerminateProcess does not return, but the compiler wants an end here.
  ::ExitProcess(exit_code);
}

LONG WINAPI SehFilter(EXCEPTION_POINTERS* pointers) {
  const bool has_record =
      pointers != nullptr && pointers->ExceptionRecord != nullptr;
  char detail[256];
  // An unhandled C++ throw is the shape this actually takes in the field, and
  // "code=0xE06D7363" on its own says only that. Name the type when the record
  // still carries it.
  const bool is_cpp_throw =
      has_record &&
      pointers->ExceptionRecord->ExceptionCode == kCppExceptionCode;
  if (is_cpp_throw) {
    char type_name[192];
    const char* named = DescribeCppExceptionType(pointers->ExceptionRecord,
                                                 type_name, sizeof(type_name));
    FormatCppExceptionDetail(detail, sizeof(detail), named,
                             pointers->ExceptionRecord->ExceptionAddress);
  } else {
    FormatSehDetail(detail, sizeof(detail), has_record,
                    has_record ? pointers->ExceptionRecord->ExceptionCode : 0,
                    has_record ? pointers->ExceptionRecord->ExceptionAddress
                               : nullptr);
  }
  ReportAndDie(is_cpp_throw ? "unhandled C++ exception" : "structured exception",
               detail, pointers, 1);
}

void TerminateHandler() {
  char buffer[512];
  ReportAndDie("std::terminate", DescribeActiveException(buffer, sizeof(buffer)),
               nullptr, 3);
}

void SignalHandler(int signal_number) {
  char detail[64];
  std::snprintf(detail, sizeof(detail), "signal=%d", signal_number);
  ReportAndDie(SignalKind(signal_number), detail, nullptr, 3);
}

void InvalidParameterHandler(const wchar_t* expression, const wchar_t* function,
                             const wchar_t* file, unsigned int line,
                             uintptr_t /*reserved*/) {
  char detail[768];
  FormatInvalidParameterDetail(detail, sizeof(detail), expression, function,
                               file, line);
  ReportAndDie("CRT invalid parameter", detail, nullptr, 3);
}

void PureCallHandler() {
  ReportAndDie("pure virtual call", nullptr, nullptr, 3);
}

}  // namespace

void InstallCrashHandlers(const std::string& dump_dir,
                          const std::string& log_path) {
  std::snprintf(g_dump_dir, sizeof(g_dump_dir), "%s", dump_dir.c_str());
  std::snprintf(g_log_path, sizeof(g_log_path), "%s", log_path.c_str());

  ::SetUnhandledExceptionFilter(SehFilter);
  std::set_terminate(TerminateHandler);
  std::signal(SIGABRT, SignalHandler);
  _set_invalid_parameter_handler(InvalidParameterHandler);
  _set_purecall_handler(PureCallHandler);

  // Route SIGABRT to our handler rather than the CRT's message box. WER
  // reporting is dropped too: we write our own minidump, and a kiosk must not
  // sit on a modal dialog waiting for a click that will never come.
  _set_abort_behavior(0, _WRITE_ABORT_MSG | _CALL_REPORTFAULT);

#ifdef _DEBUG
  // Debug-CRT assertions default to a dialog; send them to stderr instead so
  // they reach the log like everything else.
  _CrtSetReportMode(_CRT_ASSERT, _CRTDBG_MODE_FILE);
  _CrtSetReportFile(_CRT_ASSERT, _CRTDBG_FILE_STDERR);
  _CrtSetReportMode(_CRT_ERROR, _CRTDBG_MODE_FILE);
  _CrtSetReportFile(_CRT_ERROR, _CRTDBG_FILE_STDERR);
#endif

  // Name the blind spot while the log is still being written, because the one
  // time it mattered this file just stopped and the absence looked like a
  // mystery rather than a signpost. See the header for the two occurrences.
  WriteRecord(
      "[startup] crash handlers installed: structured exceptions, "
      "std::terminate, SIGABRT, CRT invalid parameter, pure virtual call. A "
      "FAIL-FAST (0xC0000409, or the 0xE0464645 DirectComposition raises) "
      "bypasses every one of them: no [crash] record, no minidump, this log "
      "simply ends mid-run. For that, read the Application event log "
      "(\"Application Error\", id 1000 - it names the faulting module and "
      "exception code) and %ProgramData%\\Microsoft\\Windows\\WER.");
}

}  // namespace tfc
