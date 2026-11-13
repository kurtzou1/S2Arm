# 下载页（GitHub Pages）

给不用 GitHub 的玩家一个直接下载启动器的页面：<https://jhaizhou-ops.github.io/S2Arm/>。

## 怎么工作

- 页面只有一个文件 [index.html](index.html)，样式和脚本都内联，不引外部资源。
- 两个下载按钮直接指向 `releases/latest/download/<产物名>`，GitHub 自动跳到最新正式版的同名文件。**发版时 Mac / Windows 产物名必须保持 `S2Arm-mac-arm64.dmg`、`S2Arm-windows-x64.zip` 不变**，否则按钮会 404；改名要同步改 `index.html`。Windows 安装程序 `S2Arm-windows-x64-setup.exe`（v0.3.0 起）：页面脚本看最新正式版里有它，就把 Windows 主按钮换成它、压缩包降为「便携版」链接；没有就照旧给压缩包（所以页面可以先于带安装程序的版本发布）。
- `releases/latest` 只认正式版：标成「预发布」的版本不会出现在按钮上。
- 页面脚本调用一次 `api.github.com/repos/jhaizhou-ops/S2Arm/releases/latest`，补上版本号、发布日期、文件大小和 SHA-256。页顶的「点个星」链接到仓库主页（GitHub 不支持站外一键点星，要在仓库页点 Star），脚本再调一次 `api.github.com/repos/jhaizhou-ops/S2Arm` 显示当前 Star 数。接口不通（未登录用户每个 IP 每小时 60 次）时只少这几行字和数字，按钮照常可用；关掉脚本也能下载。
- 发版不用重新发布页面：按钮和版本信息都是访问时现取的。

## 启动器公告（notice.json）

Mac / Windows 启动器读 [notice.json](notice.json)：启动时从 <https://jhaizhou-ops.github.io/S2Arm/notice.json> 取（取不到用发版时打进包里的同一份，再没有就不显示，不报错）。
判定在 `pack/jobs/updater.py inbox`，两端共用：**永远只给玩家看最新一期**——顶部横幅只放最新一条没看过的「重要」公告，更旧的不补弹、不叠加；
所有公告都列在启动器的「消息」里，只有最新那条没看过时算未读。玩家关掉横幅或打开「消息」= 看过最新那条和它之前的全部。

```json
{"schema": 1,
 "id": "给旧版启动器看的那条", "text": {"zh-Hans": "…", "en": "…"}, "url": "https://s2arm.com/…",
 "messages": [
   {"id": "2026-11-13-a", "level": "important", "platforms": ["windows"], "text": {"zh-Hans": "…", "en": "…"}, "url": "https://…"},
   {"id": "2026-11-10-b", "level": "info", "text": {"zh-Hans": "…", "en": "…"}}
 ]}
```

- `messages` 按**最新在前**排；发新公告就在最前面插一条，**换一个新的 `id`**。合进 `main` 后 Pages 自动发布，已发出的启动器下次启动就显示，不用发版。
- `level`：`important` 出横幅（只看最新那条重要的），其余只进「消息」。`platforms` 不写 = 全平台；写了只给列着的（`mac` / `windows`）。
- 顶层 `id` / `text` / `url` 给 v0.3.4 之前的启动器看（它们不认 `messages`、也不分平台）：只放全平台都要看的最要紧那一条，没有就不写。
  新版启动器有 `messages` 时不看顶层；没有 `messages` 时把顶层当一条全平台「重要」公告。
- 撤掉全部公告：把文件改成 `{"schema": 1}`。
- `url` 可选：「详情」打开的链接，只认 `https` 的 github.com / jhaizhou-ops.github.io / s2arm.com。纯文本，不支持格式。

## 更新说明（签名清单里的 notes）

启动器打开时的「有新版」弹窗和更新后第一次打开的「这版更新了什么」，读签名清单（`update-manifest.json` / 官网 `latest.json`）里的 `notes`，
由 `tools/sign_update_manifest.py --notes notes/vX.Y.Z.md` 从发版说明解析后一起签名：「## 小节」→ 弹窗里的分组，每条取加粗那句、下一行斜体当英文；
「## 亮点」一节只用于「这版更新了什么」，**没写亮点就不弹它**（程序不替人挑）。同样只给最新一期：跳过的版本不补弹，看过关掉的不再弹。

## 发布

[.github/workflows/pages.yml](../../.github/workflows/pages.yml) 在 `main` 上本目录或用到的图片有改动时，把 `index.html` 和三张图（`docs/images/` 的标志、Mac / Windows 启动器截图，`launchers/macos/Branding/AppIcon-1024.png` 作图标）拷进 `_site/` 发布，不构建、不下载依赖。也可以在 Actions 页手动运行。

首次启用需要仓库管理员做一次：Settings → Pages → Build and deployment → Source 选 **GitHub Actions**；然后在 Actions 页手动运行一次 Pages 工作流。

## 本地预览

```sh
mkdir -p build/site/images
cp docs/site/index.html build/site/
cp docs/images/s2arm-wordmark-transparent.png docs/images/launcher-welcome.png docs/images/launcher-windows.png build/site/images/
cp launchers/macos/Branding/AppIcon-1024.png build/site/images/icon.png
python3 -m http.server -d build/site 8000
```

## 预览

[preview/](preview/) 里是本地用 Chromium 截的整页图，只供审阅和文档引用，不会发布到 Pages：

| Mac（中文） | Windows（英文） | iPhone |
|---|---|---|
| ![Mac 中文](preview/desktop-mac-zh.jpg) | ![Windows 英文](preview/desktop-windows-en.jpg) | ![iPhone](preview/mobile-iphone.jpg) |
