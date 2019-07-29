// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.invalid_type_builder;

import '../fasta_codes.dart' show LocatedMessage;

import 'builder.dart' show TypeDeclarationBuilder;

abstract class InvalidTypeBuilder extends TypeDeclarationBuilder {
  InvalidTypeBuilder(String name, int charOffset, [Uri fileUri])
      : super(null, 0, name, null, charOffset, fileUri);

  LocatedMessage get message;

  String get debugName => "InvalidTypeBuilder";
}
