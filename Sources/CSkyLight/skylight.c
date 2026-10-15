#include "CSkyLight.h"
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>

typedef CGError (*SetFrontProcessFn)(ProcessSerialNumber *psn, uint32_t wid, uint32_t mode);
typedef CGError (*PostEventRecordFn)(ProcessSerialNumber *psn, uint8_t *bytes);
typedef AXError (*AXGetWindowFn)(AXUIElementRef element, uint32_t *wid);
typedef OSStatus (*GetProcessForPIDFn)(pid_t pid, ProcessSerialNumber *psn);

// kCPSUserGenerated: the activation counts as a user action, like a click in the Dock.
static const uint32_t kUserGenerated = 0x200;

static SetFrontProcessFn set_front_process;
static PostEventRecordFn post_event_record;
static AXGetWindowFn ax_get_window;
static GetProcessForPIDFn get_process_for_pid;
static pthread_once_t load_once = PTHREAD_ONCE_INIT;

static void load(void) {
    void *skylight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    if (skylight) {
        set_front_process = (SetFrontProcessFn)dlsym(skylight, "_SLPSSetFrontProcessWithOptions");
        post_event_record = (PostEventRecordFn)dlsym(skylight, "SLPSPostEventRecordTo");
    }
    ax_get_window = (AXGetWindowFn)dlsym(RTLD_DEFAULT, "_AXUIElementGetWindow");
    get_process_for_pid = (GetProcessForPIDFn)dlsym(RTLD_DEFAULT, "GetProcessForPID");
}

bool olala_focus_available(void) {
    pthread_once(&load_once, load);
    return set_front_process && post_event_record && get_process_for_pid;
}

bool olala_focus_window(pid_t pid, uint32_t wid) {
    if (!olala_focus_available()) return false;
    ProcessSerialNumber psn = {0, 0};
    if (get_process_for_pid(pid, &psn) != noErr) return false;
    if (set_front_process(&psn, wid, kUserGenerated) != kCGErrorSuccess) return false;
    // Two synthetic records (types 1 and 2) addressed to the window make it key.
    uint8_t record[0xf8];
    for (uint8_t type = 1; type <= 2; type++) {
        memset(record, 0, sizeof record);
        record[0x04] = 0xf8;
        record[0x08] = type;
        record[0x3a] = 0x10;
        memset(record + 0x20, 0xff, 0x10);
        memcpy(record + 0x3c, &wid, sizeof wid);
        post_event_record(&psn, record);
    }
    return true;
}

uint32_t olala_ax_window_id(AXUIElementRef element) {
    pthread_once(&load_once, load);
    uint32_t wid = 0;
    if (!ax_get_window || ax_get_window(element, &wid) != kAXErrorSuccess) return 0;
    return wid;
}
