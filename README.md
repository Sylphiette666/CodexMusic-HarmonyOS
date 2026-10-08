# 听见 · Codex Music

这是“实验一：音乐播放 APP”的独立 HarmonyOS 工程，使用 **Codex 完成需求分析、代码编写、构建修复、测试与实验材料整理**，替代实验指导中 TRAE 承担的开发工作。DevEco Studio 仍用于 HarmonyOS SDK、构建、签名和设备运行。

工程不依赖 TRAE，也不依赖原来的 `Application` 工程。

[完成版实验报告](实验一_音乐播放APP_CODEX实验报告.docx) 已按用户提供的《实验报告模板》填写，共 8 页，保留八个章节、学校页眉与页码，包含三段关键代码、真实排错记录和四张模拟器截图。个人信息、成绩、帮助程度评分和签名留空；提示词复现案例与原始对话记录、已验证项与待测项分别注明。

## 环境与启动

| 项目 | 配置 |
| --- | --- |
| 应用名称 | 听见 |
| Bundle Name | `cn.gdut.codexmusic` |
| 语言与界面 | ArkTS、ArkUI，Stage 模型 |
| 目标 / 最低兼容 SDK | HarmonyOS `6.1.1(24)`，API 24 |
| 支持设备声明 | phone、tablet、2in1 |
| 持久化 | HarmonyOS RDB：`codex_music.db` |
| 音频播放 | Media Kit `AVPlayer` |

1. 用 DevEco Studio 的 **Open** 打开本 README 所在的 `CodexMusic` 根目录。根目录包含 `build-profile.json5`、`AppScope`、`entry`；不要只打开 `entry` 子目录。
2. 在 SDK Manager 中准备匹配的 HarmonyOS 6.1.1 / API 24 SDK，等待项目同步和 OHPM 依赖解析。
3. 选择 API 24 或兼容版本的 HarmonyOS 模拟器或设备。
4. 真机运行时，在项目签名配置中启用 **Automatically generate signature**，按 DevEco Studio 提示完成开发者账号、设备和签名配置，再点击 Run。本次本机 API 24 模拟器已成功安装并运行未签名 HAP；其他模拟器以其安装策略为准。
5. 启动后可直接播放三首随包附带的原创器乐，无须先寻找或下载歌曲。

命令行构建：

```powershell
Set-Location -LiteralPath 'D:\Work\Harmony_Next\CodexMusic'
.\scripts\build.ps1
```

安装位置不同的电脑可以指定工具路径：

```powershell
.\scripts\build.ps1 -DevEcoHome 'C:\Program Files\Huawei\DevEco Studio'
```

脚本调用 DevEco Studio 附带的 Node、Hvigor、Java 和 SDK，不需要 TRAE。构建输出位于 `entry/build/default/outputs/default/`。名称包含 `unsigned` 的 HAP 是未签名产物；本机测试模拟器允许安装，但不能据此保证其他设备允许。真机请使用 DevEco Studio 的匹配签名配置。项目不包含个人证书、密码或设备授权文件。

`artifacts/entry-default-unsigned.hap` 与 `artifacts/entry-ohosTest-unsigned.hap` 是本次验证对应的最终未签名应用包和测试包。根目录的 `实验一_音乐播放APP_CODEX实验报告.docx` 已完成五页排版检查，姓名、学号等个人信息待本人填写；`docs/fixtures` 提供可复现的 `CodexImport.wav` 和配套 LRC 验收素材。

## 四个页面

| 页面 | 操作与行为 |
| --- | --- |
| 播放 | 封面、标题、歌手、专辑、播放/暂停、上一首/下一首、进度拖动、音量、顺序/随机/单曲循环、动态歌词、导入 LRC、语音点歌、播报歌曲和文字指令 |
| 待播 | 展示当前播放队列；点击歌曲跳转播放；空队列可播放全部音乐 |
| 音乐库 | 浏览音乐；按歌名、歌手、专辑和原文件名搜索；多选音频导入；扫描本应用；设备支持时选择目录；将歌曲加入歌单 |
| 我的歌单 | 新建歌单、查看歌曲、加入/移除歌曲、删除歌单；通过 RDB 保存，重启后读取 |

