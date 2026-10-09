# DSH-RL — 2D 横板动作 Roguelike 的**内嵌 AI 导演层**

Godot 4.7.2 / GDScript。核心命题只有一个：

> **模型是脑子，不是手。**

模型不生成几何、不改血量、不逐帧控制敌人。它只做两件事：读一个 6 维结构化上下文，
写一条**受限原语**；这条原语先过**确定性校验器**，再经**双缓冲**在下一帧生效。
模型慢、超时、返回垃圾、根本没接上——游戏都必须照常可玩。

这不是一个"接了个聊天框的 Demo"。是一个关于 **LLM 做游戏系统设计时如何被工程手段关进笼子** 的实践。

---

## 1. 链路：一次模型决策的完整生命周期

```
Level.spawn_enemy_for → Director.on_room_enter
  ├─ build_ctx(level, stats)            # 本地统计 → 6 维向量，不是自然语言
  ├─ clamp_ctx()                        # 铁律 A/B 在此强制钳制（所有 ctx 都过）
  ├─ RuleBrain.decide()  → validate() → apply()    # L1 立即生效，0 延迟
  ├─ [可选] ModelBrain.request()        # 本机 OpenAI 兼容端点，超时 2s
  │     └─ 返回非法/超时/空 → fails++, 降级 L1；fails>=3 → enabled=false
  ├─ validate(prims, level, ctx, used)  # 白名单/范围/铁律/幂等，逐条检查
  └─ buf_next = clamp_ctx(ctx)
Director.tick → pending && buf_next != buf_cur && !shadow → swap
```

**双缓冲的意义**：`tick()` 里读的永远是 `buf_cur`，模型的结果落在 `buf_next`。
所以哪怕模型卡 2 秒，本帧时间不受影响——上一份 ctx 继续用。

### 校验器（`ai/director.gd::validate`，7 道门）

按顺序失败即**整条丢弃**（不是部分生效）：

1. 原语在 `PRIMITIVES` 白名单里（7 个：`set_ctx` / `spawn_wave` / `set_pacing` / `grant_pickup` / `set_affix` / `hint` / `noop`）
2. 必需参数齐全
3. `set_ctx` 的 `dim ∈ CTX_KEYS`、`value ∈ [0,1]`；其余按 `ranges` 闭区间
4. `hint.text_id` 在 `HINTS` 白名单里（5 条固定文案）
5. `set_affix.affix` 在 `Cfg.AFFIXES` 里
6. **铁律 A**：`hp < 0.30` 时 `spawn_wave` 直接拒；`set_ctx(aggression, >0.5)` 直接拒
7. 幂等：`"%d|%s|%s" % [current_room, prim_name, str(prim)]` 已出现过 → 拒（防抖）

### 三条铁律（硬编码，不信提示词）

| 铁律 | 实现 | 位置 |
|---|---|---|
| A 低血不后退 | `hp<0.30 → aggression ≤ 0.45、rhythm ≤ 0.5`；且拒绝加援军 | `clamp_ctx` + `validate` |
| B 怜悯有窗口 | `mercy` 仅在「`hp<0.35` 且 180 帧内未受伤 且 房内敌人 ≤2」才允许非 0 | `clamp_ctx` |
| C 白名单 | 表外原语整条丢弃 | `validate` |

铁律 A/B 在 `clamp_ctx()` 里对**所有** ctx 执行，不管它来自规则脑还是模型脑——
模型无法通过"返回一个合法的 0.9 aggression"来绕过。

### 三档降级

| 档 | 触发 | 行为 |
|---|---|---|
| L2 模型脑 | 端点返回合法 JSON 数组 | 用模型 ctx |
| L1 规则脑 | 未配置 / 超时 / 非法 / 解析失败 | 本地 `RuleBrain`，**默认档，游戏完整可玩** |
| L0 冻结 | 连续 3 次失败 | `enabled = false`，本局不再查询 |

### 唯一允许的自然语言出口

`hint` 只能选 id，文案由游戏内的 `HINTS` 表提供：

```gdscript
const HINTS := {
    "careful": "前面有埋伏。",
    "rest":    "这里安全，喘口气。",
    "elite":   "重甲在前 —— 削韧或绕背。",
    "low_hp":  "血不多了，考虑后撤。",
    "secret":  "这房间有夹层。",
}
```

理由：自由文本是注入面。模型能选 id，不能写字。

---

## 2. 代码规模

