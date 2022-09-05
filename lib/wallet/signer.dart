import 'dart:convert';
import 'dart:typed_data';

import 'package:agent_dart/agent/crypto/keystore/api.dart';
import 'package:agent_dart/identity/identity.dart';
import 'package:agent_dart/identity/secp256k1.dart';
import 'package:agent_dart/utils/extension.dart';

import 'keysmith.dart';
import 'rosetta.dart';
import 'types.dart';

typedef SigningCallback = void Function([dynamic data]);

enum SignType { ecdsa, ed25519 }

enum SourceType { ii, plug, keySmith, base }

enum CurveType { secp256k1, ed25519, all }

abstract class Signer<T extends SignablePayload, R> {
  const Signer();

  bool? get isLocked;

  Future<void>? unlock(String passphrase, {String? keystore});

  Future<void>? lock(String? passphrase);

  Future<R> sign(
    T payload, {
    SignType? signType = SignType.ed25519,
    SigningCallback? callback,
  });
}

abstract class BaseSigner<T extends BaseAccount, R extends SignablePayload, E>
    extends Signer<R, E> {
  const BaseSigner();
}

abstract class BaseAccount {
  const BaseAccount();

  Ed25519KeyIdentity? getIdentity();

  Secp256k1KeyIdentity? getEcIdentity();

  Map<String, dynamic> toJson();

  ECKeys? getEcKeys();
}

class ICPAccount extends BaseAccount {
  ICPAccount({this.curveType = CurveType.ed25519});

  bool isLocked = false;
  String? _keystore;
  String? _phrase;
  final CurveType curveType;

  Ed25519KeyIdentity? get identity => _identity;
  Ed25519KeyIdentity? _identity;

  Secp256k1KeyIdentity? get ecIdentity => _ecIdentity;
  Secp256k1KeyIdentity? _ecIdentity;

  ECKeys? get ecKeys => _ecKeys;
  ECKeys? _ecKeys;

  static Future<ICPAccount> fromSeed(
    Uint8List seed, {
    int? index,
    CurveType curveType = CurveType.ed25519,
  }) async {
    ECKeys keys = ecKeysfromSeed(seed, index: index ?? 0);
    final Ed25519KeyIdentity? identity = curveType == CurveType.secp256k1
        ? null
        : await Ed25519KeyIdentity.generate(seed);
    final Secp256k1KeyIdentity? ecIdentity = curveType == CurveType.ed25519
        ? null
        : Secp256k1KeyIdentity.fromKeyPair(
            keys.ecPublicKey!,
            keys.ecPrivateKey!,
          );
    return ICPAccount(curveType: curveType)
      .._ecKeys = keys
      .._identity = identity
      .._ecIdentity = ecIdentity
      .._phrase = '';
  }

  static Future<ICPAccount> fromPhrase(
    String phrase, {
    String passphrase = '',
    int? index,
    List<int>? icPath = icBasePath,
    CurveType curveType = CurveType.ed25519,
  }) async {
    ECKeys? keys;
    Secp256k1KeyIdentity? ecIdentity;
    Ed25519KeyIdentity? identity;

    if (curveType == CurveType.secp256k1 || curveType == CurveType.all) {
      keys = await getECKeysAsync(
        phrase,
        passphase: passphrase,
        index: index != null
            ? index != hardened
                ? index
                : 0
            : 0,
      );
      ecIdentity = Secp256k1KeyIdentity.fromKeyPair(
        keys.ecPublicKey!,
        keys.ecPrivateKey!,
      );
    }
    if (curveType == CurveType.ed25519 || curveType == CurveType.all) {
      var path = List<int>.from(icPath ?? icBasePath);
      identity = await fromMnemonicWithoutValidation(
        phrase,
        path,
        offset: index ?? hardened,
      );
    }

    return ICPAccount(curveType: curveType)
      .._ecKeys = keys
      .._identity = identity
      .._ecIdentity = ecIdentity
      .._phrase = phrase;
  }

  @override
  Ed25519KeyIdentity? getIdentity() => _identity;

  @override
  Secp256k1KeyIdentity? getEcIdentity() => _ecIdentity;

  @override
  Map<String, dynamic> toJson() {
    throw UnimplementedError();
  }

  @override
  ECKeys? getEcKeys() => _ecKeys;

  Future<void> lock(String? passphrase) async {
    _keystore = await encodePhrase(_phrase!, passphrase ?? '');
    _phrase = null;
    _ecKeys = null;
    _identity = null;
    _ecIdentity = null;
    isLocked = true;
  }

  Future<void> unlock(String passphrase, {String? keystore}) async {
    try {
      if ((_keystore == null)) {
        if (keystore != null) {
          _keystore = keystore;
        } else {
          throw 'keystore file is not found';
        }
      }
      final phrase = await decodePhrase(
        jsonDecode(_keystore!),
        passphrase,
      );
      var newIcp = await ICPAccount.fromPhrase(
        phrase,
        index: 0,
        curveType: curveType,
      );
      _phrase = phrase;
      _ecKeys = newIcp._ecKeys;
      _identity = newIcp._identity;
      _ecIdentity = newIcp._ecIdentity;
      newIcp._ecKeys = null;
      newIcp._identity = null;
      isLocked = false;
    } catch (e) {
      throw 'Cannot unlock account with password $passphrase '
          'and keystore $_keystore';
    }
  }
}

