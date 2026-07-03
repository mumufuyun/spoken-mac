"""
spoken/audio/devices.py
麦克风设备枚举模块。

支持 PyAudio 和 sounddevice 两种后端，
返回统一格式的设备列表。
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import List, Optional

logger = logging.getLogger(__name__)


@dataclass
class AudioDevice:
    """音频输入设备信息。"""

    index: int           # 设备索引（PyAudio/sounddevice）
    name: str            # 设备名称
    max_channels: int    # 最大输入声道数
    default_sample_rate: float  # 默认采样率
    is_default: bool     # 是否为系统默认输入设备

    def __str__(self) -> str:
        default_mark = " [默认]" if self.is_default else ""
        return (
            f"[{self.index}] {self.name}{default_mark} "
            f"(声道: {self.max_channels}, 采样率: {int(self.default_sample_rate)}Hz)"
        )


def list_devices_pyaudio() -> List[AudioDevice]:
    """使用 PyAudio 枚举所有输入设备。

    Returns:
        AudioDevice 列表，按索引升序排列

    Raises:
        ImportError: PyAudio 未安装
        RuntimeError: PyAudio 初始化失败
    """
    try:
        import pyaudio
    except ImportError as e:
        raise ImportError("PyAudio 未安装，请运行: pip install PyAudio") from e

    pa = pyaudio.PyAudio()
    devices: List[AudioDevice] = []

    try:
        # 获取默认输入设备索引
        try:
            default_info = pa.get_default_input_device_info()
            default_index: Optional[int] = int(default_info["index"])
        except OSError:
            default_index = None
            logger.warning("无法获取默认输入设备信息")

        # 遍历所有设备
        for i in range(pa.get_device_count()):
            try:
                info = pa.get_device_info_by_index(i)
                # 只保留有输入声道的设备
                if info.get("maxInputChannels", 0) > 0:
                    devices.append(AudioDevice(
                        index=i,
                        name=str(info["name"]),
                        max_channels=int(info["maxInputChannels"]),
                        default_sample_rate=float(info["defaultSampleRate"]),
                        is_default=(i == default_index),
                    ))
            except Exception as e:
                logger.debug("获取设备 %d 信息失败: %s", i, e)
    finally:
        pa.terminate()

    logger.info("PyAudio 枚举到 %d 个输入设备", len(devices))
    return devices


def list_devices_sounddevice() -> List[AudioDevice]:
    """使用 sounddevice 枚举所有输入设备。

    Returns:
        AudioDevice 列表，按索引升序排列

    Raises:
        ImportError: sounddevice 未安装
    """
    try:
        import sounddevice as sd
    except ImportError as e:
        raise ImportError("sounddevice 未安装，请运行: pip install sounddevice") from e

    devices: List[AudioDevice] = []
    try:
        default_input = sd.default.device[0]  # type: ignore[index]
    except Exception:
        default_input = -1

    for device in sd.query_devices():
        if device["max_input_channels"] > 0:  # type: ignore[index]
            idx = device["index"] if "index" in device else len(devices)  # type: ignore[call-overload]
            # sounddevice 的 DeviceList 可能没有 index 字段，需要用枚举下标
            devices.append(AudioDevice(
                index=int(idx),
                name=str(device["name"]),  # type: ignore[index]
                max_channels=int(device["max_input_channels"]),  # type: ignore[index]
                default_sample_rate=float(device["default_samplerate"]),  # type: ignore[index]
                is_default=(int(idx) == default_input),
            ))

    logger.info("sounddevice 枚举到 %d 个输入设备", len(devices))
    return devices


def list_devices(backend: str = "pyaudio") -> List[AudioDevice]:
    """枚举可用麦克风设备（统一入口）。

    Args:
        backend: 后端选择，"pyaudio" 或 "sounddevice"

    Returns:
        AudioDevice 列表

    Raises:
        ValueError: backend 参数无效
    """
    if backend == "pyaudio":
        return list_devices_pyaudio()
    elif backend == "sounddevice":
        return list_devices_sounddevice()
    else:
        raise ValueError(f"不支持的音频后端: {backend}，可选: pyaudio / sounddevice")


def get_default_device(backend: str = "pyaudio") -> Optional[AudioDevice]:
    """获取系统默认输入设备。

    Args:
        backend: 后端选择

    Returns:
        默认设备，如果没有则返回 None
    """
    try:
        devices = list_devices(backend)
        for dev in devices:
            if dev.is_default:
                return dev
        # 如果没有标记为默认的，返回第一个
        return devices[0] if devices else None
    except Exception as e:
        logger.error("获取默认设备失败: %s", e)
        return None


def print_devices(backend: str = "pyaudio") -> None:
    """打印所有可用输入设备（调试用）。

    Args:
        backend: 后端选择
    """
    try:
        devices = list_devices(backend)
        if not devices:
            print("未找到任何输入设备")
            return
        print(f"\n可用麦克风设备（后端: {backend}）：")
        for dev in devices:
            print(f"  {dev}")
        print()
    except Exception as e:
        logger.error("枚举设备失败: %s", e)
        print(f"枚举设备失败: {e}")


if __name__ == "__main__":
    # 直接运行此模块可列出所有可用设备
    print_devices("pyaudio")
