#!/usr/bin/env python3

import argparse
import json
from pathlib import Path

from rimeai_eval.onnx_ranker import export_quantized_onnx_ranker


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Export the trained RimeAI 24M ranker as quantized ONNX"
    )
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--opset", type=int, default=17)
    args = parser.parse_args()
    manifest = export_quantized_onnx_ranker(
        args.source,
        args.output,
        opset=args.opset,
    )
    print(json.dumps(manifest, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
