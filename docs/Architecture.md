# Darwin 19.x Z-Kernel 架构文档

## 一、项目概述

**Darwin 19.x Z-Kernel** 是一个用 Zig 语言编写的类 macOS/Darwin 操作系统内核，版本目标为 XNU 19.6.0 兼容性。项目支持 x86_64、aarch64、riscv64、loongarch64 等多种架构，通过 UEFI 固件启动运行。

### 1.1 项目目标

- 实现 Darwin 19.x（macOS Catalina 10.15）核心功能兼容性
- 使用 Zig 语言提供编译时安全和现代 C++ 无法实现的特性
- 支持多种 CPU 架构的统一内核代码
- 构建一个可运行在 QEMU 模拟器上的类 macOS 环境

### 1.2 技术栈

| 组件 | 技术 |
|------|------|
| 编程语言 | Zig 0.13+ |
| 构建系统 | Zig Build (build.zig) |
| 固件接口 | UEFI 2.x |
| 目标架构 | x86_64, aarch64, riscv64, loongarch64 |
| 模拟器 | QEMU |

---

## 二、系统架构总览

Darwin 19.x Z-Kernel 采用与 XNU 类似的微内核 + 宏内核混合架构：

```
┌─────────────────────────────────────────────────────────────┐
│                        User Space                            │
│  ┌─────────┐  ┌──────────┐  ┌─────────┐  ┌─────────────┐ │
│  │launchd  │  │Mach IPC   │  │BSD API  │  │System Calls │ │
│  └────┬────┘  └─────┬────┘  └────┬────┘  └──────┬──────┘ │
└───────┼─────────────┼─────────────┼────────────────┼──────────┘
        │             │             │                │
        ▼             ▼             ▼                ▼
┌───────────────────────────────────────────────────────────────┐
│                      Kernel Interface                         │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              Mach API (IPC + VM + Scheduling)           │ │
│  └─────────────────────────────────────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │              BSD Layer (POSIX Compatibility)              │ │
│  └─────────────────────────────────────────────────────────┘ │
└─────────────────────────┬───────────────────────────────────┘
                          │
┌─────────────────────────┼───────────────────────────────────┐
│                     IOKit Framework                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │IORegistry    │  │IOService     │  │IODeviceTree      │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
└─────────────────────────┼───────────────────────────────────┘
                          │
┌─────────────────────────┼───────────────────────────────────┐
│                     Hardware Layer                            │
│  ┌─────────┐  ┌───────┴───────┐  ┌────────────────────┐   │
│  │CPU/SMP  │  │    Drivers     │  │  Virtual Memory   │   │
│  │Scheduler│  │(PCI/ATA/USB)  │  │  (PMM/Buddy/Slab)│   │
│  └─────────┘  └───────────────┘  └────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
```

---

## 三、核心子系统

### 3.1 Mach 内核子系统

Mach 是 XNU 的微内核核心，提供进程/线程调度、虚拟内存管理和 IPC 通信。

#### 3.1.1 Mach Task (`src/kernel/mach/task.zig`)

Task 是 Mach 中的资源容器，对应 BSD 层的进程概念。

**核心结构体：**
```zig
pub const Task = struct {
    pid: u32,
    name: [64]u8,
    state: TaskState,
    port_namespace: port_mod.PortNamespace,
    task_port: u32,
    parent_pid: u32,
    priority: u8,
    vm_map: *vm_map_mod.VMMap,
    ledger: u32,
};
```

**核心 API：**
| 函数 | 说明 |
|------|------|
| `initKernelTask()` | 初始化内核任务（PID 0） |
| `createTask(name, parent)` | 创建新任务 |
| `lookupTask(pid)` | 按 PID 查找任务 |
| `terminateTask(pid)` | 终止任务 |
| `suspendTask(pid)` | 挂起任务 |
| `resumeTask(pid)` | 恢复任务 |
| `taskGetInfo(pid, flavor, buf)` | 获取任务信息 |

#### 3.1.2 Mach Thread (`src/kernel/mach/thread.zig`)

Thread 是 Mach 中的可调度执行单元，每个 Thread 属于一个 Task。

**核心结构体：**
```zig
pub const Thread = struct {
    tid: u32,
    task_pid: u32,
    state: ThreadState,
    priority: u8,
    policy: ThreadPolicyFlavor,
    kernel_stack_base: u64,
    kernel_stack_top: u64,
    saved_rsp: u64,
    user_stack: u64,
    user_entry: u64,
};
```

