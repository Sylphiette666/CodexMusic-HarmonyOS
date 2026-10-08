# Codex 提示词与开发记录

## 本次任务与工具替换

用户提供《实验一 音乐播放 APP.docx》，实际请求为：

> 完成实验，使用 CODEX 完全代替 TRAE

本工程将指导材料中由 TRAE 承担的代码助手工作全部改由 Codex 完成：读取需求、检查本地 SDK、设计模块、编写 ArkTS、生成原创试听资源、运行构建、处理编译错误、补充测试与实验文档。

HarmonyOS 原生开发仍使用 DevEco Studio 的 SDK、Hvigor、OHPM、签名和设备运行工具。替换代码助手不等于替换原生工具链。

开发目录为 `D:\Work\Harmony_Next\CodexMusic`，与已有 `Application` 项目分开。应用包名为 `cn.gdut.codexmusic`，目标与最低兼容版本为 HarmonyOS 6.1.1 / API 24。

## 实施记录

| 阶段 | 实际完成的工作 | 对应文件或依据 |
| --- | --- | --- |
| 需求拆分 | 分为四个页面、播放与队列、音乐库导入、RDB 歌单、歌词、后台播放及语音控制 | `entry/src/main/ets/pages/Index.ets` 及独立 model/services |
| 工程创建 | 创建独立 Stage 模型工程，设置 Bundle、API 版本、模块与资源 | `AppScope/app.json5`、`build-profile.json5`、`entry/src/main/module.json5` |
| 原生接口核实 | 读取本机 SDK `.d.ts`；核对 Picker、文件 IO、元数据提取、语音及后台接口 | DevEco Studio SDK；系统文件选择器官方文档 |
| 音乐与歌单 | 建立歌曲、歌单、歌单歌曲关联和初始化标记；使用 RDB 持久化及参数绑定 | `MusicRepository.ets` |
| 搜索与播放规则 | 实现歌名/歌手/专辑/文件名搜索；顺序末首自然完成停止、随机及单曲循环；语音命令文本解析 | `MusicModels.ets` |
| 文件导入 | 系统选择器授权、复制到沙箱、SHA-256 标识、真实元数据和内嵌封面、同名歌词及错误反馈 | `ImportService.ets` |
| 权限边界修正 | 增加“扫描本应用”；实测手机 syscap 可返回 true 但忽略 FOLDER，修复为仅 deviceType=2in1 且具备目录能力时开放目录选择 | `ImportService.scanImported()`、`scanDirectory()` |
| 实际播放 | 接入 `AVPlayer`，处理准备/播放/暂停/完成、seek、音量与异步切歌；统一为单一原生 stateChange 监听器 | `PlayerService.ets` |
| 后台与会话 | 接入 AVSession、长时任务和音频中断；修复暂停时 speed=0 导致的 401，改用合法 speed=1 并单独表达播放状态 | `PlayerService.ets`、模块 `backgroundModes` |
| 歌词 | 普通 LRC 行时间、增强 LRC 字时间、多时间标签、offset、跳转后的定位 | `Lyrics.ets`、播放页 |
| 语音 | 权限请求、真实麦克风 PCM、中文离线识别会话、分帧、超时与资源释放；增加“播报歌曲”离线 TTS | `VoiceService.ets` |
| 试听素材 | 随包提供三首原创合成器乐，各 30 秒；歌词区为时间轴教学配文 | `resources/rawfile`、`AUDIO_LICENSE.txt` |
| 构建和检查 | 通过脚本调用 DevEco 工具链；修复 ArkTS 类型和接口问题；主 HAP 和 ohosTest HAP 构建成功 | `scripts/build.ps1`、构建输出日志 |
| 行为测试 | 30 项模型/SQLite、14 项导入 mock、播放/语音服务 mock 均通过；API 24 模拟器 10 项 Hypium 通过，含真实 RDB | `scripts/test-*.cjs`、`docs/*test-results*` |
| 模拟器界面 | 检查进度、暂停、seek、切歌/模式、搜索、歌单持久化和后台进度；真实 Picker 导入、原生标签、沙箱重扫和 LRC 关联；本机允许安装未签名 HAP | `docs/ui-test-results.json`、`docs/screenshots` |
| 实验交付 | 编写中文使用说明、设备验收步骤、开发及验证记录；准确区分通过、部分验证和待测 | `README.md`、`docs/实验验收指南.md`、`docs/验证记录.md` |

