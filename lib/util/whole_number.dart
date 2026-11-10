/// A whole number read from the database. In a browser SQLite hands a number past 2^53 over as a BigInt - which is no `int` there - and
/// the hashes of texts (see `NoteSorter.hashOf`) are 63 bits wide. It is rounded to what a number of the browser can hold, as the hash
/// itself is made there, so that the two still compare equal; on every other platform nothing changes.
int wholeNumber(Object? value) => switch (value) {
      int() => value,
      BigInt() => value.toInt(),
      num() => value.toInt(),
      _ => throw TypeError(),
    };
