/*
 * spb_fuzz_driver.c - a small stand-in for libFuzzer's main (D-042).
 *
 * Apple's clang ships no libFuzzer runtime, so the harnesses
 * (LLVMFuzzerTestOneInput) are linked with this driver instead: it runs
 * every seed in the corpus, then a deterministic number of mutated
 * inputs, under whatever sanitizers the build uses. With an LLVM clang
 * the same harnesses link with -fsanitize=fuzzer and this file is left
 * out (SPB_LIBFUZZER).
 *
 *   spb_fuzz_<target> [-runs=N] [-seed=S] [-max_len=L] [-artifact=PATH]
 *                     corpus-dir-or-file...
 *
 * Before each input runs it is the "current input"; if the process dies
 * (sanitizer report, abort, signal) that input is written to the
 * artifact path (default fuzz-<pid>.crash) for reproduction: pass the
 * file back as the only argument with -runs=0.
 */

#include <dirent.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Every harness defines all three. */
int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size);
int LLVMFuzzerInitialize(int *argc, char ***argv);
/* NULL-terminated tokens the mutator splices in. */
extern const char *const spb_fuzz_dictionary[];

#if defined(__has_feature)
#if __has_feature(address_sanitizer) || __has_feature(thread_sanitizer)
#define SPB_HAVE_SANITIZER 1
void __sanitizer_set_death_callback(void (*callback)(void));
#endif
#endif

typedef struct input { uint8_t *data; size_t size; } input;

static input *corpus;
static size_t n_corpus, corpus_cap;
static const uint8_t *current;
static size_t current_size;
static char artifact[1024];

static void add_input(const uint8_t *data, size_t size)
{
    if (n_corpus == corpus_cap) {
        corpus_cap = corpus_cap ? 2 * corpus_cap : 64;
        corpus = realloc(corpus, corpus_cap * sizeof(*corpus));
    }
    corpus[n_corpus].data = malloc(size ? size : 1);
    memcpy(corpus[n_corpus].data, data, size);
    corpus[n_corpus].size = size;
    n_corpus++;
}

static void load_file(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        perror(path);
        exit(2);
    }
    uint8_t *buf = NULL;
    size_t size = 0, cap = 0, n;
    do {
        if (size + 4096 > cap)
            buf = realloc(buf, cap = 2 * cap + 4096);
        n = fread(buf + size, 1, cap - size, f);
        size += n;
    } while (n > 0);
    fclose(f);
    add_input(buf, size);
    free(buf);
}

static void load_path(const char *path)
{
    struct stat st;
    if (stat(path, &st) < 0) {
        perror(path);
        exit(2);
    }
    if (!S_ISDIR(st.st_mode)) {
        load_file(path);
        return;
    }
    /* Sorted, so that a given seed always mutates the same inputs. */
    struct dirent **names;
    int n = scandir(path, &names, NULL, alphasort);
    for (int i = 0; i < n; i++) {
        if (names[i]->d_name[0] != '.') {
            char full[2048];
            snprintf(full, sizeof(full), "%s/%s", path, names[i]->d_name);
            load_file(full);
        }
        free(names[i]);
    }
    free(names);
}

/* Async-signal-safe: write the input being run. */
static void save_current(void)
{
    if (!current)
        return;
    int fd = open(artifact, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0)
        return;
    size_t done = 0;
    while (done < current_size) {
        ssize_t w = write(fd, current + done, current_size - done);
        if (w <= 0)
            break;
        done += (size_t)w;
    }
    close(fd);
    static const char msg[] = "spb_fuzz: crashing input saved to ";
    write(2, msg, sizeof(msg) - 1);
    write(2, artifact, strlen(artifact));
    write(2, "\n", 1);
}

static void on_signal(int sig)
{
    save_current();
    signal(sig, SIG_DFL);
    raise(sig);
}

static void run(const uint8_t *data, size_t size)
{
    current = data;
    current_size = size;
    LLVMFuzzerTestOneInput(data, size);
    current = NULL;
}

/* xorshift64*: deterministic for a given seed. */
static uint64_t rng_state;
static uint64_t rnd(void)
{
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return rng_state * 2685821657736338717ULL;
}
static size_t below(size_t n) { return n ? (size_t)(rnd() % n) : 0; }

static size_t n_dictionary(void)
{
    size_t n = 0;
    while (spb_fuzz_dictionary[n])
        n++;
    return n;
}

/* Insert len bytes at pos, if they fit. */
static size_t insert(uint8_t *buf, size_t size, size_t max, size_t pos,
                     const uint8_t *bytes, size_t len)
{
    if (size + len > max)
        return size;
    memmove(buf + pos + len, buf + pos, size - pos);
    memcpy(buf + pos, bytes, len);
    return size + len;
}

