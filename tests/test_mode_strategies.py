"""
模式策略属性测试。

Property 4: Mode configuration independence
For any two different modes, when each mode has its own configuration and history,
then changes to one mode's configuration should not affect the other mode's configuration or history.

Property 5: Mode prompt correctness
For any mode E (Meeting Minutes), the system prompt should contain meeting-related keywords;
for any mode F (Content Structuring), the system prompt should contain structuring-related keywords.

Validates: Requirements 3.1, 3.2, 3.3, 3.5
"""

import unittest


class TestModePromptCorrectness(unittest.TestCase):
    """Property 5: 测试模式提示词正确性。"""

    def test_mode_e_contains_meeting_keywords(self):
        """模式 E 提示词应包含会议相关关键词。"""
        from spoken.ai.prompts import get_system_prompt

        prompt = get_system_prompt("E")
        meeting_keywords = ["会议", "纪要", "主题", "参与者", "讨论点", "决策", "待办"]
        found_keywords = [kw for kw in meeting_keywords if kw in prompt]
        self.assertTrue(
            len(found_keywords) >= 3,
            f"模式 E 提示词应包含会议相关关键词，但只找到: {found_keywords}"
        )

    def test_mode_f_contains_structuring_keywords(self):
        """模式 F 提示词应包含结构化相关关键词。"""
        from spoken.ai.prompts import get_system_prompt

        prompt = get_system_prompt("F")
        structuring_keywords = ["结构化", "整理", "分类", "要点", "主题", "层次"]
        found_keywords = [kw for kw in structuring_keywords if kw in prompt]
        self.assertTrue(
            len(found_keywords) >= 3,
            f"模式 F 提示词应包含结构化相关关键词，但只找到: {found_keywords}"
        )

    def test_mode_e_not_contains_structuring_only_keywords(self):
        """模式 E 不应只包含通用结构化关键词而不含会议关键词。"""
        from spoken.ai.prompts import get_system_prompt

        prompt = get_system_prompt("E")
        # 应包含"会议"这个核心词
        self.assertIn("会议", prompt)

    def test_mode_f_not_contains_meeting_only_keywords(self):
        """模式 F 不应只包含会议关键词而不含通用结构化关键词。"""
        from spoken.ai.prompts import get_system_prompt

        prompt = get_system_prompt("F")
        # 不应包含"会议纪要"这个会议专属词
        self.assertNotIn("会议纪要", prompt)

    def test_all_modes_have_prompts(self):
        """所有支持的模式都应有默认提示词。"""
        from spoken.ai.prompts import get_system_prompt

        for mode in ["B", "C", "D", "E", "F"]:
            prompt = get_system_prompt(mode)
            self.assertTrue(len(prompt) > 50, f"模式 {mode} 的提示词过短")

    def test_custom_prompt_override(self):
        """自定义提示词应覆盖默认提示词。"""
        from spoken.ai.prompts import get_system_prompt

        custom = "这是一个自定义提示词"
        prompt = get_system_prompt("E", custom_prompt=custom)
        self.assertEqual(prompt, custom)

    def test_invalid_mode_raises_error(self):
        """无效模式应抛出错误。"""
        from spoken.ai.prompts import get_system_prompt

        with self.assertRaises(ValueError):
            get_system_prompt("X")


class TestModeConfigurationIndependence(unittest.TestCase):
    """Property 4: 测试模式配置独立性。"""

    def test_ai_processor_mode_prompts_independent(self):
        """AIProcessor 中各模式的自定义提示词应相互独立。"""
        from spoken.ai.processor import AIProcessor

        processor = AIProcessor(
            custom_prompt_e="会议纪要自定义提示词",
            custom_prompt_f="内容结构化自定义提示词",
        )

        self.assertEqual(processor._custom_prompts["E"], "会议纪要自定义提示词")
        self.assertEqual(processor._custom_prompts["F"], "内容结构化自定义提示词")

    def test_mode_prompt_change_does_not_affect_others(self):
        """修改一个模式的提示词不应影响其他模式。"""
        from spoken.ai.processor import AIProcessor

        processor = AIProcessor(
            custom_prompt_e="会议提示词",
            custom_prompt_f="结构化提示词",
        )

        # 修改 E 的提示词
        processor._custom_prompts["E"] = "新的会议提示词"

        # F 的提示词不应受影响
        self.assertEqual(processor._custom_prompts["F"], "结构化提示词")

    def test_mode_timeout_independent(self):
        """各模式的超时配置应相互独立。"""
        from spoken.ai.processor import AIProcessor

        processor = AIProcessor()
        processor._mode_timeouts["E"] = 15.0
        processor._mode_timeouts["F"] = 20.0

        self.assertEqual(processor._mode_timeouts["E"], 15.0)
        self.assertEqual(processor._mode_timeouts["F"], 20.0)


class TestStateControllerModes(unittest.TestCase):
    """测试 StateController 支持新模式。"""

    def test_mode_e_name(self):
        """模式 E 的名称应为会议纪要。"""
        from spoken.state import MODE_NAMES

        self.assertEqual(MODE_NAMES["E"], "会议纪要")

    def test_mode_f_name(self):
        """模式 F 的名称应为内容结构化。"""
        from spoken.state import MODE_NAMES

        self.assertEqual(MODE_NAMES["F"], "内容结构化")

    def test_mode_cycle_includes_all_modes(self):
        """模式循环应包含所有 6 个模式。"""
        from spoken.state import _MODE_CYCLE, WorkMode

        modes_in_cycle = set()
        current = WorkMode.DIRECT
        for _ in range(6):
            modes_in_cycle.add(current)
            current = _MODE_CYCLE[current]

        self.assertEqual(len(modes_in_cycle), 6)

    def test_workmode_enum_values(self):
        """WorkMode 枚举值应正确。"""
        from spoken.state import WorkMode

        self.assertEqual(WorkMode.DIRECT, "A")
        self.assertEqual(WorkMode.POLISH, "B")
        self.assertEqual(WorkMode.TO_PROMPT, "C")
        self.assertEqual(WorkMode.TRANSLATE, "D")
        self.assertEqual(WorkMode.MEETING_MINUTES, "E")
        self.assertEqual(WorkMode.STRUCTURED, "F")


if __name__ == "__main__":
    unittest.main()
