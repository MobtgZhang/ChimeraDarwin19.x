# ChimeraOS 系统架构文档

## 1. 项目概述

ChimeraOS 是一个使用 **Zig** 语言从零编写的操作系统，目标是在 x86_64 / ARM64 架构上实现 macOS 应用程序的二进制兼容。项目采用与 Apple XNU 类似的混合内核设计，结合 Mach 微内核和 BSD 兼容层，为 Mach-O 格式的可执行文件提供原生运行环境。

## 2. 架构分层

```
┌──────────────────────────────────────────────────────────┐
│                   macOS 应用程序 (.app)                    │
├──────────────────────────────────────────────────────────┤
│  Frameworks 层    AppKit / Foundation / CoreGraphics      │
├──────────────────────────────────────────────────────────┤
│  Runtime 层       dyld 动态链接器 / Objective-C Runtime     │
├──────────────────────────────────────────────────────────┤
│  System Libs     libSystem (libc / libdispatch / libxpc)  │
├──────────────────────────────────────────────────────────┤
│  Kernel          Z-Kernel (Mach IPC + BSD POSIX + IOKit)  │
├──────────────────────────────────────────────────────────┤
│  Hardware        x86_64 / ARM64                           │
└──────────────────────────────────────────────────────────┘
```

## 3. 内核子系统

### 3.1 Mach 微内核层

Mach 层提供操作系统最核心的原语：

| 模块 | 说明 |
|------|------|
| `mach/port.zig` | Mach Port 定义与权限管理，进程间通信的基础端点 |
| `mach/message.zig` | `mach_msg()` 收发实现，支持同步/异步消息传递 |
| `mach/task.zig` | Task（进程抽象），资源容器与地址空间隔离 |
| `mach/thread.zig` | Thread 管理与调度接口 |
| `mach/clock.zig` | Mach 时钟服务，定时器与告警处理 |
| `mach/vm/map.zig` | VM Map，虚拟地址空间映射管理 |
| `mach/vm/object.zig` | VM Object，匿名/文件映射对象 |
| `mach/vm/pager.zig` | 默认分页器 |

### 3.2 BSD 兼容层（POSIX）

BSD 层在 Mach 之上构建 POSIX 标准接口：

| 模块 | 说明 |
|------|------|
| `bsd/syscall.zig` | Darwin 系统调用表与分发器 |
| `bsd/proc.zig` | BSD 进程模型（kqueue, wait） |
| `bsd/signal.zig` | POSIX 信号处理 |
| `bsd/vfs/vnode.zig` | VNode 抽象层 |
| `bsd/vfs/devfs.zig` | `/dev` 设备文件系统 |

### 3.3 I/O Kit 驱动框架

| 模块 | 说明 |
|------|------|
| `iokit/registry.zig` | IORegistry 设备树 |
| `iokit/service.zig` | IOService 基类 |
| `iokit/drivers/pcie.zig` | PCIe 总线扫描驱动 |
| `iokit/drivers/pit.zig` | PIT 8254 可编程间隔定时器（1000 Hz 系统时钟） |
| `iokit/drivers/rtc.zig` | CMOS 实时时钟（BCD/BIN 自动转换、24 小时制） |
| `iokit/drivers/keyboard.zig` | PS/2 键盘驱动（扫描码翻译、修饰键追踪、US QWERTY） |
| `iokit/drivers/mouse.zig` | PS/2 鼠标驱动（3 字节数据包、绝对坐标、屏幕边界钳制） |
| `iokit/drivers/framebuffer.zig` | UEFI GOP 帧缓冲显示驱动（像素级读写、矩形填充） |
| `iokit/drivers/ata.zig` | ATA/IDE PIO 模式磁盘驱动（设备识别、扇区读写） |
| `iokit/drivers/ac97.zig` | AC'97 音频编解码器驱动（初始化、音量控制） |

### 3.4 内存管理

| 模块 | 说明 |
|------|------|
| `mm/pmm.zig` | 物理内存管理器（页帧分配） |
| `mm/slab.zig` | Slab 分配器（小对象快速分配） |
| `lib/buddy.zig` | Buddy 分配器（大块连续内存分配） |