34 个 `.gd` 文件，9,323 行（`Get-ChildItem -Recurse -Include *.gd` 逐文件计数）。

| 目录 | 文件 | 行数 | 职责 |
|---|---|---|---|
| `gen/` | 8 | 3,116 | 网格图 / 体素图 / 运动核 / 房间模板 / 楼层布局 / 六头内容 |
| `tools/` | 10 | 1,757 | 自检、无头批量模拟、7 个定位探针 |
| `actors/` | 4 | 1,329 | 玩家 / 敌人 / 弹幕 / 基类 |
| `core/` | 4 | 803 | 常量、跳跃物理解析式、可随机访问 RNG、指纹 |
| `run/` | 2 | 696 | 关卡实例化、跨局 meta |
| `ai/` | 2 | 553 | 导演层（含 L1/L2 脑与校验器）、行为树 |
| `scenes/` | 1 | 342 | `main.gd` 装配 + 输入 + HUD |
| `combat/` | 1 | 329 | 帧数据表（起手/命中/收招/取消窗口） |
| `render/` | 1 | 219 | 程序化绘制（无贴图资产） |
| `loot/` | 1 | 179 | 掉落 / 词条 / 合成 |

最大单文件：`gen/gridmap.gd` 24,892 字节、`tools/sim.gd` 28,106 字节、`tools/selftest.gd` 20,448 字节。

---

## 3. 可复现的验证手段

这套项目的"我测过了"不靠手感，靠三个可复跑的工具：

### `tools/selftest.gd`（20,448 字节 / 496 行）

生成层硬约束自检，按组打断言并输出证据串。断言 ID 与设计文档的 V1 系列对齐：

| 组 | 内容 | 断言 ID |
|---|---|---|
| A | 跳跃物理派生常量（`h_single=122.5`、`h_max=200.9`、下落档射程 273px 等） | A1–A13 |
| B | 运动核 K 规模 / 双向性 / 缺口容量 / **核 vs 物理双向核对** | B1–B9 |
| C | 走廊生成扫描（4 种尺寸 × 40 seed）构造性连通 + 双向可达 | C1–C6 |
| D | 世界线确定性（同 seed 同指纹、不同 seed 不同指纹、RNG 每头独立流） | D1–D7 |
| E | 机关：单调布尔加 + 最小不动点 + 关键性 + 无死锁 | E1–E7 |
| F | 房间模板不变量（200 张） | F1–F4 |
| G | 楼层布局硬约束（12 seed × 3 层） | G1–G2 |
| H | 六头内容约束 / θ 真的改变内容 / 原型覆盖 | H1–H7 |

源码里共 **56 处断言**（`t.ok()` 43 + `t.near()` 13，正则计数；其中 `D1.*` 在循环里，
运行时计数会翻倍）。断言失败时 `testkit.gd::summary` 会打印 `✗ [ID] 证据串` 并返回失败数。

> 我本人没有在本机跑过 `selftest.gd`——仓库内没有留它的输出日志。上面的数字是
> 读源码数出来的，不是运行结果。运行方式见 §5。

### `tools/sim.gd`（28,106 字节 / 732 行）—— 无头机器人可玩性门

它的定位是**下限探针**，不是 AI 玩家：向右走 → 遇墙/遇坑就跳 → 敌人在攻击距离内就砍 →
血低就后撤。规划器用**和运行时同一套运动核掩码**做 A*（`KM.get_kernel()`），
所以"规划得出"≈"物理走得到"。

六个断言门：

| ID | 断言 |
|---|---|
| S1 | 模拟跑完 N 局不崩（通关/死亡/卡住计数） |
| S2 | 机器人确实杀到了敌人 |
| S3 | 机器人确实挨到了伤害（证明敌人真的会打人） |
| S4 | 同种子 + 同策略 ⇒ **同事件序列**（`res_b["trace"] == res["trace"]`，逐字符比较） |
| S5 | 同种子 + 同策略 ⇒ **同世界线指纹**（`lv.map.fingerprint()`） |
| S6 | `stalled <= runs/4` **且** `平均推进 >= 5.0 房` |

S4/S5 每局都把整局重跑一遍再比对，所以它是**世界线确定性的端到端证据**，不只是单元测试。

