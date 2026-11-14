// 诊断脱敏：三端身份规则以 tests/fixtures/redact_cases.tsv 为共同契约。
#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "diagredact.h"

static NSString *replace(NSString *s, NSString *pattern, NSString *value) {
    NSError *error = nil;
    NSRegularExpression *rule = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:&error];
    if (!rule || error) return nil;
    return [rule stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:value];
}

// Scan identity values before shape rules; never stop at an escaped quote or a space in an unterminated value.
static NSString *redact_assignments(NSString *s) {
    NSError *error = nil;
    NSRegularExpression *keys = [NSRegularExpression regularExpressionWithPattern:@"(?i)(?<![A-Z0-9_.-])[\"']?(?:udid|uuid|serial(?:number)?|device[_-]?id)[\"']?[ \\t]*[:=][ \\t]*" options:0 error:&error];
    if (!keys || error) return nil;
    NSMutableString *result = [NSMutableString string];
    NSUInteger cursor = 0;
    for (NSTextCheckingResult *match in [keys matchesInString:s options:0 range:NSMakeRange(0, s.length)]) {
        if (NSMaxRange(match.range) <= cursor) continue;
        NSUInteger start = NSMaxRange(match.range);
        unichar first = start < s.length ? [s characterAtIndex:start] : 0;
        BOOL quoted = first == '"' || first == '\'';
        unichar quote = quoted ? first : 0;
        NSUInteger end = start + (quoted ? 1 : 0);
        while (end < s.length) {
            unichar c = [s characterAtIndex:end];
            if (c == '\r' || c == '\n') break;
            if (quote) {
                if (c == '\\') {
                    end++;
                    if (end < s.length && [s characterAtIndex:end] != '\r' && [s characterAtIndex:end] != '\n') end++;
                } else { if (c == quote) quote = 0; end++; }
            } else if (c == '"' || c == '\'') {
                quote = c; end++;
            } else if ([NSCharacterSet.whitespaceCharacterSet characterIsMember:c] || c == ',' || c == ';' || c == '}' || (quoted && c == ']')) {
                break;
            } else { end++; }
        }
        if (end > start) {
            [result appendString:[s substringWithRange:NSMakeRange(cursor, start - cursor)]];
            NSString *mark = quoted ? (first == '"' ? @"\"" : @"'") : @"";
            [result appendFormat:@"%@[REDACTED]%@", mark, quoted && !quote ? mark : @""];
            cursor = end;
        }
    }
    [result appendString:[s substringFromIndex:cursor]];
    return result;
}