Codex 在可并行的工作上进行了模块分工：模型/数据库/歌词、文件导入、播放/语音分别实现，主流程负责界面、工程配置与集成。模块共享 Song 数据契约，集成时补充了原文件名字段，避免只按沙箱哈希文件名搜索。

## 关键实现选择

### 文件选择与扫描

普通应用不能仅凭实验要求获得全盘文件访问权限。实现同时检查设备类型为 2in1 及系统目录选择能力；不支持时提示多选音频导入。用户选中的文件复制到应用私有目录，避免临时 URI 授权结束后音乐失效。

一次真实模拟器检查发现：API 24 phone 上 `canIUse(FolderSelection)` 返回 true，系统却忽略 FOLDER 参数并打开普通文件选择器。因此没有把一次读取旧提示栏的结果算作通过，而是修复检查条件，增加 phone/tablet 能力误报以及 2in1 无能力两个回归场景。最终模拟器回归已明确显示 API 24 不支持文件夹授权、仅支持有能力的 2in1；该修复不推断未测试 API 26 的设备行为。

本机 API 24 SDK 对目录选择标注了设备差异；当前官方说明同样列出 `DocumentSelectMode` 的设备与版本限制。[官方依据](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-file-picker)

同一内容使用 SHA-256 作为歌曲标识；附件保存在应用目录中。导入失败会清理本次创建的文件，清理接口检查目录归属，避免删改用户源文件。

### 歌词精度

普通 LRC 只有整行起始时间，无法从中恢复歌手每个字的真实发音时间，因此将字间动画明确标记为估算。增强 LRC 按已有字/词时间标记驱动动画，仍要求素材本身正确标注。

内置曲目为器乐，不包含合成歌手演唱。配文用于观察时间轴、跳动和切歌，不冒充商业歌曲或真实逐字演唱歌词。

### 语音与模拟器

语音路径为麦克风 PCM → Core Speech 离线识别 → 命令解析 → 播放控制。文字输入入口只是共用命令解析的备用交互，不能作为麦克风识别已通过的证据。

“播报歌曲”另接入中文离线 TTS，读取当前歌曲信息；根据 TTS 的实际播放完成事件释放服务，并与录音识别互斥。服务 mock 已验证完成、异常和录音优先处理，真实可听播报仍按设备证据验收。

语音服务是否可用、后台会话是否获准以及锁屏行为均由目标设备决定。模拟器实测已观察到 Home 后进度从 13 秒增加至 19 秒，且后台长时任务开启；这不等于实际听感、长期后台、锁屏或真机策略全部通过。

### 原生状态兼容性修复

AVPlayer 的状态变化统一注册一个原生 `stateChange` 监听器，由该监听器处理持续状态更新和等待状态的分发，避免重复注册同一原生事件。AVSession 的 `speed` 保持合法的 `1`；暂停使用播放状态表达，修复先前将速度设为 `0` 触发的 401。最终模拟器暂停、seek、增强歌词定位及后台任务回归均未再出现该错误。

## 可复用的 Codex 提示词

以下是根据本次实际工作整理的复现提示词，**并非逐字对话历史**。可在相同工程中分阶段使用。

### 1. 读取需求与建立工程

```text
读取“实验一 音乐播放APP.docx”，区分指导材料和我的实际请求。
使用 Codex 完全代替 TRAE，在 CodexMusic 创建独立 HarmonyOS Stage 工程。
使用 ArkTS/ArkUI，目标 HarmonyOS 6.1.1 API 24，包名 cn.gdut.codexmusic。
完成播放、待播、音乐库、我的歌单四页；先检查本地 SDK 和现有工程配置。
保留旧 Application 工程，不虚构用户身份和设备验收结果。
```

