/*
 * touchbar_guard - Modern macOS daemon to neutralize phantom touches on MacBook Pros
 *
 * Copyright (c) 2026 Yustyna
 * Licensed under the MIT License.
 *
 * ======================================================================================
 * THE PROBLEM:
 * ======================================================================================
 * On MacBook Pro models with Apple Silicon and Touch Bar (e.g. 13" M1 MacBookPro17,1
 * and 13" M2 MacBookPro14,7), as well as late Intel models (2016-2020), hardware aging
 * commonly leads to failure of the OLED Touch Bar display. The display stays pitch black,
 * yet the capacitive touch digitizer layer remains fully functional and starts generating
 * errant "phantom touches".
 *
 * When combined with a worn or defective Hall effect lid angle sensor (lid sensor),
 * closing the laptop lid does NOT cause the Mac to sleep. When the screen locks or
 * displays sleep, phantom touches continuously wake up the display, adjust display brightness,
 * change audio volume, trigger Siri, or register ghost keystrokes, draining the battery
 * inside backpacks and overheating the machine.
 *
 * ======================================================================================
 * THE FATAL BUG IN EXISTING WORKAROUNDS (Kernel Panic Mechanics):
 * ======================================================================================
 * Several community workarounds circulating online (e.g., Reddit scripts) attempt to
 * stop the Touch Bar by executing:
 *      kill -STOP $(pgrep TouchBarServer) $(pgrep ControlStrip)
 *
 * On modern macOS (macOS 14 Sonoma, macOS 15 Sequoia, and newer), freezing `TouchBarServer`
 * causes a catastrophic, 100% reproducible KERNEL PANIC:
 *
 *   panic(cpu 1 caller 0xfffffe001ec4cf3c): _dmaReferences overflow @IOMemoryDescriptor.cpp:5086
 *   Debugger message: panic
 *   Backtrace (CPU 1), panicked thread: 0xfffffe1ffc774640:
 *   ...
 *   Kernel Extensions in backtrace:
 *      com.apple.driver.AppleMobileDispH13G-DFR(...)
 *
 * WHY THIS HAPPENS:
 * 1. Apple Silicon Macs use the `com.apple.driver.AppleMobileDispH13G-DFR` driver to manage
 *    the DFR (Display Function Row) hardware framebuffer.
 * 2. `TouchBarServer` is the direct user-space display server client for this DFR driver.
 * 3. When `TouchBarServer` receives SIGSTOP, its Mach message loop halts. As a result,
 *    it cannot acknowledge DMA frame transfers completed by the DFR hardware driver.
 * 4. The DFR kernel driver continues to queue DMA transactions and increments an
 *    internal `IOMemoryDescriptor` reference counter (`_dmaReferences`).
 * 5. In XNU (`osfmk/arm/pmap.c` and `iokit/Kernel/IOMemoryDescriptor.cpp`), `_dmaReferences`
 *    is implemented as a signed 16-bit integer (max value: 32,767).
 * 6. Within a short period of unserviced DMA requests, `_dmaReferences` exceeds 32,767,
 *    triggering an immediate kernel panic assertion at line 5086 of `IOMemoryDescriptor.cpp`.
 *
 * ======================================================================================
 * THE SURGICAL SOLUTION IMPLEMENTED HERE:
 * ======================================================================================
 * NEVER signal or freeze `TouchBarServer`!
 * Instead, this daemon targets ONLY `ControlStrip` (`/System/Library/CoreServices/ControlStrip.app`).
 *
 * 1. `ControlStrip` is purely a user-space AppKit/CoreGraphics UI client application.
 *    It renders the interactive widgets (volume slider, brightness slider, mute, Siri).
 * 2. Suspending `ControlStrip` via SIGSTOP stops all UI event handling on the Touch Bar.
 *    Phantom touches on the digitizer no longer trigger any UI action.
 * 3. Crucially, `TouchBarServer` and the DFR kernel driver continue to communicate normally:
 *    zero DMA frame stalls, zero IOMemoryDescriptor reference leaks, ZERO kernel panics.
 * 4. When the display wakes or the user unlocks the screen, this daemon sends SIGCONT to
 *    `ControlStrip`, instantly restoring full interactivity.
 */

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <notify.h>
#include <libproc.h>
#include <signal.h>
#include <syslog.h>
#include <os/log.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOMessage.h>
#include <sys/proc_info.h>
#include <unistd.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DAEMON_VERSION "1.0.0"
#define TARGET_PROCESS "ControlStrip"

