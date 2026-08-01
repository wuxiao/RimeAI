"""Protocol example only; this is not a trained model."""

import json
import sys


MODEL_ARTIFACT_ID = "demo-context-repeat-v1"


for line in sys.stdin:
    request = json.loads(line)
    context = request["context"]
    candidates = request["candidates"]
    ranked = sorted(
        candidates,
        key=lambda candidate: (
            -context.count(candidate["text"]),
            candidate["baseline_rank"],
        ),
    )
    best_repeat_count = context.count(ranked[0]["text"])
    response = {
        "schema_version": 1,
        "request_id": request["request_id"],
        "ranking": [candidate["id"] for candidate in ranked],
        "confidence": 0.8 if best_repeat_count else 0.2,
        "model_artifact_id": MODEL_ARTIFACT_ID,
    }
    print(json.dumps(response, ensure_ascii=False), flush=True)