### 3.5 架构相关代码 (x86_64)

| 模块 | 说明 |
|------|------|
| `arch/x86_64/gdt.zig` | 全局描述符表（内核/用户态段） |
| `arch/x86_64/idt.zig` | 中断描述符表（256 中断向量） |
| `arch/x86_64/paging.zig` | 4 级页表管理 |
| `arch/x86_64/serial.zig` | 串口驱动（调试输出） |
| `arch/x86_64/pic.zig` | 8259 PIC 可编程中断控制器（IRQ 重映射至向量 32-47） |
| `arch/x86_64/ports.zig` | 共享端口 I/O 原语（outb/inb/outw/inw/outl/inl/rdtsc） |

### 3.6 桌面图形界面 (GUI)

| 模块 | 说明 |
|------|------|
| `gui/desktop.zig` | 桌面合成器主模块，协调壁纸、窗口、菜单、Dock |
| `gui/graphics.zig` | 2D 图形原语（矩形、圆角矩形、圆、直线、渐变、文字） |
| `gui/window.zig` | 窗口管理器（macOS 风格标题栏、交通灯按钮、拖拽、Z 序） |
| `gui/menubar.zig` | macOS 风格菜单栏（Apple 图标、应用名、菜单项、时钟） |
| `gui/dock.zig` | macOS 风格 Dock 栏（应用图标、悬停效果、运行指示器） |
| `gui/widgets.zig` | UI 组件库（按钮、标签、文本输入框） |
| `gui/cursor.zig` | 鼠标光标渲染（标准箭头） |
| `gui/icons.zig` | 系统图标数据（Apple、Finder、终端、设置、文件夹等） |
| `gui/font.zig` | 8×16 VGA 位图字体（ASCII 32-126） |
| `gui/color.zig` | 颜色类型、Alpha 混合、macOS 风格主题色板 |
| `gui/event.zig` | GUI 事件类型与事件队列 |

## 4. 用户态组件

### 4.1 Mach-O 加载器

| 模块 | 说明 |
|------|------|
| `loader/macho/parser.zig` | Mach-O 头部与 Load Command 解析 |
| `loader/macho/fat.zig` | Fat Binary（Universal）处理 |
| `loader/macho/segments.zig` | Segment/Section 映射 |

### 4.2 系统库（规划中）

- `libsystem_kernel` — 系统调用包装
- `libc` — C 标准库基础函数
- `libdispatch` — Grand Central Dispatch (GCD)
- `libpthread` — POSIX 线程

### 4.3 Objective-C 运行时（规划中）

- `objc_msgSend` 消息派发
- Class / Metaclass 结构管理
- ARC 自动引用计数

## 5. 启动流程（多架构 UEFI）

各架构统一交接 `BootInfo`（GOP 帧缓冲描述 + UEFI 内存图），再进入 `kernelMain()`。GOP 的 **像素格式**（BGRX / RGBX 等）记录在 `FramebufferInfo.pixel_format` 中，GUI 通过 `lib/pixel_format.zig` 将逻辑 xRGB 主题色转换为帧缓冲原生布局。

| 架构 | 固件入口镜像 | 引导源文件 | 说明 |
|------|----------------|------------|------|
| x86_64 | `BOOTX64.efi` | [src/main.zig](src/main.zig) | `std.os.uefi`，Zig 直接链接 UEFI PE |
| aarch64 | `BOOTAA64.efi` | [src/main.zig](src/main.zig) | 同上 |
| riscv64 | `BOOTRISCV64.efi` | [src/main_riscv64.zig](src/main_riscv64.zig) | freestanding ELF → `riscv64-linux-gnu-objcopy -O pei-riscv64-little` → [scripts/fix_pe_imagebase.py](scripts/fix_pe_imagebase.py) |
| loongarch64 | `BOOTLOONGARCH64.efi` | [src/main_loong64.zig](src/main_loong64.zig) | 同上（`pei-loongarch64` + `loongarch64-linux-gnu-objcopy`） |

RISC-V 另支持 **非 UEFI** 检测：若 `a1` 处不是 EFI 系统表签名，则使用 QEMU `virt` 的简化内存图回退（便于 `-kernel` 调试）。

