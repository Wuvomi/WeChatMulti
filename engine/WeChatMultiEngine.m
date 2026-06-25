// WeChatMultiEngine.m
//
// 自研最小多开注入引擎(微信 4.1.11 / com.tencent.xinWeChat)。
// 在 __attribute__((constructor)) 里做三件事:
//   1) 门②(真·业务体早期单例门中和,仅第二+实例执行):
//      运行时在 wechat.dylib __text 里按特征码定位 WeChatMain/0x2106bc 放行函数
//      里那条"可启动=false → 返回 -1 → loader exit(255)"的 `tbz w20,#0,<bail>`
//      判定分支,把它 NOP 掉,使第二实例不再被早退。位移随 build 变,运行时按
//      特征码动态算,绝不硬编码偏移。详见 patch_body_early_gate()。
//   2) 门③(辅助):swizzle +[NSRunningApplication runningApplicationsWithBundleIdentifier:],
//      当 bundleId == com.tencent.xinWeChat 时返回空数组。单独不足以放行(门②才是
//      真门),但消除 UI 层"已有实例"提示,保留无害。其它 bundleId 一律走原实现。
//   3) 权限探针:读屏幕录制授权 + 试探全盘访问(FDA),把结果写到容器内
//      .../WeChatMulti/perms.json,供 GUI 读。
//
// 该 dylib 经 insert_dylib 注入到 wechat.dylib 的 LC_LOAD_DYLIB,随业务体加载,
// constructor 先于 WeChatMain 触发执行,故门②/门③ patch 必然先于单例判定就位。
//
// 编译(必须 -mmacosx-version-min=11.0,否则 constructor 在老 min 版下不跑):
//   clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 \
//     -framework Foundation -framework AppKit -framework CoreGraphics \
//     -mmacosx-version-min=11.0 \
//     -install_name @rpath/WeChatMultiEngine.dylib \
//     -o WeChatMultiEngine.dylib WeChatMultiEngine.m

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <libkern/OSCacheControl.h>
#import <dlfcn.h>
#import <unistd.h>
#import <libproc.h>
#import <stdlib.h>
#import <limits.h>
#import <sys/file.h>
#import <fcntl.h>
#import <sys/stat.h>
#import <dirent.h>
#import <pwd.h>
#import <errno.h>

// CGPreflightScreenCaptureAccess 在部分 SDK header 里没有声明,手动声明。
extern bool CGPreflightScreenCaptureAccess(void) __attribute__((weak_import));

static const char *kWeChatBundleID = "com.tencent.xinWeChat";

#pragma mark - 日志

static void engine_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[WeChatMultiEngine] %@", msg);
}

#pragma mark - 门③:swizzle runningApplicationsWithBundleIdentifier:

// 原始 IMP 的存放点。+[NSRunningApplication runningApplicationsWithBundleIdentifier:]
// 是类方法,签名: NSArray<NSRunningApplication*>* (Class, SEL, NSString*)
typedef NSArray * (*RA_IMP)(id, SEL, NSString *);
static RA_IMP g_orig_runningApps = NULL;

static NSArray *engine_runningApplicationsWithBundleIdentifier(id self, SEL _cmd, NSString *bundleID) {
    // 只针对微信自身的 bundleID 谎报"没有在运行的实例",其它 id 透传原实现。
    if (bundleID != nil &&
        [bundleID isEqualToString:[NSString stringWithUTF8String:kWeChatBundleID]]) {
        engine_log(@"runningApplicationsWithBundleIdentifier:%@ -> [] (forced empty, 多开放行)", bundleID);
        return @[];
    }
    if (g_orig_runningApps) {
        return g_orig_runningApps(self, _cmd, bundleID);
    }
    return @[];
}