`stalled` 的判据（`tools/sim.gd:187-195`）：
**连续 900 帧 `player.p.x` 位移 < 0.5px**，与"帧上限用尽但一直在推进"（`timeout`）严格区分。
这个区分是刻意做的——早期版本把两者混为一谈，得出了"关卡走不通"的错误结论，
实际是机器人不会脱困（补了"挣扎"：卡住 240 帧就左右交替 + 周期起跳乱试 210 帧）。

### `tools/probe*.gd` —— 7 个一次性定位器

`probe.gd` / `probe2` / `probe3` / `probe10` / `probe11` / `probe12` / `probe13`。
不是正式测试，是出 bug 时写来"把现场打印出来"的。它们的价值在于留下了排查路径：
例如 `probe10.gd --strict=1` 是可复跑的**关卡几何可玩性证明**（严格掩码下 18 层零问题）。

---

## 4. 无头模拟实测结果

`logs/headless-sim-{1..6}.log` 是 6 次真实无头模拟的运行日志（按修改先后编号，
越靠后越新）。下面是**日志里逐行读出来的原始数字**，没有加工。

### 4.1 训练轨迹（看结论怎么变的）

| 日志 | 命令规模 | S6 判定 | 卡死 | 平均推进 | 平均击杀 | 实测中位 TTK |
|---|---|---|---|---|---|---|
| 1 | `runs=2 frames=20000` | ✗ | 2/2（当时口径） | — | 5 | 5.42s（样本 10） |
| 2 | `runs=2 frames=20000` | ✗ | 2/2 | — | 6 | 9.85s（样本 13） |
| 3 | `runs=2 frames=20000` | ✗ | 2/2 | — | 7 | 5.43s（样本 15） |
| 4 | `runs=4 frames=20000` | ✗ | 4/4 | — | 6 | 3.63s（样本 26） |
| 5 | `runs=4 frames=24000` | ✗ | 4/4 | — | 11 | 2.90s（样本 45） |
| 6 | `runs=6 frames=24000` | ✗ | **真·卡死 1/6**，帧上限用尽 5 | **4.2** | **13** | **4.37s（样本 83）** |

每份日志的结尾都是 `--- 无头模拟: 通过 5 / 失败 1 ---`，**且失败明细区间里写的都是 S6**。
从 log1 到 log6，中位 TTK 从 5.42s 收敛到 2.90s→4.37s，平均击杀 5 → 13，
逐层通过从「第1层 0 / 第2层 0 / 第3层 0」变成「第1层 4 / 第2层 2 / 第3层 0」。

> 口径说明：`testkit.gd::summary` 只打印**失败**断言的 `✗ [ID] 证据串`，通过的断言不逐条打印。
> 所以日志能直接证明的是「6 个门里恰好 1 个失败，那个失败的是 S6」，**不能**直接证明
> 其它 5 个门里哪个是哪个。S1–S5 的断言内容见 §3 表格（读 `tools/sim.gd:119-128` 得到）。

### 4.2 最新一次（log 6）逐局明细

```
DSH-RL 无头模拟器  runs=6 max_frames=24000

  seed=3000    → floor_clear：房 9/11，杀 31，承伤  56（spike 24）  帧  42659  TTK中位 3.2s
  seed=10919   → floor_clear：房 4/11，杀 10，承伤  48（spike 32）  帧  32408  TTK中位 3.0s
  seed=18838   → playing   ：房 6/11，杀  6，承伤  96（spike 96）  帧   6691  TTK中位 2.2s
  seed=26757   → playing   ：房 4/11，杀  5，承伤   0（     —）     帧  24000  TTK中位 7.0s
  seed=34676   → floor_clear：房 4/11，杀 26，承伤 112（spike 40）  帧  43267  TTK中位 6.2s
  seed=42595   → floor_clear：房 4/11，杀  5，承伤  32（spike 32）  帧  32104  TTK中位 7.0s

  · 模拟 6 局：233037 ms（平均 38839 ms/局）
  ✗ [S6] 不许走进死胡同、且必须真的在推进（真·卡死 1/6，帧上限用尽 5；平均推进 4.2 个房间）
  · 平均每局 30188 帧（503.1 秒模拟时间）；平均击杀 13；平均承伤 57
  · 逐层通过：第1层 4 / 第2层 2 / 第3层 0
  · TTK 参考：普通敌人 1.5~3.0 秒（契约），实测中位 TTK 4.37 秒（样本 83 个敌人）
```

**从这些数字可以直接读出的结论，我如实写：**