从音乐库或歌单开始播放时，以该列表作为播放队列。顺序模式自然播完最后一首时停止，进度保留在结尾；手动“上一首/下一首”可跨越队列边界。随机模式在多首歌曲时避开当前项；单曲循环作用于自然播完，手动切歌仍然有效。

## 音频和文件访问

“导入音频”启动系统 `DocumentViewPicker`。可以选择 MP3、M4A、AAC、WAV、FLAC、OGG、AMR；具体文件能否解码，以设备支持及文件内容为准。也可一并选择同名 `.lrc` 文件。

授权文件会复制到应用私有 `filesDir/music` 目录，再使用 `AVMetadataExtractor` 读取标题、歌手、专辑、时长和内嵌封面。没有标签时以原文件名、未知歌手和未知专辑回退；无内嵌封面时显示默认封面。复制后的内容以 SHA-256 标识，重复导入相同内容保持同一歌曲 ID。原始用户文件保持不变。

- 单音频上限 256 MB；每批读取上限 512 MB；单批最多处理 500 首。
- 文件选择器一次最多选择 100 个文件；目录扫描最多检查 5000 个条目，最多向下递归 12 层。
- LRC 上限 1 MB，支持 UTF-8 和带 BOM 的 UTF-16；无法识别编码会提示另存为 UTF-8。
- 损坏、空文件、超限、访问失败和元数据异常会列出错误；一个文件失败不会阻止其他合法文件导入。

**“扫描本应用”仅扫描已经导入的应用私有目录。它不是手机全盘扫描。** 内置原始资源由应用首次初始化加入音乐库，不需要通过扫描导入。

**“选目录”仅对具有目录选择能力的 2in1 设备启用。** 实测 API 24 手机可能报告支持相关系统能力，却忽略 FOLDER 参数；因此代码同时检查 `deviceInfo.deviceType` 和 `canIUse`，手机/平板明确提示使用多选音频或扫描本应用，不放开未验证的新版本能力。支持的 2in1 也必须先由用户授权，再读取所选目录及子目录，并匹配同目录同名 LRC。不会申请系统级文件管理权限或绕过沙箱。[官方文档：DocumentViewPicker](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-file-picker)

## 歌词与试听素材

内置《晨光序曲》《雨中漫步》《星河回响》各 30 秒，均为本项目合成的原创器乐。界面里的文字是用于验证歌词显示的配文，**不是歌手演唱的录音歌词**。资源说明见 `entry/src/main/resources/rawfile/AUDIO_LICENSE.txt`。

普通 LRC 提供行级时间，程序在相邻行之间等距估算字间时间，并显示“普通 LRC · 字间时间为估算”。增强 LRC 提供 `<mm:ss.xx>` 字/词时间标记，程序按这些标记同步着色和跳动；准确程度取决于导入文件的时间标注质量。

```text
[00:00.00]这是普通行级歌词
[00:05.00]<00:05.00>听<00:05.80>见<00:06.60>音<00:07.40>乐<00:08.20>
```

歌词解析支持多时间标签、毫秒精度和 `[offset:+/-毫秒]`。正偏移延后显示，负偏移提前显示。跳转进度后根据播放器时间重新定位歌词，不依赖人工计时器假装推进歌曲。

## 后台播放与语音

播放器使用单一服务实例，结合 `AVSession` 和 `audioPlayback` 长时任务处理后台音频。播放页会显示后台状态；申请或系统服务异常时显示实际错误。后台、锁屏控制和音频中断应按设备验收表分别验证，不能仅凭编译成功认定已通过。

点击“语音点歌”时请求麦克风权限，通过 `AudioCapturer` 获取 16 kHz、单声道、16-bit PCM，送入 Core Speech 中文离线识别引擎。录音最长 15 秒；初始化超时、权限拒绝、麦克风占用或设备缺少语音服务会给出提示。

可说“播放晨光”“暂停”“继续播放”“上一首”“下一首”“搜索雨中”。文字指令入口复用相同的命令解析，用于可重复验证播放控制；**文字输入测试不算真实语音识别通过**。应用没有接入第三方语音接口，也不要求填写 API Key。