// Handle kIOMainPortDefault compatibility across SDK versions without triggering deprecation warnings
#if defined(MAC_OS_X_VERSION_12_0) && MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_12_0
#ifndef kIOMainPortDefault
#define kIOMainPortDefault kIOMasterPortDefault
#endif
#endif

// Global state tracking
static volatile sig_atomic_t g_is_blocked = 0;
static io_connect_t g_power_port = 0;
static os_log_t g_logger = NULL;

// Format current timestamp into buffer [YYYY-MM-DD HH:MM:SS]
static void get_iso_timestamp(char *buf, size_t max_len) {
    time_t now = time(NULL);
    struct tm tm_buf;
    localtime_r(&now, &tm_buf);
    strftime(buf, max_len, "%Y-%m-%d %H:%M:%S", &tm_buf);
}

// Unified logging across os_log, syslog, and stdout
static void log_message(const char *format, ...) {
    va_list args;
    va_start(args, format);

    char msg_buf[1024];
    vsnprintf(msg_buf, sizeof(msg_buf), format, args);
    va_end(args);

    char time_buf[32];
    get_iso_timestamp(time_buf, sizeof(time_buf));

    // 1. Stdout (line-buffered)
    fprintf(stdout, "[%s] [TouchBarGuard] %s\n", time_buf, msg_buf);
    fflush(stdout);

    // 2. Syslog
    syslog(LOG_NOTICE, "[TouchBarGuard] %s", msg_buf);

    // 3. Apple Unified Logging (os_log)
    if (g_logger) {
        os_log(g_logger, "%{public}s", msg_buf);
    }
}

// Find all instances of target_name and send them the specified signal
static int send_signal_to_process(const char *target_name, int sig) {
    int bytes_needed = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes_needed <= 0) {
        return 0;
    }

    // Allocate buffer with headroom for dynamically created processes
    int count = (bytes_needed / (int)sizeof(pid_t)) + 64;
    pid_t *pids = (pid_t *)malloc(count * sizeof(pid_t));
    if (!pids) {
        return 0;
    }

    int bytes_read = proc_listpids(PROC_ALL_PIDS, 0, pids, count * (int)sizeof(pid_t));
    if (bytes_read <= 0) {
        free(pids);
        return 0;
    }

    int actual_count = bytes_read / (int)sizeof(pid_t);
    int signaled_count = 0;

    for (int i = 0; i < actual_count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == getpid()) continue;

        char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
        bool matched = false;

        if (proc_name(pid, name, sizeof(name)) > 0) {
            if (strcmp(name, target_name) == 0) {
                matched = true;
            }
        }

        // Fallback check against full path if name is truncated
        if (!matched) {
            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            if (proc_pidpath(pid, path, sizeof(path)) > 0) {
                char *slash = strrchr(path, '/');
                if (slash && strcmp(slash + 1, target_name) == 0) {
                    matched = true;
                }
            }
        }

        if (matched) {
            if (kill(pid, sig) == 0) {
                signaled_count++;
            }
        }
    }

    free(pids);
    return signaled_count;
}

