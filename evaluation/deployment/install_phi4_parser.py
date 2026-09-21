from pathlib import Path


target = Path(
    "/sgl-workspace/sglang/python/sglang/srt/function_call/function_call_parser.py"
)
source = target.read_text(encoding="utf-8")

import_anchor = (
    "from sglang.srt.function_call.poolside_v1_detector import PoolsideV1Detector\n"
)
registry_anchor = '        "pythonic": PythonicDetector,\n'

if "from sglang.srt.function_call.phi4_detector import Phi4Detector" not in source:
    if import_anchor not in source:
        raise RuntimeError("SGLang parser import anchor not found")
    source = source.replace(
        import_anchor,
        import_anchor
        + "from sglang.srt.function_call.phi4_detector import Phi4Detector\n",
        1,
    )

if '"phi4": Phi4Detector' not in source:
    if registry_anchor not in source:
        raise RuntimeError("SGLang parser registry anchor not found")
    source = source.replace(
        registry_anchor,
        '        "phi4": Phi4Detector,\n' + registry_anchor,
        1,
    )

target.write_text(source, encoding="utf-8")
