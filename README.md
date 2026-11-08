# Fm黄果 · iOS 短剧播放器

「Fm黄果」是一个原生 iOS 短剧播放器（SwiftUI + AVPlayer），数据来自黄果短剧公开站点。

> ⚠️ 本项目仅供个人学习研究。应用内所有视频内容均来自互联网公开网站，与本应用无关，请支持正版。内容仅面向年满 18 周岁的成年用户。

## 功能

- **智能线路**：启动时自动从 hgai2.com 读取三条线路、从 huangguoai.pages.dev 读取最新地址，并发测速，自动进入最快线路；全部失败时回退永久域名。原生直连站点 API，无需网页 18+ 确认。
- **浏览与搜索**：分类（AI短剧 / AI漫剧 / AI换脸 / AI魔改 / 吃瓜）、排序（最新 / 最热 / 随机）、无限滚动、关键词搜索（走站点 `/api/search` 接口）、搜索历史。
- **内置播放器**：AVPlayer 自定义控制层——倍速（0.75~2x）、选集、亮度/音量手势、左右滑快进、双击切换填充、横竖屏、自动连播。
- **进度记忆**：每 5 秒落盘播放进度，下次从断点继续；历史播放记录、收藏、清空历史。
- **系统要求**：iOS 15.4+

## 构建

项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
brew install xcodegen
xcodegen generate
open FmHuangguo.xcodeproj
```

GitHub Actions（`.github/workflows/build.yml`）在 push 到 `main` 时自动构建**免签名 ipa**（arm64），上传 artifact 并发布到 Release `latest`。

安装：使用 Sideloadly / AltStore / 爱思助手等工具对 ipa 自签后安装。

## 目录结构

```
FmHuangguo/
├── project.yml                    # XcodeGen 工程定义（iOS 15.4）
├── .github/workflows/build.yml    # CI 构建 ipa + Release
└── FmHuangguo/
    ├── App/                       # 入口、TabView、AppState 线路选择
    ├── Services/
    │   ├── RouteService.swift     # 线路发现（hgai2 + pages.dev）与测速
    │   └── SiteAPI.swift          # 站点 API（列表/搜索/详情/播放）
    ├── Models/                    # 数据模型与本地收藏/历史存储
    └── Views/                     # 首页/搜索/详情/播放器/历史/收藏/设置
```