**调度策略：**
| 优先级 | 值 | 说明 |
|--------|-----|------|
| IDLE | 0 | 最低优先级，空闲线程 |
| LOW | 16 | 低优先级 |
| NORMAL | 31 | 普通优先级 |
| HIGH | 48 | 高优先级 |
| REALTIME | 63 | 实时优先级 |

**核心 API：**
| 函数 | 说明 |
|------|------|
| `init()` | 初始化线程子系统 |
| `createKernelThread(name, priority, entry)` | 创建内核线程 |
| `schedule()` | 调度器主函数 |
| `timerTick()` | 时钟中断调度 |
| `contextSwitch()` | 上下文切换 |

#### 3.1.3 Mach Port 和 IPC (`src/kernel/mach/port.zig`, `ipc_table.zig`, `message.zig`)

Mach IPC 是 Darwin 的核心进程间通信机制，基于 Port 实现消息传递。

**Port Right 类型：**
| 类型 | 说明 |
|------|------|
| `send` | 发送权限 |
| `receive` | 接收权限 |
| `send_once` | 单次发送权限 |
| `port_set` | 端口集合 |
| `dead_name` | 已销毁端口的名称 |

**消息结构体：**
```zig
pub const MsgHeader = extern struct {
    bits: u32,
    size: u32,
    remote_port: u32,
    local_port: u32,
    voucher_port: u32,
    id: u32,
};
```

**核心 API：**
| 函数 | 说明 |
|------|------|
| `machMsgTrap(args)` | Mach 消息陷阱 |
| `machMsg(args)` | Mach 消息发送/接收 |
| `ipcAllocPort(right)` | 分配端口 |
| `ipcDeallocPort(name)` | 释放端口 |

#### 3.1.4 Mach Host (`src/kernel/mach/host.zig`)

Host 是系统级的 Mach 对象，提供机器信息和特权操作。

**核心 API：**
| 函数 | 说明 |
|------|------|
| `getHostBasicInfo()` | 获取主机基本信息 |
| `getProcessorCount()` | 获取 CPU 数量 |
| `getMachineType()` | 获取机器类型字符串 |
| `getOsVersion()` | 获取 OS 版本 |

#### 3.1.5 Mach Voucher (`src/kernel/mach/voucher.zig`)

Voucher 用于 Mach IPC 消息中的资源归属追踪。

**Voucher 属性键：**
| 键 | 说明 |
|----|------|
| `cpu_time` | CPU 时间记账 |
| `memory_lock_grp` | 内存锁定组 |
| `io_bandwidth` | IO 带宽记账 |

#### 3.1.6 Mach Ledger (`src/kernel/mach/ledger.zig`)

Ledger 提供任务/线程的资源记账功能。

**记账资源类型：**
| 类型 | 说明 |
|------|------|
| `cpu_time` | CPU 使用时间 |
| `thread_cpu_time` | 线程 CPU 时间 |
| `memory_used` | 虚拟内存使用 |
| `memory_phys` | 物理内存使用 |
| `io_physical` | 物理 IO |
| `io_logical` | 逻辑 IO |

#### 3.1.7 Mach Processor (`src/kernel/mach/processor.zig`)

Processor 管理 CPU 和处理器集合。

**核心 API：**
| 函数 | 说明 |
|------|------|
| `registerProcessor(id, cpu_type)` | 注册处理器 |
| `getProcessorCount()` | 获取处理器数量 |
| `processorSetAssignProcessor(ps_id, proc_id)` | 分配处理器到集合 |

---

### 3.2 虚拟内存子系统

#### 3.2.1 VM Map (`src/kernel/mach/vm/map.zig`)

VM Map 管理每个任务的虚拟地址空间。

**核心结构体：**
```zig
pub const VMMap = struct {
    entries: [MAX_ENTRIES]VMEntry,
    entry_count: usize,
    min_addr: u64,
    max_addr: u64,
    pml4_phys: u64,
    lock: SpinLock,
};

pub const VMEntry = struct {
    start: u64,
    end: u64,
    object: ?*VMObject,
    offset: u64,
    protection: VMProt,
    max_protection: VMProt,
    inherit: InheritFlag,
    wired: bool,
    active: bool,
};
```

