# Chrome 标签页 · Pock 组件

在 MacBook 的 Touch Bar 上显示 Google Chrome 的标签页列表，点击即可切换。

基于 [Pock](https://github.com/pock/pock)（Touch Bar 组件管理器）。

---

## 效果

- **聚焦 Chrome 时**：触控栏变成「‹ 返回 + 标签页列表」，当前标签高亮
- **点击某个标签**：Chrome 立即切换到该标签
- **切到其他应用**：自动回到一级菜单
- **非 Chrome 时**：显示一个 Chrome 图标占位

## 前置条件

- macOS 11+，带 Touch Bar 的 Mac
- [Pock](https://pock.app) 0.9.0
- Google Chrome
- **给 Pock 授予「辅助功能」权限**
  （系统设置 → 隐私与安全性 → 辅助功能 → 找到 Pock 并勾选）

## 安装

本项目不提交编译产物，需要先构建。

```bash
# 构建并安装到 Pock
./build.sh --install

# 只构建，不安装
./build.sh
```

构建只需 **Command Line Tools**（`xcode-select --install`），**不需要 Xcode / CocoaPods / ibtool**。首次构建会从 GitHub 拉取 PockKit 0.2.0 + SnapKit 并编译，约半分钟。

安装后重启 Pock：

```bash
pkill -x Pock; open -a /Applications/Pock.app
```

## 使用

1. 点菜单栏的 Pock 图标 → **自定义 Pock…**
2. 把「**Chrome 标签页**」拖到触控栏
3. 聚焦 Chrome，即显示标签列表；点标签切换

## 工作方式

通过 macOS **Accessibility API（AX）** 读取 Chrome「标签页」菜单里的标签项，点击时对对应菜单项发送 `AXPress`。

- 不依赖 AppleScript（规避 TCC 自动化权限的 `-1743` 问题）
- 不联网、不写文件、不持久化数据
- **只在聚焦 Chrome 时读取一次**；点击标签立即乐观高亮，不做定时轮询

## 权限与隐私说明

- 需要 Pock 的「辅助功能」权限（用于读取 Chrome 的 AX 菜单）
- 只读 Chrome 的「标签页」菜单，不读取其他应用内容
- 标签标题只在本地内存中显示，**不发送、不存储**

## 已知限制

- 只显示当前窗口的标签，不聚合多窗口
- 标签标题过长会截断
- 不做实时监听：在 Chrome 里增删标签后，需切走再切回刷新
- 依赖 Pock 0.9.0（Pock 已停更）

## 目录结构

```
chrome-tabs-pock/
├── build.sh              构建脚本
├── src/
│   ├── ChromeTabs.swift  源码
│   └── Info.plist        bundle 元数据
└── README.md
```

## 与 Pock 官方的关系

第三方组件，与 Pock 官方无关。