- **确定性门（S4/S5）在 6 次运行里每次都过**——这是这套系统里最硬的一条结论。
  同种子重跑两次，事件序列与地图指纹逐字节相同。
  （推导方式：日志证明"6 个门里只失败 S6"，所以 S1–S5 都通过，S4/S5 在 S1–S5 之内。
  这不是直接读数，是排除法。）
- **可玩性门（S6）不过。** log6 的"平均推进 4.2 房"低于 S6 自己要求的 5.0。
  log6 之前**四次连续失败**（2/2、2/2、2/2、4/4、4/4）。
- **第 3 层（BOSS 层）从未通过**：6 次日志里 `第3层 0` 是恒定值。
- **TTK 系统性偏慢**：契约是普通敌人 1.5~3.0s，最后一次实测中位 4.37s（超上限约 46%）。
- **6 局里有 5 局把 24000 帧跑完**，说明大部分时间花在"没死但也没打完"上。
  但要注意 `frames` 是**跨层累加**的（`tools/sim.gd:63-76`：每层重置局部的 `frames`，
  再 `res["frames"] += res2["frames"]`），所以 42659 / 43267 这两局的单层帧数其实远低于上限。
  `max_frames` 是**每层**的预算，不是整局的。
- 还有一处我解释不了的口径不一致：`playing` 状态的 run2 只有 6691 帧（远低于 24000），
  且最后一层 `state == "playing"`。按 `tools/sim.gd:171` 的循环条件，这需要
  `while` 因 `hit_stall` 的 `break` 退出；但 `hit_stall` 为真时 run 会被归到 `stalled`
  分支、日志前缀就不该是 `playing`。我没能定位这个不一致，如实标出来。
- 20 局跨全部 6 份日志的汇总：平均 17,143 帧 / 9.6 杀 / 36 承伤 / 6.1 房。

### 4.3 反向证据：承伤来源集中在尖刺

各局的 `承伤 XX（{ "spike": N }）` 括号里是伤害来源。log6：

| seed | 总承伤 | spike 承伤 | spike 占比 |
|---|---|---|---|
| 3000 | 56 | 24 | 43% |
| 10919 | 48 | 32 | 67% |
| 18838 | 96 | 96 | **100%** |
| 26757 | 0 | — | — |
| 34676 | 112 | 40 | 36% |
| 42595 | 32 | 32 | **100%** |

也就是说机器人挨的伤害里有很大一部分来自地形而不是敌人。这直接指向一个结论：
**S6 不过的根因更可能是机器人的走位（踩尖刺）而不是敌人太难或关卡堵死**——
`sim.gd` 的机器人策略里没有任何"避开尖刺"的分支（`tools/sim.gd:277-360` 只有贪心右行 /
跳坑 / 近战 / 后撤四个分支）。这是我在这次读代码时最想标出来的一条观察。

---

## 5. 跑起来

用仓库自带的 `tools/run.ps1`（会把 Godot 的 stdout/stderr 和退出码一起落盘）：

```powershell
# 生成层自检
& '.\tools\run.ps1' -Script tools/selftest.gd -Extra '-- --quick' -TimeoutSec 900

# 无头机器人可玩性门（6 局）
& '.\tools\run.ps1' -Script tools/sim.gd -Extra '-- --runs=6 --frames=24000' -TimeoutSec 1800 -Quiet

# 单局带轨迹（诊断用，会打印尾事件 / 轨迹尾 / 现场网格 / 钥匙门状态）
& '.\tools\run.ps1' -Script tools/sim.gd -Extra '-- --runs=1 --frames=12000 --seed=3000 --trace=1'

# 严格掩码可达性（关卡几何可玩性证明）
& '.\tools\run.ps1' -Script tools/probe10.gd -Extra '-- --seed=3000 --count=6 --strict=1' -TimeoutSec 600 -Quiet
```

直接跑 Godot（`sim.gd` 的默认值是 `runs=8 max_frames=40000`，`-Extra` 里必须显式覆盖）：

```powershell
E:\Godot\Godot_v4.7.2-stable_win64_console.exe --headless --path <项目目录> `
  --script tools/sim.gd -- --runs=6 --frames=24000
