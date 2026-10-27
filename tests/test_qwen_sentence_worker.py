"""qwen sentence worker（prompt 路线）：信封自声明 RAW 口径标记。

reveal C-F2：prompt 路线的 confidence 是 RAW softmax 几何平均，与
constrained 路线的掩码内归一化口径不可比——信封必须自声明，评测侧
才能拒绝跨口径比较。打分数值本身保持 RAW 不变。
"""

from rimeai_runtime.constrained_worker_protocol import (
    CONFIDENCE_CALIBER_RAW_SOFTMAX,
)
from tools.qwen_sentence_worker import build_response


def test_build_response_declares_raw_softmax_caliber() -> None:
    response = build_response("req-1", "你好", 0.42, "stub:prompt")
    assert response == {
        "schema_version": 1,
        "request_id": "req-1",
        "suggestion": "你好",
        "confidence": 0.42,
        "model_artifact_id": "stub:prompt",
        "confidence_caliber": "raw-softmax-geometric-mean",
    }
    assert CONFIDENCE_CALIBER_RAW_SOFTMAX == "raw-softmax-geometric-mean"
