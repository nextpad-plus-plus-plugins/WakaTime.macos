// WakaTime — macOS port
// Original Windows plugin: "WakaTime for Notepad++" (notepadpp-wakatime) by
// Alan Hamlett / WakaTime, BSD-3-Clause (Copyright (c) 2014 Alan Hamlett).
// https://github.com/wakatime/notepadpp-wakatime
//
// Automatic coding-time tracker. It watches editor activity and enqueues
// "heartbeats" (entity = file path, timestamp, lines-in-file, lineno, is_write)
// which are flushed to WakaTime by shelling out to the official `wakatime-cli`
// helper. The heartbeat engine — cadence, throttle, 10-second flush timer, queue
// drain with --extra-heartbeats, and the exact wakatime-cli argument vector — is
// ported verbatim from the .NET source (WakaTime.cs / CliParameters.cs /
// WakaTimePackage.cs). Only the platform layer changes:
//
//   .NET / Win32 (original)                  macOS port (this file)
//   ──────────────────────────────────────   ──────────────────────────────────
//   System.Timers.Timer (10 s)               dispatch_source_t timer (10 s)
//   ConcurrentQueue<Heartbeat>               std::deque + NSLock
//   Process.Start / RedirectStdin (Run-      NSTask + NSPipe, run on a background
//     Process.cs, BelowNormal priority)        GCD queue (editor never blocks)
//   GetPrivateProfileString / WritePrivate-  hand-rolled INI reader/writer for
//     ProfileString on ~/.wakatime.cfg         the shared ~/.wakatime.cfg
//   Dependencies.GetCliLocation (+ auto-     resolve ~/.wakatime/wakatime-cli*,
//     download a wakatime-cli-windows-*.exe)   then PATH, then Homebrew. We do
//                                              NOT auto-download (see note below).
//   WinForms SettingsForm / ApiKeyForm       programmatic AppKit modal panel
//   NPPM_ADDTOOLBARICON (HBITMAP)            NPPM_ADDTOOLBARICON_FORDARKMODE
//                                              (host loads toolbar.png/_dark.png)
//
// ONE DELIBERATE BEHAVIOR DIFFERENCE FROM WINDOWS: the Windows plugin downloads
// (and self-updates) wakatime-cli from GitHub on startup. On macOS we do NOT
// auto-download a binary. If wakatime-cli cannot be found we alert the user once
// with install guidance (`brew install wakatime-cli`, or https://wakatime.com/help)
// and keep queueing heartbeats (they flush once the CLI is installed). Everything
// else — when/whether a heartbeat fires, and how wakatime-cli is invoked — matches
// the Windows plugin exactly.

#include "NppPluginInterfaceMac.h"
#include "Scintilla.h"
#import <Cocoa/Cocoa.h>

#include <dlfcn.h>
#include <cmath>
#include <cstring>
#include <ctime>
#include <deque>
#include <sstream>
#include <atomic>
#include <string>
#include <vector>

// ─────────────────────────────────────────────────────────────────────────────
// Plugin identity / constants  (mirrors Metadata + Constants.cs)
// ─────────────────────────────────────────────────────────────────────────────
static const char *PLUGIN_NAME    = "WakaTime";
// notepadpp-wakatime upstream version this port tracks (HISTORY.rst 5.1.2).
static const char *PLUGIN_VERSION = "5.1.2";
// EditorName/PluginName used in the --plugin user-agent string (WakaTimePackage.cs).
static const char *EDITOR_NAME    = "notepadpp";
static const char *PLUGIN_UA_NAME = "notepadpp-wakatime";

// Constants.HeartbeatFrequency = 2 minutes.
static const int   kHeartbeatFrequencyMinutes = 2;
// System.Timers.Timer interval = 10 000 ms.
static const double kFlushIntervalSeconds = 10.0;

static const int nbFunc = 4;   // Settings | Dashboard | (sep) | About

// Save-button target for the Settings dialog. The full @interface is declared
// here (before the anonymous namespace) so showSettingsDialog can instantiate it
// and send messages; the @implementation lives after the namespace because it
// calls the namespaced C++ helpers (apiKeyValid / cfgSet / gApiKey).
@interface WTSaveTarget : NSObject
@property (nonatomic, strong) NSTextField *keyField;
@property (nonatomic, strong) NSTextField *urlField;
@property (nonatomic, strong) NSButton    *debugBtn;
@property (nonatomic, strong) NSWindow    *win;
- (void)onSave:(id)sender;
@end

