// #279 Mac 游戏窗口焦点判定（runtime/include/s2a_mac_focus.h），期望按头文件注释手写；再对 front_mac.m / textinput_mac.m 做接线断言
#include "../include/s2a_mac_focus.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int failures, checks;
static void check(int ok, const char *what) { checks++; if (!ok) { failures++; fprintf(stderr, "✗ %s\n", what); } }
static char *slurp(const char *path) {
    FILE *f = fopen(path, "rb"); if (!f) { fprintf(stderr, "打不开 %s\n", path); exit(2); }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)n + 1); if (fread(b, 1, (size_t)n, f) != (size_t)n) exit(2); b[n] = 0; fclose(f); return b;
}
// 从 start 起到行尾那一段里有没有 needle（接线断言只看单行方法体）
static int line_has(const char *src, const char *start, const char *needle) {
    const char *p = strstr(src, start); if (!p) return -1;
    const char *e = strchr(p, '\n'); size_t n = e ? (size_t)(e - p) : strlen(p);
    char *line = strndup(p, n); int r = strstr(line, needle) != NULL; free(line); return r;
}
int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "用法：t_mac_focus <front_mac.m> <textinput_mac.m>\n"); return 2; }
    // 平常：游戏窗口是 key 就在前台
    check(s2a_mac_game_focused(true, true, false, false), "App 活跃、游戏窗口是 key：前台");
    // #279：游戏叫出的系统输入框挂在游戏窗口上，抢走 key 也照旧前台
    check(s2a_mac_game_focused(true, false, true, true), "自家输入框挂在游戏窗口上是 key：前台（#279）");
    // 反例：切到别的 App
    check(!s2a_mac_game_focused(false, true, false, false), "切到别的 App（游戏窗口仍记着 key）：失焦");
    check(!s2a_mac_game_focused(false, false, true, true), "输入框开着时切到别的 App：失焦");
    // 反例：点到本 App 别的窗口（键位窗口等）
    check(!s2a_mac_game_focused(true, false, false, false), "本 App 别的窗口是 key：失焦");
    // 反例：不是我们登记的输入框（别的 sheet / 已答复正在收起的输入框）
    check(!s2a_mac_game_focused(true, false, false, true), "游戏窗口上别的 sheet 是 key：失焦");
    // 反例：登记的输入框没挂在游戏窗口上（没有宿主窗口时走 runModal）
    check(!s2a_mac_game_focused(true, false, true, false), "输入框不挂在游戏窗口上：失焦");

    char *front = slurp(argv[1]), *ti = slurp(argv[2]);
    check(line_has(front, "- (void)windowDidResignKey:", "game_window_focused(self.window)") == 1, "windowDidResignKey 按 key window 落点报焦点");
    check(line_has(front, "- (void)windowDidResignKey:", "display_focus_publish(NO)") == 0, "windowDidResignKey 不再无条件报失焦");
    check(line_has(front, "- (void)windowDidResignKey:", "reset_input()") == 1, "windowDidResignKey 照旧复位本机输入");
    check(line_has(front, "- (void)windowDidResignKey:", "focused = NO") == 1, "windowDidResignKey 照旧停喂本机键鼠");
    check(line_has(front, "- (void)applicationDidResignActive:", "display_focus_publish(NO)") == 1, "切出 App 照旧报失焦");
    check(line_has(front, "- (void)applicationDidBecomeActive:", "game_window_focused(self.window)") == 1, "回到 App（输入框还开着）也按同一判定");
    check(line_has(front, "- (void)windowDidBecomeKey:", "game_window_focused(self.window)") == 1, "windowDidBecomeKey 按同一判定");
    check(strstr(front, "NSApp.isActive && self.window.isKeyWindow") == NULL && strstr(front, ".isActive && window.isKeyWindow") == NULL
          && strstr(front, "isActive && d.window.isKeyWindow") == NULL && strstr(front, "isActive && g_delegate.window.isKeyWindow") == NULL,
          "front_mac.m 不留旧的 isActive && isKeyWindow 判定");
    check(strstr(front, "s2a_text_input_mac_is_input_window(key)") != NULL, "判定查的是当前 key window 是不是登记中的输入框");
    check(strstr(ti, "int s2a_text_input_mac_is_input_window(NSWindow *w)") != NULL, "textinput_mac.m 导出输入框识别");
    check(strstr(ti, "!in.answered && in.alert.window == w") != NULL, "已答复的输入框不算");

    printf("%s t_mac_focus：%d / %d\n", failures ? "✗" : "✓", checks - failures, checks);
    return failures ? 1 : 0;
}
