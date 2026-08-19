import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/firmware_image.dart';

class FirmwareRepositoryException implements Exception {
  final String message;
  const FirmwareRepositoryException(this.message);

  factory FirmwareRepositoryException.http(int code) =>
      FirmwareRepositoryException('Server returned HTTP $code.');

  static const noDownloadURL = FirmwareRepositoryException(
      'No download URL was provided for this build.');
  static const checksumMismatch = FirmwareRepositoryException(
      'Downloaded firmware failed its SHA-256 check.');

  @override
  String toString() => message;
}

/// REST client for the AWS firmware catalog (see docs/AWS_BACKEND.md).
class FirmwareRepository {
  final Uri baseURL;
  final http.Client _client;

  /// Supplies a Cognito JWT for authorized requests. Returns null when
  /// unauthenticated.
  Future<String?> Function() tokenProvider = () async => null;

  FirmwareRepository({required this.baseURL, http.Client? client})
      : _client = client ?? http.Client();

  Future<Map<String, String>> _headers() async {
    final token = await tokenProvider();
    return token == null ? {} : {'Authorization': 'Bearer $token'};
  }

  /// List builds available for a board, newest first.
  Future<List<FirmwareImage>> listFirmware(String boardId) async {
    final url = baseURL.resolve('boards/$boardId/firmware');
    final response = await _client.get(url, headers: await _headers());
    _check(response);
    final envelope = jsonDecode(response.body) as Map<String, dynamic>;
    return ((envelope['items'] as List?) ?? const [])
        .map((e) => FirmwareImage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// Fetch build detail including a presigned `downloadUrl`.
  Future<FirmwareImage> detail(String buildId) async {
    final url = baseURL.resolve('firmware/$buildId');
    final response = await _client.get(url, headers: await _headers());
    _check(response);
    return FirmwareImage.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>);
  }

  /// Download the firmware binary and verify its SHA-256 before returning it.
  Future<Uint8List> download(FirmwareImage image) async {
    final resolved =
        image.downloadUrl != null ? image : await detail(image.buildId);
    final url = resolved.downloadUrl;
    if (url == null) throw FirmwareRepositoryException.noDownloadURL;

    final response = await _client.get(url);
    _check(response);

    final digest = sha256.convert(response.bodyBytes).toString();
    if (digest.toLowerCase() != resolved.sha256.toLowerCase()) {
      throw FirmwareRepositoryException.checksumMismatch;
    }
    return response.bodyBytes;
  }

  void _check(http.Response response) {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FirmwareRepositoryException.http(response.statusCode);
    }
  }

  void dispose() => _client.close();
}
