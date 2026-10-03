# Spoken 发布签名

目标：后续版本保持同一应用标识和开发者团队身份，减少更新后重新请求系统权限和钥匙串访问授权。

## 当前状态

2026-10-03 已发布的 2.4.5（245.2）仍为临时本地签名。本机无可用应用签名证书，维护者尚未开通 Apple Developer Program。正式签名入口已准备；尚未产生 Developer ID 签名安装包，也未验证跨版本权限继承。

## 配置证书

1. 开通 Apple Developer Program 后，由账号持有人创建 **Developer ID Application** 证书。不是 Apple Development，也不是 Developer ID Installer。
2. 在这台 Mac 创建证书请求，将证书和对应私钥保存在钥匙串。若导入已有证书，必须包含匹配的私钥。
3. 用 `security find-identity -v -p codesigning` 查看证书指纹。固定开发者 Team ID 和证书 SHA-1；证书续期时显式修改指纹，保持 Team ID 和应用标识不变。

不要将私钥、证书导出包或钥匙串密码写入仓库。签名工具直接使用本机钥匙串。

## 构建和打包

```bash
export SPOKEN_SIGNING_IDENTITY='证书的 40 位 SHA-1 指纹'
export SPOKEN_TEAM_ID='10 位 Team ID'
python3 scripts/sign_release_app.py --check
bash scripts/build_release_app.sh
bash scripts/package_dmg.sh --release
```

入口在编译前检查证书类型、私钥可用性和所属团队，缺失或不匹配则停止。主应用和 Sparkle 的框架、辅助程序、XPC 服务由内到外签名，使用 Hardened Runtime 和安全时间戳；不通过关闭库验证来绕过身份检查。

产物位于 `build/release/`。包内各组件必须通过 Apple Developer ID 证书链、固定团队、完整性和稳定身份检查。`prepare_website_release.py` 在生成更新订阅和修改网页文件前再次执行同样检查，拒绝临时签名包。

签名不等于公证：这些命令不会提交 Apple 公证，不会自动安装、上传 GitHub 或部署网站。正式分发前仍应单独完成公证。已发布的下载 URL 和安装包不得覆盖；首次切换正式签名时使用新版本、新构建号。

## 验收

签名工具的离线校验：`python3 -m unittest discover -s scripts -p 'test_release_signing.py'`。它验证证书选择、拒绝临时签名和构建前停止，不读取模型密钥或修改用户授权。

取得证书后还必须完成真实验收：

1. 签名并构建两个不同构建号，检查二者的应用标识、团队及 designated requirement 一致。
2. 在隔离测试账号中，对第一个版本授权麦克风、辅助功能和测试钥匙串项目。
3. 通过 Sparkle 更新至第二个版本，验证启动、录音、自动输入及测试密钥读取不重复授权。
4. 从现有临时签名版本首次迁移时，允许用户重新授权一次；不重置系统权限数据库，不放宽钥匙串访问控制，也不迁移为明文密钥。

## 官方依据

- [Apple：应用签名身份与权限](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
- [Apple：创建 Developer ID 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Sparkle：手动签名组件](https://sparkle-project.org/documentation/sandboxing/#code-signing)
