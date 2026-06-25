// WeChatMultiHook.dylib —— 注入进微信，给 Dock 右键菜单加「开新微信」
// 独立、可选、可逆模块。仅做一件事：在 applicationDockMenu: 里插入一项。
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>

@interface WMHelper : NSObject
+ (instancetype)shared;
- (void)openNew:(id)sender;
@end

@implementation WMHelper
+ (instancetype)shared {
    static WMHelper *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [WMHelper new]; });
    return s;
}
- (void)openNew:(id)sender {
    NSURL *url = [NSURL fileURLWithPath:@"/Applications/WeChat.app"];
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.createsNewApplicationInstance = YES;               // = open -n
    cfg.environment = @{@"LANG": @"zh_CN.UTF-8", @"LC_ALL": @"zh_CN.UTF-8"}; // 强制中文
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:url configuration:cfg completionHandler:nil];
}
@end

// 原 applicationDockMenu: 实现（若有）
static NSMenu *(*g_origDockMenu)(id, SEL, NSApplication *) = NULL;

static NSMenu *wm_dockMenu(id self, SEL _cmd, NSApplication *sender) {
    NSMenu *menu = g_origDockMenu ? g_origDockMenu(self, _cmd, sender) : nil;
    if (!menu) menu = [[NSMenu alloc] init];
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"开新微信"
                                                  action:@selector(openNew:)
                                           keyEquivalent:@""];
    item.target = [WMHelper shared];
    [menu insertItem:item atIndex:0];
    [menu insertItem:[NSMenuItem separatorItem] atIndex:1];
    return menu;
}

static void wm_installHook(void) {
    id delegate = [NSApp delegate];
    if (!delegate) return;
    Class cls = object_getClass(delegate);
    SEL sel = @selector(applicationDockMenu:);
    Method m = class_getInstanceMethod(cls, sel);
    if (m) {                              // 已有实现 → 接管并保留原结果
        g_origDockMenu = (NSMenu *(*)(id, SEL, NSApplication *))method_getImplementation(m);
        method_setImplementation(m, (IMP)wm_dockMenu);
    } else {                              // 没有 → 直接添加
        class_addMethod(cls, sel, (IMP)wm_dockMenu, "@@:@");
    }
}

__attribute__((constructor))
static void wm_init(void) {
    // App 完成启动后 delegate 才就绪，延后安装 hook
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull note) { wm_installHook(); }];
    // 兜底：若注入时已启动完成，下一轮 runloop 再装一次
    dispatch_async(dispatch_get_main_queue(), ^{ wm_installHook(); });
}
