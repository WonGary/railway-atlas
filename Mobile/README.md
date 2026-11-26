# 手机测试版

Android 8.0 及以上可安装 [铁道漫游 0.8.17（APK）](https://github.com/WonGary/railway-atlas/releases/download/web-v0.8.17/Railway-Atlas-0.8.17-Android.apk)。下载后在文件管理器中打开，按系统提示安装。已安装本仓库签名版的用户可直接点「更新」。随包城市可在首次打开时离线查看，在线底图和地图问答需要网络。[版本说明和 SHA-256 校验值](https://github.com/WonGary/railway-atlas/releases/tag/web-v0.8.17)

## iPhone 和 iPad

在发布页下载 `.ipa`，用 SideStore 或 iLoader 以自己的 Apple 账户重新签名安装。iPhone 和 iPad 共用这个包，最低支持 iOS / iPadOS 17。覆盖更新时保留旧应用，并沿用原来的账号和应用标识。另附的 `iOS-xcarchive.zip` 是真机归档，供开发者重新导出。通过 TestFlight 分发需另行使用发行证书签名并上传 App Store Connect。

**用自己的个人开发者团队导出 IPA**　下面的步骤在 GitHub 的 Mac 上完成编译。自己的 Mac 只需要用 Transporter 上传。

1. 用已加入 Apple Developer Program 的个人账号，在 Apple Developer 中注册明确的 App ID。工程默认的 Bundle ID 是 `app.railwayatlas.ios`。如果你已注册了另一个 ID，使用自己的。到 App Store Connect 创建 App 并选相同的 ID。
2. 准备带私钥的 Apple Distribution `.p12`、导出时设置的密码，以及这个 App ID 和证书对应的 **App Store Connect** `.mobileprovision`。保存到自己的安全位置。
3. 在仓库的 **Settings → Secrets and variables → Actions** 新增三个仓库密钥。`IOS_DIST_P12_BASE64` 填 `.p12` 的 Base64，`IOS_DIST_P12_PASSWORD` 填密码，`IOS_PROFILE_BASE64` 填描述文件的 Base64。在 Mac 上用 `base64 -i 文件名 | pbcopy` 可直接复制到剪贴板。签名材料只填在 Secrets 页面。
4. 到 **Actions → Export a signed TestFlight IPA → Run workflow**，选 `main`，输入比同版已上传构建更大的正整数。此流程从所选描述文件读取团队和 Bundle ID，编译、签名并导出。完成后下载 `signed-TestFlight-IPA`，解压取出 `.ipa`。
5. 在 Mac 上用 Transporter 登录，选择 `.ipa` 并交付。苹果处理完成后，在 App Store Connect 的 TestFlight 页面添加测试人员。首次邀请外部测试者时，提交该构建进行 Beta 审核。

如果签名资料已经在装有 Xcode 的 Mac 上，也可直接打开仓库的 `RailwayAtlas.xcodeproj`，选择 `RailwayAtlas-iOS`，在 Signing & Capabilities 选自己的 Team 和 Bundle ID，设置发行版本与构建号，选择真机目标后点 Product → Archive → Distribute App → App Store Connect。

[苹果分发描述文件说明](https://developer.apple.com/help/account/provisioning-profiles/create-an-app-store-provisioning-profile/) · [上传构建](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/) · [TestFlight](https://developer.apple.com/testflight/)

## Android 构建

GitHub Actions 的 **Build the Android APK** 使用 Java 17、Android SDK 35、Gradle 8.11.1。下载 `android-unsigned` 后，用 Android Build Tools 中的 `apksigner.jar` 和本机专用签名目录执行以下命令。首次运行创建测试签名，以后复用同一目录。备份该目录，后续覆盖安装需要原密钥。

```sh
python3 Mobile/sign-android.py /path/to/apksigner.jar app-release-unsigned.apk "Railway-Atlas-$(cat Mobile/VERSION)-Android.apk" --key-dir /path/to/private-signing-directory
```
