// ignore_for_file: camel_case_types, non_constant_identifier_names
//
// Windows Data Protection API (DPAPI) bindings.
//
// DPAPI encrypts a blob with a key derived from the current user's Windows
// credentials. The ciphertext is useless on another machine or to another user
// account, and the agent never has to invent, store or ship a key of its own.
// This is the storage Windows itself provides for this purpose, which is why
// the agent uses it rather than rolling its own encryption.
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

/// `DATA_BLOB` — a length/pointer pair. Used for both input and output.
final class CRYPT_DATA_BLOB extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptProtectDataNative = Int32 Function(
  Pointer<CRYPT_DATA_BLOB> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<CRYPT_DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<CRYPT_DATA_BLOB> pDataOut,
);
typedef _CryptProtectDataDart = int Function(
  Pointer<CRYPT_DATA_BLOB> pDataIn,
  Pointer<Utf16> szDataDescr,
  Pointer<CRYPT_DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<CRYPT_DATA_BLOB> pDataOut,
);

typedef _CryptUnprotectDataNative = Int32 Function(
  Pointer<CRYPT_DATA_BLOB> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<CRYPT_DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  Uint32 dwFlags,
  Pointer<CRYPT_DATA_BLOB> pDataOut,
);
typedef _CryptUnprotectDataDart = int Function(
  Pointer<CRYPT_DATA_BLOB> pDataIn,
  Pointer<Pointer<Utf16>> ppszDataDescr,
  Pointer<CRYPT_DATA_BLOB> pOptionalEntropy,
  Pointer<Void> pvReserved,
  Pointer<Void> pPromptStruct,
  int dwFlags,
  Pointer<CRYPT_DATA_BLOB> pDataOut,
);

typedef _LocalFreeNative = IntPtr Function(IntPtr hMem);
typedef _LocalFreeDart = int Function(int hMem);

class _Crypt32 {
  _Crypt32._(this._crypt32, this._kernel32);

  static _Crypt32? _instance;

  static _Crypt32 get instance => _instance ??= _Crypt32._(
        DynamicLibrary.open('crypt32.dll'),
        DynamicLibrary.open('kernel32.dll'),
      );

  final DynamicLibrary _crypt32;
  final DynamicLibrary _kernel32;

  late final _CryptProtectDataDart protect =
      _crypt32.lookupFunction<_CryptProtectDataNative, _CryptProtectDataDart>(
    'CryptProtectData',
  );

  late final _CryptUnprotectDataDart unprotect = _crypt32
      .lookupFunction<_CryptUnprotectDataNative, _CryptUnprotectDataDart>(
    'CryptUnprotectData',
  );

  late final _LocalFreeDart localFree =
      _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeDart>('LocalFree');
}

/// Thrown when DPAPI refuses to encrypt or decrypt.
class DpapiException implements Exception {
  const DpapiException(this.message);
  final String message;
  @override
  String toString() => 'DpapiException: $message';
}

/// User-scoped DPAPI encryption.
abstract final class Dpapi {
  /// `CRYPTPROTECT_UI_FORBIDDEN` — never show a prompt; the agent runs headless.
  static const int _uiForbidden = 0x1;

  static bool get isSupported => Platform.isWindows;

  /// Encrypts [plaintext], binding the ciphertext to the current Windows user.
  ///
  /// [entropy] is an application-specific salt mixed into the key derivation.
  /// It is not a secret — it simply means a blob produced by this application
  /// cannot be decrypted by a different application running as the same user.
  static Uint8List protect(Uint8List plaintext, {Uint8List? entropy}) {
    if (!isSupported) {
      throw const DpapiException('DPAPI is only available on Windows.');
    }

    final input = calloc<CRYPT_DATA_BLOB>();
    final output = calloc<CRYPT_DATA_BLOB>();
    final Pointer<CRYPT_DATA_BLOB> entropyBlob =
        entropy == null ? nullptr : calloc<CRYPT_DATA_BLOB>();
    Pointer<Uint8> inputBytes = nullptr;
    Pointer<Uint8> entropyBytes = nullptr;

    try {
      inputBytes = calloc<Uint8>(plaintext.length);
      inputBytes.asTypedList(plaintext.length).setAll(0, plaintext);
      input.ref
        ..cbData = plaintext.length
        ..pbData = inputBytes;

      if (entropy != null) {
        entropyBytes = calloc<Uint8>(entropy.length);
        entropyBytes.asTypedList(entropy.length).setAll(0, entropy);
        entropyBlob.ref
          ..cbData = entropy.length
          ..pbData = entropyBytes;
      }

      final ok = _Crypt32.instance.protect(
        input,
        nullptr,
        entropyBlob,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) {
        throw const DpapiException('CryptProtectData failed.');
      }

      final length = output.ref.cbData;
      final result = Uint8List.fromList(
        output.ref.pbData.asTypedList(length),
      );
      _Crypt32.instance.localFree(output.ref.pbData.address);
      return result;
    } finally {
      calloc.free(input);
      calloc.free(output);
      if (entropyBlob != nullptr) calloc.free(entropyBlob);
      if (inputBytes != nullptr) calloc.free(inputBytes);
      if (entropyBytes != nullptr) calloc.free(entropyBytes);
    }
  }

  /// Reverses [protect]. Throws [DpapiException] if the blob was produced by a
  /// different user, on a different machine, or with different [entropy].
  static Uint8List unprotect(Uint8List ciphertext, {Uint8List? entropy}) {
    if (!isSupported) {
      throw const DpapiException('DPAPI is only available on Windows.');
    }

    final input = calloc<CRYPT_DATA_BLOB>();
    final output = calloc<CRYPT_DATA_BLOB>();
    final Pointer<CRYPT_DATA_BLOB> entropyBlob =
        entropy == null ? nullptr : calloc<CRYPT_DATA_BLOB>();
    Pointer<Uint8> inputBytes = nullptr;
    Pointer<Uint8> entropyBytes = nullptr;

    try {
      inputBytes = calloc<Uint8>(ciphertext.length);
      inputBytes.asTypedList(ciphertext.length).setAll(0, ciphertext);
      input.ref
        ..cbData = ciphertext.length
        ..pbData = inputBytes;

      if (entropy != null) {
        entropyBytes = calloc<Uint8>(entropy.length);
        entropyBytes.asTypedList(entropy.length).setAll(0, entropy);
        entropyBlob.ref
          ..cbData = entropy.length
          ..pbData = entropyBytes;
      }

      final ok = _Crypt32.instance.unprotect(
        input,
        nullptr,
        entropyBlob,
        nullptr,
        nullptr,
        _uiForbidden,
        output,
      );
      if (ok == 0) {
        throw const DpapiException('CryptUnprotectData failed.');
      }

      final length = output.ref.cbData;
      final result = Uint8List.fromList(
        output.ref.pbData.asTypedList(length),
      );
      _Crypt32.instance.localFree(output.ref.pbData.address);
      return result;
    } finally {
      calloc.free(input);
      calloc.free(output);
      if (entropyBlob != nullptr) calloc.free(entropyBlob);
      if (inputBytes != nullptr) calloc.free(inputBytes);
      if (entropyBytes != nullptr) calloc.free(entropyBytes);
    }
  }
}