namespace {

NppData   nppData;
FuncItem  funcItem[nbFunc];

// ── heartbeat engine state (mirrors WakaTime.cs fields) ─────────────────────
struct Heartbeat {
    std::string entity;     // file path
    long long   lineNumber; // 1-based current line
    long long   lines;      // total lines in file
    std::string timestamp;  // "<seconds>.<microseconds>"
    bool        isWrite;
};

NSLock                *gQueueLock = nil;       // guards gQueue
std::deque<Heartbeat>  gQueue;                 // ConcurrentQueue<Heartbeat>

std::string  gLastFile;                        // _lastFile
double       gLastHeartbeat = 0.0;             // _lastHeartbeat (unix seconds, UTC)
bool         gHasLastFile = false;             // _lastFile != null

dispatch_source_t gTimer = nil;                // _timer
bool              gInitialized = false;
bool              gCliMissingWarned = false;   // alert-once guard (macOS-only)

std::string  gApiKey;                          // cached CliParameters.Key (main thread only)
std::atomic<bool> gHasApiKey{false};           // cross-thread flag the flush reads (gApiKey non-empty?)
std::string  gPluginUA;                        // cached CliParameters.Plugin

// ─────────────────────────────────────────────────────────────────────────────
// Scintilla / Npp helpers
// ─────────────────────────────────────────────────────────────────────────────
NppHandle currentSci() {
    int which = -1;
    nppData._sendMessage(nppData._nppHandle, NPPM_GETCURRENTSCINTILLA, 0, (intptr_t)&which);
    return (which == 0) ? nppData._scintillaMainHandle
         : (which == 1) ? nppData._scintillaSecondHandle : 0;
}

intptr_t sci(NppHandle h, uint32_t msg, uintptr_t wp = 0, intptr_t lp = 0) {
    return h ? nppData._sendMessage(h, msg, wp, lp) : 0;
}

// GetCurrentFile() — NPPM_GETFULLCURRENTPATH; returns "" when no path / -1.
std::string currentFile() {
    char buf[2048];
    buf[0] = '\0';
    intptr_t r = nppData._sendMessage(nppData._nppHandle, NPPM_GETFULLCURRENTPATH,
                                      (uintptr_t)sizeof(buf), (intptr_t)buf);
    if (r == -1) return std::string();
    return std::string(buf);
}

// ScintillaGateway.GetCurrentLineNumber() — 1-based (Win plugin sends 1-based).
long long currentLineNumber() {
    NppHandle h = currentSci();
    if (!h) return 0;
    long long pos = (long long)sci(h, SCI_GETCURRENTPOS);
    return (long long)sci(h, SCI_LINEFROMPOSITION, (uintptr_t)pos) + 1;
}

// ScintillaGateway.GetLineCount().
long long currentLineCount() {
    NppHandle h = currentSci();
    if (!h) return 0;
    return (long long)sci(h, SCI_GETLINECOUNT);
}

// ─────────────────────────────────────────────────────────────────────────────
// ~/.wakatime.cfg  — shared INI config (mirrors ConfigFile.cs + Dependencies)
// Hand-rolled INI so it interoperates byte-for-byte with the other WakaTime
// tools that read/write the same file. Get/Save operate on [settings] by default.
// ─────────────────────────────────────────────────────────────────────────────
std::string homeLocation() {
    // Dependencies.HomeLocation: WAKATIME_HOME if set + exists, else $HOME.
    const char *wh = getenv("WAKATIME_HOME");
    if (wh && *wh) {
        NSString *p = [NSString stringWithUTF8String:wh];
        BOOL isDir = NO;
        if ([[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&isDir] && isDir)
            return std::string(wh);
    }
    NSString *home = NSHomeDirectory();
    return home ? std::string([home UTF8String]) : std::string();
}

std::string configFilePath() {
    return homeLocation() + "/.wakatime.cfg";
}

std::string trim(const std::string &s) {
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return std::string();
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
}

// GetPrivateProfileString(section,key) on ~/.wakatime.cfg → "" if absent.
std::string cfgGet(const std::string &key, const std::string &section = "settings") {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:configFilePath().c_str()];
        NSError *err = nil;
        NSString *contents = [NSString stringWithContentsOfFile:path
                                                       encoding:NSUTF8StringEncoding
                                                          error:&err];
        if (!contents) return std::string();
        std::string cur;
        std::string want = section;
        std::istringstream iss([contents UTF8String]);
        std::string line;
        while (std::getline(iss, line)) {
            std::string t = trim(line);
            if (t.empty() || t[0] == ';' || t[0] == '#') continue;
            if (t.front() == '[' && t.back() == ']') {
                cur = trim(t.substr(1, t.size() - 2));
                continue;
            }
            if (cur != want) continue;
            size_t eq = t.find('=');
            if (eq == std::string::npos) continue;
            std::string k = trim(t.substr(0, eq));
            if (k == key) return trim(t.substr(eq + 1));
        }
        return std::string();
    }
}