**内存保护标志：**
```zig
pub const VM_PROT_READ = VMProt{ .read = true };
pub const VM_PROT_RW = VMProt{ .read = true, .write = true };
pub const VM_PROT_RX = VMProt{ .read = true, .execute = true };
pub const VM_PROT_RWX = VMProt{ .read = true, .write = true, .execute = true };
```

#### 3.2.2 VM Object (`src/kernel/mach/vm/object.zig`)

VM Object 是虚拟内存的后备存储。

**对象类型：**
| 类型 | 说明 |
|------|------|
| `anonymous` | 匿名内存（零页） |
| `copy_on_write` | 写时复制对象 |
| `device` | 设备内存映射 |
| `physical` | 物理内存页 |
| `pager` | 分页器后备 |

**核心 API：**
| 函数 | 说明 |
|------|------|
| `createAnonymous(size)` | 创建匿名对象 |
| `createDevice(phys, size)` | 创建设备对象 |
| `createShadowObject(parent)` | 创建 COW 影子对象 |
| `fault(offset)` | 页错误处理 |

#### 3.2.3 VM Pager (`src/kernel/mach/vm/pager.zig`)

Pager 处理页面的换入/换出操作。

**分页器类型：**
| 类型 | 说明 |
|------|------|
| `anonymous` | 匿名分页器（零页分配） |
| `device` | 设备分页器 |
| `vnode` | 文件系统分页器 |
| `swap` | 交换空间分页器 |

---

### 3.3 BSD 层子系统

BSD 层提供 POSIX 兼容性和 Unix 文件系统抽象。

#### 3.3.1 BSD Process (`src/kernel/bsd/proc.zig`)

BSD Process 建立在 Mach Task 之上，添加文件描述符表、凭证和进程组。

**进程状态：**
```zig
pub const ProcState = enum(u8) {
    embryo,    // 创建中
    runnable,  // 可运行
    sleeping,   // 睡眠中
    stopped,   // 已停止
    zombie,    // 僵尸进程
};
```

**文件描述符：**
| FD | 默认目标 |
|----|----------|
| 0 | stdin (/dev/null) |
| 1 | stdout (/dev/console) |
| 2 | stderr (/dev/console) |

#### 3.3.2 BSD Signal (`src/kernel/bsd/signal.zig`)

Signal 处理 POSIX 信号机制。

**信号列表（Darwin 编号）：**
| 信号 | 编号 | 默认动作 |
|------|------|----------|
| SIGHUP | 1 | 终止 |
| SIGINT | 2 | 终止 |
| SIGQUIT | 3 | 终止+Core |
| SIGKILL | 9 | 终止 |
| SIGSEGV | 11 | 终止+Core |
| SIGCHLD | 20 | 忽略 |
| SIGUSR1 | 30 | 终止 |
| SIGUSR2 | 31 | 终止 |

#### 3.3.3 BSD Syscall (`src/kernel/bsd/syscall.zig`)

系统调用分派表，处理 BSD 和 Darwin 特有调用。

**系统调用表（部分）：**
| 编号 | 名称 | 说明 |
|------|------|------|
| 1 | exit | 进程退出 |
| 2 | fork | 进程复制 |
| 3 | read | 读文件 |
| 4 | write | 写文件 |
| 5 | open | 打开文件 |
| 6 | close | 关闭文件 |
| 197 | mmap | 内存映射 |
| 317 | mach_msg_trap | Mach 消息 |

#### 3.3.4 BSD Pipe (`src/kernel/bsd/pipe.zig`)

Pipe 提供进程间单向字节流通信。

#### 3.3.5 BSD KAUTH (`src/kernel/bsd/kauth.zig`)

KAUTH 是 BSD 授权框架，提供文件系统、进程和套接字授权钩子。

**授权作用域：**
| 作用域 | 说明 |
|--------|------|
| `vnode` | 文件系统操作 |
| `socket` | 套接字操作 |
| `process` | 进程操作 |
| `iokit_user_client` | IOKit 客户端 |

#### 3.3.6 BSD Proc Info (`src/kernel/bsd/proc_info.zig`)

Proc Info 提供进程信息查询接口。

---

### 3.4 VFS 子系统

#### 3.4.1 VNode (`src/kernel/bsd/vfs/vnode.zig`)

VNode 是文件系统中所有对象的抽象。

