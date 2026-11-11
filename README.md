<div align="center">

# Fm黄果 · iOS 短剧播放器

**原生 SwiftUI + AVPlayer 打造的黄果短剧客户端**

[![Build](https://img.shields.io/github/actions/workflow/status/Fourth-Master/FmHuangguo/build.yml?branch=main&label=CI%20%E6%9E%84%E5%BB%BA&logo=github)](https://github.com/Fourth-Master/FmHuangguo/actions/workflows/build.yml)
[![Release](https://img.shields.io/github/v/release/Fourth-Master/FmHuangguo?include_prereleases&label=%E6%9C%80%E6%96%B0%E7%89%88)](https://github.com/Fourth-Master/FmHuangguo/releases/latest)
[![Platform](https://img.shields.io/badge/iOS-15.4%2B-blue?logo=ios&logoColor=white)](#构建)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-orange?logo=swift&logoColor=white)](#构建)
[![License](https://img.shields.io/badge/%E7%94%A8%E9%80%94-%E4%BB%85%E9%99%90%E5%AD%A6%E4%B9%A0-red)](#免责声明)

</div>

---

## ✨ 功能特性

### 🛣 智能线路
- 启动时自动从 hgai2.com 读取三条线路、从 huangguoai.pages.dev 读取最新地址，**并发测速自动选最快**
- **秒启动**：当天缓存最快线路，二次启动轻量探活（~300ms）直接进入，失效自动回退完整测速
- 原生直连站点 API，**无需网页 18+ 确认**

### 🎬 内置播放器
- 自定义控制层：进度条（点击即跳 + 拖动 seek）、上/下集、选集面板、自动连播、横竖屏
- **手势全部可自定义**（设置页映射）：双击暂停/填充切换、长按倍速、长按上下滑调倍速（0.5x ~ 3x）
- 亮度 / 音量滑动手势、左右滑动快进、HUD 提示
- 适配 **AES-128 加密 HLS 流**，播放取址走站点最新 `playback` 接口

### 📖 浏览与搜索
- 分类浏览（AI短剧 / AI漫剧 / AI换脸 / AI魔改 / 吃瓜），最新 / 最热 / 随机排序，无限滚动
- 关键词搜索 + 搜索历史，首页 🔥 热门标签直达搜索
- 封面图走站点 **crypto-image 加密协议**，App 内解密 + 内存 / 磁盘双缓存

### 📚 追剧管理
- **进度记忆**：每 5 秒落盘，下次从断点继续
- 历史记录 / 收藏，**每日更新检测**（历史红字 / 收藏 NEW 标记）
- **离线缓存**：一键下载当前集 HLS 分片，完全离线播放，缓存管理页统一清理

### 🔧 其他
- 设置页内置调试日志（查看 / 分享 / 清空），版本更新自动清空旧日志
- 版本更新检测

## 📲 安装

1. 前往 [Releases `latest`](https://github.com/Fourth-Master/FmHuangguo/releases/tag/latest) 下载 `FmHuangguo-x.x.x.ipa`
2. 使用 Sideloadly / AltStore / 爱思助手等工具对 ipa 自签后安装到设备

> ipa 为**免签名构建**（CI 自动产出），需自行签名后安装。

## 🔨 构建

项目使用 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 管理工程：

```bash
brew install xcodegen
xcodegen generate
open FmHuangguo.xcodeproj
```

[GitHub Actions](.github/workflows/build.yml) 在 push 到 `main` 时自动构建**免签名 ipa**（arm64，`CODE_SIGNING_ALLOWED=NO`），上传 artifact 并发布到 Release `latest`。

## 📂 目录结构

```
FmHuangguo/
├── project.yml                      # XcodeGen 工程定义（iOS 15.4）
├── .github/workflows/build.yml      # CI 构建 ipa + 发布 Release
└── FmHuangguo/
    ├── App/
    │   ├── FmHuangguoApp.swift      # 入口
    │   └── AppState.swift           # 全局状态与线路路由（测速缓存）
    ├── Services/
    │   ├── RouteService.swift       # 线路发现（hgai2 + pages.dev）与并发测速
    │   ├── SiteAPI.swift            # 站点 API（列表/搜索/详情/playback 取址）
    │   ├── CryptoImageLoader.swift  # 封面图解密 + 双级缓存
    │   ├── VideoCacheManager.swift  # 离线缓存（HLS 分片 + key 下载、m3u8 改写）
    │   ├── UpdateChecker.swift      # 每日更新检测
    │   ├── GesturePrefs.swift       # 手势自定义映射（UserDefaults）
    │   └── DebugLogger.swift        # 调试日志
    ├── Models/
    │   ├── Models.swift             # 数据模型
    │   └── Library.swift            # 收藏 / 历史 / 进度本地存储
    └── Views/
        ├── RouteSplashView.swift    # 启动测速页
        ├── HomeView.swift           # 首页（热门标签 + 分类）
        ├── SearchView.swift         # 搜索
        ├── DramaDetailView.swift    # 剧集详情
        ├── PlayerView.swift         # 自定义播放器
        ├── DownloadsView.swift      # 离线缓存管理
        ├── LibraryViews.swift       # 历史 / 收藏
        ├── SettingsView.swift       # 设置（手势映射 / 日志 / 测速）
        └── Common.swift             # 公共组件
```

## ⚠️ 免责声明

本项目仅供**个人学习研究**使用。应用内所有视频内容均来自互联网公开网站，与本应用无关，请支持正版。内容仅面向年满 18 周岁的成年用户。
