/// A language model that continues a list of token ids, however it is run (ONNX
/// Runtime in the app, a stand-in in the tests).
abstract class CausalLm {
  /// The tokens that follow [prompt], picking the most likely one each time,
  /// until a token of [stop] or [maxNewTokens]. The stop token is not in the result.
  ///
  /// The first [sharedPrefix] tokens of [prompt] are the same every time (the
  /// instructions and examples): a model may remember what it made of them.
  ///
  /// [onProgress] is told the tokens so far after each one, and the run ends early
  /// (with what there is) once [shouldStop] says so. A [repetitionPenalty] above 1
  /// makes a token that was used already less likely, against loops.
  Future<List<int>> generate(
    List<int> prompt, {
    required int maxNewTokens,
    required Set<int> stop,
    int sharedPrefix = 0,
    void Function(List<int> generated)? onProgress,
    bool Function()? shouldStop,
    double repetitionPenalty = 1,
  });

  Future<void> close();
}