static void install_gate3_swizzle(void) {
    Class cls = objc_getClass("NSRunningApplication");
    if (!cls) {
        engine_log(@"NSRunningApplication class 未找到,跳过 swizzle");
        return;
    }
    SEL sel = @selector(runningApplicationsWithBundleIdentifier:);
    // 类方法存放在元类上。
    Method m = class_getClassMethod(cls, sel);
    if (!m) {
        engine_log(@"未找到 +runningApplicationsWithBundleIdentifier: 方法");
        return;
    }
    g_orig_runningApps = (RA_IMP)method_getImplementation(m);
    IMP newImp = (IMP)engine_runningApplicationsWithBundleIdentifier;
    method_setImplementation(m, newImp);
    engine_log(@"swizzled +[NSRunningApplication runningApplicationsWithBundleIdentifier:]");
}

#pragma mark - 权限探针

static NSString *perms_dir(void) {
    NSString *base = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,
                                                          NSUserDomainMask, YES) firstObject];
    if (base == nil) {
        // 沙盒里 NSApplicationSupportDirectory 会落到容器内;再退而求其次。
        base = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
    }
    return [base stringByAppendingPathComponent:@"WeChatMulti"];
}

static BOOL probe_screen_capture(void) {
    if (CGPreflightScreenCaptureAccess != NULL) {
        return CGPreflightScreenCaptureAccess() ? YES : NO;
    }
    return NO;
}

// 取真实用户 home(不是沙盒容器 home)。getpwuid 在沙盒里仍返回真实 home,
// 而 NSHomeDirectory()/$HOME 会被重定向到容器,拿不到 ~/Library/Safari 真实路径。
static const char *real_user_home(void) {
    const char *h = NULL;
    struct passwd *pw = getpwuid(getuid());
    if (pw && pw->pw_dir && pw->pw_dir[0]) h = pw->pw_dir;
    return h;
}

// 判定是否拥有"完全磁盘访问"(FDA / kTCCServiceSystemPolicyAllFiles)。
//
// 设计取舍(详见 re/probe-hardening.md):
//   旧实现直接 fopen 系统 TCC 数据库 /Library/.../TCC.db 判 FDA。这是典型隐私探测
//   特征:沙盒进程触碰 TCC.db 会被 sandboxd 记成越界,语义上"读权限数据库"极可疑,
//   易被风控/EDR 命中。
//
//   改为探测一个"受 FDA 保护、语义无害、且 macOS 上基本 always 存在"的目录:
//   用户 ~/Library/Safari。理由:
//     - 它受 TCC 保护(kTCCServiceSystemPolicyAllFiles):无 FDA 的沙盒进程访问被拒,
//       拥有 FDA 时放行——与 TCC.db 同样能区分"有/无 FDA"。
//     - 语义无害:仅 opendir 列目录句柄,不读 Safari 任何内容,也不碰任何权限库。
//     - 几乎所有 macOS 用户态机器都自带 Safari,该目录稳定存在。
//   判定:opendir 成功 → 有 FDA;EPERM/EACCES(TCC 拒)→ 无 FDA。
//   注意 macOS 上 TCC 拒绝多体现为 EPERM(errno=1),也兼容 EACCES。
//
//   稳健性:若 Safari 目录因极端环境缺失(ENOENT),回退探测 ~/Library/Mail 目录
//   (同受 FDA 保护)。两者皆不可达且非权限拒绝时,保守返回 NO(无 FDA)。
static int fda_probe_dir(const char *path) {
    // 返回 1=可访问(有 FDA 迹象), 0=被 TCC 拒(无 FDA), -1=不存在/无法判定
    DIR *d = opendir(path);
    if (d) {
        closedir(d);
        return 1;
    }
    int e = errno;
    if (e == EPERM || e == EACCES) return 0; // TCC 拒绝 → 无 FDA
    return -1; // ENOENT 等 → 该候选不可用,交给下一个
}

static BOOL probe_full_disk_access(void) {
    const char *home = real_user_home();
    if (!home) return NO;

    char path[PATH_MAX];

    // 候选 1:~/Library/Safari(首选,无害且稳定)
    snprintf(path, sizeof(path), "%s/Library/Safari", home);
    int r = fda_probe_dir(path);
    if (r == 1) return YES;
    if (r == 0) return NO;

    // 候选 2 回退:~/Library/Mail(同受 FDA 保护)
    snprintf(path, sizeof(path), "%s/Library/Mail", home);
    r = fda_probe_dir(path);
    if (r == 1) return YES;
    if (r == 0) return NO;

    // 两候选均不存在/无法判定:保守按无 FDA。
    return NO;
}

