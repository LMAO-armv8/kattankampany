// ignore_for_file: non_constant_identifier_names
//
// Minimal advapi32 registry bindings.
//
// Only the five calls the agent needs (create, set, query, delete, close) are
// bound, all against `HKEY_CURRENT_USER`. The agent never writes to
// `HKEY_LOCAL_MACHINE`, so it never needs administrator rights at runtime.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _RegCreateKeyExNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpSubKey,
  Uint32 reserved,
  Pointer<Utf16> lpClass,
  Uint32 dwOptions,
  Uint32 samDesired,
  Pointer<Void> lpSecurityAttributes,
  Pointer<IntPtr> phkResult,
  Pointer<Uint32> lpdwDisposition,
);
typedef _RegCreateKeyExDart = int Function(
  int hKey,
  Pointer<Utf16> lpSubKey,
  int reserved,
  Pointer<Utf16> lpClass,
  int dwOptions,
  int samDesired,
  Pointer<Void> lpSecurityAttributes,
  Pointer<IntPtr> phkResult,
  Pointer<Uint32> lpdwDisposition,
);

typedef _RegOpenKeyExNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpSubKey,
  Uint32 ulOptions,
  Uint32 samDesired,
  Pointer<IntPtr> phkResult,
);
typedef _RegOpenKeyExDart = int Function(
  int hKey,
  Pointer<Utf16> lpSubKey,
  int ulOptions,
  int samDesired,
  Pointer<IntPtr> phkResult,
);

typedef _RegSetValueExNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpValueName,
  Uint32 reserved,
  Uint32 dwType,
  Pointer<Uint8> lpData,
  Uint32 cbData,
);
typedef _RegSetValueExDart = int Function(
  int hKey,
  Pointer<Utf16> lpValueName,
  int reserved,
  int dwType,
  Pointer<Uint8> lpData,
  int cbData,
);

typedef _RegQueryValueExNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);
typedef _RegQueryValueExDart = int Function(
  int hKey,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);

typedef _RegDeleteValueNative = Int32 Function(
  IntPtr hKey,
  Pointer<Utf16> lpValueName,
);
typedef _RegDeleteValueDart = int Function(
  int hKey,
  Pointer<Utf16> lpValueName,
);

typedef _RegCloseKeyNative = Int32 Function(IntPtr hKey);
typedef _RegCloseKeyDart = int Function(int hKey);

class _Advapi32 {
  _Advapi32._(this._lib);

  static _Advapi32? _instance;
  static _Advapi32 get instance =>
      _instance ??= _Advapi32._(DynamicLibrary.open('advapi32.dll'));

  final DynamicLibrary _lib;

  late final _RegCreateKeyExDart createKeyEx =
      _lib.lookupFunction<_RegCreateKeyExNative, _RegCreateKeyExDart>(
    'RegCreateKeyExW',
  );
  late final _RegOpenKeyExDart openKeyEx =
      _lib.lookupFunction<_RegOpenKeyExNative, _RegOpenKeyExDart>(
    'RegOpenKeyExW',
  );
  late final _RegSetValueExDart setValueEx =
      _lib.lookupFunction<_RegSetValueExNative, _RegSetValueExDart>(
    'RegSetValueExW',
  );
  late final _RegQueryValueExDart queryValueEx =
      _lib.lookupFunction<_RegQueryValueExNative, _RegQueryValueExDart>(
    'RegQueryValueExW',
  );
  late final _RegDeleteValueDart deleteValue =
      _lib.lookupFunction<_RegDeleteValueNative, _RegDeleteValueDart>(
    'RegDeleteValueW',
  );
  late final _RegCloseKeyDart closeKey =
      _lib.lookupFunction<_RegCloseKeyNative, _RegCloseKeyDart>('RegCloseKey');
}

abstract final class RegistryConstants {
  static const int hkeyCurrentUser = 0x80000001;
  static const int keyRead = 0x20019;
  static const int keyWrite = 0x20006;
  static const int keyAllAccess = 0xF003F;
  static const int regSz = 1;
  static const int errorSuccess = 0;
  static const int errorFileNotFound = 2;
}