**VNode 类型：**
| 类型 | 说明 |
|------|------|
| `regular` | 常规文件 |
| `directory` | 目录 |
| `block_device` | 块设备 |
| `char_device` | 字符设备 |
| `symlink` | 符号链接 |
| `socket` | 套接字 |
| `fifo` | 命名管道 |

**核心 API：**
| 函数 | 说明 |
|------|------|
| `allocVNode(vtype, ops, name)` | 分配 VNode |
| `vnodeCreate(vtype, ops, name)` | 创建 VNode |
| `registerMount(fs_type, root, ops, device)` | 注册挂载点 |

#### 3.4.2 DevFS (`src/kernel/bsd/vfs/devfs.zig`)

DevFS 在 `/dev` 下提供设备节点。

**内置设备：**
| 设备 | 主编号 | 次编号 | 类型 |
|------|--------|--------|------|
| null | 1 | 3 | 字符设备 |
| zero | 1 | 5 | 字符设备 |
| console | 5 | 1 | 字符设备 |
| random | 8 | 0 | 字符设备 |
| urandom | 8 | 1 | 字符设备 |

#### 3.4.3 VFS Syscalls (`src/kernel/bsd/vfs/vfs_syscalls.zig`)

VFS 系统调用实现文件系统操作。

---

### 3.5 IOKit 框架

IOKit 是 Apple 的设备驱动框架，基于 C++ 风格的对象模型。

#### 3.5.1 IORegistry (`src/kernel/iokit/registry.zig`)

IORegistry 是设备树结构，存储所有 IOKit 对象。

**核心 API：**
| 函数 | 说明 |
|------|------|
| `allocNode(class_name, name)` | 分配注册表节点 |
| `findByClass(class)` | 按类名查找 |
| `findByProperty(key, value)` | 按属性查找 |
| `fromPath(path)` | 按路径查找 |

#### 3.5.2 IOService (`src/kernel/iokit/service.zig`)

IOService 是所有驱动的基类。

**服务状态：**
```zig
pub const ServiceState = enum(u8) {
    inactive,
    registered,
    matched,
    started,
    stopped,
};
```

**生命周期：**
1. `probe()` - 检测硬件
2. `start()` - 启动服务
3. `stop()` - 停止服务

#### 3.5.3 Platform Expert (`src/kernel/iokit/platform.zig`)

Platform Expert 管理 ACPI 和设备树集成。

**平台类型：**
| 类型 | 说明 |
|------|------|
| `generic` | 通用平台 |
| `acpi` | ACPI 平台 |
| `device_tree` | 设备树平台 |

#### 3.5.4 Power Management (`src/kernel/iokit/powermanagement.zig`)

电源管理子系统。

---

### 3.6 Mach-O 加载器

#### 3.6.1 Parser (`src/loader/macho/parser.zig`)

Mach-O 二进制格式解析器。

**支持的 CPU 类型：**
| 类型 | 值 |
|------|-----|
| x86_64 | 0x01000007 |
| ARM64 | 0x0100000C |
| RISC-V64 | 0x80000000 |
| LoongArch64 | 0x80000000 |

**Load Command 类型：**
| LC | 说明 |
|----|------|
| LC_SEGMENT_64 | 64位段 |
| LC_SYMTAB | 符号表 |
| LC_DYSYMTAB | 动态符号表 |
| LC_MAIN | 程序入口点 |
| LC_UUID | UUID |
| LC_DYLD_INFO | dyld 信息 |
| LC_DYLD_CHAINED_FIXUPS | 链式修复 |

#### 3.6.2 Segments (`src/loader/macho/segments.zig`)

段加载器，处理 __TEXT、__DATA 等标准段。

#### 3.6.3 DyLinker (`src/loader/macho/dylinker.zig`)

动态链接器，支持 dyld 风格符号绑定。

#### 3.6.4 TBD (`src/loader/macho/tbd.zig`)

Text-Based Dylib 解析器，支持 Swift 5.3+。

---

### 3.7 内存管理子系统

#### 3.7.1 PMM (`src/kernel/mm/pmm.zig`)

物理内存管理器，使用位图跟踪空闲页。

#### 3.7.2 Slab (`src/kernel/mm/slab.zig`)

Slab 分配器，为常用对象大小提供缓存。

