# Rune 图标 · 生图设计说明

用户要求：使用生图模型制作具有 iOS 27 风格感的图标，克制、有辨识度，与应用审美一致。

## 设计方向

- **首选：松绿与温润玻璃符文**。松绿底，浅玉色玻璃 R 符文，轮廓比材质细节更重要。
- **备选：暖白与烟绿玻璃**。暖白底，深烟绿符文，保持相同结构与留白。
- 禁止机器人、星芒、脑形、彩虹镀铬、紫蓝渐变和复杂装饰。
- 1024 × 1024、完整方形、不透明；不预烘焙外部圆角与投影，系统负责图标遮罩。
- 生成后检查 32 / 60 / 120px 识别度、亮暗桌面衬底，以及图标资产是否不透明、尺寸是否准确。

## 调用来源与结果（C43）

通过用户配置的 PinAI Key 查询可用模型后，确认实际 ID 为 **`gpt-image-2.5-flare`**；原先填写的 `gpt-image-2.5flare` 缺少一个连字符，已纠正。未切换到截图中的 `gpt-image-2` 或内置生图工具。

使用 imagegen 技能自带 CLI，经 `https://api.pinaic.com/v1` 发出 **2 次生成、1 次编辑**：先生成两个方向，再以暖白候选为形状参考生成深色版本。调用日志只保留状态与耗时，不含 Key；本机 Python 的证书链通过 certifi 补齐，未关闭 TLS 校验。

### 选定版本

- **浅色默认**：暖白底、烟绿色玻璃符文。轮廓明确，材质细节克制。
- **深色**：深松绿底、浅玉色磨砂玻璃符文，沿用浅色版几何与位置。
- 原始松绿候选含透明像素，未采用。原始图全部保留供追溯。

模型实际返回 1254 × 1254；仅做尺寸归一化与 RGB 格式导出，得到 1024 × 1024 不透明 PNG。没有手绘或编程重绘替代模型成果。已检查 32 / 60 / 120px 导出与 60px 实际呈现；Xcode 图标资源构建通过。

### 文件

- [浅色图标](../../output/imagegen/rune-icon-light.png)
- [深色图标](../../output/imagegen/rune-icon-dark.png)
- [浅色原始生成图](../../output/imagegen/candidates/rune-graphite.png)
- [深色原始编辑图](../../output/imagegen/rune-icon-dark-original.png)
- [尺寸、模式与哈希验证](../../output/imagegen/icon-validation.json)

已接入 `Apps/Rune/Assets.xcassets/AppIcon.appiconset`：默认 `AppIcon.png`、深色 `AppIcon-Dark.png`，通过 asset catalog 的 luminosity/dark appearance 声明。外层图标遮罩由系统提供。旧代码图标备份为 `output/imagegen/legacy-code-icon.png`。

### 最终提示词

- [浅色版提示词](../../output/imagegen/prompts/rune-graphite.txt)：暖白、不透明全幅背景；烟绿玻璃符文；正交、浅浮雕、收敛的边缘高光。
- [深色编辑提示词](../../output/imagegen/prompts/rune-dark-edit.txt)：保持参考图的几何与位置，只改背景和材质色；明确不透明、无光晕。
- [未采用的初稿提示词](../../output/imagegen/prompts/rune-jade.txt)
- [初稿批次请求](../../output/imagegen/rune-icon-jobs.jsonl)

## 凭据与验证边界

`.env.pinai` 仅留在本机，已加入 gitignore，权限为 0600；`.env.pinai.example` 不含密钥。Key 只传给用户指定的 PinAI 主机，不输出或写进图标、应用资源和日志。

图标具有用户要求的现代玻璃材质风格；当前工程验证 SDK 是 iOS 26.5，并不将这次设计与构建称为 iOS 27 真机验收。