/// String values under `HKEY_CURRENT_USER`.
abstract final class Win32Registry {
  static bool get isSupported => Platform.isWindows;

  /// Reads a REG_SZ value. Returns null when the key or value is absent.
  static String? readString({
    required String subKey,
    required String valueName,
  }) {
    if (!isSupported) return null;
    final api = _Advapi32.instance;
    final keyPtr = subKey.toNativeUtf16();
    final namePtr = valueName.toNativeUtf16();
    final handle = calloc<IntPtr>();
    final size = calloc<Uint32>();

    try {
      if (api.openKeyEx(
            RegistryConstants.hkeyCurrentUser,
            keyPtr,
            0,
            RegistryConstants.keyRead,
            handle,
          ) !=
          RegistryConstants.errorSuccess) {
        return null;
      }
      final hKey = handle.value;
      Pointer<Uint8> buffer = nullptr;
      try {
        if (api.queryValueEx(hKey, namePtr, nullptr, nullptr, nullptr, size) !=
            RegistryConstants.errorSuccess) {
          return null;
        }
        final bytes = size.value;
        if (bytes == 0) return null;
        buffer = calloc<Uint8>(bytes);
        if (api.queryValueEx(hKey, namePtr, nullptr, nullptr, buffer, size) !=
            RegistryConstants.errorSuccess) {
          return null;
        }
        return buffer.cast<Utf16>().toDartString();
      } finally {
        if (buffer != nullptr) calloc.free(buffer);
        api.closeKey(hKey);
      }
    } catch (_) {
      return null;
    } finally {
      calloc.free(keyPtr);
      calloc.free(namePtr);
      calloc.free(handle);
      calloc.free(size);
    }
  }

  /// Creates the key if needed and writes a REG_SZ value.
  static bool writeString({
    required String subKey,
    required String valueName,
    required String value,
  }) {
    if (!isSupported) return false;
    final api = _Advapi32.instance;
    final keyPtr = subKey.toNativeUtf16();
    final namePtr = valueName.toNativeUtf16();
    final handle = calloc<IntPtr>();
    final disposition = calloc<Uint32>();
    final valuePtr = value.toNativeUtf16();

    try {
      if (api.createKeyEx(
            RegistryConstants.hkeyCurrentUser,
            keyPtr,
            0,
            nullptr,
            0,
            RegistryConstants.keyWrite,
            nullptr,
            handle,
            disposition,
          ) !=
          RegistryConstants.errorSuccess) {
        return false;
      }
      final hKey = handle.value;
      try {
        // REG_SZ length must include the terminating null character.
        final byteLength = (value.length + 1) * 2;
        final result = api.setValueEx(
          hKey,
          namePtr,
          0,
          RegistryConstants.regSz,
          valuePtr.cast<Uint8>(),
          byteLength,
        );
        return result == RegistryConstants.errorSuccess;
      } finally {
        api.closeKey(hKey);
      }
    } catch (_) {
      return false;
    } finally {
      calloc.free(keyPtr);
      calloc.free(namePtr);
      calloc.free(handle);
      calloc.free(disposition);
      calloc.free(valuePtr);
    }
  }

  /// Deletes a value. Returns true if it is gone afterwards — including when it
  /// was already absent.
  static bool deleteValue({
    required String subKey,
    required String valueName,
  }) {
    if (!isSupported) return false;
    final api = _Advapi32.instance;
    final keyPtr = subKey.toNativeUtf16();
    final namePtr = valueName.toNativeUtf16();
    final handle = calloc<IntPtr>();

    try {
      if (api.openKeyEx(
            RegistryConstants.hkeyCurrentUser,
            keyPtr,
            0,
            RegistryConstants.keyAllAccess,
            handle,
          ) !=
          RegistryConstants.errorSuccess) {
        return true;
      }
      final hKey = handle.value;
      try {
        final result = api.deleteValue(hKey, namePtr);
        return result == RegistryConstants.errorSuccess ||
            result == RegistryConstants.errorFileNotFound;
      } finally {
        api.closeKey(hKey);
      }
    } catch (_) {
      return false;
    } finally {
      calloc.free(keyPtr);
      calloc.free(namePtr);
      calloc.free(handle);
    }
  }
}
