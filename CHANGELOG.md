# Changelog

每个版本必须在此记录变更；发布流程会提取对应版本的段落，作为 GitHub Release
正文并渲染进 Sparkle appcast 的更新说明。段落格式：`## <版本号> - <日期>`，条目必须写成单行。

## 0.1.3 - 2026-11-26

### 新增

- 新增主题：设置页新增「主题」入口，可选默认、自定颜色、Midnight、Sunset 四种主题，另有纯色背景、彩色卡片、卡片颜色三个开关；换主题立刻生效，整个 App 的背景、强调色、卡片都跟着变，选完下次打开还在。
- 新增播放页跟随封面变色：播放时播放页的背景和强调色跟着当前歌曲封面的主色调走，封面换了颜色跟着换；颜色会跟着音频轻微律动，拿不到音频电平时用平缓的呼吸动画代替；设置页主题区可关掉，关了播放页用回主题的颜色。
- 新增跨平台整合导入：导入 Apple Music 歌单时，每首歌先在优先平台上找，找不到就依次去其他已登录的平台上找，找到的都放进本地歌单「Apple」里，一张歌单、多个平台，不用切换；结果页按平台分数量显示，没登录的平台自动跳过。

### 修复

- 播放更流畅，修掉帧卡顿：进度条的刷新从每秒 120 次降到每秒 30 次，播歌时界面不再卡顿。

## 0.1.2 - 2026-11-26

### 新增

- 新增导入 Apple Music 歌单：粘贴 Apple Music 歌单链接，逐首在已登录平台上搜索匹配，建一个名为「Apple」的新歌单并把找到的歌加进去，没找到的歌会列出来。
- 歌单列表新增「导入 Apple Music 歌单」入口（侧边栏与「我的」页歌单标题旁的下载图标）。

### 修复

- 修复 QQ 音乐、酷狗音乐、汽水音乐扫码登录时，轮询在切到音乐 App 扫码期间断掉就再也回不来的问题：单次网络失败不再直接结束登录，回到前台后会用同一个二维码继续轮询。
- 修复设置页添加账号时扫码登录同样会被一次网络失败打断的问题（与上方同一次重构）。

## 0.1.1 - 2026-11-24

### 新增

- 新增洛雪音源，以 Swift 原生实现、无需 JS 运行时。
- 汽水音乐仅返回试听片段或无完整音频时会自动换源，所有音源都失败才显示汽水的原因。
- 新增「探索」页：搜索与精选合并，顶部为搜索框，下方按分类显示两行歌单，点分类标题可查看该分类全部歌单。
- Mac 与 iPad 侧边栏加入交互动画（iOS 16–27 通用）：选中高亮滑动、按压回弹、悬停高亮、图标弹跳、设置齿轮旋转、账号切换过渡、状态点渐变、歌单增删动画。
- 主内容区加入动画：加载骨架淡入为内容，我的收藏、搜索、听歌排行的分段切换淡入淡出。
- Mac 播放详情页改为从底部播放栏放大展开，关闭时缩回播放栏。

### 修复

- 修复 iPadOS 16 切换应用后回到播放详情页，当前行歌词高亮不显示的问题。
- 修复 iOS 16–17 旋转播放详情页时出现白边或黑块、内容消失和被裁切的问题。
- 拖动进度、调整歌词偏移或切换歌词来源、切换音质后，歌词会重新对齐实际播放进度。
- 修复 Toast 被播放详情页遮挡的问题，并移除 iPad 上重复的 Toast 层。
- 修复 iPad 点击热搜候选词时搜索整行展示文字而不是实际关键词的问题。
- 修复 iOS 16 底栏搜索按钮只有图标可点、圆形区域其他位置点击无效的问题。
- 修复侧边栏账号状态圆点在校验被取消后一直闪烁「验证中」的问题。

### 改进

- iOS 16–17 播放详情页改为从迷你播放条放大打开，接近 iOS 18+ 原生 zoom，动画曲线改为按响应时间定义的弹簧，更柔和；iOS 18 及以上使用系统原生 zoom 转场。
- 歌词只显示正文，去掉作词、作曲、制作等署名、版权声明以及开头的「歌名 - 歌手」行，保留对唱标签。
- 改进跨平台歌词匹配：忽略翻译、出处等标题附注，Live、伴奏等版本标记必须一致；识别歌手别名与日文汉字写法；网易云、QQ 音乐、酷狗可按歌曲 ID 直接匹配歌词。
- 纯音乐按各平台自身标记判定（网易云、QQ 音乐、酷狗、汽水、LRCLIB）。
- 歌词来源出错，以及手动切换来源时「此来源没有这首歌的歌词」，改为 Toast 提示，不再弹窗。
- 底栏不再随滚动收缩，搜索按钮移到「推荐」右侧。
- 统一首页布局：歌曲行与排行榜在 Mac、iPad、iPhone 上统一为 357pt 列宽，全应用歌单与专辑卡片统一为 178pt 封面与 22pt 平滑圆角。
- iPhone 迷你播放栏加大封面，字体跟随系统字号，调整控件尺寸与间距。
- iPhone 横屏播放详情页沿用 Mac 与 iPad 的间距规则，封面更大，左侧歌曲操作与右侧歌词按钮平齐。
- iOS 竖屏下歌词、评论、待播清单、加入歌单面板与封面左边缘对齐，iPhone 顶栏与进度条等宽。
- Mac 与 iPad 侧边栏平台切换器与设置中的账号卡片一致，显示头像、有效性小点与会员信息。
- 优化 Mac 首页滑动流畅度：滚动时暂停悬停效果，减轻歌曲行开销，主窗口不再随播放器每次变化重绘。

## 0.1.0 - 2026-11-10

### Added

- First public release of Coda, an independently maintained fork of Kumone: a native SwiftUI music client for macOS 15+ and iOS/iPadOS 16+.
- Multiple music services: NetEase Cloud Music, QQ Music, KuGou and Qishui (capabilities vary by service).
- One responsive player interface that adapts to window sizes, device sizes and orientations, with synced lyrics, romaji and furigana.
- Automix transitions, audio spectrum and CarPlay support.
- Unsigned iOS IPA for AltStore / SideStore, with an AltStore source for updates.

### Improved

- Separate bundle identifiers, data, caches and Keychain services for release (`wow.caicai.coda`) and development (`wow.caicai.coda.dev`) builds, so Coda never touches Kumone data.
- The Mac build is ad-hoc signed and not notarized; see the install notes for the first launch.

---

### 新增

- Coda 首个公开版本：基于 Kumone 独立维护的原生 SwiftUI 音乐客户端，支持 macOS 15+ 与 iOS/iPadOS 16+。
- 接入网易云音乐、QQ 音乐、酷狗音乐和汽水音乐，各平台能力不同。
- 单一响应式播放界面，适配窗口、设备尺寸与横竖屏，支持歌词同步、罗马音与假名注音。
- 支持自动混音过渡、音频频谱与 CarPlay。
- 提供未签名 iOS IPA，可通过 AltStore / SideStore 安装，并提供 AltStore 更新源。

### 改进

- 正式版（`wow.caicai.coda`）与开发版（`wow.caicai.coda.dev`）使用独立的应用标识、数据、缓存与钥匙串。
- Mac 版采用 ad-hoc 签名且未经公证，首次打开请参考安装说明。
