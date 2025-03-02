import 'dart:typed_data';

import 'package:modular_web/modular_web.dart';
import 'package:test/test.dart';

void main() {
  group('CID', () {
    test('equivalency', () {
      CID cid =
          blobID(Uint8List.fromList('sjdjifoiodsjfoidjsfoijdsf'.codeUnits));
      final cbor = cidToCbor(cid);
      CID cid2 = cidFromCbor(cbor);
      expect(cid, cid2);
    });
  });
}
