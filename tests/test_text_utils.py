"""
文本处理工具函数测试。

测试 utils/text.py 中的 strip_think_tags 函数：
1. 各种 CoT/思考标签格式的过滤
2. 不完整标签的清理（流式输出截断）
3. 边界情况（空字符串、无标签、嵌套标签等）

Validates: Requirements - CoT tag filtering
"""

import unittest

from spoken.utils.text import strip_think_tags


class TestStripThinkTags(unittest.TestCase):
    """strip_think_tags 函数测试。"""

    # ── 基本功能 ──

    def test_empty_string(self):
        """空字符串应返回空字符串。"""
        self.assertEqual(strip_think_tags(""), "")

    def test_no_tags(self):
        """无标签的文字应原样返回（去除首尾空白后）。"""
        self.assertEqual(strip_think_tags("你好世界"), "你好世界")

    def test_strip_whitespace(self):
        """结果应去除首尾空白。"""
        self.assertEqual(strip_think_tags("  你好  "), "你好")

    # ── <think> 标签 ──

    def test_think_tag_removed(self):
        """think 标签应被移除。"""
        text = "<think>这是思考过程</think>最终结果"
        result = strip_think_tags(text)
        self.assertEqual(result, "最终结果")

    def test_thinking_tag_removed(self):
        """thinking 标签应被移除。"""
        text = "<thinking>这是推理过程</thinking>最终答案"
        result = strip_think_tags(text)
        self.assertEqual(result, "最终答案")

    def test_think_tag_multiline(self):
        """多行 think 标签应被完整移除。"""
        text = "<think>第一行\n第二行\n第三行</think>结果"
        result = strip_think_tags(text)
        self.assertEqual(result, "结果")

    # ── <reasoning> 标签 ──

    def test_reasoning_tag_removed(self):
        """reasoning 标签应被移除。"""
        text = "<reasoning>推理过程</reasoning>答案"
        result = strip_think_tags(text)
        self.assertEqual(result, "答案")

    # ── 不完整标签（流式输出截断）──

    def test_incomplete_open_think_tag(self):
        """流式截断：只有开头 think 标签应清理后续内容。"""
        text = "<think>这是不完整的思考"
        result = strip_think_tags(text)
        self.assertEqual(result, "")

    def test_incomplete_close_think_tag(self):
        """流式截断：只有结尾 close think 标签应清理之前内容。"""
        text = "不完整的思考</think>最终结果"
        result = strip_think_tags(text)
        self.assertEqual(result, "最终结果")

    def test_incomplete_open_reasoning_tag(self):
        """流式截断：只有开头 reasoning 标签应清理后续内容。"""
        text = "<reasoning>不完整推理"
        result = strip_think_tags(text)
        self.assertEqual(result, "")

    # ── 多标签组合 ──

    def test_multiple_think_tags(self):
        """多个 think 标签应全部被移除。"""
        text = "<think>思考1</think>中间文字<think>思考2</think>最终"
        result = strip_think_tags(text)
        self.assertEqual(result, "中间文字最终")

    def test_mixed_tag_types(self):
        """混合标签类型应全部被移除。"""
        text = "<think>思考</think>正文<reasoning>推理</reasoning>结果"
        result = strip_think_tags(text)
        self.assertEqual(result, "正文结果")

    # ── 保留正文内容 ──

    def test_preserves_content_before_tags(self):
        """标签前的文字应保留。"""
        text = "前面的文字"
        result = strip_think_tags(text)
        self.assertEqual(result, "前面的文字")

    def test_preserves_content_after_tags(self):
        """标签后的文字应保留。"""
        text = "<think>思考</think>后面的文字"
        result = strip_think_tags(text)
        self.assertEqual(result, "后面的文字")

    def test_preserves_content_between_tags(self):
        """两组标签之间的文字应保留。"""
        text = "<think>思考1</think>中间<think>思考2</think>"
        result = strip_think_tags(text)
        self.assertEqual(result, "中间")

    # ── None 安全 ──

    def test_none_input(self):
        """None 输入应安全处理。"""
        # strip_think_tags 检查 `if not text`，None 也是 falsy
        self.assertIsNone(strip_think_tags(None))

    # ── CoT 俄语标签 ──

    def test_cot_russian_tag_removed(self):
        """俄语 CoT 标签应被移除。"""
        text = "<\u0434\u0443\u043c\u0430\u044e>思考过程</resposta>结果"
        result = strip_think_tags(text)
        self.assertEqual(result, "结果")


if __name__ == "__main__":
    unittest.main()
