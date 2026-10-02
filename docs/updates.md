# 客户端更新

2.4.0 起接入 Sparkle 2.10.0。启动时及运行期间每 6 小时检查更新；用户确认后下载、安装并重启。菜单栏提供「检查更新」，设置中的「软件更新」可关闭自动检查。自动检查偏好由 Sparkle 保存，不在每次启动时重置。

发现新版时菜单栏显示 ↑。录音、识别、AI 处理和文字输入期间不主动展示更新窗口；安装准备完成后若仍有任务，会等到空闲再继续。安装开始后不接受新的录音快捷键。用户设置、模式文件和模型凭据不属于安装包，不随应用替换而删除。

2.3.1 及更早版本没有更新组件，必须先手动安装一次 2.4.0。

## 发布新版

客户端与网站分属两个仓库。网站继续通过现有 Cloudflare Pages Git 集成发布，无需新增后端。

1. 修改 Xcode 项目的版本和构建号，新增 `docs/releases/<版本>.json`，填写 `title` 和 `notes`。
2. 运行 `bash scripts/build_local_app.sh` 和 `bash scripts/package_dmg.sh`。
3. 同步安装包、更新信息与网站版本：

   ```sh
   python3 scripts/prepare_website_release.py \
     --website /path/to/spoken-web-v2 \
     --installer build/Spoken-2.4.0-arm64.dmg \
     --notes docs/releases/2.4.0.json
   ```

4. 在网站仓库核对更新说明、安装说明与截图，运行测试和生产构建，再按原流程发布。安装包和 `updates/appcast.xml` 必须在同一次部署中上线。
5. 从生产地址下载安装包与更新信息，核对文件哈希、签名及版本；用旧版隔离客户端检查更新。

发布脚本不自动推送或部署。它验证镜像内应用的签名、标识、版本、更新地址和公钥，使用 Sparkle 官方工具生成并验证签名，再写入网站文件。它拒绝回退构建号、同构建号不同内容、覆盖已有版本下载地址。仅替换网页中的 DMG 不会产生客户端更新提醒。

固定更新地址：`https://spoken-web-v2.pages.dev/updates/appcast.xml`。网站上的 `public/updates/release.json` 是网页版本与更新说明的数据源。该目录要求重新验证缓存，旧安装包地址保留。

## 签名与构建

- Sparkle 版本及下载 SHA-256 固定在 `scripts/prepare_sparkle.sh`；Xcode 使用同版本的 Swift Package Manager 依赖。
- 更新归档与更新信息均使用 Ed25519 签名，客户端在解压前校验归档。公钥在 `Spoken/Info.plist`；私钥保存在登录钥匙串，账户名为 `com.moss.spoken.updates`，不放入仓库或网站。
- 发布时需解锁 Mac，并允许官方 Sparkle 签名工具访问对应密钥。迁移发布机器前按 Sparkle 文档单独备份并安全导入密钥；不要重新生成公钥后直接替换已分发客户端的信任关系。
- 本地构建仍采用 ad-hoc 签名，没有 Apple Developer ID 签名和公证。Sparkle 更新签名不能代替 Apple 公证；首次安装与辅助功能授权仍按现有说明处理。
- 本机仅安装 Command Line Tools。已验证该构建路径；完整 Xcode Archive / Developer ID 发布需在具备对应环境的机器验证。

## 验证

```sh
bash scripts/run_offline_ai_tests.sh
python3 scripts/test_updates.py
```

更新集成测试使用随机应用标识、一次性签名密钥、localhost 和临时应用，不启动真实 Spoken、不访问用户配置或模型。它编译实际 `AppUpdateService`，验证发现新版、下载、忙碌时延后、替换应用、重新启动，以及拒绝被篡改的归档和更新信息、无更新和请求失败。

官方依据：[集成与签名](https://sparkle-project.org/documentation/)、[发布更新](https://sparkle-project.org/documentation/publishing/)、[后台应用提醒](https://sparkle-project.org/documentation/gentle-reminders/)。
