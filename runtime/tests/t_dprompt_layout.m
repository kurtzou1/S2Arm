// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#import "../../ios/dprompt_layout.h"
#include <math.h>
#include <stdio.h>

int main(void) {
    S2APromptLayout phone = S2APromptLayoutMake(420, 92, 2);
    S2APromptLayout small = S2APromptLayoutMake(320, 192, 2);
    S2APromptLayout wide = S2APromptLayoutMake(912, 92, 2);
    S2APromptLayout notice = S2APromptLayoutMake(320, 75, 1);
    S2APromptLayout tablet = S2APromptLayoutMake(1366, 92, 2);
    S2APromptLayout longTitle = S2APromptLayoutMake(768, 250, 2);
    int failures = 0;
#define CHECK(value) do { if (!(value)) { failures++; printf("FAIL %s\n", #value); } } while (0)
    CHECK(phone.width == 396 && phone.vertical && !phone.verticalButtons);
    CHECK(small.width == 296 && small.vertical && small.verticalButtons);
    CHECK(fabs(wide.width - 501.6) < .001 && !wide.vertical && !wide.verticalButtons);
    CHECK(notice.width == 296 && notice.vertical && !notice.verticalButtons);
    CHECK(tablet.width == 560 && !tablet.vertical && !tablet.verticalButtons);
    CHECK(fabs(longTitle.width - 422.4) < .001 && longTitle.vertical && longTitle.verticalButtons);
    CHECK(S2APromptLayoutMake(0, 75, 1).width == 0);
    printf("%s t_dprompt_layout: %d/7 checks\n", failures ? "✗" : "✓", 7 - failures);
    return failures ? 1 : 0;
}