static void write_perms_json(void) {
    @autoreleasepool {
        BOOL screen = probe_screen_capture();
        BOOL fda = probe_full_disk_access();

        NSString *dir = perms_dir();
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *err = nil;
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                           attributes:nil error:&err];
        }

        // engine 版本:GUI 据此判断装的是否旧引擎(旧引擎无此字段)→ 引导更新。
        // 每次引擎二进制有实质改动(探针/门逻辑等)就 bump,与 app selfEngineVersion 对齐。
        NSDictionary *payload = @{
            @"screen": @(screen),
            @"fda": @(fda),
            @"engine": @"0.9.2",
            @"pid": @(getpid()),
            @"updated": @([[NSDate date] timeIntervalSince1970]),
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:payload
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:&err];
        NSString *path = [dir stringByAppendingPathComponent:@"perms.json"];
        BOOL ok = [json writeToFile:path atomically:YES];
        engine_log(@"perms.json -> %@ {screen:%d, fda:%d} write=%d",
                   path, screen, fda, ok);
    }
}

#pragma mark - 第二实例判据

// 判断本进程是否"第二+同路径实例"——用容器内 flock 锁文件,沙盒内可靠。
//
// 为什么不用 NSRunningApplication / proc_listpids:
//   - open -n / 直接 exec 起的实例不一定在 LaunchServices 注册,NSRunningApplication
//     数不到(实测两实例都判成"首个")。
//   - 微信进程开了 App Sandbox,sandbox 挡住 proc_listpids/proc_pidpath 看别的进程
//     (在沙盒里枚举进程返回不到同路径实例),所以进程表法在注入场景里也失效。
//
// 可靠做法:在容器内共享目录放一把 flock 排他锁。
//   - 首个实例 flock(LOCK_EX|LOCK_NB) 成功 → 它是 primary,持锁不放(锁随进程退出
//     由内核自动释放,无残留)。
//   - 第二实例 flock 失败(EWOULDBLOCK)→ 说明已有 primary 活着 → 它是 secondary。
// 容器目录对同 bundleId 所有实例共享、沙盒内可写;flock 的活性判定由内核保证。
//
// 锁 fd 必须在进程生命周期内一直持有,故用静态变量存着不关。
static int g_instance_lock_fd = -1;

static BOOL is_secondary_instance(void) {
    @autoreleasepool {
        NSString *dir = perms_dir(); // 容器内 .../WeChatMulti(与 perms.json 同目录)
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:dir]) {
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
                           attributes:nil error:NULL];
        }
        NSString *lockPath = [dir stringByAppendingPathComponent:@"instance.lock"];
        const char *cpath = [lockPath fileSystemRepresentation];

        int fd = open(cpath, O_CREAT | O_RDWR, 0644);
        if (fd < 0) {
            // 开锁文件失败:无法判定,保守当 primary(不动业务体,避免误 patch 首个实例)。
            engine_log(@"实例判据: 打开锁文件失败 errno=%d,保守按 primary", errno);
            return NO;
        }
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            // 抢到锁 → primary。持锁到进程退出(不 close)。
            g_instance_lock_fd = fd;
            // 记下自己的 pid,便于调试。
            ftruncate(fd, 0);
            char buf[32];
            int n = snprintf(buf, sizeof(buf), "%d\n", getpid());
            if (n > 0) { lseek(fd, 0, SEEK_SET); (void)!write(fd, buf, (size_t)n); }
            return NO;
        }
        if (errno == EWOULDBLOCK) {
            // 锁被占 → 已有 primary 活着 → secondary。关掉本次探测 fd(不持锁)。
            close(fd);
            return YES;
        }
        // 其它错误:保守按 primary。
        engine_log(@"实例判据: flock 异常 errno=%d,保守按 primary", errno);
        close(fd);
        return NO;
    }
}