```

GUI：

```powershell
E:\Godot\Godot_v4.7.2-stable_win64_console.exe --headless --path <项目目录> --quit-after 400
```

操作键（`project.godot` 的 `[input]` 段）：`A/D` 移动，`Space` 跳，`J` 攻击，`K` 翻滚，
`L` 格挡，`W/S` 上下，`Q` 换武器，`U/I` 技能 1/2，`F` 交互（合成），`N` 切 AI 透明度面板，
`M` 调试地图。

**AI 导演层的模型后端**：本机 OpenAI 兼容端点 `http://127.0.0.1:8080/v1/chat/completions`，
模型名 `local-small`。不接后端时不需要任何配置——默认就是 L1 规则脑，游戏完整可玩。

打开 L2 模型脑的唯一入口是命令行参数 `--ai`（`main.gd:38`）：

```powershell
E:\Godot\...console.exe --path <项目目录> -- --ai=1
# HUD 会打印「种子 N · 模型导演 L2」；不加 --ai 则是「规则导演 L1」
```

按 `N` 可以开关 HUD 里的 **AI 透明度面板**——它直接读 `run.director.journal`，
显示最近 8 条导演日志（`main.gd:286-293`）。HUD 右下角还有一个帧时间读数
（`%.0f fps  frame %d`），注释里写着它是"模型不在关键路径上"的证据
（`main.gd:294`）——**但这个证据没有被采集过**，见 §7.5。

注意 `Cfg.AI.default_endpoint` 这个常量**和 `ModelBrain.url` 的默认值重复了**，
而 `ModelBrain._init` 不读常量、`set_model_backend()` 也没有任何调用点
（`grep set_model_backend` 只命中定义那一行）。也就是说 `Cfg.AI` 段里的端点配置
是摆设，改它不会生效。要换后端得改 `director.gd:235` 的字面量。

---

## 6. 目录结构

```
rogue-dshrl/
├── project.godot          Godot 4.7 / GL Compatibility / 60Hz 定步 / 13 个输入动作
├── ai/
│   ├── director.gd        导演层本体（430 行）：ctx / 校验器 / 三档降级 / 双缓冲 / 日志
│   └── bt.gd              敌人行为树（被 ctx 六维加权）
├── core/
│   ├── constants.gd       常量总表（338 行）：PHY / KERNEL / FRAME / DIFFICULTY / AI / CTX_KEYS
│   ├── jump_phys.gd       跳跃物理的解析式（selftest A 组全部断言它）
│   ├── rng.gd             可随机访问的每头独立流
│   └── digest.gd          指纹（16 hex）
├── gen/                   生成层：gridmap 695 行含 prune_traps；voxel_map 的 reach_from/reach_back_from
├── combat/framedata.gd    帧数据表（起手/命中/收招/取消窗口）
├── actors/ players / enemies / projectiles
├── run/                   level.gd 18,251B + run_state.gd（跨局 meta）
├── loot/items.gd          稀有度曲线 / 词条 / 纯函数合成
├── render/art.gd          程序化绘制
├── scenes/main.gd         装配 + 输入 + HUD + AI 透明度面板
├── tools/                 selftest / sim / 7 个 probe / run.ps1 / testkit
├── docs/                  设计文档与开发状态
└── logs/                  6 次无头模拟的真实日志
```

---

## 7. 已知边界 / 未完成

这一节是我读代码和日志之后**如实**写下的，不是自我批评的修辞。

### 7.1 可玩性门的现状

- **S6 从未通过。** 6 份日志全部 `通过 5 / 失败 1`，失败项固定是 S6。
  最好的一次（log6）是"真·卡死 1/6、帧上限用尽 5、平均推进 4.2 房"，
  而 S6 要求 `平均推进 >= 5.0`。
- **第 3 层（BOSS 层）从未在任何一次模拟中通过。**
- **TTK 超契约。** 最后一次实测中位 4.37s，契约上限 3.0s。
- 但是：**S4/S5 的确定性结论是站得住的**——6 次运行全部通过，且是逐字节比对。

### 7.2 文档与代码的实际不一致（我逐条核对过）

仓库自己的文档已经承认了 5 条差异（`docs/开发状态与遗留问题.md` §4）。
我另外找到下面几条，**它们没有被文档承认**：

