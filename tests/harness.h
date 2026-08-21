/* Minimal test registry for the coverage gate's single test binary.
 *
 * tools/coverage.sh compiles every source under tests/ together with the
 * instrumented sources and links one executable, so cases cannot register
 * themselves from a main() that only one translation unit owns. They register
 * from __attribute__((constructor)) instead, which runs before main and works
 * identically from C, C++ and Objective-C -- this submodule's testable surface
 * is C++ today, but the header has to keep working when it is not.
 *
 * Storage and main() live in main.cpp. This header is declarations and macros
 * only, so including it from a second translation unit costs nothing.
 */

#ifndef HYPERSPACE_TESTS_HARNESS_H
#define HYPERSPACE_TESTS_HARNESS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*harness_case_fn)(void);

/* Called from constructors, so it must not depend on anything with its own
 * dynamic initialisation -- the registry is a plain array for that reason. */
void harness_register(const char *name, harness_case_fn fn);

void harness_fail(const char *file, int line, const char *expr);
void harness_fail_near(const char *file, int line, const char *expr,
                       double actual, double expected, double tolerance);

#ifdef __cplusplus
}
#endif

/* Defines the case and registers it in one step. The trailing signature lets
 * the macro be followed by a normal function body. */
#define TEST(case_name)                                                       \
    static void case_name(void);                                              \
    __attribute__((constructor)) static void harness_enroll_##case_name(void) \
    {                                                                         \
        harness_register(#case_name, case_name);                              \
    }                                                                         \
    static void case_name(void)

#define CHECK(expr)                                                           \
    do {                                                                      \
        if (!(expr)) harness_fail(__FILE__, __LINE__, #expr);                 \
    } while (0)

/* Float maths that has been through a divide or a square root does not survive
 * exact comparison across compiler versions, so every such assertion carries a
 * tolerance and reports both values when it fails. */
#define CHECK_NEAR(actual, expected, tolerance)                               \
    do {                                                                      \
        double harness_a = (double)(actual);                                  \
        double harness_e = (double)(expected);                                \
        double harness_t = (double)(tolerance);                               \
        double harness_d = harness_a - harness_e;                             \
        if (harness_d < 0) harness_d = -harness_d;                            \
        if (!(harness_d <= harness_t))                                        \
            harness_fail_near(__FILE__, __LINE__, #actual " ~= " #expected,   \
                              harness_a, harness_e, harness_t);               \
    } while (0)

#endif /* HYPERSPACE_TESTS_HARNESS_H */
