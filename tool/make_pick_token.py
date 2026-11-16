"""Makes assets/onnx/pick_token.onnx: the next token of a language model's scores, picked where the scores are (inside ONNX Runtime).

  python tool/make_pick_token.py

In: logits [batch 1, T, vocabulary] (float). Out: picked [2] (float): the token (the best of the last position, the first of equal
ones, as the Dart loop chose; exact as a float up to 2^24) and its log probability (its score minus the log-sum-exp of all). One
output, so that one call brings it over.
Why: the readers' token loops brought every score over to Dart (59,392 for GLM-OCR) to find the best one: about 7.5 ms a token on a
Ryzen 7 8845HS, on the screen's thread. With this model two numbers come over.
"""
import onnx
from onnx import TensorProto, helper

nodes = [
    helper.make_node('Constant', [], ['start'], value=helper.make_tensor('s', TensorProto.INT64, [1], [-1])),
    helper.make_node('Constant', [], ['end'], value=helper.make_tensor('e', TensorProto.INT64, [1], [2**62])),
    helper.make_node('Constant', [], ['axis'], value=helper.make_tensor('a', TensorProto.INT64, [1], [1])),
    helper.make_node('Constant', [], ['flat_shape'], value=helper.make_tensor('f', TensorProto.INT64, [1], [-1])),
    helper.make_node('Slice', ['logits', 'start', 'end', 'axis'], ['last']),
    helper.make_node('Reshape', ['last', 'flat_shape'], ['flat']),
    helper.make_node('ArgMax', ['flat'], ['token'], axis=0, keepdims=1),
    helper.make_node('ReduceMax', ['flat'], ['best'], axes=[0], keepdims=1),
    helper.make_node('ReduceLogSumExp', ['flat'], ['all'], axes=[0], keepdims=1),
    helper.make_node('Sub', ['best', 'all'], ['log_prob']),
    helper.make_node('Cast', ['token'], ['token_float'], to=TensorProto.FLOAT),
    helper.make_node('Concat', ['token_float', 'log_prob'], ['picked'], axis=0),
]
graph = helper.make_graph(
    nodes, 'pick_token',
    [helper.make_tensor_value_info('logits', TensorProto.FLOAT, [1, 'T', 'V'])],
    [helper.make_tensor_value_info('picked', TensorProto.FLOAT, [2])],
)
model = helper.make_model(graph, opset_imports=[helper.make_opsetid('', 17)], producer_name='notation')
model.ir_version = 8
onnx.checker.check_model(model)
onnx.save(model, 'assets/onnx/pick_token.onnx')
print('assets/onnx/pick_token.onnx', len(model.SerializeToString()), 'bytes')
