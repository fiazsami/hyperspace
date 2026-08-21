/* The one main() the whole submodule links against, plus the registry storage
 * the constructors in harness.h write into.
 *
 * A second main() anywhere under tests/ is a link error that takes the entire
 * submodule's gate down, so topic files never define one. See
 * .claude/skills/testing/SKILL.md in the superproject.
 */

#include "harness.h"

#include <cstdio>

namespace {

/* A plain array rather than a container: harness_register runs from
 * __attribute__((constructor)), which can execute before the dynamic
 * initialisation of a std::vector at namespace scope. Zero-initialised static
 * storage is ready before any constructor runs. */
const int kMaxCases = 512;

struct Registration {
    const char *name;
    harness_case_fn fn;
};

Registration g_cases[kMaxCases];
int g_case_count = 0;
int g_overflow = 0;

int g_current_failures = 0;

}  // namespace

extern "C" void harness_register(const char *name, harness_case_fn fn)
{
    if (g_case_count >= kMaxCases) {
        /* Silently dropping cases would make the suite quietly weaker as it
         * grows, which is the failure this whole harness exists to avoid. */
        g_overflow++;
        return;
    }
    g_cases[g_case_count].name = name;
    g_cases[g_case_count].fn = fn;
    g_case_count++;
}

extern "C" void harness_fail(const char *file, int line, const char *expr)
{
    std::printf("  FAIL %s:%d  CHECK(%s)\n", file, line, expr);
    g_current_failures++;
}

extern "C" void harness_fail_near(const char *file, int line, const char *expr,
                                  double actual, double expected, double tolerance)
{
    std::printf("  FAIL %s:%d  %s\n", file, line, expr);
    std::printf("       actual %.9g, expected %.9g, tolerance %.9g\n",
                actual, expected, tolerance);
    g_current_failures++;
}

int main()
{
    if (g_overflow > 0) {
        std::printf("harness: %d case(s) did not fit in the registry "
                    "(kMaxCases = %d) -- raise it in main.cpp\n",
                    g_overflow, kMaxCases);
        return 1;
    }

    int failed_cases = 0;
    for (int i = 0; i < g_case_count; i++) {
        g_current_failures = 0;
        g_cases[i].fn();
        if (g_current_failures > 0) {
            std::printf("FAILED %s (%d check%s)\n", g_cases[i].name,
                        g_current_failures, g_current_failures == 1 ? "" : "s");
            failed_cases++;
        }
    }

    std::printf("%d case%s, %d failed\n", g_case_count,
                g_case_count == 1 ? "" : "s", failed_cases);

    /* Non-zero means the gate reports no coverage at all: a number from a
     * partial run would be a lie. */
    return failed_cases == 0 ? 0 : 1;
}
