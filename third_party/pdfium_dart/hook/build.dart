import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import '../lib/src/proxy_http_client.dart';

const _pdfiumRelease = 'chromium%2F7811';
const _assetName = 'libpdfium';

/// Cozy Safe: the SHA-256 of each archive of release chromium/7811, as GitHub lists them
/// for github.com/bblanchon/pdfium-binaries. A download that differs is refused, so a
/// changed or swapped binary stops the build. Bumping the release means new values here.
const _sha256 = {
  'pdfium-android-arm.tgz': 'bb9250eefb33343f56f27f7e60c81ab3236d932c40e21557bf02ca4c276eb832',
  'pdfium-android-arm64.tgz': 'f51539cadeb5135534305b8bdf8685ce2fbe9991dbbc5b35f553108411b9ed14',
  'pdfium-android-x64.tgz': '23faaf6f993a39524d9dc7fafbb760e295f8bd5e9ffa46139bad2299fb5c80f3',
  'pdfium-android-x86.tgz': '3b9f6466f93241b5df4ee932485e128469b98ebf6a4466ae5737ec56e5400074',
  'pdfium-linux-arm.tgz': '9bdcf34b4d109f48c2f64527358096bfb9d110b8d1f5b7bb164a54cb068908fb',
  'pdfium-linux-arm64.tgz': '1682079aae24d73fcfb4f1ae115dd7b661780ad31ad43c8804da2d518dc546e8',
  'pdfium-linux-x64.tgz': 'e76e0a37aefb843d56f04657475ce612157021b1ebc53d801f2fbfcc537ccf64',
  'pdfium-linux-x86.tgz': 'b1eb95df7692b805779b8f8191c6532266003e94ba956a5011b846639f65dc9f',
  'pdfium-mac-arm64.tgz': 'f9bbf1ebdc459e5f5ff25b2d457cc21db55ebfc0cf3d89fc1b90ce5445dac394',
  'pdfium-mac-x64.tgz': 'b31565aacda1f84393cd98438b06b49f21124888785e7dd1ddf015fa4406bd80',
  'pdfium-win-arm64.tgz': 'fa52ad62562a7bbe258c19fbf12adb794af2c204daba52a088ac1315a9968211',
  'pdfium-win-x64.tgz': '2e7af12674ac3716cb0e20369bb9fb269ceadfa2f0b0597097a520e6834175a0',
  'pdfium-win-x86.tgz': 'a8d84dae2afa81a48cf3ded6f64d9e9cabb469897ae0281f4146eedcfce276fb',
};

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    if (input.config.code.targetOS == OS.iOS) return;

    final target = _PdfiumTarget.fromCodeConfig(input.config.code);
    final outputSubdir = _pdfiumRelease.replaceAll('%2F', '_');
    final outputFile = input.outputDirectoryShared.resolve(
      '$outputSubdir/${target.archivePlatform}-${target.archiveArch}/${target.libraryFileName}',
    );

    await _downloadPdfium(
      outputFile: outputFile,
      target: target,
      pdfiumRelease: _pdfiumRelease,
    );

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: _assetName,
        linkMode: DynamicLoadingBundled(),
        file: outputFile,
      ),
    );
  });
}

Future<void> _downloadPdfium({
  required Uri outputFile,
  required _PdfiumTarget target,
  required String pdfiumRelease,
}) async {
  final output = File.fromUri(outputFile);
  if (await output.exists()) return;

  final archiveName = 'pdfium-${target.archivePlatform}-${target.archiveArch}.tgz';
  final want = _sha256[archiveName];
  if (want == null) {
    throw Exception('No pinned SHA-256 for $archiveName: add it to hook/build.dart.');
  }
  final archiveUri = Uri.parse(
    'https://github.com/bblanchon/pdfium-binaries/releases/download/'
    '$pdfiumRelease/$archiveName',
  );

  final response = await getWithRetries(archiveUri);
  if (response.statusCode != 200) {
    throw Exception(
      'Failed to download PDFium: HTTP ${response.statusCode} $archiveUri',
    );
  }

  final got = sha256.convert(response.bodyBytes).toString();
  if (got != want) {
    throw Exception('PDFium archive $archiveName has SHA-256 $got, expected $want. Refused.');
  }

  final archive = TarDecoder().decodeBytes(
    GZipDecoder().decodeBytes(response.bodyBytes),
  );
  final member = archive.findFile(target.archiveLibraryPath);
  if (member == null) {
    throw Exception(
      'PDFium archive $archiveUri does not contain ${target.archiveLibraryPath}.',
    );
  }

  await output.parent.create(recursive: true);
  await output.writeAsBytes(member.content as List<int>);
}

final class _PdfiumTarget {
  const _PdfiumTarget({
    required this.archivePlatform,
    required this.archiveArch,
    required this.archiveLibraryPath,
    required this.libraryFileName,
  });

  final String archivePlatform;
  final String archiveArch;
  final String archiveLibraryPath;
  final String libraryFileName;

  static _PdfiumTarget fromCodeConfig(CodeConfig config) {
    final arch = switch (config.targetArchitecture) {
      Architecture.ia32 => 'x86',
      Architecture.x64 => 'x64',
      Architecture.arm => 'arm',
      Architecture.arm64 => 'arm64',
      _ => throw UnsupportedError(
        'Unsupported PDFium architecture: ${config.targetArchitecture}',
      ),
    };

    return switch (config.targetOS) {
      OS.android => _PdfiumTarget(
        archivePlatform: 'android',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.so',
        libraryFileName: 'libpdfium.so',
      ),
      OS.windows => _PdfiumTarget(
        archivePlatform: 'win',
        archiveArch: arch,
        archiveLibraryPath: 'bin/pdfium.dll',
        libraryFileName: 'pdfium.dll',
      ),
      OS.linux => _PdfiumTarget(
        archivePlatform: 'linux',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.so',
        libraryFileName: 'libpdfium.so',
      ),
      OS.macOS => _PdfiumTarget(
        archivePlatform: 'mac',
        archiveArch: arch,
        archiveLibraryPath: 'lib/libpdfium.dylib',
        libraryFileName: 'libpdfium.dylib',
      ),
      _ => throw UnsupportedError(
        'Unsupported PDFium platform: ${config.targetOS}',
      ),
    };
  }
}
