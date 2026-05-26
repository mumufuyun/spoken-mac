# -*- mode: python ; coding: utf-8 -*-
"""
Spoken PyInstaller 打包配置

用法:
    pyinstaller spoken.spec --clean

输出:
    dist/Spoken/          单目录打包产物
    dist/Spoken/Spoken.exe 启动入口

注意:
    - 本配置使用单目录模式（onedir），启动速度优于单文件模式
    - 首次打包会自动下载 pywebview 所需的 WebView2 Runtime（若系统未安装）
    - 入口使用 run.py 而非 __main__.py，避免打包后相对导入失效
    - 发布版无控制台窗口，日志写入 %APPDATA%\Spoken\spoken.log
"""

from PyInstaller.building.build_main import Analysis, PYZ, EXE, COLLECT
import os

# 项目根目录（ spoken.spec 的父目录）
project_root = os.path.dirname(os.path.abspath(SPECPATH))

# 数据文件：配置、提示音、图标等
datas = [
    # 默认配置文件（打包后位于 _MEIPASS/spoken/config/defaults.toml）
    (os.path.join(project_root, "config", "defaults.toml"), "spoken/config"),
]

# 隐藏导入：动态导入的模块
hiddenimports = [
    "pystray._win32",
    "pywebview",
    "webview",
    "openai",
    "keyboard",
    "PIL",
    "PIL.Image",
    "PIL.ImageDraw",
    "PIL.ImageFont",
    "pyaudio",
    "sounddevice",
    "winsdk",
    "tomli",
    "tomli_w",
    "websockets",
    "httpx",
    "jiter",
    "distro",
    # Windows 特定
    "ctypes",
    "ctypes.wintypes",
    "clr",
    "pythonnet",
    "webview.http",
    "webview.util",
    "webview.screen",
    "webview.window",
    "webview.menu",
    "webview.localization",
    # 项目内部模块（防止打包时遗漏）
    "spoken.config.settings",
    "spoken.config.defaults",
    "spoken.asr.engine",
    "spoken.asr.windows_speech",
    "spoken.asr.xunfei_realtime",
    "spoken.audio.capture",
    "spoken.audio.devices",
    "spoken.injector.base",
    "spoken.injector.clipboard",
    "spoken.injector.dispatcher",
    "spoken.injector.ime",
    "spoken.injector.sendinput",
    "spoken.ai.processor",
    "spoken.ai.prompts",
    "spoken.hotkey.manager",
    "spoken.overlay.window",
    "spoken.tray.icon",
    "spoken.utils.logger",
    "spoken.utils.window",
    "spoken.pipeline",
    "spoken.state",
    "spoken.core.errors",
    "spoken.core.events",
    "spoken.core.executor",
    "spoken.core.lifecycle",
    "spoken.core.state_machine",
    "spoken.ai.client",
    "spoken.ai.strategies",
    "spoken.asr.manager",
    "spoken.injector.registry",
    "spoken.overlay.diagnose",
]

# 排除：测试文件、开发工具、过大的调试符号
excludes = [
    "pytest",
    "_pytest",
    "pytest_cache",
    "mypy",
    "pylint",
    "black",
    "unittest",
    "tkinter.test",
    "matplotlib",
    "numpy.random._examples",
]

a = Analysis(
    [os.path.join(project_root, "run.py")],
    pathex=[project_root],
    binaries=[],
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=excludes,
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data)

# 图标文件路径（spec 文件同级目录）
icon_path = os.path.join(os.path.abspath(SPECPATH), "spoken.ico")

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,  # onedir 模式：binaries/datas 由 COLLECT 单独放
    name="Spoken",
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    upx_exclude=[],
    console=False,  # 发布版无控制台窗口，日志写入文件
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=icon_path if os.path.exists(icon_path) else None,
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name="Spoken",  # 输出目录：dist/Spoken/
)
