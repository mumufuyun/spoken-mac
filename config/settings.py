"""
spoken/config/settings.py
配置管理模块：加载默认配置，支持用户配置覆盖。

用户配置路径：%APPDATA%\\Spoken\\config.toml
加载顺序：defaults.toml → 用户 config.toml（部分覆盖）
"""

from __future__ import annotations

import copy
import logging
import os
import sys
import threading
from pathlib import Path
from typing import Any

# Python 3.11+ 内置 tomllib（只读）；3.10 及以下用 tomli
if sys.version_info >= (3, 11):
    import tomllib
else:
    try:
        import tomli as tomllib  # type: ignore[no-redef]
    except ImportError as e:
        raise ImportError(
            "Python < 3.11 需要安装 tomli：pip install tomli"
        ) from e

try:
    import tomli_w  # 用于写入 toml 文件
except ImportError:
    tomli_w = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)

# 默认配置文件路径
# 打包后（PyInstaller onefile/onedir）用 sys._MEIPASS 定位；
# 开发态用 __file__ 同级目录
def _resolve_defaults_path() -> Path:
    """解析 defaults.toml 的实际路径，兼容打包和开发两种环境。"""
    import sys
    meipass = getattr(sys, "_MEIPASS", None)
    if meipass:
        # PyInstaller 打包环境：datas 解压到 _MEIPASS/spoken/config/
        candidate = Path(meipass) / "spoken" / "config" / "defaults.toml"
        if candidate.exists():
            return candidate
        # 兼容旧 spec 配置，datas 可能直接在 _MEIPASS/config/
        candidate2 = Path(meipass) / "config" / "defaults.toml"
        if candidate2.exists():
            return candidate2
    # 开发态：与本模块同目录
    return Path(__file__).parent / "defaults.toml"

_DEFAULTS_PATH = _resolve_defaults_path()


def _expand_env(value: str) -> str:
    """展开字符串中的环境变量（如 %APPDATA%）。"""
    if sys.platform == "win32":
        return os.path.expandvars(value)
    return value


def _get_default_user_config_path() -> Path:
    """返回标准用户配置文件路径。"""
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA", "")
        if not appdata:
            logger.warning("环境变量 APPDATA 未设置，将使用用户主目录")
            appdata = str(Path.home())
        return Path(appdata) / "Spoken" / "config.toml"

    # 非 Windows 环境（开发用）
    return Path.home() / ".config" / "spoken" / "config.toml"



def _get_project_config_path() -> Path:
    """返回项目根目录下的 config.toml 路径。"""
    return Path(__file__).resolve().parents[1] / "config.toml"



def _get_user_config_path() -> Path:
    """返回用户配置文件路径。

    优先级：
      1. 标准用户配置（Windows: %APPDATA%\\Spoken\\config.toml）
      2. 项目根目录 config.toml（开发态回退）
      3. 标准用户配置目标路径（用于首次写入）
    """
    default_path = _get_default_user_config_path()
    if default_path.exists():
        return default_path

    project_path = _get_project_config_path()
    if project_path.exists():
        logger.info("未找到标准用户配置，回退使用项目配置: %s", project_path)
        return project_path

    return default_path


