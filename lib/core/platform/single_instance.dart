import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateMutexNative = IntPtr Function(
  Pointer<Void> lpMutexAttributes,
  Int32 bInitialOwner,
  Pointer<Utf16> lpName,
);
typedef _CreateMutexDart = int Function(
  Pointer<Void> lpMutexAttributes,
  int bInitialOwner,
  Pointer<Utf16> lpName,
);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

typedef _CloseHandleNative = Int32 Function(IntPtr hObject);
typedef _CloseHandleDart = int Function(int hObject);

/// Prevents two copies of the agent running for the same Windows user.
///
/// Two agents on one machine would both claim jobs from the same store and both
/// send them to the same printer — the exact duplicate-printing scenario the
/// whole queue design exists to prevent. A named mutex is the cheapest reliable
/// guard, and Windows releases it automatically if the process is killed.
class SingleInstanceGuard {
  SingleInstanceGuard({this.mutexName = _defaultName});

  static const String _defaultName =
      r'Local\WooCommercePrintAgent.SingleInstance';

  /// `Local\` scopes the mutex to the current session, so Fast User Switching
  /// still lets a second Windows user run their own agent.
  final String mutexName;

  static const int _errorAlreadyExists = 183;

  int _handle = 0;
  bool _acquired = false;

  bool get isAcquired => _acquired;

  /// Returns true when this process is the only instance.
  bool acquire() {
    if (!Platform.isWindows) {
      _acquired = true;
      return true;
    }
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final createMutex =
        kernel32.lookupFunction<_CreateMutexNative, _CreateMutexDart>(
      'CreateMutexW',
    );
    final getLastError =
        kernel32.lookupFunction<_GetLastErrorNative, _GetLastErrorDart>(
      'GetLastError',
    );

    final namePtr = mutexName.toNativeUtf16();
    try {
      _handle = createMutex(nullptr, 1, namePtr);
      if (_handle == 0) {
        // Could not create the mutex at all — do not block startup over it.
        _acquired = true;
        return true;
      }
      if (getLastError() == _errorAlreadyExists) {
        _acquired = false;
        return false;
      }
      _acquired = true;
      return true;
    } catch (_) {
      _acquired = true;
      return true;
    } finally {
      calloc.free(namePtr);
    }
  }

  void release() {
    if (!Platform.isWindows || _handle == 0) return;
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final closeHandle =
          kernel32.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
        'CloseHandle',
      );
      closeHandle(_handle);
    } catch (_) {
      // Windows reclaims the handle when the process exits.
    } finally {
      _handle = 0;
      _acquired = false;
    }
  }
}
