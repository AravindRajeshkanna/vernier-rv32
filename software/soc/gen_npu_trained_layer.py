#!/usr/bin/env python3
"""Generates software/soc/npu_trained_layer_data.h: real trained-model
weights for rtl/soc/wb_npu.v (Phase 14), closing the one gap every NPU
stage so far has named as still open - every prior workload
(gen_npu_layer.py, gen_npu_dma_workload.py) used int8 vectors drawn
straight from random.Random, which have no relationship to any task at
all. These weights are different in kind, not just in source: they are
the output of an actual gradient-descent training loop minimizing a
real cross-entropy loss, the same category of artifact a real deployed
quantized model's weights would be, not a synthetic stand-in for one.

What is, and is not, "real" here, stated plainly rather than implied:
the WEIGHTS are genuinely trained - no numpy/sklearn/torch exists in
this environment, so this is a from-scratch, pure-Python-stdlib
multi-class linear (softmax) classifier, trained by per-example
stochastic gradient descent on cross-entropy loss, no bias term (the
peripheral's own MAC engine is a pure dot product with no accumulation
input, so a model that needs a bias would not be faithfully
representable in hardware at all). The DATA is still synthetic - four
class "prototype" directions in NPU_TRAINED_INPUT_DIM-dimensional
space, real training/validation examples drawn as prototype-plus-noise
- not sourced from any real-world dataset, since none is fetched or
bundled here. A model trained on genuinely real-world data remains a
still-open, still-different gap; this closes "trained weights", not
"real-world data".

Trained in float, quantized to int8 afterward (standard post-training
quantization, matching how quantized-inference deployments actually
work): per-tensor min-max quantization, separately for the weight
matrix and for the one held-out activation vector that is actually fed
through hardware. The expected dot products below are computed here,
independently of both the training code above and of
rtl/soc/wb_npu.v's own Verilog arithmetic, from the quantized int8
values alone - the same "independent reference" role every earlier NPU
generator already plays.

Held-out accuracy (over VALIDATION_N fresh examples, never used in
training) is measured and printed to stderr, then embedded as a comment
below - the concrete evidence that this model actually learned the
task rather than merely being called "trained". A short seed search
(matching gen_npu_layer.py's own convention) additionally requires: the
one activation vector checked in hardware is correctly classified by
both the float model and its int8-quantized counterpart (so
quantization provably did not flip this example's own decision), and
its four quantized dot products are pairwise distinct and nonzero (so a
sign error, a dropped term, or a neuron mix-up would visibly change the
result, not pass by coincidence).
"""
import math
import random
import sys

INPUT_DIM = 128
N_CLASSES = 4
PROTOTYPE_NORM = 12.0
NOISE_SIGMA = 3.5
TRAIN_N = 300
VALIDATION_N = 100
EPOCHS = 25
LEARNING_RATE = 0.08
L2 = 0.001
ACCURACY_FLOOR = 0.75


def dot(a, b):
    return sum(x * y for x, y in zip(a, b))


def make_prototypes(rng):
    protos = []
    for _ in range(N_CLASSES):
        v = [rng.gauss(0.0, 1.0) for _ in range(INPUT_DIM)]
        norm = math.sqrt(sum(x * x for x in v)) or 1.0
        protos.append([x * (PROTOTYPE_NORM / norm) for x in v])
    return protos


def make_example(rng, protos, label):
    return [p + rng.gauss(0.0, NOISE_SIGMA) for p in protos[label]]


def train(seed):
    rng = random.Random(seed)
    protos = make_prototypes(rng)
    train_set = [(make_example(rng, protos, y % N_CLASSES), y % N_CLASSES)
                 for y in range(TRAIN_N)]
    val_set = [(make_example(rng, protos, y % N_CLASSES), y % N_CLASSES)
               for y in range(VALIDATION_N)]

    weights = [[0.0] * INPUT_DIM for _ in range(N_CLASSES)]
    order = list(range(TRAIN_N))
    for _epoch in range(EPOCHS):
        rng.shuffle(order)
        for idx in order:
            x, y = train_set[idx]
            logits = [dot(weights[k], x) for k in range(N_CLASSES)]
            m = max(logits)
            exps = [math.exp(v - m) for v in logits]
            s = sum(exps)
            probs = [e / s for e in exps]
            for k in range(N_CLASSES):
                err = probs[k] - (1.0 if k == y else 0.0)
                wk = weights[k]
                for i in range(INPUT_DIM):
                    wk[i] -= LEARNING_RATE * (err * x[i] + L2 * wk[i])

    correct = 0
    for x, y in val_set:
        logits = [dot(weights[k], x) for k in range(N_CLASSES)]
        if logits.index(max(logits)) == y:
            correct += 1
    accuracy = correct / VALIDATION_N

    # The one example actually fed through rtl/soc/wb_npu.v's own DMA
    # path in hardware - a fresh example, disjoint from both train_set
    # and val_set, so it was never seen during training or accuracy
    # measurement either.
    hw_x, hw_y = make_example(rng, protos, 0), 0
    float_logits = [dot(weights[k], hw_x) for k in range(N_CLASSES)]
    float_pred = float_logits.index(max(float_logits))

    return weights, hw_x, hw_y, float_pred, accuracy