// WritePrivateProfileString(section,key,value) — preserve other keys/sections.
void cfgSet(const std::string &section, const std::string &key, const std::string &value) {
    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:configFilePath().c_str()];
        NSString *existing = [NSString stringWithContentsOfFile:path
                                                       encoding:NSUTF8StringEncoding
                                                          error:nil];
        std::vector<std::string> lines;
        if (existing) {
            std::istringstream iss([existing UTF8String]);
            std::string l;
            while (std::getline(iss, l)) {
                if (!l.empty() && l.back() == '\r') l.pop_back();
                lines.push_back(l);
            }
        }

        std::string cur;
        bool replaced = false;
        int sectionStart = -1, sectionEnd = -1;  // [start,end) line range of target section body
        for (size_t i = 0; i < lines.size(); ++i) {
            std::string t = trim(lines[i]);
            if (!t.empty() && t.front() == '[' && t.back() == ']') {
                std::string name = trim(t.substr(1, t.size() - 2));
                if (cur == section && sectionStart >= 0 && sectionEnd < 0)
                    sectionEnd = (int)i;
                cur = name;
                if (cur == section) sectionStart = (int)i + 1;
                continue;
            }
            if (cur == section) {
                size_t eq = t.find('=');
                if (eq != std::string::npos && trim(t.substr(0, eq)) == key) {
                    lines[i] = key + " = " + value;
                    replaced = true;
                }
            }
        }
        if (cur == section && sectionStart >= 0 && sectionEnd < 0)
            sectionEnd = (int)lines.size();

        if (!replaced) {
            std::string entry = key + " = " + value;
            if (sectionStart >= 0) {
                lines.insert(lines.begin() + sectionEnd, entry);
            } else {
                if (!lines.empty() && !trim(lines.back()).empty())
                    lines.push_back("");
                lines.push_back("[" + section + "]");
                lines.push_back(entry);
            }
        }

        std::string out;
        for (size_t i = 0; i < lines.size(); ++i) { out += lines[i]; out += "\n"; }
        NSString *data = [NSString stringWithUTF8String:out.c_str()];
        [data writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        // The config holds the plaintext API key — keep it owner-only (0600).
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)}
                                         ofItemAtPath:path error:nil];
    }
}

bool cfgGetBool(const std::string &key, bool dflt = false) {
    std::string v = cfgGet(key);
    if (v.empty()) return dflt;
    for (auto &c : v) c = (char)tolower((unsigned char)c);
    if (v == "true")  return true;
    if (v == "false") return false;
    return dflt;
}

// ─────────────────────────────────────────────────────────────────────────────
// wakatime-cli resolution
//   Official install location first (~/.wakatime/wakatime-cli*), then PATH, then
//   common Homebrew prefixes. (Windows used a fixed ~/.wakatime/wakatime-cli-
//   windows-<arch>.exe that it downloaded; we never download — see file header.)
// ─────────────────────────────────────────────────────────────────────────────
std::string resourcesLocation() {           // Dependencies.ResourcesLocation
    return homeLocation() + "/.wakatime";
}

std::string findCliInDir(const std::string &dir) {
    @autoreleasepool {
        NSString *nsDir = [NSString stringWithUTF8String:dir.c_str()];
        NSFileManager *fm = [NSFileManager defaultManager];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:nsDir isDirectory:&isDir] || !isDir) return std::string();
        // Prefer plain "wakatime-cli", then any wakatime-cli* (e.g. -darwin-arm64).
        std::vector<std::string> preferred = {
            "wakatime-cli", "wakatime-cli-darwin-arm64", "wakatime-cli-darwin-amd64",
        };
        for (const auto &name : preferred) {
            std::string cand = dir + "/" + name;
            if ([fm isExecutableFileAtPath:[NSString stringWithUTF8String:cand.c_str()]])
                return cand;
        }
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:nsDir error:nil];
        for (NSString *e in entries) {
            if ([e hasPrefix:@"wakatime-cli"]) {
                std::string cand = dir + "/" + std::string([e UTF8String]);
                if ([fm isExecutableFileAtPath:[NSString stringWithUTF8String:cand.c_str()]])
                    return cand;
            }
        }
        return std::string();
    }
}