### 2. 模型、数据库与歌词

```text
实现 Song/Playlist 模型和 Harmony RDB 持久化，支持歌单创建、删除、加歌、移除及重启恢复。
搜索同时覆盖歌名、歌手、专辑和原文件名。
实现普通和增强 LRC，普通行歌词的字间动画必须标为估算；增强格式按已有时间标记同步。
使用参数绑定、事务和明确的错误处理，补充真实 SQL 与边界测试。
```

### 3. 本地音频导入

```text
使用 DocumentViewPicker 授权选择多首音频，复制到 filesDir/music 后长期使用。
使用 AVMetadataExtractor 读取标题、歌手、专辑、时长、封面，缺失标签使用文件名回退。
用内容哈希去重，支持同名 LRC，限制文件大小，隔离损坏文件错误。
目录扫描先检查设备支持，不绕过沙箱；手机提供“扫描本应用”。
清理文件必须检查路径归属，不删除用户的原始音频。
```

### 4. 播放与语音

```text
用实际 AVPlayer 完成播放、暂停、seek、音量、三种模式和快速切歌。
顺序播放在最后一首自然完成时停止，保留结尾进度；手动切歌仍可跨队列边界。
加入 AVSession、audioPlayback 长时任务及音频中断处理。
麦克风采集 PCM 送入系统中文离线语音识别，支持点歌、搜索、暂停和切歌。
提供中文离线 TTS“播报歌曲”入口，识别与播报互斥，按真实完成事件释放资源。
拒绝权限、设备不支持、服务超时必须明确提示，不用假识别结果替代真实语音。
```

### 5. 构建修复与验收

```text
使用 scripts/build.ps1 执行实际 SDK 编译，按输出修复 ArkTS 和资源问题。
运行模型、导入和服务测试，保留日志并说明哪些平台接口是模拟的。
在可用模拟器或真机上检查四页交互及音频，保存真实截图和结果。
输出中文 README、验收指南、开发记录；没有运行的设备项写待验证。
未签名 HAP 注明设备限制；本机允许安装的模拟器与需要匹配签名的真机分别说明。
```

## 证据范围

- 导入服务已执行 14 项行为测试，结果保存在 `docs/import-test-results.txt`。测试使用真实临时文件和模拟系统 API，包含取消、目录类型/能力限制、部分写入、去重、重扫、元数据/封面分支、坏文件清理、大小限制、歌词编码、安全删除和资源释放。
- `model-test-results.txt` 为 30/30 本机模型/SQLite 测试通过；`services-test-results.txt` 为播放和语音（含 TTS）服务 mock 套件通过。
- `device-test-results.txt` 为 API 24 模拟器 Hypium 10/10 通过，其中 4 项使用真实 Harmony RDB。最终主 HAP 和 ohosTest HAP 构建均成功，日志为 `build-results.txt` 和 `test-build-results.txt`。
- `ui-test-results.json` 保存模拟器界面逐项检查摘要，覆盖进度/暂停/seek、模式、歌曲搜索、歌单及关联歌曲的进程重启持久化，以及 Home 后进度推进和后台任务状态。上下首操作亦已实测；未检查人工听感和完整录屏。
- 原生 Picker 已导入带 RIFF INFO 标签的 CodexImport.wav，显示 Import Test / Codex Lab / Local Album；音乐库从 3 首到 4 首，沙箱重扫后仍 4 首。原文件名搜索及导入曲目进度推进至 3 秒通过。真实选择 LRC 后关联 4 行，本次重新安装后仍保留，并在 00:06 定位到增强歌词。
- TTS 状态到达“歌曲信息播报完成”；真实拒绝麦克风权限后出现未获授权提示。没有进行口述语音识别的正向硬件验收，也没有人工确认播报听感。
- 设备功能表见 `实验验收指南.md`，按证据标注通过、部分验证或待测。内嵌封面、完整录屏、口述识别及 TTS 听感仍待对应设备验证，不能由 mock 测试替代。
- 本次不生成个人签名证书，不代填学号或班级，不声称未发生的真实设备验证。
