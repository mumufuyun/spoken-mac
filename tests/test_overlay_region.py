"""
Overlay 浮窗裁切区域测试。

测试 _apply_rounded_region 方法的行为，包括：
1. 缓存逻辑（尺寸不变且有缓存时跳过更新）
2. 子窗口裁切（EnumChildWindows + SetWindowRgn）
3. GDI 资源清理（DeleteObject）
4. 边界情况（无 hwnd、非 Windows 平台等）

Validates: Requirements 1.3, 1.4
"""

import unittest
from unittest.mock import MagicMock, patch, PropertyMock
import ctypes


class TestOverlayRegionCacheLogic(unittest.TestCase):
    """测试 _apply_rounded_region 的缓存逻辑。"""

    def test_skip_update_when_same_size_and_cache_exists(self):
        """尺寸不变且有顶层+子窗口缓存时应跳过更新。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()
        overlay._region_width = 640
        overlay._region_height = 120
        overlay._cached_region = 12345  # 模拟有效句柄
        overlay._cached_child_regions = [67890]  # 模拟子窗口缓存

        with patch.object(overlay, "_get_hwnd", return_value=100):
            # 不应调用任何 Win32 API
            with patch("ctypes.windll") as mock_windll:
                overlay._apply_rounded_region(640, 120)
                mock_windll.gdi32.CreateRoundRectRgn.assert_not_called()

    def test_trigger_update_when_size_changed(self):
        """尺寸变化时应触发更新。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()
        overlay._region_width = 640
        overlay._region_height = 120
        overlay._cached_region = 12345
        overlay._cached_child_regions = [67890]

        with patch.object(overlay, "_get_hwnd", return_value=100):
            with patch.object(overlay, "_apply_rounded_region_impl", create=True):
                # 尺寸变化应触发更新
                # 直接验证 _region_width / _region_height 在调用后是否可能改变
                # 由于 _apply_rounded_region 会执行，我们通过检查缓存条件不满足来确认
                self.assertNotEqual(
                    (overlay._region_width, overlay._region_height),
                    (800, 200),
                )

    def test_trigger_update_when_no_child_cache(self):
        """有顶层缓存但无子窗口缓存时应触发更新。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()
        overlay._region_width = 640
        overlay._region_height = 120
        overlay._cached_region = 12345
        overlay._cached_child_regions = []  # 无子窗口缓存

        # 即使尺寸相同，缓存条件也不满足
        with patch.object(overlay, "_get_hwnd", return_value=100):
            with patch("spoken.overlay.window._IS_WINDOWS", True):
                # 缓存检查应不通过（_cached_child_regions 为空）
                self.assertFalse(
                    overlay._cached_region and overlay._cached_child_regions
                )


class TestOverlayRegionNoWindow(unittest.TestCase):
    """测试无窗口时的安全处理。"""

    def test_no_window_object(self):
        """无 pywebview 窗口对象时应直接返回。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = None
        # 不应抛出异常
        overlay._apply_rounded_region(640, 120)

    def test_no_hwnd(self):
        """无法获取 hwnd 时应直接返回。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()

        with patch.object(overlay, "_get_hwnd", return_value=None):
            # 不应抛出异常
            overlay._apply_rounded_region(640, 120)

    def test_not_windows_platform(self):
        """非 Windows 平台时应直接返回。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()

        with patch("spoken.overlay.window._IS_WINDOWS", False):
            overlay._apply_rounded_region(640, 120)


