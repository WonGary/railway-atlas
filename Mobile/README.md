# 手机测试版

Android 8 及以上使用 `Railway-Atlas-0.8.3-Android.apk`。在系统文件管理器点开 APK，按提示允许这次安装。以后使用同一签名的新版本可以覆盖升级。地图、六城线路资料和站区细节随包提供，在线底图和地图问答需要网络。

## iPhone 和 iPad

`Railway-Atlas-0.8.3-iOS-xcarchive.zip` 里是原生 SwiftUI / MapKit 应用的真机归档，最低支持 iOS / iPadOS 17。归档使用临时签名。发给朋友时，请分享 App Store Connect 生成的 TestFlight 邀请。

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
python3 Mobile/sign-android.py /path/to/apksigner.jar app-release-unsigned.apk Railway-Atlas-0.8.3-Android.apk --key-dir /path/to/private-signing-directory
```
