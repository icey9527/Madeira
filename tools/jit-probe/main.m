#import <UIKit/UIKit.h>
#include "JITAllocator.h"
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>

static NSString *probeLogPath;

static void recordProbe(NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (![[NSFileManager defaultManager] fileExistsAtPath:probeLogPath]) {
        [[NSFileManager defaultManager] createFileAtPath:probeLogPath contents:nil attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:probeLogPath];
    [handle seekToEndOfFile];
    [handle writeData:data];
    [handle synchronizeFile];
    [handle closeFile];
}

static void allocatorLog(const char *message) {
    recordProbe([NSString stringWithUTF8String:message]);
}

@interface ProbeController : UIViewController
@property(nonatomic, strong) UITextView *logView;
@property(nonatomic, strong) UIButton *runButton;
@end

@implementation ProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"Madeira JIT 测试";
    self.logView = [[UITextView alloc] init];
    self.logView.editable = NO;
    self.logView.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"运行免调试器 JIT 测试" forState:UIControlStateNormal];
    [self.runButton addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    self.runButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.runButton];
    [self.view addSubview:self.logView];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.runButton.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [self.runButton.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.runButton.heightAnchor constraintEqualToConstant:44],
        [self.logView.topAnchor constraintEqualToAnchor:self.runButton.bottomAnchor constant:8],
        [self.logView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [self.logView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.logView.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]
    ]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"分享日志" style:UIBarButtonItemStylePlain target:self action:@selector(shareLog:)];
    [self refreshLog];
}

- (void)refreshLog {
    self.logView.text = [NSString stringWithContentsOfFile:probeLogPath encoding:NSUTF8StringEncoding error:nil];
}

- (void)shareLog:(UIBarButtonItem *)sender {
    UIActivityViewController *sheet = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:probeLogPath]] applicationActivities:nil];
    sheet.popoverPresentationController.barButtonItem = sender;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)runProbe {
    self.runButton.enabled = NO;
    recordProbe(@"BEGIN: 仅测试现有双映射分配器，不调用调试器 BRK 协议。若退出，重新打开后分享日志。");
    uint32_t flags = 0;
    bool known = jit_cs_status(&flags);
    recordProbe([NSString stringWithFormat:@"csops known=%d flags=0x%08x CS_DEBUGGED=%d", known, flags, (flags & 0x10000000) != 0]);
    JITRegion *region = jit_region_create(0x4000);
    if (!region) {
        recordProbe(@"FAIL: 无法创建双映射区域。");
    } else {
        uint32_t code[] = {0xD2800540, 0xD65F03C0};
        void *entry = jit_region_write(region, 0, code, sizeof(code));
        if (!entry || memcmp(jit_region_rx_ptr(region), code, sizeof(code)) != 0) {
            recordProbe(@"FAIL: 写入或 RW/RX 共享检查失败。");
        } else {
            recordProbe(@"EXECUTE: 即将从 RX 地址执行，预期返回 42。");
            int64_t first = ((int64_t (*)(void))entry)();
            recordProbe([NSString stringWithFormat:@"第一次执行=%lld，预期=42", (long long)first]);
            code[0] = 0xD2800560;
            entry = jit_region_write(region, 0, code, sizeof(code));
            recordProbe(@"EXECUTE: 已通过 RW 重写同一页，预期返回 43。");
            int64_t second = entry ? ((int64_t (*)(void))entry)() : -1;
            recordProbe([NSString stringWithFormat:@"第二次执行=%lld，预期=43", (long long)second]);
            recordProbe(first == 42 && second == 43 ? @"PASS: 双映射、动态执行及重写后执行通过。" : @"FAIL: 返回值不符合预期。");
        }
        jit_region_destroy(region);
    }
    [self refreshLog];
    self.runButton.enabled = YES;
}
@end

@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation ProbeApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    probeLogPath = [documents stringByAppendingPathComponent:@"jit-probe.log"];
    jit_set_log_callback(allocatorLog);
    recordProbe([NSString stringWithFormat:@"START: iOS %@, build %@", UIDevice.currentDevice.systemVersion, [NSBundle.mainBundle objectForInfoDictionaryKey:@"ProbeCommit"]]);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [[UINavigationController alloc] initWithRootViewController:[[ProbeController alloc] init]];
    [self.window makeKeyAndVisible];
    return YES;
}
@end

int main(int argc, char *argv[]) {
    const char *container = getenv("HOME");
    if (container) {
        char path[4096];
        snprintf(path, sizeof(path), "%s/Documents/jit-probe.log", container);
        int descriptor = open(path, O_WRONLY | O_CREAT | O_APPEND, 0600);
        if (descriptor >= 0) {
            const char message[] = "MAIN: process entered main before UIKit initialization.\n";
            write(descriptor, message, sizeof(message) - 1);
            fsync(descriptor);
            close(descriptor);
        }
    }
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApp.class));
    }
}