#pragma mark - 门②:业务体早期单例门中和(WeChatMain/0x2106bc 放行判定)

// 干净 wechat.dylib 出厂时 WeChatMain(0x1637c)首条已是 `b 0x2106bc`,跳过
// 0x16380 的 init 链——所以"把 stp 序言改成 b"这一刀在出厂二进制里已经做好,
// 引擎无需再补。真正卡死第二实例的早退在 0x2106bc("放行入口")函数里:
//   …
//   tbz w20, #0x0, <bail>   ; w20 = 可启动布尔;第二实例里 bit0=0 → 跳 bail
//   bl  …                   ; (放行路径)
//   bl  …
//   mov w0, #0x2
//   …
//   <bail>: mov w20, #-1    → WeChatMain 返回 -1 → loader 把 -1 当退出码 → exit(255)
// 中和办法:把那条 `tbz w20,#0,<bail>` NOP 掉,让控制流不再跳 bail、直接走放行。
// 位移(imm14)随 build 变,这里按特征码动态定位,绝不硬编码偏移。

// 在某进程镜像列表里找到 wechat.dylib 的 mach_header + slide。
static const struct mach_header_64 *find_wechat_dylib(intptr_t *slide_out) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        const char *suffix = "/Resources/wechat.dylib";
        size_t slen = strlen(suffix);
        if (len >= slen && strcmp(name + len - slen, suffix) == 0) {
            if (slide_out) *slide_out = _dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

// 改写一个可执行页里的 4 字节指令(RW→写→RX→刷 i-cache),X1a0He 同款双保险:
// 先试 mach_vm_protect / vm_protect(可越过 page 的 max_prot 限制),失败再 mprotect。
static BOOL patch_word(void *addr, uint32_t newword) {
    size_t pagesize = (size_t)sysconf(_SC_PAGESIZE);
    uintptr_t a = (uintptr_t)addr;
    void *page = (void *)(a & ~(uintptr_t)(pagesize - 1));
    size_t span = pagesize * 2; // 4 字节可能跨页,保险覆盖 2 页

    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)page, span,
                                  FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    BOOL via_mach = (kr == KERN_SUCCESS);
    if (!via_mach) {
        if (mprotect(page, span, PROT_READ | PROT_WRITE | PROT_EXEC) != 0) {
            engine_log(@"门②: 解锁页失败 (vm_protect kr=%d, mprotect errno=%d)", kr, errno);
            return NO;
        }
    }

    *(volatile uint32_t *)addr = newword;

    // 复原 RX 权限。
    if (via_mach) {
        vm_protect(mach_task_self(), (vm_address_t)page, span, FALSE,
                   VM_PROT_READ | VM_PROT_EXECUTE);
    } else {
        mprotect(page, span, PROT_READ | PROT_EXEC);
    }
    // 刷指令缓存,确保新指令被取到。
    sys_icache_invalidate(addr, 4);
    return YES;
}

// 在 [text, text+size) 内按特征码找门②那条 `tbz w20,#0,<bail>`:
//   word & 0xFFF8001F == 0x36000014   (= tbz w20, #0, <任意位移>;掩掉 imm14)
// 并要求其后紧跟「两条 bl + 一条 mov w0,#2(40 00 80 52)」以消歧。
// 命中返回该指令地址,否则 NULL。
static uint32_t *locate_body_gate(const uint8_t *text, size_t size) {
    const uint32_t *w = (const uint32_t *)text;
    size_t count = size / 4;
    // 末尾要回看 4 条指令,留出余量。
    for (size_t i = 0; i + 4 < count; i++) {
        if ((w[i] & 0xFFF8001Fu) != 0x36000014u) continue; // tbz w20,#0,...
        // 紧邻两条 bl(opcode bits[31:26]=100101 → (word>>26)==0x25)
        if (((w[i + 1] >> 26) & 0x3F) != 0x25) continue;
        if (((w[i + 2] >> 26) & 0x3F) != 0x25) continue;
        // mov w0, #2  == 0x52800040
        if (w[i + 3] != 0x52800040u) continue;
        return (uint32_t *)&w[i];
    }
    return NULL;
}