“播报歌曲”使用 Core Speech 中文离线语音合成（TTS）读出当前歌名和歌手。服务根据播放完成回调结束会话，并处理超时和不支持情况；录音识别与播报互斥，避免识别应用自己的播报内容。TTS 的实际可听效果需要设备验证。

声明权限为 `MICROPHONE`、`KEEP_BACKGROUND_RUNNING` 和 `INTERNET`。麦克风仅在用户启动识别后申请；本地试听不需要麦克风授权。语音功能能否运行仍取决于目标设备提供的 Core Speech 能力。

## 工程组织

```text
entry/src/main/ets/
  pages/Index.ets              四个 Tab 页和交互
  model/MusicModels.ets        歌曲/歌单、搜索、队列规则、语音指令
  model/Lyrics.ets             普通与增强 LRC 解析和时间定位
  model/MusicRepository.ets    歌曲、歌单、关联关系的 RDB 存储
  services/ImportService.ets   系统选择、沙箱导入、元数据、LRC、扫描
  services/PlayerService.ets   AVPlayer、AVSession、后台和音频中断
  services/VoiceService.ets    权限、录音、语音引擎、会话清理
entry/src/main/resources/      音频、封面、字符串与页面配置
scripts/                      构建和测试工具
docs/                         实验记录、验收步骤及证据
```

本地逻辑测试：

```powershell
# 在支持 node:sqlite 的 Node.js 中运行模型/数据库契约测试。
node .\scripts\test-model.cjs
node .\scripts\test-import-service.cjs
node .\scripts\test-services.cjs
```

如果 DevEco Studio 不在默认目录，先将 `DEVECO_HOME` 环境变量设为实际路径。模型测试使用真实临时 SQLite 数据库执行 SQL，通过适配层模拟 Harmony RDB 接口；导入及播放/语音测试用模拟的平台 API 验证业务行为。这些测试不能替代原生音频解码、麦克风、文件选择器、后台策略和设备数据库的验收。

## 已保存的验证结果

主 HAP 与 ohosTest HAP 的最终构建均成功，日志为 [build-results.txt](docs/build-results.txt) 和 [test-build-results.txt](docs/test-build-results.txt)。本机 API 24 模拟器完成 10 项 Hypium 测试（包括真实 Harmony RDB）；本机 30 项模型/SQLite 测试、14 项导入 mock 行为测试、播放/语音服务 mock 测试均通过。

模拟器界面实测覆盖了内置曲目、关键词搜索、歌单创建/加入及进程重启保存、播放器进度推进、暂停保持、seek 到 15 秒、上下首和模式切换。退到桌面期间进度从 13 秒增加至 19 秒，并显示后台长时任务开启。

系统文件选择器已实际导入 `CodexImport.wav`，原生元数据提取正确显示 `Import Test / Codex Lab / Local Album`；沙箱重扫后音乐库保持 4 首，原文件名搜索成功，导入曲目进度推进至 3 秒。实际选择 LRC 后关联 4 行歌词，本次重新安装后仍保留并在 00:06 定位增强歌词。TTS 状态到达“歌曲信息播报完成”；真实拒绝麦克风权限后出现明确提示。

最终版本已回归暂停/seek 媒体会话无 401 错误、后台任务及 API 24 手机目录限制提示。开发中将 AVSession 暂停状态下不合法的 `speed=0` 修正为 `speed=1`，暂停由播放状态字段表达；AVPlayer 的 `stateChange` 统一为一个原生监听器。这些证据未包含人工听感、完整录屏、真机后台或麦克风口述识别的正向结果；详见验证记录。

阅读 [验证记录](docs/验证记录.md) 查看证据与限制；使用 [实验验收指南](docs/实验验收指南.md) 继续设备验收；阅读 [CODEX 提示词与开发记录](docs/CODEX提示词与开发记录.md) 查看替代 TRAE 的开发流程。构建日志、测试输出及截图应与对应运行环境一起保存，不将待验证项写为通过。