// Resolve a bare name on PATH via the user's login shell (so PATH matches a
// Terminal, incl. asdf/Homebrew shims), mirroring Linter.macos's `/bin/sh -lc`.
std::string whichViaShell(const std::string &name) {
    @autoreleasepool {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
        task.arguments = @[ @"-l", @"-c",
                            [NSString stringWithFormat:@"command -v %s", name.c_str()] ];
        NSPipe *out = [NSPipe pipe];
        task.standardOutput = out;
        task.standardError  = [NSPipe pipe];
        NSError *e = nil;
        if (![task launchAndReturnError:&e]) return std::string();
        NSData *d = [out.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        if (task.terminationStatus != 0 || !d || d.length == 0) return std::string();
        std::string s((const char *)d.bytes, d.length);
        s = trim(s);
        if (!s.empty() && [[NSFileManager defaultManager]
                              isExecutableFileAtPath:[NSString stringWithUTF8String:s.c_str()]])
            return s;
        return std::string();
    }
}

// GetCliLocation() macOS analogue. Returns "" if not found.
std::string cliLocation() {
    // 1. Official install dir ~/.wakatime/  (where `brew`/installer place it).
    std::string p = findCliInDir(resourcesLocation());
    if (!p.empty()) return p;
    // 2. Common Homebrew / local prefixes — cheap filesystem checks, no shell.
    for (const char *dir : { "/opt/homebrew/bin", "/usr/local/bin" }) {
        std::string cand = std::string(dir) + "/wakatime-cli";
        if ([[NSFileManager defaultManager]
                isExecutableFileAtPath:[NSString stringWithUTF8String:cand.c_str()]])
            return cand;
    }
    // 3. PATH via a login shell (last resort — exotic setups like asdf shims).
    //    Spawning a shell is comparatively expensive, so we only reach it after
    //    the cheap checks above miss.
    p = whichViaShell("wakatime-cli");
    if (!p.empty()) return p;
    return std::string();
}

void warnCliMissingOnce() {
    if (gCliMissingWarned) return;
    gCliMissingWarned = true;
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            NSAlert *a = [[NSAlert alloc] init];
            a.messageText = @"wakatime-cli not found";
            a.informativeText =
                @"WakaTime needs the wakatime-cli helper to send your coding activity, "
                @"but it could not be found.\n\nInstall it with:\n"
                @"    brew install wakatime-cli\n\n"
                @"or download it from https://wakatime.com/help/plugins, and place it at "
                @"~/.wakatime/wakatime-cli (or anywhere on your PATH).\n\n"
                @"Heartbeats are queued and will be sent automatically once the CLI is "
                @"available.";
            a.alertStyle = NSAlertStyleWarning;
            [a addButtonWithTitle:@"Open WakaTime Help"];
            [a addButtonWithTitle:@"OK"];
            if ([a runModal] == NSAlertFirstButtonReturn)
                [[NSWorkspace sharedWorkspace]
                    openURL:[NSURL URLWithString:@"https://wakatime.com/help/plugins"]];
        }
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// CliParameters.ToArray() — EXACT argument vector, same order as the .NET source.
//   --key <k> --entity <f> --lines-in-file <n> --lineno <n> --time <t>
//   --plugin <ua> [--write] [--extra-heartbeats]
// ─────────────────────────────────────────────────────────────────────────────
NSArray<NSString *> *buildCliArgs(const Heartbeat &h, bool hasExtra) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    auto add = [&](const std::string &s) {
        [a addObject:[NSString stringWithUTF8String:s.c_str()]];
    };
    // The API key is deliberately NOT passed as --key (which would expose it in
    // `ps`). wakatime-cli reads it from ~/.wakatime.cfg [settings] api_key, which
    // the Settings dialog writes (0600). homeLocation() honours WAKATIME_HOME just
    // like wakatime-cli, so both always agree on the config file.
    add("--entity");         add(h.entity);
    add("--lines-in-file");  add(std::to_string(h.lines));
    add("--lineno");         add(std::to_string(h.lineNumber));
    add("--time");           add(h.timestamp);
    add("--plugin");         add(gPluginUA);
    if (h.isWrite) add("--write");
    if (hasExtra)  add("--extra-heartbeats");
    return a;
}

// Heartbeat.ToString() — JSON object for the --extra-heartbeats stdin array.
std::string heartbeatJson(const Heartbeat &h) {
    std::string e;
    for (char c : h.entity) {
        if (c == '\\')      e += "\\\\";
        else if (c == '"')  e += "\\\"";
        else                e += c;
    }
    std::string s = "{\"entity\":\"" + e + "\",";
    s += "\"lines-in-file\":" + std::to_string(h.lines) + ",";
    s += "\"lineno\":" + std::to_string(h.lineNumber) + ",";
    s += "\"time\":" + h.timestamp + ",";
    s += std::string("\"is_write\":") + (h.isWrite ? "true" : "false") + "}";
    return s;
}

