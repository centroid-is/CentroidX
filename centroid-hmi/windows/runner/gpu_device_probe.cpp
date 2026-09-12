#include "gpu_device_probe.h"

#include <dxgi.h>
#include <windows.h>

#include <vector>

namespace tfc {
namespace {

// Narrow a DXGI_ADAPTER_DESC's wide description without pulling in a locale.
std::string ToUtf8(const wchar_t* wide) {
  if (wide == nullptr || *wide == L'\0') {
    return std::string();
  }
  const int needed = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, nullptr, 0,
                                           nullptr, nullptr);
  if (needed <= 1) {
    return std::string();
  }
  std::vector<char> buffer(static_cast<size_t>(needed));
  const int written = ::WideCharToMultiByte(CP_UTF8, 0, wide, -1, buffer.data(),
                                            needed, nullptr, nullptr);
  if (written <= 1) {
    return std::string();
  }
  // written includes the terminating NUL.
  return std::string(buffer.data(), static_cast<size_t>(written - 1));
}

}  // namespace

bool GpuDeviceProbe::Create() {
  Reset();

  // Null adapter and the hardware driver type: the same default ANGLE takes,
  // so the sentinel lands on the adapter the renderer is actually using.
  //
  // BGRA_SUPPORT matches what ANGLE asks for. No debug flag: the debug layer
  // is not installed on a plant PC and asking for it fails device creation
  // outright, which would cost the diagnosis on exactly the machines that
  // need it.
  const D3D_FEATURE_LEVEL levels[] = {
      D3D_FEATURE_LEVEL_11_1, D3D_FEATURE_LEVEL_11_0,
      D3D_FEATURE_LEVEL_10_1, D3D_FEATURE_LEVEL_10_0,
      D3D_FEATURE_LEVEL_9_3,
  };

  Microsoft::WRL::ComPtr<ID3D11Device> device;
  D3D_FEATURE_LEVEL obtained = D3D_FEATURE_LEVEL_9_3;
  HRESULT hr = ::D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
      static_cast<UINT>(sizeof(levels) / sizeof(levels[0])), D3D11_SDK_VERSION,
      &device, &obtained, nullptr);

  if (FAILED(hr)) {
    // A machine with no hardware adapter at all (some VMs, session 0) still
    // renders through WARP. A sentinel there is still worth having: WARP does
    // not TDR, so a removed WARP device is itself informative.
    hr = ::D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                             D3D11_CREATE_DEVICE_BGRA_SUPPORT, levels,
                             static_cast<UINT>(sizeof(levels) / sizeof(levels[0])),
                             D3D11_SDK_VERSION, &device, &obtained, nullptr);
  }
  if (FAILED(hr) || !device) {
    return false;
  }

  device_ = device;

  // The adapter description is read once, here, while everything still works.
  // Reading it after the loss would mean querying a dead device.
  Microsoft::WRL::ComPtr<IDXGIDevice> dxgi_device;
  if (SUCCEEDED(device_.As(&dxgi_device))) {
    Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
    if (SUCCEEDED(dxgi_device->GetAdapter(&adapter))) {
      DXGI_ADAPTER_DESC desc = {};
      if (SUCCEEDED(adapter->GetDesc(&desc))) {
        adapter_description_ = ToUtf8(desc.Description);
        vendor_id_ = static_cast<unsigned int>(desc.VendorId);
        device_id_ = static_cast<unsigned int>(desc.DeviceId);
      }
    }
  }

  // A device with no description is still a usable sentinel, so this is not a
  // failure — the report says "unknown adapter" and still names the reason.
  return true;
}

std::uint32_t GpuDeviceProbe::GetRemovedReason() const {
  if (!device_) {
    return 0u;  // S_OK
  }
  return static_cast<std::uint32_t>(device_->GetDeviceRemovedReason());
}

void GpuDeviceProbe::Reset() {
  device_.Reset();
  adapter_description_.clear();
  vendor_id_ = 0;
  device_id_ = 0;
}

bool QuerySessionDisplayAdapterLuid(unsigned long long* luid_out) {
  if (luid_out == nullptr) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIFactory1> factory;
  if (FAILED(::CreateDXGIFactory1(IID_PPV_ARGS(&factory))) || !factory) {
    return false;
  }
  Microsoft::WRL::ComPtr<IDXGIAdapter1> adapter;
  if (FAILED(factory->EnumAdapters1(0, &adapter)) || !adapter) {
    return false;
  }
  DXGI_ADAPTER_DESC1 desc = {};
  if (FAILED(adapter->GetDesc1(&desc))) {
    return false;
  }
  *luid_out = LuidToU64(desc.AdapterLuid);
  return true;
}

}  // namespace tfc