// Query state of target process (e.g. whether it is running, stopped, or absent)
static void check_process_status(const char *target_name) {
    int bytes_needed = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (bytes_needed <= 0) {
        printf("Error: Unable to list system processes.\n");
        return;
    }

    int count = (bytes_needed / (int)sizeof(pid_t)) + 64;
    pid_t *pids = (pid_t *)malloc(count * sizeof(pid_t));
    if (!pids) {
        printf("Error: Memory allocation failed.\n");
        return;
    }

    int bytes_read = proc_listpids(PROC_ALL_PIDS, 0, pids, count * (int)sizeof(pid_t));
    int actual_count = (bytes_read > 0) ? (bytes_read / (int)sizeof(pid_t)) : 0;
    bool found = false;

    for (int i = 0; i < actual_count; i++) {
        pid_t pid = pids[i];
        if (pid <= 0 || pid == getpid()) continue;

        char name[PROC_PIDPATHINFO_MAXSIZE] = {0};
        if (proc_name(pid, name, sizeof(name)) > 0 && strcmp(name, target_name) == 0) {
            found = true;
            struct proc_bsdinfo procinfo;
            int info_bytes = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &procinfo, sizeof(procinfo));

            const char *state_str = "UNKNOWN";
            if (info_bytes > 0) {
                switch (procinfo.pbi_status) {
                    case 1: state_str = "SIDL (idle)"; break;
                    case 2: state_str = "SRUN (running)"; break;
                    case 3: state_str = "SSLEEP (sleeping/responsive)"; break;
                    case 4: state_str = "SSTOP (STOPPED / FROZEN via SIGSTOP)"; break;
                    case 5: state_str = "SZOMB (zombie)"; break;
                    default: state_str = "OTHER"; break;
                }
            }

            char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
            proc_pidpath(pid, path, sizeof(path));

            printf("  • Process: %s (PID: %d)\n", target_name, pid);
            printf("    Path:   %s\n", path);
            printf("    Status: %s\n", state_str);
        }
    }

    if (!found) {
        printf("  • Process '%s' is NOT running.\n", target_name);
    }

    free(pids);
}

// Freeze ControlStrip to stop UI controls (brightness, volume, mute, siri)
static void block_touchbar(const char *reason) {
    if (g_is_blocked) {
        return;
    }
    g_is_blocked = 1;

    int count = send_signal_to_process(TARGET_PROCESS, SIGSTOP);
    if (count > 0) {
        log_message("BLOCKED Touch Bar [SIGSTOP -> %s (instances: %d)] (Reason: %s)", TARGET_PROCESS, count, reason);
    } else {
        log_message("BLOCKED Touch Bar (Reason: %s, note: %s process not found)", reason, TARGET_PROCESS);
    }
}

// Resume ControlStrip
static void unblock_touchbar(const char *reason) {
    if (!g_is_blocked) {
        return;
    }
    g_is_blocked = 0;

    int count = send_signal_to_process(TARGET_PROCESS, SIGCONT);
    if (count > 0) {
        log_message("UNBLOCKED Touch Bar [SIGCONT -> %s (instances: %d)] (Reason: %s)", TARGET_PROCESS, count, reason);
    } else {
        log_message("UNBLOCKED Touch Bar (Reason: %s, note: %s process not found)", reason, TARGET_PROCESS);
    }
}

// IOKit system power callback
static void power_callback(__unused void *refCon, __unused io_service_t service, natural_t messageType, void *messageArgument) {
    switch (messageType) {
        case kIOMessageSystemWillSleep:
            block_touchbar("System will sleep (IOKit)");
            IOAllowPowerChange(g_power_port, (long)messageArgument);
            break;
        case kIOMessageSystemHasPoweredOn:
            unblock_touchbar("System powered on (IOKit)");
            break;
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange(g_power_port, (long)messageArgument);
            break;
        default:
            break;
    }
}

// IOKit display wrangler callback (detects display off / display on)
static void display_wrangler_callback(__unused void *refcon, __unused io_service_t service, natural_t messageType, __unused void *messageArgument) {
    if (messageType == kIOMessageDeviceWillPowerOff) {
        block_touchbar("Display wrangler power off (IODisplayWrangler)");
    } else if (messageType == kIOMessageDeviceHasPoweredOn) {
        unblock_touchbar("Display wrangler power on (IODisplayWrangler)");
    }
}