// ─────────────────────────────────────────────────────────────────────────────
// Timestamp  "<seconds>.<microseconds>"  (ToUnixEpoch in WakaTime.cs)
// ─────────────────────────────────────────────────────────────────────────────
std::string toUnixEpoch(double unixSeconds) {
    long long secs = (long long)floor(unixSeconds);
    long long micros = (long long)llround((unixSeconds - (double)secs) * 1000000.0);
    if (micros >= 1000000) { micros -= 1000000; secs += 1; }
    char buf[64];
    snprintf(buf, sizeof(buf), "%lld.%06lld", secs, micros);
    return std::string(buf);
}

double nowUnixUTC() {
    return [[NSDate date] timeIntervalSince1970];
}

// ─────────────────────────────────────────────────────────────────────────────
// HandleActivity / AppendHeartbeat / EnoughTimePassed  (WakaTime.cs — verbatim)
// ─────────────────────────────────────────────────────────────────────────────
bool enoughTimePassed(double now) {
    // _lastHeartbeat < now.AddMinutes(-HeartbeatFrequency)
    return gLastHeartbeat < (now - kHeartbeatFrequencyMinutes * 60.0);
}

void appendHeartbeat(const std::string &fileName, bool isWrite, double time) {
    Heartbeat h;
    h.entity     = fileName;
    h.lineNumber = currentLineNumber();
    h.lines      = currentLineCount();
    h.timestamp  = toUnixEpoch(time);
    h.isWrite    = isWrite;
    [gQueueLock lock];
    gQueue.push_back(h);
    [gQueueLock unlock];
}

void handleActivity(const std::string &file, bool isWrite) {
    if (file.empty()) return;          // currentFile == null guard
    double now = nowUnixUTC();
    // if (!isWrite && _lastFile != null && !EnoughTimePassed(now) && file == _lastFile) return;
    if (!isWrite && gHasLastFile && !enoughTimePassed(now) && file == gLastFile)
        return;
    gLastFile = file;
    gHasLastFile = true;
    gLastHeartbeat = now;
    appendHeartbeat(file, isWrite, now);
}

// ─────────────────────────────────────────────────────────────────────────────
// ProcessHeartbeats() — drain the queue and invoke wakatime-cli on a background
// thread (WakaTime.cs + RunProcess.cs). Dequeue first heartbeat → its args;
// any remaining heartbeats → --extra-heartbeats fed as a JSON array on stdin.
// ─────────────────────────────────────────────────────────────────────────────
void runCli(const Heartbeat &first, const std::vector<Heartbeat> &extra) {
    std::string binary = cliLocation();
    if (binary.empty()) { warnCliMissingOnce(); return; }
    if (!gHasApiKey.load()) return;    // nothing to send without a key (thread-safe)

    bool hasExtra = !extra.empty();
    @autoreleasepool {
        NSTask *task = [[NSTask alloc] init];
        task.executableURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:binary.c_str()]];
        task.arguments = buildCliArgs(first, hasExtra);

        NSPipe *outPipe = [NSPipe pipe];
        NSPipe *errPipe = [NSPipe pipe];
        task.standardOutput = outPipe;
        task.standardError  = errPipe;

        NSPipe *inPipe = nil;
        std::string stdinStr;
        if (hasExtra) {
            // SerializeArrayHeartbeat: "[h1,h2,...]" then RunProcess writes "<json>\n\n".
            stdinStr = "[";
            for (size_t i = 0; i < extra.size(); ++i) {
                if (i) stdinStr += ",";
                stdinStr += heartbeatJson(extra[i]);
            }
            stdinStr += "]";
            inPipe = [NSPipe pipe];
            task.standardInput = inPipe;
        }

        NSError *e = nil;
        if (![task launchAndReturnError:&e]) {
            // Could not start the CLI even though the path existed — warn once.
            warnCliMissingOnce();
            return;
        }
        if (hasExtra) {
            NSString *payload = [NSString stringWithFormat:@"%s\n\n",
                                 stdinStr.c_str()];   // RunProcess.cs writes "{stdin}\n"
            NSData *d = [payload dataUsingEncoding:NSUTF8StringEncoding];
            NSFileHandle *inH = inPipe.fileHandleForWriting;
            @try { [inH writeData:d]; } @catch (...) {}
            @try { [inH closeFile]; } @catch (...) {}
        }
        // Drain both pipes concurrently so the child can't block writing to one
        // (a full stderr pipe) while we're still reading the other — which would
        // deadlock the stdout read.
        NSFileHandle *errH = errPipe.fileHandleForReading;
        dispatch_semaphore_t errDone = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            @try { [errH readDataToEndOfFile]; } @catch (...) {}
            dispatch_semaphore_signal(errDone);
        });
        [outPipe.fileHandleForReading readDataToEndOfFile];
        dispatch_semaphore_wait(errDone, DISPATCH_TIME_FOREVER);
        [task waitUntilExit];
    }
}

