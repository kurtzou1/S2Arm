/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors */
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "dev_policy_table.h"

#ifdef __cplusplus
extern "C" {
#endif

struct s2a_dev_facts;
struct s2a_dev_cost_profile;
struct s2a_dev_workload_budget;

struct s2a_dev_policy_inputs {
    const struct s2a_dev_facts *facts;
    /* Later phases can supply these once there is a measured trade-off.
     * Current defaults depend only on facts. Missing inputs are valid. */
    const struct s2a_dev_cost_profile *cost;
    const struct s2a_dev_workload_budget *budget;
};

enum s2a_policy_id {
#define ITEM(id, name, class, repr, requires, consumers, off, on, other) S2A_POLICY_##id,
    S2A_DEV_POLICY_ITEMS(ITEM)
#undef ITEM
    S2A_POLICY_COUNT
};

enum s2a_policy_class {
    S2A_POLICY_SEMANTIC, S2A_POLICY_CORE, S2A_POLICY_EXTENSION, S2A_POLICY_FACT,
};

enum s2a_policy_basis {
    S2A_POLICY_BASELINE, S2A_POLICY_QUERY, S2A_POLICY_UNKNOWN,
};

enum s2a_policy_representation {
    S2A_POLICY_CHOICE, S2A_POLICY_HEX, S2A_POLICY_DECIMAL,
};

struct s2a_policy_meta {
    const char *name;
    enum s2a_policy_class class_id;
    enum s2a_policy_representation representation;
    const char *requires;
    const char *consumers;
    const char *values[3];
};

struct s2a_policy_item {
    uint64_t value;  /* Only meaningful when the basis is not UNKNOWN. */
    enum s2a_policy_basis basis;
    const char *evidence;
};

struct s2a_dev_policy {
    struct s2a_policy_item items[S2A_POLICY_COUNT];
};

/* Pure compatibility derivation. It describes the current defaults before
 * device creation, including missing facts. It does not claim actual enables. */
int s2a_dev_policy_derive(const struct s2a_dev_policy_inputs *inputs, struct s2a_dev_policy *out);
const struct s2a_policy_meta *s2a_dev_policy_meta(enum s2a_policy_id id);
const struct s2a_policy_item *s2a_dev_policy_get(const struct s2a_dev_policy *policy, enum s2a_policy_id id);
int s2a_dev_policy_summary(const struct s2a_dev_policy *policy, const char *digest, char *out, size_t cap);

#ifdef __cplusplus
}
#endif