| # | 文档 / 注释说 | 代码实际是 | 位置 |
|---|---|---|---|
| 1 | `docs/..._AI导演层_v0.1.md` §8 说模块分布在 `ai/ctx.gd`、`ai/brain.gd::RuleBrain`/`ModelBrain`、`ai/primitives.gd::validate`/`apply` | 这三个文件**都不存在**。全部实现在 `ai/director.gd` 一个文件里，`RuleBrain`/`ModelBrain` 是内部 class | §8 落地实现表 |
| 2 | §4.1「单次预算 ≤ 40 ms（`Cfg.AI.budget_ms`），超时直接降级到规则脑」 | 常量名是 `infer_budget_ms`（不是 `budget_ms`），且**全仓库无任何引用**——`grep Cfg.AI` 在 `ai/`、`gen/`、`run/` 里零命中。真实超时是 `ModelBrain.timeout_s = 2.0`，硬编码 | `director.gd:238` |
| 3 | §7 IV-4「模型超时不影响帧时间（双缓冲）」 | 双缓冲本身是真的（`tick()` 读 `buf_cur`），但 `on_room_enter` 里 `_request_async()` 是**同步调用**，`request()` 内部用 `Time.get_ticks_msec()` 循环等到 2s deadline。代码注释自己承认了："demo 里同步调一次本地端点……正式版应放到 Thread 里" | `director.gd:380,391-399` |
| 4 | 同上 §4.1「每房最多 1 次 query（`Cfg.AI.query_per_room = 1`）」 | 常量确实定义了，但代码用的是 `queries_this_room` 变量，**从未与常量比较**；常量只在文档里被引用 | `director.gd:366` |
| 5 | `Cfg.AI.query_per_floor = 2`（每层 ≤ 2 次） | 设计文档把这条写进了 IV-7 的"现状 ✅"，但 `queries_this_room` 在每次进房时清零，**没有任何按层的累计** | `director.gd:366` |
| 5b | `Cfg.AI` 段的 `max_drop_fps_delta`、`bt_frame_divisor`、`ctx_dims`、`http_timeout_ms`、`default_endpoint` | **全部零引用**（`grep` 只在 `constants.gd` 定义处命中）。`bt_frame_divisor` 注释说的"每帧最多推进 ceil(alive/4) 个 BT"这条性能约束因此**没有实现** | `constants.gd:285-290` |
| 6 | `Cfg.AI.shadow_mode = true`（注释「影子模式：只记录不生效」） | `Director._init()` 的 `shadow` 参数默认 `false`；`Cfg.AI.shadow_mode` 从未被读取 | `director.gd:345` |
| 7 | §4.2 三档降级、IV-1 说"L1 是默认档" | 属实。但 **L0 是一去不返的**：`fails>=3 → enabled=false`，而 `on_room_enter` 只在 `enabled` 为真时才重置任何状态，无法恢复。对局内可接受，"下一局恢复"没实现 | `director.gd:404-406` |
| 8 | `project.godot` 第 2-3 行与 `selftest.gd:49` 引用 `docs/横板动作Roguelike_机制拆解_v0.1.md`、`docs/..._地图生成方案_v0.1.md` | 这两份文档**不在仓库里**。`docs/` 下只有 AI 导演层和开发状态两份 | `docs/` |
| 9 | `docs/开发状态与遗留问题.md` §1 说 S1–S6「✅ 6/6 绿（6 局：真·卡死 0，第 1 层 6/6、第 2 层 5/6 通过，平均 27 杀）」§6.7 说"6 局模拟从真·卡死 3/6 变成 **0/6**" | **仓库里 6 份日志全部是 S6 失败。** 最新一份是"真·卡死 1/6"，平均击杀 13（不是 27），平均推进 4.2（不是"7.2→更高"） | `logs/` vs `docs/` |
| 10 | `docs/开发状态与遗留问题.md` §3.1 说"`tools/selftest.gd` → 61/61 通过" | 源码里是 **56 处断言 call site**（`t.ok()` 43 + `t.near()` 13）。差 5 条，可能是文档写于断言改版之前。**我没有跑过它，所以我不确定哪个对** | `tools/selftest.gd` |

第 2、3、5、5b 条是同一类问题：**`core/constants.gd` 的 `AI` 段（9 个字段）里有 8 个是
"文档驱动开发"留下的摆设**——`query_per_room`、`query_per_floor`、`infer_budget_ms`、
`max_drop_fps_delta`、`bt_frame_divisor`、`ctx_dims`、`http_timeout_ms`、`default_endpoint`
没有一个被代码读过（`shadow_mode` 也没被读，只是它的语义恰好和默认值撞上了）。
真正生效的参数全部硬编码在 `director.gd` / `constants.gd` 的其它段里。
这是这套项目最值得拿来讨论的一个工程教训：**把参数写进常量表不等于接上了线**，
而且它会持续误导读者——包括设计文档自己。