void processHeartbeats() {
    // Snapshot + clear the queue under lock (TryDequeue loop in the original).
    Heartbeat first;
    std::vector<Heartbeat> extra;
    [gQueueLock lock];
    if (gQueue.empty()) { [gQueueLock unlock]; return; }
    first = gQueue.front();
    gQueue.pop_front();
    while (!gQueue.empty()) { extra.push_back(gQueue.front()); gQueue.pop_front(); }
    [gQueueLock unlock];

    runCli(first, extra);
}

// ProcessHeartbeats(timer) → Task.Run(ProcessHeartbeats): always off the main thread.
void flushAsync() {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        processHeartbeats();
    });
}

// ─────────────────────────────────────────────────────────────────────────────
// Settings dialog  (programmatic AppKit; mirrors SettingsForm.cs / ApiKeyForm.cs)
//   Fields: API Key (required, validated), api_url (optional). Save writes to
//   ~/.wakatime.cfg [settings]. API-key regex matches the Windows validation.
// ─────────────────────────────────────────────────────────────────────────────
bool apiKeyValid(const std::string &key) {
    // (?im)^(waka_)?[0-9A-F]{8}[-]?(?:[0-9A-F]{4}[-]?){3}[0-9A-F]{12}$
    @autoreleasepool {
        NSString *pattern =
            @"^(waka_)?[0-9A-Fa-f]{8}-?(?:[0-9A-Fa-f]{4}-?){3}[0-9A-Fa-f]{12}$";
        NSRegularExpression *re =
            [NSRegularExpression regularExpressionWithPattern:pattern
                                                      options:NSRegularExpressionCaseInsensitive
                                                        error:nil];
        if (!re) return false;
        NSString *s = [NSString stringWithUTF8String:key.c_str()];
        NSRange r = NSMakeRange(0, s.length);
        return [re numberOfMatchesInString:s options:0 range:r] > 0;
    }
}

NSTextField *makeLabel(NSString *text, NSRect frame) {
    NSTextField *l = [[NSTextField alloc] initWithFrame:frame];
    l.stringValue = text;
    l.bezeled = NO; l.drawsBackground = NO; l.editable = NO; l.selectable = NO;
    return l;
}

void showSettingsDialog() {
    @autoreleasepool {
        NSRect frame = NSMakeRect(0, 0, 460, 188);
        NSWindow *win = [[NSWindow alloc]
            initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                        backing:NSBackingStoreBuffered
                          defer:NO];
        win.title = @"WakaTime Settings";
        win.releasedWhenClosed = NO;
        NSView *cv = win.contentView;

        // API Key row.
        [cv addSubview:makeLabel(@"API Key:", NSMakeRect(20, 148, 110, 18))];
        NSTextField *keyField = [[NSTextField alloc] initWithFrame:NSMakeRect(135, 145, 305, 24)];
        keyField.stringValue = [NSString stringWithUTF8String:cfgGet("api_key").c_str()];
        keyField.placeholderString = @"waka_xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx";
        [cv addSubview:keyField];

        // api_url row (optional).
        [cv addSubview:makeLabel(@"API URL (optional):", NSMakeRect(20, 110, 130, 18))];
        NSTextField *urlField = [[NSTextField alloc] initWithFrame:NSMakeRect(155, 107, 285, 24)];
        urlField.stringValue = [NSString stringWithUTF8String:cfgGet("api_url").c_str()];
        urlField.placeholderString = @"https://api.wakatime.com/api/v1";
        [cv addSubview:urlField];

        // Debug checkbox (Windows SettingsForm has a Debug toggle).
        NSButton *debug = [[NSButton alloc] initWithFrame:NSMakeRect(135, 76, 200, 20)];
        [debug setButtonType:NSButtonTypeSwitch];
        debug.title = @"Debug";
        debug.state = cfgGetBool("debug") ? NSControlStateValueOn : NSControlStateValueOff;
        [cv addSubview:debug];

        NSTextField *hint = makeLabel(
            @"Get your API key at https://wakatime.com/settings/account",
            NSMakeRect(20, 48, 420, 18));
        hint.textColor = [NSColor secondaryLabelColor];
        [cv addSubview:hint];

        // Buttons.
        NSButton *cancel = [[NSButton alloc] initWithFrame:NSMakeRect(250, 12, 90, 30)];
        cancel.title = @"Cancel";
        cancel.bezelStyle = NSBezelStyleRounded;
        cancel.keyEquivalent = @"\033";              // Esc
        [cancel setTarget:NSApp];
        [cancel setAction:@selector(abortModal)];
        [cv addSubview:cancel];

        NSButton *save = [[NSButton alloc] initWithFrame:NSMakeRect(350, 12, 90, 30)];
        save.title = @"Save";
        save.bezelStyle = NSBezelStyleRounded;
        save.keyEquivalent = @"\r";                  // default button (Enter)
        [cv addSubview:save];

        // Save handler validates the key, then writes to ~/.wakatime.cfg. Wired to
        // an Objective-C target (WTSaveTarget) that captures the fields by KVC.
        WTSaveTarget *tgt = [[WTSaveTarget alloc] init];
        [tgt setValue:keyField forKey:@"keyField"];
        [tgt setValue:urlField forKey:@"urlField"];
        [tgt setValue:debug    forKey:@"debugBtn"];
        [tgt setValue:win      forKey:@"win"];
        save.target = tgt;
        save.action = @selector(onSave:);

        [win center];
        [NSApp runModalForWindow:win];          // tgt is retained by save.target
        [win orderOut:nil];
    }
}

} // namespace