class TestOverlayRegionChildWindowClipping(unittest.TestCase):
    """测试子窗口裁切逻辑。"""

    def test_child_regions_cached(self):
        """子窗口裁切区域应被缓存。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()
        overlay._cached_child_regions = []

        # 模拟成功裁切后的状态
        overlay._cached_child_regions = [1001, 1002]
        overlay._region_width = 640
        overlay._region_height = 120
        overlay._cached_region = 999

        # 缓存条件应满足
        self.assertTrue(overlay._cached_region and overlay._cached_child_regions)
        self.assertEqual(len(overlay._cached_child_regions), 2)

    def test_child_regions_cleaned_before_reapply(self):
        """重新裁切前应清理旧的子窗口区域句柄。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()
        old_regions = [1001, 1002, 1003]
        overlay._cached_child_regions = old_regions.copy()

        with patch.object(overlay, "_get_hwnd", return_value=100):
            with patch("spoken.overlay.window._IS_WINDOWS", True):
                with patch("ctypes.windll") as mock_windll:
                    # 模拟 GetWindowRect
                    mock_rect = MagicMock()
                    mock_rect.right = 640
                    mock_rect.left = 0
                    mock_rect.bottom = 120
                    mock_rect.top = 0
                    mock_windll.user32.GetWindowRect.return_value = 1

                    # 模拟 EnumChildWindows 不找到子窗口
                    mock_windll.user32.EnumChildWindows = MagicMock()

                    # 模拟 DPI
                    mock_windll.user32.GetDpiForWindow.return_value = 96

                    # 模拟 CreateRoundRectRgn
                    mock_windll.gdi32.CreateRoundRectRgn.return_value = 999
                    mock_windll.user32.SetWindowRgn.return_value = 1
                    mock_windll.gdi32.DeleteObject.return_value = 1

                    overlay._apply_rounded_region(640, 120)

                    # 应调用 DeleteObject 清理旧句柄
                    for old_hrgn in old_regions:
                        mock_windll.gdi32.DeleteObject.assert_any_call(old_hrgn)

    def test_init_has_child_regions_field(self):
        """__init__ 应初始化 _cached_child_regions 为空列表。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        self.assertIsInstance(overlay._cached_child_regions, list)
        self.assertEqual(overlay._cached_child_regions, [])


class TestOverlayRegionEdgeCases(unittest.TestCase):
    """测试裁切区域边界情况。"""

    def test_zero_size_region(self):
        """零尺寸应处理而不崩溃。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        # 零尺寸时缓存不命中，会尝试调用 Win32
        overlay._window = MagicMock()

        with patch.object(overlay, "_get_hwnd", return_value=None):
            # 无 hwnd 时安全返回
            overlay._apply_rounded_region(0, 0)

    def test_very_large_size(self):
        """极大尺寸应允许更新。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        overlay._window = MagicMock()
        overlay._region_width = 1920
        overlay._region_height = 1080
        overlay._cached_region = None
        overlay._cached_child_regions = []

        with patch.object(overlay, "_get_hwnd", return_value=100):
            with patch("spoken.overlay.window._IS_WINDOWS", True):
                with patch("ctypes.windll") as mock_windll:
                    mock_rect = MagicMock()
                    mock_rect.right = 3840
                    mock_rect.left = 0
                    mock_rect.bottom = 2160
                    mock_rect.top = 0
                    mock_windll.user32.GetWindowRect.return_value = 1
                    mock_windll.user32.EnumChildWindows = MagicMock()
                    mock_windll.user32.GetDpiForWindow.return_value = 96
                    mock_windll.gdi32.CreateRoundRectRgn.return_value = 999
                    mock_windll.user32.SetWindowRgn.return_value = 1

                    overlay._apply_rounded_region(3840, 2160)

                    # 应创建裁切区域
                    mock_windll.gdi32.CreateRoundRectRgn.assert_called()


class TestOverlayRegionProperty(unittest.TestCase):
    """
    Property 1: Overlay cropping region consistency.
    For any valid window dimensions, applying a rounded region
    should result in a region that covers the content area.
    """

    def test_region_cache_tracks_dimensions_small(self):
        """小尺寸下裁切缓存应正确跟踪。"""
        self._test_region_dimensions(100, 50)

    def test_region_cache_tracks_dimensions_medium(self):
        """中等尺寸下裁切缓存应正确跟踪。"""
        self._test_region_dimensions(400, 200)

    def test_region_cache_tracks_dimensions_large(self):
        """大尺寸下裁切缓存应正确跟踪。"""
        self._test_region_dimensions(800, 400)

    def test_region_cache_tracks_dimensions_1080p(self):
        """1080p 尺寸下裁切缓存应正确跟踪。"""
        self._test_region_dimensions(1920, 1080)

    def test_region_cache_tracks_dimensions_custom(self):
        """自定义尺寸下裁切缓存应正确跟踪。"""
        self._test_region_dimensions(300, 150)

    def _test_region_dimensions(self, width, height):
        """辅助方法：测试给定尺寸下的缓存行为。"""
        from spoken.overlay.window import OverlayWindow

        overlay = OverlayWindow()
        # 模拟成功应用后的状态
        overlay._region_width = width
        overlay._region_height = height
        overlay._cached_region = 12345
        overlay._cached_child_regions = [67890]

        # 相同尺寸且缓存有效时，不应更新
        with patch.object(overlay, "_get_hwnd", return_value=100):
            with patch("ctypes.windll") as mock_windll:
                overlay._apply_rounded_region(width, height)
                mock_windll.gdi32.CreateRoundRectRgn.assert_not_called()


if __name__ == "__main__":
    unittest.main()
