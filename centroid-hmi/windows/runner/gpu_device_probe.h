#ifndef RUNNER_GPU_DEVICE_PROBE_H_
#define RUNNER_GPU_DEVICE_PROBE_H_

#include <d3d11.h>
#include <wrl/client.h>

#include <cstdint>
#include <string>

// A D3D11 device the runner keeps purely so it can be asked why it died.
//
// The reason the log has nothing useful in it after a device loss is that the
// only device that knows is ANGLE's, and ANGLE's lives inside
// flutter_windows.dll where we cannot reach it. So the runner creates a device
// of its own on the same (default) adapter at startup and never renders with
// it. It costs a few hundred kilobytes and answers the one question that
// matters: GetDeviceRemovedReason().
//
// The event that takes ANGLE's device down -- a TDR, a driver restart, an
// adapter reset -- is adapter-wide, so this device goes down with it and its
// reason code is ANGLE's reason code. When this device is *still alive* after
// the renderer has stopped presenting frames, that is a finding in itself: the
// GPU is fine and something narrower killed the render context, which points
// at the session/desktop swap rather than at the driver.
//
// Deliberately not unit tested: every line is a D3D call, there is no seam
// worth inventing, and the decisions this feeds are all in gpu_diagnosis.h
// where they are tested. Everything here fails soft -- a machine where the
// device cannot be created still runs the app, it just reports "no sentinel"
// instead of a reason.

namespace tfc {

class GpuDeviceProbe {
 public:
  // Creates the sentinel device and reads the adapter's description. Returns
  // false if either failed; the probe is then permanently unavailable and
  // FormatLossReport is told so rather than being handed a misleading S_OK.
  bool Create();

  // False when Create() was never called or did not succeed.
  bool available() const { return device_ != nullptr; }

  // S_OK while the device is alive, a DXGI_ERROR_DEVICE_* code once it is not.
  // Returns S_OK when unavailable, which is why callers must check
  // available() first -- see LossEvidence::sentinel_available.
  //
  // The HRESULT is cast to a fixed-width unsigned value here rather than being
  // passed on as `long`: see the note on DxgiReason in gpu_diagnosis.h.
  std::uint32_t GetRemovedReason() const;

  const std::string& adapter_description() const {
    return adapter_description_;
  }
  unsigned int vendor_id() const { return vendor_id_; }
  unsigned int device_id() const { return device_id_; }

  // Drops the device. Used after a loss has been reported so a later recovery
  // can create a fresh one rather than keep asking a corpse.
  void Reset();

 private:
  Microsoft::WRL::ComPtr<ID3D11Device> device_;
  std::string adapter_description_;
  unsigned int vendor_id_ = 0;
  unsigned int device_id_ = 0;
};

// A LUID as one number, so two adapters can be compared without dxgi.h in
// the platform-free code that does the comparing (session_rebuild_policy.h).
inline unsigned long long LuidToU64(const LUID& luid) {
  return (static_cast<unsigned long long>(
              static_cast<unsigned long>(luid.HighPart))
          << 32) |
         luid.LowPart;
}

// The LUID of the adapter this session currently displays on: the first
// adapter a fresh DXGI factory enumerates, which is the one holding the
// session's primary output. A fresh factory every call, because a factory
// made before a session change describes the session before it. Returns
// false when DXGI will not say -- which the caller must treat as unknown,
// not as a change.
bool QuerySessionDisplayAdapterLuid(unsigned long long* luid_out);

}  // namespace tfc

#endif  // RUNNER_GPU_DEVICE_PROBE_H_