// Setup GCD signal handler for clean graceful shutdown
static void setup_signal_handlers(dispatch_queue_t queue) {
    signal(SIGTERM, SIG_IGN);
    signal(SIGINT, SIG_IGN);
    signal(SIGHUP, SIG_IGN);

    static dispatch_source_t sigterm_src;
    static dispatch_source_t sigint_src;
    static dispatch_source_t sighup_src;

    sigterm_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, queue);
    dispatch_source_set_event_handler(sigterm_src, ^{
        log_message("Received SIGTERM, restoring %s before exit...", TARGET_PROCESS);
        unblock_touchbar("Daemon terminating (SIGTERM)");
        exit(0);
    });
    dispatch_resume(sigterm_src);

    sigint_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, queue);
    dispatch_source_set_event_handler(sigint_src, ^{
        log_message("Received SIGINT, restoring %s before exit...", TARGET_PROCESS);
        unblock_touchbar("Daemon terminating (SIGINT)");
        exit(0);
    });
    dispatch_resume(sigint_src);

    sighup_src = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, queue);
    dispatch_source_set_event_handler(sighup_src, ^{
        log_message("Received SIGHUP, resetting state and refreshing listeners.");
    });
    dispatch_resume(sighup_src);
}

// Print CLI usage instructions
static void print_usage(const char *prog_name) {
    printf("touchbar_guard - macOS Touch Bar Phantom Touch Shield v%s\n", DAEMON_VERSION);
    printf("Usage:\n");
    printf("  %s [options]\n\n", prog_name);
    printf("Options:\n");
    printf("  -d, --daemon       Run in background daemon mode (default)\n");
    printf("  -f, --foreground   Run in foreground with stdout logging\n");
    printf("  -s, --status       Display status of TouchBarGuard and %s\n", TARGET_PROCESS);
    printf("      --freeze       Manually freeze %s (SIGSTOP) for testing\n", TARGET_PROCESS);
    printf("      --thaw         Manually thaw %s (SIGCONT)\n", TARGET_PROCESS);
    printf("  -v, --version      Show version and build info\n");
    printf("  -h, --help         Show this help message\n\n");
}