```
UEFI 固件
  └─► BOOT*.efi（上表）
        ├── 查询 GOP（含 pixel_format）/ 可选控制台
        ├── 获取内存映射并 ExitBootServices
        └─► kernelMain() (src/kernel/main.zig)
              ├── Phase 0: HAL 早期初始化 + 日志
              ├── Phase 1: 架构相关 CPU / 中断 / MMU
              ├── Phase 2: PMM + Buddy
              ├── Phase 3–4: 定时器与输入（x86_64 为 PIT/RTC/PS/2，其余多为桩）
              ├── Phase 5: GOP 帧缓冲（按 pixel_format 解释像素）
              ├── Phase 6–9: VM、Mach、BSD、VFS、IOKit（依架构裁剪驱动）
              ├── Phase 10: 桌面 GUI（System Info 等按 `arch.name` 显示）
              └── 桌面事件循环
```

### 5.1 参考规范（外部资源）

- [UEFI 规范](https://uefi.org/specifications) — GOP、内存描述符、`ExitBootServices`。
- [tianocore/edk2](https://github.com/tianocore/edk2) — `MdePkg` 头文件与固件行为对照。

## 6. 构建系统

项目使用 Zig 原生构建系统 (`build.zig`)：

- **构建目标**: `-Darch=x86_64`（默认）| `aarch64` | `riscv64` | `loong64` | `mips64el`
- **输出目录**: `build/`（或 `zig build --prefix <dir>`）
- **构建命令**: `zig build --prefix build` 或 `bash scripts/build.sh`
- **QEMU 运行**: `zig build run` 或 `bash scripts/run.sh`（LoongArch 的 `zig build run` 会委托 `scripts/run.sh` 并可通过环境变量 `CHIMERA_BUILD_PREFIX` 指定安装前缀）
- **磁盘镜像**: `zig build image` 或 `bash scripts/create_image.sh`
- **额外工具**: LoongArch / RISC-V 的 PE 转换依赖对应 `*-linux-gnu-objcopy` 与 `python3`（`fix_pe_imagebase.py`）

## 7. 目录结构

```
ChimeraOS/
├── build.zig              # 顶层构建脚本
├── build.zig.zon          # 依赖与元数据声明
├── src/                   # 源代码
│   ├── main.zig           # UEFI 引导入口（x86_64 / aarch64）
│   ├── main_loong64.zig   # LoongArch64 UEFI + 可选直接启动
│   ├── main_riscv64.zig   # RISC-V64 UEFI + 可选直接启动
│   ├── kernel/            # 内核层
│   │   ├── main.zig       # 内核入口与初始化流程
│   │   ├── arch/x86_64/   # x86_64 架构代码（GDT, IDT, PIC, Paging, Serial, Ports）
│   │   ├── mach/          # Mach 微内核子系统
│   │   ├── bsd/           # BSD POSIX 兼容层
│   │   ├── iokit/         # I/O Kit 驱动框架
│   │   │   └── drivers/   # 硬件驱动（PCIe, PIT, RTC, KBD, Mouse, FB, ATA, AC97）
│   │   ├── mm/            # 内存管理
│   │   └── lib/           # 内核内部库
│   ├── gui/               # 桌面图形界面
│   │   ├── desktop.zig    # 桌面合成器（主模块）
│   │   ├── graphics.zig   # 2D 图形原语
│   │   ├── window.zig     # 窗口管理器
│   │   ├── menubar.zig    # macOS 风格菜单栏
│   │   ├── dock.zig       # macOS 风格 Dock 栏
│   │   └── ...            # 组件、光标、图标、字体、颜色、事件
│   ├── loader/            # Mach-O 加载器
│   │   └── macho/         # Mach-O 解析与段映射
│   └── lib/               # 公共库（日志、像素格式等）
├── scripts/               # 构建与运行脚本
│   ├── build.sh           # 构建脚本
│   ├── test.sh            # 测试脚本
│   ├── run.sh             # QEMU 模拟运行
│   └── create_image.sh    # 磁盘镜像创建
└── docs/                  # 项目文档
    ├── architecture.md    # 架构文档（本文件）
    └── features.md        # 特性与路线图

```