**缓存规格：**
| 缓存 | 对象大小 |
|------|----------|
| cache_32 | 32 字节 |
| cache_64 | 64 字节 |
| cache_128 | 128 字节 |
| cache_256 | 256 字节 |
| cache_512 | 512 字节 |
| cache_1024 | 1024 字节 |

#### 3.7.3 Buddy (`src/kernel/lib/buddy.zig`)

伙伴分配器，管理 4KB-256KB 的内存块。

---

## 四、架构支持

### 4.1 支持的架构

| 架构 | 目录 | 上下文切换 | 说明 |
|------|------|-----------|------|
| x86_64 | `arch/x86_64/` | ✓ | 主要开发架构 |
| aarch64 | `arch/aarch64/` | ✓ | ARM 64位 |
| riscv64 | `arch/riscv64/` | ✓ | RISC-V 64位 |
| loongarch64 | `arch/loong64/` | ✓ | 龙芯64位 |

### 4.2 内核虚拟地址空间布局

| 架构 | 内核基址 | 内核顶部 |
|------|----------|----------|
| x86_64 | 0xFFFF800000000000 | 0xFFFFFFFFFFFF0000 |
| aarch64 | 0xFFFF000000000000 | 0xFFFFFFFFFFFF0000 |
| loongarch64 | 0x9000000000000000 | 0x9000FFFFFFFF0000 |

---

## 五、启动流程

```
UEFI Firmware
    │
    ▼
bootMain() [src/main.zig]
    │
    ├─► arch.earlyInit()      // 架构早期初始化
    ├─► arch.cpuInit()         // CPU 表（GDT/IDT）
    ├─► pmm.init()            // 物理内存管理
    ├─► initBuddyZone()       // 伙伴分配器
    ├─► arch.timerInit()      // 定时器初始化
    ├─► arch.inputInit()     // 输入设备
    ├─► framebuffer.init()   // 帧缓冲
    ├─► mach_vm_map.initKernelMap()  // 虚拟内存
    ├─► mach_task.initKernelTask()  // Mach 任务
    ├─► mach_thread.init()    // 线程调度器
    ├─► bsd_syscall.init()    // BSD 系统调用
    ├─► bsd_proc.init()       // BSD 进程
    ├─► bsd_vnode.init()      // VFS
    ├─► iokit_registry.init() // IOKit 注册表
    ├─► iokit_pcie.init()     // PCI 总线
    │
    ▼
desktop.init()                // GUI 桌面
    │
    ▼
while (true) {               // 主事件循环
    keyboard.poll()           // 键盘轮询
    mouse.poll()              // 鼠标轮询
    desktop.render()           // 桌面渲染
    arch.cpuRelax()           // CPU 休眠
}
```

---

## 六、构建和运行

### 6.1 构建命令

```bash
# x86_64 (默认)
zig build -Darch=x86_64

# aarch64
zig build -Darch=aarch64

# riscv64
zig build -Darch=riscv64

# loongarch64
zig build -Darch=loongarch64
```

### 6.2 运行命令

```bash
# 运行 x86_64 版本
zig build run -Darch=x86_64

# 运行 aarch64 版本
zig build run -Darch=aarch64
```

---

## 七、未来规划

### 7.1 短期目标 (P0)
- 完善系统调用实现
- 实现 fork/execve
- 实现 COW 写时复制
- 完善 VFS 操作

### 7.2 中期目标 (P1)
- 实现 HFS+/APFS 文件系统
- 实现网络协议栈
- 实现 launchd 进程管理器
- 实现代码签名验证

### 7.3 长期目标 (P2)
- 实现 Kernel Cache 加载
- 实现用户态进程
- 实现用户态 dyld
- 完善 IOKit 驱动

---

## 八、附录

### 8.1 术语表

| 术语 | 说明 |
|------|------|
| XNU | X is Not Unix，macOS 内核 |
| Mach | 微内核，提供 IPC 和 VM |
| BSD | Berkeley Software Distribution，Unix 兼容层 |
| IOKit | Apple 的设备驱动框架 |
| Mach-O | macOS 可执行文件格式 |
| VNode | 虚拟文件系统节点 |
| UEFI | Unified Extensible Firmware Interface |

### 8.2 参考资料

- Apple XNU Kernel Source (opensource.apple.com)
- OSFMK 7.3 Reference
- Zig Language Documentation
- UEFI Specification

---

**文档版本**: 1.0
**最后更新**: 2026-04-08
**内核版本**: Darwin 19.x Z-Kernel
