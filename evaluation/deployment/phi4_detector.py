import json
import re
from typing import List

from sglang.srt.entrypoints.openai.protocol import Tool
from sglang.srt.function_call.base_format_detector import BaseFormatDetector
from sglang.srt.function_call.core_types import (
    StreamingParseResult,
    StructureInfo,
    _GetInfoFunc,
)


class Phi4Detector(BaseFormatDetector):
    """Parse Phi-4 native ``<|tool_call|>JSON<|/tool_call|>`` blocks."""

    def __init__(self):
        super().__init__()
        self.bot_token = "<|tool_call|>"
        self.eot_token = "<|/tool_call|>"

    def has_tool_call(self, text: str) -> bool:
        stripped = text.lstrip()
        return self.bot_token in text or stripped.startswith("[")

    def detect_and_parse(self, text: str, tools: List[Tool]) -> StreamingParseResult:
        stripped = text.strip()
        if self.bot_token not in text:
            try:
                parsed = json.loads(stripped)
                calls = self.parse_base_json(parsed, tools)
                if calls:
                    return StreamingParseResult(normal_text="", calls=calls)
            except (TypeError, ValueError, json.JSONDecodeError):
                pass
            return StreamingParseResult(normal_text=text, calls=[])

        calls = []
        normal_parts = []
        cursor = 0
        pattern = re.compile(
            re.escape(self.bot_token) + r"(.*?)" + re.escape(self.eot_token),
            re.DOTALL,
        )
        for match in pattern.finditer(text):
            normal_parts.append(text[cursor : match.start()])
            try:
                calls.extend(self.parse_base_json(json.loads(match.group(1).strip()), tools))
            except (TypeError, ValueError, json.JSONDecodeError):
                normal_parts.append(match.group(0))
            cursor = match.end()
        normal_parts.append(text[cursor:])
        return StreamingParseResult(normal_text="".join(normal_parts), calls=calls)

    def parse_streaming_increment(
        self, new_text: str, tools: List[Tool]
    ) -> StreamingParseResult:
        self._buffer += new_text
        start = self._buffer.find(self.bot_token)

        if start == -1:
            stripped = self._buffer.lstrip()
            if stripped.startswith("["):
                try:
                    parsed = json.loads(stripped)
                except json.JSONDecodeError:
                    return StreamingParseResult()
                calls = self.parse_base_json(parsed, tools)
                if calls:
                    self._buffer = ""
                    return StreamingParseResult(normal_text="", calls=calls)
                normal_text = self._buffer
                self._buffer = ""
                return StreamingParseResult(normal_text=normal_text)

            partial = self._ends_with_partial_token(self._buffer, self.bot_token)
            if partial:
                normal_text = self._buffer[:-partial]
                self._buffer = self._buffer[-partial:]
            else:
                normal_text = self._buffer
                self._buffer = ""
            return StreamingParseResult(normal_text=normal_text)

        if start > 0:
            normal_text = self._buffer[:start]
            self._buffer = self._buffer[start:]
            return StreamingParseResult(normal_text=normal_text)

        end = self._buffer.find(self.eot_token, len(self.bot_token))
        if end == -1:
            return StreamingParseResult()

        block_end = end + len(self.eot_token)
        block = self._buffer[:block_end]
        self._buffer = self._buffer[block_end:]
        return self.detect_and_parse(block, tools)

    def finish(self, tools: List[Tool]) -> StreamingParseResult:
        if not self._buffer:
            return StreamingParseResult()
        text = self._buffer
        self._buffer = ""
        return self.detect_and_parse(text, tools)

    def supports_structural_tag(self) -> bool:
        return False

    def parses_required_natively(self) -> bool:
        return True

    def structure_info(self) -> _GetInfoFunc:
        return lambda name: StructureInfo(
            begin=self.bot_token + '[{"name":"' + name + '","parameters":',
            end="}]" + self.eot_token,
            trigger=self.bot_token,
        )