def _deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    """递归合并两个字典，override 覆盖 base 中的同名键。

    Args:
        base: 基础配置（默认值）
        override: 覆盖配置（用户自定义）

    Returns:
        合并后的新字典（不修改原始对象）
    """
    result = copy.deepcopy(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = copy.deepcopy(value)
    return result


# 敏感配置键（日志中脱敏显示）
_SENSITIVE_KEYS = frozenset({"api_key", "secret", "password", "token"})

# 不允许被用户空值覆盖的敏感字段路径（保护打包后的默认密钥）
# 格式: (section, key) 或 (section, subsection, key)
_PROTECTED_FIELDS: list[tuple[str, ...]] = [
    ("asr", "xunfei", "app_id"),
    ("asr", "xunfei", "api_key"),
    ("asr", "xunfei", "api_secret"),
    ("ai", "api_key"),
]


def _preserve_sensitive_defaults(config: dict[str, Any], defaults: dict[str, Any]) -> None:
    """保护敏感字段：若用户配置提供空值，但默认值有有效值，则恢复默认值。

    这解决了旧版本用户配置文件（空 api_key）覆盖新版本默认值的问题。
    """
    for path in _PROTECTED_FIELDS:
        # 获取默认值
        default_node = defaults
        for key in path:
            if not isinstance(default_node, dict) or key not in default_node:
                break
            default_node = default_node[key]
        else:
            # 默认值存在且非空
            if default_node:
                # 检查用户配置
                user_node = config
                for key in path[:-1]:
                    if not isinstance(user_node, dict) or key not in user_node:
                        break
                    user_node = user_node[key]
                else:
                    last_key = path[-1]
                    if isinstance(user_node, dict) and last_key in user_node:
                        user_value = user_node[last_key]
                        if user_value == "" or user_value is None:
                            user_node[last_key] = copy.deepcopy(default_node)
                            logger.info(
                                "敏感字段保护: %s 用户值为空，恢复默认值",
                                ".".join(path),
                            )


class Settings:
    """配置管理类，提供统一的配置读取接口。

    v2 更新：已移除单例模式，每次 load() 创建独立实例。
    """

    def __init__(self, config: dict[str, Any], user_config_path: Path) -> None:
        self._config = config
        self._user_config_path = user_config_path
        self._config_lock = threading.Lock()
        self._save_timer_lock = threading.Lock()
        self._write_lock = threading.Lock()
        self._pending_save_timer: threading.Timer | None = None

    @classmethod
    def load(cls, user_config_path: Path | None = None) -> "Settings":
        """加载配置并创建新实例。

        Args:
            user_config_path: 自定义用户配置路径，None 则使用默认路径

        Returns:
            新的 Settings 实例

        Raises:
            FileNotFoundError: 默认配置文件缺失
            tomllib.TOMLDecodeError: 配置文件格式错误
        """
        return cls._do_load(user_config_path)

    @classmethod
    def _do_load(cls, user_config_path: Path | None) -> "Settings":
        """实际加载配置逻辑。"""
        # 1. 加载默认配置
        if not _DEFAULTS_PATH.exists():
            raise FileNotFoundError(f"默认配置文件不存在: {_DEFAULTS_PATH}")

        with open(_DEFAULTS_PATH, "rb") as f:
            defaults = tomllib.load(f)
        config = copy.deepcopy(defaults)
        logger.debug("已加载默认配置: %s", _DEFAULTS_PATH)

        # 2. 加载用户配置（覆盖默认值）
        target_path = user_config_path or _get_user_config_path()
        if target_path.exists():
            try:
                with open(target_path, "rb") as f:
                    user_config = tomllib.load(f)
                config = _deep_merge(config, user_config)
                logger.info("已加载用户配置: %s", target_path)
            except Exception as e:
                logger.error("加载用户配置失败，将使用默认值: %s - %s", target_path, e)
        else:
            logger.info("用户配置文件不存在，使用默认配置: %s", target_path)

        # 3. 保护敏感字段：用户配置若提供空值，不覆盖默认值中的有效值
        _preserve_sensitive_defaults(config, defaults)

        # 4. 校验配置合法性
        _validate_config(config)

        return cls(config, target_path)

    @classmethod
    def reset(cls) -> None:
        """兼容旧接口（单例已移除，无实际作用）。"""
        pass

    def get(self, *keys: str, default: Any = None) -> Any:
        """通过点路径获取配置值。

        Args:
            *keys: 配置路径，如 get("asr", "language")
            default: 键不存在时的默认值

        Returns:
            配置值或 default
        """
        node = self._config
        for key in keys:
            if not isinstance(node, dict) or key not in node:
                return default
            node = node[key]
        return node

    def get_section(self, *keys: str) -> dict[str, Any]:
        """获取某个配置章节（返回字典）。

        Args:
            *keys: 章节路径，如 get_section("asr")

        Returns:
            配置字典，不存在则返回空字典
        """
        result = self.get(*keys, default={})
        if not isinstance(result, dict):
            logger.warning("配置路径 %s 不是字典类型", ".".join(keys))
            return {}
        return result

    def ensure_user_config_dir(self) -> Path:
        """确保用户配置目录存在（如果不存在则创建）。

        Returns:
            用户配置目录路径
        """
        config_dir = self._user_config_path.parent
        config_dir.mkdir(parents=True, exist_ok=True)
        return config_dir

    def save_user_config(self, config: dict[str, Any]) -> None:
        """将配置写回用户配置文件。

        Args:
            config: 要保存的配置字典

        Raises:
            RuntimeError: tomli-w 未安装时抛出
        """
        if tomli_w is None:
            raise RuntimeError(
                "写入 TOML 需要安装 tomli-w：pip install tomli-w"
            )
        self.ensure_user_config_dir()
        with self._write_lock:
            with open(self._user_config_path, "wb") as f:
                tomli_w.dump(config, f)
        logger.info("用户配置已保存: %s", self._user_config_path)

    def _set_value(self, *keys: str, value: Any) -> None:
        """更新内存中的配置值（线程安全）。"""
        with self._config_lock:
            node = self._config
            for key in keys[:-1]:
                if key not in node or not isinstance(node[key], dict):
                    node[key] = {}
                node = node[key]
            node[keys[-1]] = value

    def _snapshot_config(self) -> dict[str, Any]:
        """获取当前配置快照，避免异步保存时写出半更新状态。"""
        with self._config_lock:
            return copy.deepcopy(self._config)

    def _schedule_async_save(self, delay_sec: float = 0.15) -> None:
        """延迟异步保存，合并短时间内的连续配置修改。"""
        with self._save_timer_lock:
            if self._pending_save_timer is not None:
                self._pending_save_timer.cancel()

            timer: threading.Timer

            def _delayed_save() -> None:
                snapshot = self._snapshot_config()
                try:
                    self.save_user_config(snapshot)
                finally:
                    with self._save_timer_lock:
                        if self._pending_save_timer is timer:
                            self._pending_save_timer = None

            timer = threading.Timer(delay_sec, _delayed_save)
            timer.daemon = True
            timer.name = "spoken-settings-save"
            self._pending_save_timer = timer
            timer.start()

    def set_and_save(self, *keys: str, value: Any) -> None:
        """设置某个配置项并同步保存到用户配置文件。"""
        self._set_value(*keys, value=value)
        self.save_user_config(self._snapshot_config())

    def set_and_save_async(self, *keys: str, value: Any) -> None:
        """设置某个配置项并异步保存，适合热键触发等低延迟场景。"""
        self._set_value(*keys, value=value)
        self._schedule_async_save()

    @property
    def user_config_path(self) -> Path:
        """返回用户配置文件路径。"""
        return self._user_config_path

    def __repr__(self) -> str:
        return f"Settings(user_config={self._user_config_path})"


# ══════════════════════════════════════════════════════════════════════
# 配置校验与脱敏工具
# ══════════════════════════════════════════════════════════════════════

# 已知的合法配置节及类型约束
_CONFIG_SCHEMA: dict[str, dict[str, tuple[type, ...]]] = {
    "asr": {
        "mode":          (str,),
        "language":      (str,),
        "realtime_provider": (str,),
    },
    "ai": {
        "enabled":       (bool,),
        "base_url":      (str,),
        "timeout_sec":   (int, float),
    },
    "mode": {
        "default":       (str,),
    },
    "hotkey": {
        "toggle_record": (str,),
        "record_mode":   (str,),
        "switch_mode":   (str,),
        "interrupt":     (str,),
    },
    "injection": {
        "method":        (str,),
        "focus_delay_ms": (int,),
        "char_delay_ms": (int,),
        "batch_size":    (int,),
        "batch_delay_ms": (int,),
        "target_window": (str,),
    },
}


def _validate_config(config: dict[str, Any]) -> None:
    """校验配置合法性，发现问题时记录警告但不阻止启动。

    Args:
        config: 合并后的完整配置字典
    """
    # 校验 mode.default
    mode_default = config.get("mode", {}).get("default", "A")
    if mode_default not in ("A", "B", "C", "D", "E", "F"):
        logger.warning("配置校验: mode.default=%r 无效，应为 A-F，将使用默认值 A", mode_default)
        config.setdefault("mode", {})["default"] = "A"

    # 校验 asr.mode（仅支持 realtime）
    asr_mode = config.get("asr", {}).get("mode", "realtime")
    if asr_mode not in ("realtime",):
        logger.warning("配置校验: asr.mode=%r 无效，仅支持 realtime，将使用默认值 realtime", asr_mode)
        config.setdefault("asr", {})["mode"] = "realtime"

    # 校验 injection.method
    inj_method = config.get("injection", {}).get("method", "auto")
    if inj_method not in ("auto", "sendinput", "clipboard"):
        logger.warning("配置校验: injection.method=%r 无效，应为 auto/sendinput/clipboard", inj_method)
        config.setdefault("injection", {})["method"] = "auto"

    target_window = str(config.get("injection", {}).get("target_window", "smart")).strip().lower()
    if target_window not in ("locked_on_start", "current", "smart"):
        logger.warning(
            "配置校验: injection.target_window=%r 无效，应为 locked_on_start/current/smart，将使用默认值 smart",
            config.get("injection", {}).get("target_window"),
        )
        config.setdefault("injection", {})["target_window"] = "smart"

    # 校验 asr.realtime_provider
    asr_provider = str(config.get("asr", {}).get("realtime_provider", "windows")).strip().lower()
    if asr_provider not in ("windows", "xunfei", "meituan"):
        logger.warning(
            "配置校验: asr.realtime_provider=%r 无效，应为 windows/xunfei/meituan，将使用默认值 windows",
            config.get("asr", {}).get("realtime_provider"),
        )
        config.setdefault("asr", {})["realtime_provider"] = "windows"

    windows_cfg = config.get("asr", {}).get("windows", {})
    if isinstance(windows_cfg, dict):
        language_tag = windows_cfg.get("language_tag", "")
        if language_tag is not None and not isinstance(language_tag, str):
            logger.warning("配置校验: asr.windows.language_tag=%r 无效，应为 str", language_tag)

        for float_key, default_value in (
            ("initial_silence_timeout_sec", 5.0),
            ("end_silence_timeout_sec", 0.8),
            ("auto_stop_silence_sec", 60.0),
        ):
            value = windows_cfg.get(float_key, default_value)
            try:
                if float(value) <= 0:
                    raise ValueError
            except Exception:
                logger.warning("配置校验: asr.windows.%s=%r 无效，应为正数", float_key, value)
                config.setdefault("asr", {}).setdefault("windows", {})[float_key] = default_value

    # 校验 asr.hybrid 配置
    hybrid_cfg = config.get("asr", {}).get("hybrid", {})
    if isinstance(hybrid_cfg, dict):
        hybrid_long_form = hybrid_cfg.get("long_form_sec", 10)
        try:
            if float(hybrid_long_form) <= 0:
                raise ValueError
        except Exception:
            logger.warning("配置校验: asr.hybrid.long_form_sec=%r 无效，应为正数", hybrid_long_form)
            config.setdefault("asr", {}).setdefault("hybrid", {})["long_form_sec"] = 10

    # 校验 hotkey.record_mode
    record_mode = str(config.get("hotkey", {}).get("record_mode", "push_to_talk")).strip().lower()
    if record_mode not in ("push_to_talk", "push", "hold", "ptt", "toggle"):
        logger.warning("配置校验: hotkey.record_mode=%r 无效，应为 push_to_talk/toggle", record_mode)
        config.setdefault("hotkey", {})["record_mode"] = "push_to_talk"

    # 校验类型约束
    for section, fields in _CONFIG_SCHEMA.items():
        section_data = config.get(section, {})
        if not isinstance(section_data, dict):
            logger.warning("配置校验: [%s] 应为字典类型，实际为 %s", section, type(section_data).__name__)
            continue
        for key, expected_types in fields.items():
            if key in section_data:
                value = section_data[key]
                if not isinstance(value, expected_types):
                    logger.warning(
                        "配置校验: [%s].%s 期望类型 %s，实际为 %s (%r)",
                        section, key,
                        "/".join(t.__name__ for t in expected_types),
                        type(value).__name__, value,
                    )

    logger.debug("配置校验完成")


def mask_sensitive(config: dict[str, Any]) -> dict[str, Any]:
    """返回配置的脱敏副本（敏感字段用 *** 替换）。

    用于日志输出等场景，防止 API Key 等敏感信息泄露。

    Args:
        config: 原始配置字典

    Returns:
        脱敏后的配置字典（深拷贝）
    """
    result = copy.deepcopy(config)
    _mask_recursive(result)
    return result


def _mask_recursive(d: dict[str, Any]) -> None:
    """递归脱敏字典中的敏感字段。"""
    for key, value in d.items():
        if isinstance(value, dict):
            _mask_recursive(value)
        elif key in _SENSITIVE_KEYS and isinstance(value, str) and value:
            d[key] = value[:4] + "***" + value[-4:] if len(value) > 12 else "***"