static size_t mutate(uint8_t *buf, size_t size, size_t max)
{
    size_t ndict = n_dictionary();
    int count = 1 + (int)below(8);
    for (int i = 0; i < count; i++) {
        size_t pos = below(size + 1);
        switch (below(8)) {
          case 0:                                  /* flip a bit */
            if (size)
                buf[below(size)] ^= (uint8_t)(1u << below(8));
            break;
          case 1:                                  /* set a byte */
            if (size)
                buf[below(size)] = (uint8_t)rnd();
            break;
          case 2: {                                /* insert random bytes */
            uint8_t bytes[8];
            size_t len = 1 + below(sizeof(bytes));
            for (size_t j = 0; j < len; j++)
                bytes[j] = (uint8_t)rnd();
            size = insert(buf, size, max, pos, bytes, len);
            break;
          }
          case 3: {                                /* delete a range */
            if (!size)
                break;
            size_t start = below(size), len = 1 + below(size - start);
            memmove(buf + start, buf + start + len, size - start - len);
            size -= len;
            break;
          }
          case 4: {                                /* duplicate a range */
            if (!size)
                break;
            size_t start = below(size), len = 1 + below(size - start);
            if (len > 64)
                len = 64;
            uint8_t copy[64];
            memcpy(copy, buf + start, len);
            size = insert(buf, size, max, pos, copy, len);
            break;
          }
          case 5: case 6:                          /* a dictionary token */
            if (ndict) {
                const char *tok = spb_fuzz_dictionary[below(ndict)];
                size = insert(buf, size, max, pos, (const uint8_t *)tok,
                              strlen(tok));
            }
            break;
          case 7: {                                /* splice another input */
            if (!n_corpus)
                break;
            input *other = &corpus[below(n_corpus)];
            if (!other->size)
                break;
            size_t start = below(other->size);
            size_t len = 1 + below(other->size - start);
            if (len > 256)
                len = 256;
            size = insert(buf, size, max, pos, other->data + start, len);
            break;
          }
        }
    }
    return size;
}

int main(int argc, char **argv)
{
    long runs = 1000, max_len = 4096;
    unsigned long long seed = 1;
    snprintf(artifact, sizeof(artifact), "fuzz-%d.crash", (int)getpid());

    LLVMFuzzerInitialize(&argc, &argv);

    for (int i = 1; i < argc; i++) {
        if (!strncmp(argv[i], "-runs=", 6))
            runs = atol(argv[i] + 6);
        else if (!strncmp(argv[i], "-seed=", 6))
            seed = strtoull(argv[i] + 6, NULL, 0);
        else if (!strncmp(argv[i], "-max_len=", 9))
            max_len = atol(argv[i] + 9);
        else if (!strncmp(argv[i], "-artifact=", 10))
            snprintf(artifact, sizeof(artifact), "%s", argv[i] + 10);
        else if (argv[i][0] == '-') {
            fprintf(stderr, "unknown option %s\n", argv[i]);
            return 2;
        } else
            load_path(argv[i]);
    }
    const char *env_runs = getenv("SPB_FUZZ_RUNS");
    if (env_runs)
        runs = atol(env_runs);
    if (max_len < 1)
        max_len = 1;

#ifdef SPB_HAVE_SANITIZER
    __sanitizer_set_death_callback(save_current);
#endif
    signal(SIGSEGV, on_signal);
    signal(SIGBUS, on_signal);
    signal(SIGABRT, on_signal);
    signal(SIGILL, on_signal);
    signal(SIGFPE, on_signal);

    for (size_t i = 0; i < n_corpus; i++)
        run(corpus[i].data, corpus[i].size);

    rng_state = seed ? seed : 1;
    uint8_t *buf = malloc((size_t)max_len);
    for (long r = 0; r < runs; r++) {
        size_t size = 0;
        if (n_corpus) {
            input *base = &corpus[below(n_corpus)];
            size = base->size < (size_t)max_len ? base->size : (size_t)max_len;
            memcpy(buf, base->data, size);
        }
        size = mutate(buf, size, (size_t)max_len);
        /* Copy to an exact-size buffer so that ASan sees any read past
         * the end of the input. */
        uint8_t *exact = malloc(size ? size : 1);
        memcpy(exact, buf, size);
        run(exact, size);
        free(exact);
    }
    free(buf);

    fprintf(stderr, "spb_fuzz: %zu seed input(s), %ld mutated run(s), "
            "seed %llu: no crash\n", n_corpus, runs, seed);
    for (size_t i = 0; i < n_corpus; i++)
        free(corpus[i].data);
    free(corpus);
    return 0;
}