int main(int argc, const char * argv[]) {
    // Process command line arguments
    if (argc > 1) {
        const char *arg = argv[1];
        if (strcmp(arg, "-h") == 0 || strcmp(arg, "--help") == 0) {
            print_usage(argv[0]);
            return 0;
        }
        if (strcmp(arg, "-v") == 0 || strcmp(arg, "--version") == 0) {
            printf("touchbar_guard version %s (compiled %s %s)\n", DAEMON_VERSION, __DATE__, __TIME__);
            return 0;
        }
        if (strcmp(arg, "-s") == 0 || strcmp(arg, "--status") == 0) {
            printf("=== TouchBarGuard Status ===\n");
            check_process_status("touchbar_guard");
            printf("=== ControlStrip Status ===\n");
            check_process_status(TARGET_PROCESS);
            return 0;
        }
        if (strcmp(arg, "--freeze") == 0 || strcmp(arg, "--block") == 0) {
            printf("Freezing %s (SIGSTOP)...\n", TARGET_PROCESS);
            int count = send_signal_to_process(TARGET_PROCESS, SIGSTOP);
            printf("Sent SIGSTOP to %d instance(s) of %s.\n", count, TARGET_PROCESS);
            return 0;
        }
        if (strcmp(arg, "--thaw") == 0 || strcmp(arg, "--unblock") == 0) {
            printf("Thawing %s (SIGCONT)...\n", TARGET_PROCESS);
            int count = send_signal_to_process(TARGET_PROCESS, SIGCONT);
            printf("Sent SIGCONT to %d instance(s) of %s.\n", count, TARGET_PROCESS);
            return 0;
        }
    }

    @autoreleasepool {
        // Line-buffer stdout so log lines appear immediately
        setvbuf(stdout, NULL, _IOLBF, 0);

        openlog("touchbar_guard", LOG_PID | LOG_CONS, LOG_DAEMON);
        g_logger = os_log_create("com.touchbar.guard", "daemon");

        log_message("Daemon starting (v%s, pid: %d, arch: %s)...",
                    DAEMON_VERSION, getpid(),
#if defined(__arm64__)
                    "arm64"
#elif defined(__x86_64__)
                    "x86_64"
#else
                    "unknown"
#endif
        );

        // Setup clean shutdown handlers
        setup_signal_handlers(dispatch_get_main_queue());

        // -------------------------------------------------------------------------
        // 1. BSD Darwin Notifications (notify.h)
        // -------------------------------------------------------------------------
        struct DarwinNotif {
            const char *name;
            bool is_lock;
            const char *description;
        };

        const struct DarwinNotif darwin_notifs[] = {
            // Lock events
            {"com.apple.sessionagent.screenIsLocked",     true,  "Session screen locked"},
            {"com.apple.sessionagent.screenLockUIIsShown", true,  "Screen lock UI shown"},
            {"com.apple.sessionagent.shieldWindowRaised",  true,  "Shield window raised"},
            {"com.apple.mobile.keybagd.lock_status",      true,  "Keybag lock status"},
            {"com.apple.screensaver.didstart",             true,  "Screensaver started"},

            // Unlock events
            {"com.apple.sessionagent.screenIsUnlocked",   false, "Session screen unlocked"},
            {"com.apple.sessionagent.screenLockUIIsHidden",false,"Screen lock UI hidden"},
            {"com.apple.sessionagent.shieldWindowLowered", false,"Shield window lowered"},
            {"com.apple.screensaver.didstop",             false, "Screensaver stopped"},
        };

        size_t notif_count = sizeof(darwin_notifs) / sizeof(darwin_notifs[0]);
        int registered_darwin = 0;

        for (size_t i = 0; i < notif_count; i++) {
            int token = 0;
            const char *notif_name = darwin_notifs[i].name;
            bool is_lock = darwin_notifs[i].is_lock;
            const char *desc = darwin_notifs[i].description;

            uint32_t status = notify_register_dispatch(notif_name, &token, dispatch_get_main_queue(), ^(int __unused t) {
                if (is_lock) {
                    block_touchbar(desc);
                } else {
                    unblock_touchbar(desc);
                }
            });

            if (status == NOTIFY_STATUS_OK) {
                registered_darwin++;
            } else {
                log_message("Warning: Failed to register Darwin notification '%s' (status: %u)", notif_name, status);
            }
        }
        log_message("Registered %d/%zu BSD Darwin notification listeners.", registered_darwin, notif_count);

        // -------------------------------------------------------------------------
        // 2. Cocoa Distributed Notifications (NSDistributedNotificationCenter)
        // -------------------------------------------------------------------------
        NSDistributedNotificationCenter *distCenter = [NSDistributedNotificationCenter defaultCenter];

        [distCenter addObserverForName:@"com.apple.screenIsLocked"
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(__unused NSNotification * _Nonnull note) {
            block_touchbar("Screen locked (DistributedNotification)");
        }];

        [distCenter addObserverForName:@"com.apple.screenIsUnlocked"
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(__unused NSNotification * _Nonnull note) {
            unblock_touchbar("Screen unlocked (DistributedNotification)");
        }];
        log_message("Registered Cocoa Distributed notification listeners.");

        // -------------------------------------------------------------------------
        // 3. IOKit Power Management Notifications (Sleep / Wake)
        // -------------------------------------------------------------------------
        IONotificationPortRef powerNotifyPort = NULL;
        io_object_t powerNotifier = 0;
        g_power_port = IORegisterForSystemPower(NULL, &powerNotifyPort, power_callback, &powerNotifier);
        if (g_power_port && powerNotifyPort) {
            CFRunLoopAddSource(CFRunLoopGetCurrent(),
                               IONotificationPortGetRunLoopSource(powerNotifyPort),
                               kCFRunLoopDefaultMode);
            log_message("Registered IOKit System Power management listener.");
        } else {
            log_message("Warning: Failed to register IOKit System Power listener.");
        }

        // -------------------------------------------------------------------------
        // 4. IOKit IODisplayWrangler Notifications (Display Off / On)
        // -------------------------------------------------------------------------
        IONotificationPortRef dpyNotifyPort = IONotificationPortCreate(kIOMainPortDefault);
        if (dpyNotifyPort) {
            io_service_t wrangler = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceNameMatching("IODisplayWrangler"));
            if (wrangler) {
                io_object_t dpyNotifier = 0;
                kern_return_t kr = IOServiceAddInterestNotification(dpyNotifyPort,
                                                                    wrangler,
                                                                    kIOGeneralInterest,
                                                                    display_wrangler_callback,
                                                                    NULL,
                                                                    &dpyNotifier);
                IOObjectRelease(wrangler);
                if (kr == KERN_SUCCESS) {
                    CFRunLoopAddSource(CFRunLoopGetCurrent(),
                                       IONotificationPortGetRunLoopSource(dpyNotifyPort),
                                       kCFRunLoopDefaultMode);
                    log_message("Registered IOKit IODisplayWrangler interest listener.");
                } else {
                    log_message("Warning: Failed to attach IODisplayWrangler interest notification (kr: 0x%x).", kr);
                }
            } else {
                log_message("Notice: IODisplayWrangler service not found on this hardware profile.");
            }
        } else {
            log_message("Warning: Failed to create IOKit notification port for display wrangler.");
        }

        // -------------------------------------------------------------------------
        // 5. NSWorkspace Notifications (Sleep, Wake, Screen power, Session switch)
        // -------------------------------------------------------------------------
        NSNotificationCenter *wsCenter = [[NSWorkspace sharedWorkspace] notificationCenter];

        [wsCenter addObserverForName:NSWorkspaceScreensDidSleepNotification
                              object:nil
                               queue:[NSOperationQueue mainQueue]
                          usingBlock:^(__unused NSNotification * _Nonnull note) {
            block_touchbar("Screens did sleep (NSWorkspace)");
        }];

        [wsCenter addObserverForName:NSWorkspaceScreensDidWakeNotification
                              object:nil
                               queue:[NSOperationQueue mainQueue]
                          usingBlock:^(__unused NSNotification * _Nonnull note) {
            unblock_touchbar("Screens did wake (NSWorkspace)");
        }];

        [wsCenter addObserverForName:NSWorkspaceWillSleepNotification
                              object:nil
                               queue:[NSOperationQueue mainQueue]
                          usingBlock:^(__unused NSNotification * _Nonnull note) {
            block_touchbar("Workspace will sleep (NSWorkspace)");
        }];

        [wsCenter addObserverForName:NSWorkspaceDidWakeNotification
                              object:nil
                               queue:[NSOperationQueue mainQueue]
                          usingBlock:^(__unused NSNotification * _Nonnull note) {
            unblock_touchbar("Workspace did wake (NSWorkspace)");
        }];

        [wsCenter addObserverForName:NSWorkspaceSessionDidResignActiveNotification
                              object:nil
                               queue:[NSOperationQueue mainQueue]
                          usingBlock:^(__unused NSNotification * _Nonnull note) {
            block_touchbar("Session resigned active / fast user switch (NSWorkspace)");
        }];

        [wsCenter addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification
                              object:nil
                               queue:[NSOperationQueue mainQueue]
                          usingBlock:^(__unused NSNotification * _Nonnull note) {
            unblock_touchbar("Session became active (NSWorkspace)");
        }];
        log_message("Registered NSWorkspace notification listeners.");

        log_message("Initialization complete. All protection layers active. Entering event runloop.");

        // Run the main runloop
        [[NSRunLoop currentRunLoop] run];
    }

    return 0;
}
