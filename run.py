#!/usr/bin/env python3
"""Spoken 打包入口文件。

PyInstaller 需要顶层脚本作为入口，此文件仅做简单的导入转发。
"""

from spoken.__main__ import main

if __name__ == "__main__":
    main()