class ICPSigner extends BaseSigner<ICPAccount, ConstructionPayloadsResponse,
    CombineSignedTransactionResult> {
  ICPSigner._();

  static Future<ICPSigner> create({
    CurveType curveType = CurveType.ed25519,
  }) {
    return ICPSigner.fromPhrase(generateMnemonic(), curveType: curveType);
  }

  static Future<ICPSigner> fromPhrase(
    String phrase, {
    String passphrase = '',
    int? index = 0,
    List<int>? icPath = icBasePath,
    CurveType curveType = CurveType.ed25519,
  }) async {
    final ICPAccount acc = await ICPAccount.fromPhrase(
      phrase,
      passphrase: passphrase,
      index: index,
      icPath: icPath,
      curveType: curveType,
    );
    return ICPSigner._()
      .._phrase = phrase
      .._index = index
      .._acc = acc;
  }

  static Future<ICPSigner> fromSeed(
    Uint8List seed, {
    int? index = 0,
    CurveType curveType = CurveType.ed25519,
  }) async {
    final ICPAccount acc = await ICPAccount.fromSeed(
      seed,
      index: index,
      curveType: curveType,
    );
    return ICPSigner._()
      .._index = index
      .._acc = acc;
  }

  static Future<ICPSigner> importPhrase(
    String phrase, {
    int index = 0,
    SourceType sourceType = SourceType.ii,
    CurveType curveType = CurveType.ed25519,
  }) async {
    switch (sourceType) {
      case SourceType.ii:
        return (await ICPSigner.fromPhrase(
          phrase,
          index: hardened,
          icPath: icDerivationPath,
          curveType: curveType,
        ))
          ..setSourceType(SourceType.ii);
      case SourceType.keySmith:
        return (await ICPSigner.fromPhrase(
          phrase,
          index: index,
          icPath: icDerivationPath,
          curveType: curveType,
        ))
          ..setSourceType(SourceType.keySmith);
      case SourceType.plug:
        return (await ICPSigner.fromPhrase(
          phrase,
          index: index,
          icPath: icDerivationPath,
          curveType: curveType,
        ))
          ..setSourceType(SourceType.keySmith);
      case SourceType.base:
        return (await ICPSigner.fromPhrase(
          phrase,
          index: index,
          curveType: curveType,
        ))
          ..setSourceType(SourceType.base);
      default:
        return (await ICPSigner.fromPhrase(
          phrase,
          index: hardened,
          icPath: icDerivationPath,
          curveType: curveType,
        ))
          ..setSourceType(SourceType.ii);
    }
  }

  ICPAccount get account => _acc;
  late ICPAccount _acc;

  String? _phrase;
  int? _index;
  SourceType? _sourceType;

  SourceType? get sourceType => _sourceType;

  int? get index => _index;

  bool get isHD => index == null;

  String? get idPublicKey => account.identity?.getPublicKey().toRaw().toHex();

  String? get idPublicKeyDer =>
      account.identity?.getPublicKey().toDer().toHex();

  String? get idAddress => account.identity?.getAccountId().toHex();

  @Deprecated('Use idAddress instead')
  String? get idChecksumAddress => idAddress;

  String? get ecPublicKey => account.ecIdentity?.getPublicKey().toRaw().toHex();

  String? get ecPublicKeyDer =>
      account.ecIdentity?.getPublicKey().toDer().toHex();

  String? get ecAddress => account.ecIdentity?.getAccountId().toHex();

  @Deprecated('Use ecAddress instead')
  String? get ecChecksumAddress => ecAddress;

  Future<ICPAccount> hdCreate({
    String passphrase = '',
    int? index = 0,
    List<int>? icPath = icBasePath,
    CurveType curveType = CurveType.ed25519,
  }) {
    return ICPAccount.fromPhrase(
      _phrase!,
      passphrase: passphrase,
      index: _index!,
      icPath: icPath,
      curveType: curveType,
    );
  }

  void setSourceType(SourceType type) {
    _sourceType = type;
  }

  @override
  bool? get isLocked => _acc.isLocked;

  @override
  Future<void> lock(String? passphrase) {
    return _acc.lock(passphrase);
  }

  @override
  Future<void> unlock(
    String passphrase, {
    String? keystore,
  }) {
    return _acc.unlock(passphrase, keystore: keystore);
  }

  @override
  Future<CombineSignedTransactionResult> sign(
    ConstructionPayloadsResponse payload, {
    SignType? signType = SignType.ed25519,
    SigningCallback? callback,
  }) async {
    if (signType == SignType.ed25519) {
      var res = await transferCombine(
        account.identity!,
        payload,
      );
      return res;
    }
    if (signType == SignType.ecdsa) {
      var res = await ecTransferCombine(
        account.ecIdentity!,
        payload,
      );
      return res;
    }
    throw UnsupportedError('Sign type $signType is not supported.');
  }
}