// 中和业务体早期单例门。仅应在"第二+实例"里调用。
// 返回 YES 表示已 patch(或已是 patched 状态),NO 表示未命中/失败。
static BOOL patch_body_early_gate(void) {
    intptr_t slide = 0;
    const struct mach_header_64 *mh = find_wechat_dylib(&slide);
    if (!mh) {
        engine_log(@"门②: 未找到 wechat.dylib 镜像,跳过");
        return NO;
    }
    unsigned long textsize = 0;
    // __text 节(可执行代码)。getsectiondata 已带 slide。
    uint8_t *text = getsectiondata(mh, "__TEXT", "__text", &textsize);
    if (!text || textsize == 0) {
        engine_log(@"门②: 取 __text 失败");
        return NO;
    }
    uint32_t *gate = locate_body_gate(text, (size_t)textsize);
    if (!gate) {
        engine_log(@"门②: 特征码未命中(可能 build 变化),跳过");
        return NO;
    }
    uint32_t cur = *gate;
    const uint32_t NOP = 0xD503201Fu;
    if (cur == NOP) {
        engine_log(@"门②: 已是 NOP(此前已中和),跳过");
        return YES;
    }
    if ((cur & 0xFFF8001Fu) != 0x36000014u) {
        engine_log(@"门②: 命中点字节异常 0x%08x,放弃", cur);
        return NO;
    }
    uintptr_t fileoff = (uintptr_t)gate - slide; // = slice vmaddr(本 dylib fileoff==vmaddr)
    BOOL ok = patch_word(gate, NOP);
    engine_log(@"门②: %@ tbz w20 @vmaddr 0x%lx (slide 0x%lx) 0x%08x -> NOP",
               ok ? @"已中和" : @"中和失败", (unsigned long)fileoff,
               (unsigned long)slide, cur);
    return ok;
}

#pragma mark - constructor

__attribute__((constructor))
static void wechat_multi_engine_init(void) {
    @autoreleasepool {
        engine_log(@"loaded into pid=%d (%@)", getpid(),
                   [[NSProcessInfo processInfo] processName]);

        // 0) 先判本进程是否"第二+同路径实例"。必须早于门③ swizzle(swizzle 后
        //    NSRunningApplication 会被我们谎报为空,判据会失真)。
        BOOL secondary = is_secondary_instance();
        engine_log(@"instance role: %@", secondary ? @"secondary(第二+)" : @"primary(首个)");

        // 1) 门②:仅第二+实例中和业务体早期单例门(NOP 那条 tbz w20)。
        //    首个实例绝不动业务体——它本就该正常启动。
        if (secondary) {
            patch_body_early_gate();
        }

        // 2) 门③ swizzle(辅助,消 UI 层"已有实例"提示;放行真靠门②)。
        install_gate3_swizzle();

        // 3) 权限探针:自适应节奏写 perms.json。
        //    旧实现固定每 3s(每小时上千次),探测过密,叠加越界读 TCC.db,极易被
        //    风控判成"异常探测行为"。新节奏(详见 re/probe-hardening.md):
        //      - 启动后头 ~90s:每 10s 一次(捕捉"用户刚在系统设置里授权"的窗口)。
        //      - 之后退避到稳态:每 45s 一次。
        //    FDA 变化最坏 ~45s 内反映到 GUI(实际授权多发生在启动初期密采窗口,
        //    那时 ~10s 内即可反映)。探测频率较旧实现降一个数量级以上
        //    (旧 ~1200 次/小时 → 新 ~80 次/小时)。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            const int kFastIntervalSec  = 10;   // 启动初期密采间隔
            const int kFastWindowSec    = 90;   // 密采窗口时长
            const int kSlowIntervalSec  = 45;   // 稳态间隔
            int elapsed = 0;
            for (;;) {
                write_perms_json();
                int interval = (elapsed < kFastWindowSec) ? kFastIntervalSec
                                                          : kSlowIntervalSec;
                sleep((unsigned)interval);
                elapsed += interval;
            }
        });
    }
}