// WTSaveTarget @implementation. Validates the API key like the Windows dialog: if
// invalid, shows an alert and keeps the dialog open; if valid, persists settings
// to ~/.wakatime.cfg and closes.
@implementation WTSaveTarget
- (void)onSave:(id)sender {
    std::string key = std::string([[self.keyField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] UTF8String]);
    if (!apiKeyValid(key)) {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"Please enter a valid API Key.";
        a.alertStyle = NSAlertStyleWarning;
        [a beginSheetModalForWindow:self.win completionHandler:nil];
        return;  // DialogResult.None — keep the dialog open
    }
    cfgSet("settings", "api_key", key);
    std::string url = std::string([[self.urlField.stringValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] UTF8String]);
    if (!url.empty())
        cfgSet("settings", "api_url", url);
    cfgSet("settings", "debug",
           self.debugBtn.state == NSControlStateValueOn ? "true" : "false");
    // Refresh the cached key used by the heartbeat sender.
    gApiKey = key;
    gHasApiKey.store(!gApiKey.empty());
    [NSApp stopModal];
    [self.win close];
}
@end

namespace {

// Settings menu command.
void settingsCommand() {
    showSettingsDialog();
}

// About dialog — basic info + setup steps.
void aboutCommand() {
    @autoreleasepool {
        NSAlert *a = [[NSAlert alloc] init];
        a.messageText = @"About WakaTime";
        a.alertStyle  = NSAlertStyleInformational;
        a.informativeText =
            @"WakaTime v1.0.0 (macOS port)\n"
             "Tracks upstream notepadpp-wakatime 5.1.2.\n\n"
             "Automatic coding-time tracker: it records \"heartbeats\" as you edit "
             "and sends them to WakaTime via the wakatime-cli helper. View your "
             "dashboards at wakatime.com.\n\n"
             "Setup:\n"
             "1. Install the helper:  brew install wakatime-cli\n"
             "2. Get your API key:  https://wakatime.com/settings/api-key\n"
             "3. Enter it in Plugins > WakaTime > Settings.\n\n"
             "Original Windows plugin by Alan Hamlett / WakaTime (BSD-3-Clause)\n"
             "macOS port by Andrey Letov";
        [a addButtonWithTitle:@"OK"];
        [a runModal];
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Initialize() / timer setup  (WakaTime.cs ctor + Initialize + WakaTimePackage)
// ─────────────────────────────────────────────────────────────────────────────
void initializeEngine() {
    if (gInitialized) return;
    gInitialized = true;

    gQueueLock = [[NSLock alloc] init];
    gApiKey = cfgGet("api_key");
    gHasApiKey.store(!gApiKey.empty());

    // CliParameters.Plugin = "<editor>/<ver> <plugin>/<ver>". We report a fixed
    // editor version (host NPPM_GETNPPVERSION is available but the exact wire
    // format the Win plugin builds isn't needed by wakatime-cli).
    int npp = (int)nppData._sendMessage(nppData._nppHandle, NPPM_GETNPPVERSION, 0, 0);
    std::string editorVer = "0";
    if (npp > 0) {
        int high = npp >> 16, low = npp & 0xFFFF;
        editorVer = std::to_string(high) + "." + std::to_string(low);
    }
    gPluginUA = std::string(EDITOR_NAME) + "/" + editorVer + " " +
                PLUGIN_UA_NAME + "/" + PLUGIN_VERSION;

    // _lastHeartbeat = UtcNow.AddMinutes(-3): allow the first edit to fire at once.
    gLastHeartbeat = nowUnixUTC() - 3 * 60.0;

    // 10-second flush timer on a background queue.
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                 dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    dispatch_source_set_timer(gTimer,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kFlushIntervalSeconds * NSEC_PER_SEC)),
        (uint64_t)(kFlushIntervalSeconds * NSEC_PER_SEC),
        (uint64_t)(1 * NSEC_PER_SEC));
    // Timer fires → run the flush on a background task (ProcessHeartbeats(timer)
    // → Task.Run(ProcessHeartbeats) in the original). The timer queue is already
    // background, but flushAsync keeps the "never on the timer thread" semantics.
    dispatch_source_set_event_handler(gTimer, ^{ flushAsync(); });
    dispatch_resume(gTimer);

    // Prompt for the API key on first run if none is configured (PromptApiKey()).
    if (gApiKey.empty()) {
        dispatch_async(dispatch_get_main_queue(), ^{ showSettingsDialog(); });
    }
}

void shutdownEngine() {
    if (gTimer) {
        dispatch_source_cancel(gTimer);
        gTimer = nil;
    }
    // Dispose(): flush whatever is left in the queue.
    processHeartbeats();
}

} // namespace

