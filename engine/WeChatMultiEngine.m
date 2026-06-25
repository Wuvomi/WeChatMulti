// WeChatMultiEngine.m
//
// 自研最小多开注入引擎(微信 4.1.11 / com.tencent.xinWeChat)。
// 在 __attribute__((constructor)) 里做两件事:
//   1) 多开:swizzle +[NSRunningApplication runningApplicationsWithBundleIdentifier:],
//      当 bundleId == com.tencent.xinWeChat 时返回空数组,使业务体的第③门
//      (NSRunningApplication 单例检测)查不到"已运行实例"→ 不再 exit(-1)。
//      其它 bundleId 一律走原实现,绝不全局清空。
//   2) 权限探针:读屏幕录制授权 + 试探全盘访问(FDA),把结果写到
//      ~/Library/Application Support/WeChatMulti/perms.json,供 GUI 读。
//
// 该 dylib 经 insert_dylib 注入到 wechat.dylib 的 LC_LOAD_DYLIB,随业务体加载,
// constructor 先于业务体第③门触发执行,故 swizzle 必然就位。
//
// 编译:
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

// 试读一个 FDA(全盘访问)保护路径来判断是否拥有完全磁盘访问权限。
// TCC.db 仅在拥有 FDA 时可读;读不到则视为无 FDA。
static BOOL probe_full_disk_access(void) {
    static const char *fda_probes[] = {
        "/Library/Application Support/com.apple.TCC/TCC.db",
        "/Users/Shared/.fda_probe_nonexistent", // 占位,真正判定靠下面的 TCC.db
        NULL,
    };
    // 主判据:能否打开并读取 TCC.db。沙盒进程通常被挡;有 FDA 例外时可读。
    const char *p = fda_probes[0];
    FILE *f = fopen(p, "rb");
    if (f) {
        unsigned char buf[16];
        size_t n = fread(buf, 1, sizeof(buf), f);
        fclose(f);
        // SQLite 文件头 "SQLite format 3\0";能读到任意字节即说明有访问权。
        if (n > 0) {
            return YES;
        }
    }
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

        NSDictionary *payload = @{
            @"screen": @(screen),
            @"fda": @(fda),
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

#pragma mark - constructor

__attribute__((constructor))
static void wechat_multi_engine_init(void) {
    @autoreleasepool {
        engine_log(@"loaded into pid=%d (%@)", getpid(),
                   [[NSProcessInfo processInfo] processName]);
        // 1) 先装多开门③ swizzle(必须早于业务体单例检测)。
        install_gate3_swizzle();
        // 2) 权限探针写 perms.json(异步,避免拖慢启动关键路径)。
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            write_perms_json();
        });
    }
}