def quantize_vector(v):
    scale = max(abs(x) for x in v) / 127.0
    if scale == 0.0:
        return [0] * len(v), 1.0
    q = [max(-128, min(127, round(x / scale))) for x in v]
    return q, scale


def build(seed):
    weights, hw_x, hw_y, float_pred, accuracy = train(seed)

    flat_weights = [w for row in weights for w in row]
    w_scale = max(abs(w) for w in flat_weights) / 127.0
    q_weights = [[max(-128, min(127, round(w / w_scale))) for w in row]
                 for row in weights]
    q_activation, _a_scale = quantize_vector(hw_x)

    # Independent reference: a fresh sum-of-products loop over the
    # quantized int8 values alone, not derived from any float/training
    # intermediate above.
    expected = [sum(q_activation[i] * q_weights[k][i] for i in range(INPUT_DIM))
                for k in range(N_CLASSES)]
    quant_pred = expected.index(max(expected))

    return q_activation, q_weights, expected, hw_y, float_pred, quant_pred, accuracy


def acceptable(expected, hw_y, float_pred, quant_pred, accuracy):
    if accuracy < ACCURACY_FLOOR:
        return False
    if float_pred != quant_pred:
        return False
    if float_pred != hw_y:
        return False
    if any(v == 0 for v in expected):
        return False
    return len(set(expected)) == len(expected)


SEED = None
for candidate in range(1, 50):
    a, w, expected, hw_y, float_pred, quant_pred, accuracy = build(candidate)
    if acceptable(expected, hw_y, float_pred, quant_pred, accuracy):
        SEED = candidate
        break
assert SEED is not None, "no acceptable seed found in range"

print(f"gen_npu_trained_layer: seed={SEED} held-out accuracy="
      f"{accuracy * 100:.1f}% over {VALIDATION_N} examples", file=sys.stderr)

lines = []
lines.append("/* Auto-generated by software/soc/gen_npu_trained_layer.py - do not")
lines.append(" * hand-edit. Regenerate with:")
lines.append(" *   python3 software/soc/gen_npu_trained_layer.py > \\")
lines.append(" *                          software/soc/npu_trained_layer_data.h")
lines.append(f" * seed = {SEED}")
lines.append(f" * held-out accuracy = {accuracy * 100:.1f}% over {VALIDATION_N} "
             "examples never used in training")
lines.append(" * (see the script's own header for exactly what is, and is not,")
lines.append(" * \"real\" about this model) */")
lines.append("#ifndef NPU_TRAINED_LAYER_DATA_H")
lines.append("#define NPU_TRAINED_LAYER_DATA_H")
lines.append("")
lines.append("#include <stdint.h>")
lines.append("")
lines.append(f"#define NPU_TRAINED_INPUT_DIM {INPUT_DIM}")
lines.append(f"#define NPU_TRAINED_CLASSES {N_CLASSES}")
lines.append("")
lines.append(f"static const int8_t npu_trained_activation[{INPUT_DIM}] = {{")
for i in range(0, INPUT_DIM, 16):
    lines.append("    " + ", ".join(str(x) for x in a[i:i + 16]) + ",")
lines.append("};")
lines.append("")
lines.append("static const int8_t npu_trained_weights[NPU_TRAINED_CLASSES]"
             f"[{INPUT_DIM}] = {{")
for row in w:
    lines.append("    {")
    for i in range(0, INPUT_DIM, 16):
        lines.append("        " + ", ".join(str(x) for x in row[i:i + 16]) + ",")
    lines.append("    },")
lines.append("};")
lines.append("")
lines.append("static const int32_t npu_trained_expected[NPU_TRAINED_CLASSES] = {")
lines.append("    " + ", ".join(str(x) for x in expected))
lines.append("};")
lines.append("")
lines.append(f"#define NPU_TRAINED_CORRECT_CLASS {hw_y}")
lines.append("")
lines.append("#endif /* NPU_TRAINED_LAYER_DATA_H */")

print("\n".join(lines))