// ─────────────────────────────────────────────────────────────────────────────
// Plugin exports
// ─────────────────────────────────────────────────────────────────────────────
extern "C" NPP_EXPORT void setInfo(NppData data) {
    nppData = data;
    memset(funcItem, 0, sizeof(funcItem));
    strncpy(funcItem[0]._itemName, "Settings", NPP_MENU_ITEM_SIZE - 1);
    funcItem[0]._pFunc = settingsCommand;
    funcItem[0]._pShKey = nullptr;
    strncpy(funcItem[1]._itemName, "WakaTime Dashboard", NPP_MENU_ITEM_SIZE - 1);
    funcItem[1]._pFunc = []() {
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://wakatime.com/dashboard"]];
    };
    funcItem[1]._pShKey = nullptr;
    strncpy(funcItem[2]._itemName, "---", NPP_MENU_ITEM_SIZE - 1);   // separator
    funcItem[2]._pFunc = nullptr;
    funcItem[2]._pShKey = nullptr;
    strncpy(funcItem[3]._itemName, "About", NPP_MENU_ITEM_SIZE - 1);
    funcItem[3]._pFunc = aboutCommand;
    funcItem[3]._pShKey = nullptr;
}

extern "C" NPP_EXPORT const char *getName() { return PLUGIN_NAME; }

extern "C" NPP_EXPORT FuncItem *getFuncsArray(int *nbF) { *nbF = nbFunc; return funcItem; }

extern "C" NPP_EXPORT void beNotified(SCNotification *n) {
    if (!n) return;
    switch (n->nmhdr.code) {
        case NPPN_READY:
            initializeEngine();
            break;
        case NPPN_TBMODIFICATION:
            // lParam 0 → host loads toolbar.png / toolbar_dark.png from the plugin dir.
            nppData._sendMessage(nppData._nppHandle, NPPM_ADDTOOLBARICON_FORDARKMODE,
                                 (uintptr_t)funcItem[0]._cmdID, 0);
            break;
        case NPPN_FILESAVED:
            // HandleActivity(currentFile, isWrite: true)
            handleActivity(currentFile(), true);
            break;
        case NPPN_BUFFERACTIVATED:
            // File switch — treat as activity (not a write). EnoughTimePassed /
            // file-change guard inside handleActivity decides whether it fires.
            handleActivity(currentFile(), false);
            break;
        case SCN_MODIFIED:
            // Edit activity: insert OR delete text (Win plugin only checked insert,
            // but delete is genuine editing too; the file-change/2-min throttle in
            // handleActivity keeps the cadence identical for a single open file).
            if (n->modificationType & (SC_MOD_INSERTTEXT | SC_MOD_DELETETEXT))
                handleActivity(currentFile(), false);
            break;
        case SCN_UPDATEUI:
            // Cursor / selection moved — refresh activity so lineno stays current
            // and idle-after-switch still registers within the 2-minute cadence.
            handleActivity(currentFile(), false);
            break;
        case NPPN_SHUTDOWN:
            shutdownEngine();
            break;
        default:
            break;
    }
}

extern "C" NPP_EXPORT intptr_t messageProc(uint32_t m, uintptr_t w, intptr_t l) {
    (void)m; (void)w; (void)l; return 1;
}
