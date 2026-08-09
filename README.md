# Winterbreak2 一键本地部署脚本

> ⚠️ **警告**  
> 此方法仅适用于 Kindle 固件版本 **低于 5.16.4** 的设备。

---

## 📋 前置要求

在开始之前，请确保满足以下条件：

- 一台可用的电脑（PC）
- Kindle 设备固件版本 **低于 5.16.4**
- Kindle 存储空间**几乎已满**，剩余可用空间仅保留 **50–90 MB**（用于[阻止自动更新](https://kindlemodding.org/jailbreaking/prevent-auto-update/)）
- Kindle 已保存一个**有效且已连接互联网**的 Wi-Fi 网络（建议先用文件填满存储再连接 Wi-Fi）
- 电脑上已安装解压软件（如 Windows 可用 [7-zip](https://www.7-zip.org/) 或 [WinRar](https://www.win-rar.com/start.html?&L=0)）

---

## 🚀 操作步骤

> 📖 官方教程原文参考：  
> [https://kindlemodding.org/jailbreaking/WinterBreak2/](https://kindlemodding.org/jailbreaking/WinterBreak2/)

### 方式一：在线越狱（需外网环境）

1. 从 [Releases](https://github.com/KindleModding/Winterbreak2/releases/download/v1.0.0/wb2.zip) 下载 `wb2.zip` 压缩包

2. 将 Kindle 连接至电脑，解压 `wb2.zip` 中的两个文件（`jb.sh`、`patchedUks.sqsh`）及 `winterbreak2` 文件夹，放置于 Kindle 存储的**根目录**

3. 安全弹出 Kindle 设备，确保 Kindle 已连接至 Wi-Fi 网络

4. 在 Kindle 上打开**实验性浏览器**，访问：
   ```
   https://winterbreak2.now.sh/
   ```
   > 若无法访问，请参考下方方式二进行本地部署

---

### 方式二：本地部署越狱（推荐，无需外网）

5. 克隆本仓库到本地：
   ```bash
   git clone https://github.com/noame19/Winterbreak2.git
   ```

6. 进入仓库目录，运行脚本（根据系统选择）：
   - Windows 系统：运行 `manage.ps1`
   - macOS / Linux：运行 `manage.sh`

   > 运行前请确保已安装 [Node.js](https://nodejs.org/)

7. 在脚本菜单中选择：
   - 选择 `[1] 自动部署`，等待部署完成
   - 部署完成后，选择 `[3] 本机运行网页`

8. 在 Kindle 实验性浏览器中访问终端显示的地址（格式为）：
   ```
   http://你的IP地址:3001
   ```
   > 请确保防火墙已放行 3001 端口

---

## 🔧 执行越狱

9. 在 Kindle 浏览器页面中，点击 **“越狱”** 按钮

10. 页面会弹出一个对话框，点击确认后越狱流程将自动开始

---

## 📝 注意事项

- 越狱过程中请勿断开 Wi-Fi 或关闭 Kindle
- 如遇问题，请确保 Kindle 存储空间符合要求（剩余 50–90 MB）
- 本脚本仅用于学习与研究，请遵守相关法律法规

---

## 🙏 致谢

- 项目基于 [KindleModding/Winterbreak2](https://github.com/KindleModding/Winterbreak2) 二次封装
- 感谢 KindleModding 社区的无私贡献
- Scam.Net; Concept, Discovery
- Penguins184; Server

---

## 📄 许可证

本项目仅供学习交流使用，请遵循原始项目的许可证条款。