### 7.3 功能缺口（文档自己承认的，我核对属实）

- **局内升级不存在**：只有开局一次性加成 + 击杀回血；跨局用 `run_state.Meta` 给 cell 换属性。
  "进房间选词条"没做。
- **合成没有界面**：只在背包里同类型两件之间按 `F`，稀有度 +1、词条取并集（≤3）、互斥词条拒绝。
  规则是纯函数（`loot/items.gd::fuse`），没有配方表 / 合成 UI。
- **平衡报告口径不一致**：`sim.gd` 打印 `伤害成长 ×(1+0.030)^(层-1)`，
  而 `Cfg.DIFFICULTY.dmg_per_floor = 0.06`。文档 §4.4 承认「待统一」，我核对属实。
- **BOSS 血量**：`level._spawn_boss` 里乘了 0.35，文档说按"25~35 秒可打完"压过一档，
  **但我没有在无头模拟里看到任何一局打到 BOSS**（第 3 层 0 通过），所以这个数字没被验证过。
- **美术**：`render/art.gd` 一个文件全包程序化绘制，换贴图时要改 `draw_*` 系列。
- **物理口径是分裂的**：生成用整数定点（跨机器逐位一致），运行时用浮点（同一二进制一致）。
  文档 §4.3 已承认。理由成立（运动核 K 由运行时物理解析式编译，两边必须同模型），
  但这意味着**跨平台的世界线一致性没有被证明**。

### 7.4 证据系统的弱点

无头机器人只证明"朴素贪心策略能走通多少"，它**不是**可玩性证明：

- 它不会避尖刺（§4.3 的承伤数据是直接证据）；
- 它的规划图与运行时的滑动/贴边行为不完全等价，偶发"进得去、算不出不来"的局部死锁；
- 所以"机器人跑不通"**不能推出**"关卡坏了"——项目自己也踩过这个坑
  （文档 §6.7：补了"挣扎"之后真·卡死从 3/6 降到 0/6，说明之前是机器人不会脱困）。

真正的几何正确性证据是 `gen/gridmap.gd::prune_traps` 的**不对称闭包**：

```gdscript
var f: Dictionary = open_map.reach_from(kernel, spawn, false)      # 入口：宽松掩码
var b: Dictionary = open_map.reach_back_from(kernel, goal, true)   # 出口：严格掩码
# 宽松可达 \ 严格可离开 = 进得去、出不来 → 填实（保护格除外）
```

宽松判据高估"能进去"、严格判据低估"能出来"，两者之差正是**单向陷阱区**。
填实是单调的（只缩小可达集），不会造出新陷阱；陷阱格也不可能是
"出生点→终点"路径的中间节点，所以填掉它不可能断开通路。这两点是这个算法成立的全部依据，
代码注释和文档都写清了。

### 7.5 我这次没做的事

- 没有运行 `selftest.gd` / `sim.gd` / 任何 `probe`。所有数字来自**读源码**和**读 `logs/` 里已有的日志**。
- 没有接任何模型后端，所以 **L2 模型脑从未被端到端跑过**。
  `ModelBrain.request()` 的 HTTP 收发、`parse_reply` 对真实模型输出的鲁棒性，
  都是"读了代码觉得对"，不是"验证过"。
- `logs/` 里只有 `sim.gd` 的输出，没有 `selftest.gd` 的输出。
  所以 §3 表格里 selftest 的各组断言内容是我按源码整理的，**通过情况我不知道**。
- 没有做性能画像。"模型不在关键路径上"的帧时间影响（`Cfg.AI.max_drop_fps_delta = 2.0`）
  没有测量数据。

---

## 8. 设计文档

| 文档 | 内容 | 状态 |
|---|---|---|
| `docs/横板动作Roguelike_AI导演层_v0.1.md` | 上下文 / 指令语言 / 校验器 / 异步与降级 / 接口 / 自检清单 IV-1~IV-7 | 在仓库，但与代码有 §7.2 列出的差异 |
| `docs/开发状态与遗留问题.md` | 代码实际状态、本轮修掉的真 bug、遗留问题、文档 vs 代码差异 | 在仓库。**§1/§6.7 的 S6 结论与 `logs/` 矛盾** |
| 机制拆解 / 地图生成方案 v0.1 | 手感、状态机、伤害结算；矩阵 / 运动核 / 可达性 / 六头 | **不在仓库**（被代码引用） |
