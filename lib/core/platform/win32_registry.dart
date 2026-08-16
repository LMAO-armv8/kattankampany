// ignore_for_file: non_constant_identifier_names
//
// Minimal advapi32 registry bindings.
//
// Only the calls the agent needs (create, set, query, enumerate, delete, close)
// are bound. Writes always target `HKEY_CURRENT_USER`; the agent never writes to
// `HKEY_LOCAL_MACHINE`, so it never needs administrator rights at runtime.
//
// Reads may target `HKEY_LOCAL_MACHINE`, which needs no elevation. Printer
// port topology (which COM port is a Bluetooth link, which TCP/IP port maps to
// which host) lives there and nowhere else. See `PortInspector`.
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

typedef _RegEnumValueNative = Int32 Function(
  IntPtr hKey,
  Uint32 dwIndex,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpcchValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
);
typedef _RegEnumValueDart = int Function(
  int hKey,
  int dwIndex,
  Pointer<Utf16> lpValueName,
  Pointer<Uint32> lpcchValueName,
  Pointer<Uint32> lpReserved,
  Pointer<Uint32> lpType,
  Pointer<Uint8> lpData,
  Pointer<Uint32> lpcbData,
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
  late final _RegEnumValueDart enumValue =
      _lib.lookupFunction<_RegEnumValueNative, _RegEnumValueDart>(
    'RegEnumValueW',
  );
  late final _RegCloseKeyDart closeKey =
      _lib.lookupFunction<_RegCloseKeyNative, _RegCloseKeyDart>('RegCloseKey');
}

abstract final class RegistryConstants {
  static const int hkeyCurrentUser = 0x80000001;
  static const int hkeyLocalMachine = 0x80000002;
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
  ///
  /// [hive] defaults to `HKEY_CURRENT_USER`. Reading `HKEY_LOCAL_MACHINE`
  /// requires no elevation.
  static String? readString({
    required String subKey,
    required String valueName,
    int hive = RegistryConstants.hkeyCurrentUser,
  }) {
    if (!isSupported) return null;
    final api = _Advapi32.instance;
    final keyPtr = subKey.toNativeUtf16();
    final namePtr = valueName.toNativeUtf16();
    final handle = calloc<IntPtr>();
    final size = calloc<Uint32>();

    try {
      if (api.openKeyEx(
            hive,
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

  /// Every REG_SZ value under [subKey], as `{valueName: value}`.
  ///
  /// Values of other types are skipped rather than guessed at. Returns an empty
  /// map when the key does not exist, which is the normal case on a machine with
  /// no Bluetooth stack or no TCP/IP printer ports.
  static Map<String, String> readStringValues({
    required String subKey,
    int hive = RegistryConstants.hkeyCurrentUser,
  }) {
    final result = <String, String>{};
    if (!isSupported) return result;

    final api = _Advapi32.instance;
    final keyPtr = subKey.toNativeUtf16();
    final handle = calloc<IntPtr>();

    // Documented maxima: 16 383 chars for a value name, and the agent only reads
    // short strings (COM port names, host names), so a fixed data buffer is
    // sufficient and avoids a sizing round-trip per value.
    const nameCapacity = 16384;
    const dataCapacity = 4096;
    final namePtr = calloc<Uint16>(nameCapacity).cast<Utf16>();
    final dataPtr = calloc<Uint8>(dataCapacity);
    final nameLen = calloc<Uint32>();
    final dataLen = calloc<Uint32>();
    final type = calloc<Uint32>();

    try {
      if (api.openKeyEx(
            hive,
            keyPtr,
            0,
            RegistryConstants.keyRead,
            handle,
          ) !=
          RegistryConstants.errorSuccess) {
        return result;
      }
      final hKey = handle.value;
      try {
        for (var index = 0;; index++) {
          nameLen.value = nameCapacity;
          dataLen.value = dataCapacity;
          final status = api.enumValue(
            hKey,
            index,
            namePtr,
            nameLen,
            nullptr,
            type,
            dataPtr,
            dataLen,
          );
          if (status != RegistryConstants.errorSuccess) break;
          if (type.value != RegistryConstants.regSz) continue;
          if (dataLen.value == 0) continue;

          final name = namePtr.toDartString(length: nameLen.value);
          // RegEnumValueW reports the byte count including the terminator.
          final chars = (dataLen.value ~/ 2).clamp(0, dataCapacity ~/ 2);
          var value = dataPtr.cast<Utf16>().toDartString(length: chars);
          final terminator = value.indexOf('\u0000');
          if (terminator >= 0) value = value.substring(0, terminator);
          if (value.isNotEmpty) result[name] = value;
        }
      } finally {
        api.closeKey(hKey);
      }
    } catch (_) {
      // A malformed hive is not worth failing discovery over.
    } finally {
      calloc.free(keyPtr);
      calloc.free(handle);
      calloc.free(namePtr);
      calloc.free(dataPtr);
      calloc.free(nameLen);
      calloc.free(dataLen);
      calloc.free(type);
    }
    return result;
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