static char *redact_one(const char *text) {
    @autoreleasepool {
        NSString *s = [[NSString alloc] initWithUTF8String:text];
        if (!s) return NULL;
        s = redact_assignments(s);
        if (!s) return NULL;
        // 保留 iOS 原有容器路径脱敏；不依赖 UIKit，设备实际名字仍由 diag.m 先替换。
        NSArray<NSArray<NSString *> *> *rules = @[
            @[@"(/private)?/var/mobile/Containers/(?:Data/Application|Shared/AppGroup)/[0-9A-Fa-f-]{36}", @"<APP>"],
            @[@"(/private)?/var/containers/Bundle/Application/[0-9A-Fa-f-]{36}", @"<BUNDLE>"],
            @[@"/Users/[^/\\s]+", @"/Users/<用户>"],
            @[@"(?i)((?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])(?:contact|email|mail|from|to|reply[_-]?to|user)[\"']?[ \\t]*[:=][ \\t]*[\"']?)[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])", @"$1[EMAIL]"],
            @[@"(?i)(?<![A-Z0-9.!#$%&'*+/=?^_`{|}~-])[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?(?:\\.[A-Z0-9](?:[A-Z0-9-]*[A-Z0-9])?)+(?![A-Z0-9-])", @"[EMAIL]"],
            @[@"(?i)(\\bDEVELOPMENT_TEAM[ \\t]*=[ \\t]*[\"']?|\\bSigning[ \\t]+with[ \\t]+team[ \\t]+)(?<![A-Z0-9])[A-Z0-9]{10}(?![A-Z0-9])", @"$1[TEAM_ID]"],
            @[@"(?i)(?<![A-Z0-9])(s2arm\\.)[A-Z0-9]{10}(\\.[A-F0-9]{16})(?![A-Z0-9])", @"$1[TEAM_ID]$2"],
            @[@"(?i)(?<![A-Z0-9])[A-F0-9]{8}-[A-F0-9]{16}(?![A-Z0-9])", @"[DEVICE_ID]"]
        ];
        for (NSArray<NSString *> *rule in rules) {
            s = replace(s, rule[0], rule[1]);
            if (!s) return NULL;
        }
        // 旧式 40hex 只在同一物理行有设备上下文时脱敏；不能误伤 git 提交号。
        NSRegularExpression *context = [NSRegularExpression regularExpressionWithPattern:@"(?i)\\b(?:udid|device|serial)\\b" options:0 error:nil];
        NSRegularExpression *physicalLine = [NSRegularExpression regularExpressionWithPattern:@"[^\\r\\n]+" options:0 error:nil];
        if (!context || !physicalLine) return NULL;
        NSMutableString *result = [s mutableCopy];
        NSArray<NSTextCheckingResult *> *matches = [physicalLine matchesInString:s options:0 range:NSMakeRange(0, s.length)];
        for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
            NSString *line = [s substringWithRange:match.range];
            if ([context firstMatchInString:line options:0 range:NSMakeRange(0, line.length)]) {
                NSString *out = replace(line, @"(?i)(?<![A-Z0-9])[A-F0-9]{40}(?![A-Z0-9])", @"[DEVICE_ID]");
                if (!out) return NULL;
                [result replaceCharactersInRange:match.range withString:out];
            }
        }
        s = replace(result, @"[^\\s\"'<>:=,;{}\\[\\]，。]+的(iPhone|iPad)", @"[DEVICE_NAME]的$1");
        const char *utf8 = s.UTF8String;
        return utf8 ? strdup(utf8) : NULL;
    }
}

// 按行边界分块逐块脱敏（11-14 诊断 D-GT8W：几 MB 的日志整份变成 NSString 后每条规则整份拷贝一遍，
//   iPad 上导出诊断时 stringByReplacingMatchesInString 内部分配失败——NSMallocException / appendString: nil——App 崩掉，最需要诊断的玩家导不出包）。
//   规则全在一行之内（redact_assignments 遇换行停、各正则的字符类都排除换行），按换行切块与整份处理结果逐字节相同；
//   一块失败整份返回 NULL（调用方拒绝写出原文，不漏敏感信息）
#define REDACT_CHUNK (256u << 10)
char *s2a_diag_redact(const char *text) {
    if (!text) return NULL;
    size_t n = strlen(text);
    if (n <= REDACT_CHUNK) return redact_one(text);
    size_t cap = n + n / 8 + 64, len = 0; char *out = malloc(cap);
    if (!out) return NULL;
    for (size_t at = 0; at < n; ) {
        size_t end = at + REDACT_CHUNK < n ? at + REDACT_CHUNK : n;
        if (end < n) {   // 切在这一块里最后一个换行之后；整块没有换行（超长单行）就整行带上
            const char *nl = NULL;
            for (const char *q = text + end - 1; q >= text + at; q--) if (*q == '\n') { nl = q; break; }
            if (nl) end = (size_t)(nl - text) + 1;
            else { const char *f = strchr(text + end, '\n'); end = f ? (size_t)(f - text) + 1 : n; }
        }
        char *piece = malloc(end - at + 1);
        if (!piece) { free(out); return NULL; }
        memcpy(piece, text + at, end - at); piece[end - at] = 0;
        char *clean = redact_one(piece); free(piece);
        if (!clean) { free(out); return NULL; }
        size_t m = strlen(clean);
        if (len + m + 1 > cap) {
            size_t nc = (len + m + 1) * 2; char *grown = realloc(out, nc);
            if (!grown) { free(clean); free(out); return NULL; }
            out = grown; cap = nc;
        }
        memcpy(out + len, clean, m); len += m; free(clean);
        at = end;
    }
    out[len] = 0;
    return out;
}
