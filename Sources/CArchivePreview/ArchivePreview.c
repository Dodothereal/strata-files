#include "CArchivePreview.h"
#include "ArchiveAPI.h"
#include <sys/stat.h>
#include <sys/resource.h>
#include <sandbox.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <locale.h>
#include <errno.h>
#include <pthread.h>
#include <mach/mach.h>

/* The worker never creates files. Its only archive input is the parent's pinned descriptor 3.
 * Output is a bounded binary stream, never tar or executable metadata. Passwords arrive on stdin. */
enum { password_error = 40, limit_error = 41, unsafe_error = 42, read_error = 43, missing_error = 44 };
static const uint64_t byte_limit = 60ULL << 20;
struct source { unsigned char buffer[65536]; uint64_t read; off_t size; };
static int exact_read(int fd, void *bytes, size_t count) {
    unsigned char *p = bytes;
    while (count) {
        ssize_t n = read(fd, p, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        p += n; count -= (size_t)n;
    }
    return 1;
}
static int emit(const void *bytes, size_t count) {
    const unsigned char *p = bytes;
    while (count) {
        ssize_t n = write(STDOUT_FILENO, p, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return 0;
        p += n; count -= (size_t)n;
    }
    return 1;
}
static uint32_t read32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}
static int number(uint64_t value, unsigned count) {
    unsigned char bytes[8];
    for (unsigned i = 0; i < count; ++i) bytes[count-i-1] = (unsigned char)(value >> (8*i));
    return emit(bytes, count);
}
static ssize_t input(struct archive *a, void *context, const void **buffer) {
    (void)a;
    struct source *s = context;
    if (s->read >= (1ULL << 30)) return -1;
    ssize_t n;
    do { n = read(3, s->buffer, sizeof(s->buffer)); } while (n < 0 && errno == EINTR);
    if (n > 0) s->read += (uint64_t)n;
    *buffer = s->buffer;
    return n;
}
static int64_t seek_input(struct archive *a, void *context, int64_t offset, int whence) {
    (void)a;
    struct source *s = context;
    off_t base = whence == SEEK_SET ? 0 : whence == SEEK_END ? s->size : lseek(3, 0, SEEK_CUR);
    if (base < 0 || (offset > 0 && base > INT64_MAX-offset) || (offset < 0 && offset < -base)) return -1;
    off_t target = base + offset;
    if (target > s->size) return -1;
    return lseek(3, target, SEEK_SET);
}
static void *watch_memory(void *unused) {
    (void)unused;
    while (1) {
        mach_task_basic_info_data_t info;
        mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
        if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count) != KERN_SUCCESS ||
            info.resident_size > (256ULL << 20)) _exit(limit_error);
        usleep(10000);
    }
    return NULL;
}
static int failure(struct archive *a) {
    const char *message = archive_error_string(a);
    if (message && strcasestr(message, "encrypted") && strcasestr(message, "not") && strcasestr(message, "supported")) return 45;
    if (message && (strcasestr(message, "passphrase") || strcasestr(message, "password") || strcasestr(message, "encrypted"))) return password_error;
    return read_error;
}
/* A data-only copy must not silently discard a second fork. The full extractor preserves it. */
static int needs_full_extraction(struct archive_entry *entry) {
    size_t size = 0;
    const unsigned char *metadata = archive_entry_mac_metadata(entry, &size);
    if (!metadata || !size) return 0;
    if (size < 26 || size > byte_limit || read32(metadata) != 0x00051607 || read32(metadata+4) != 0x00020000) return 1;
    unsigned count = ((unsigned)metadata[24] << 8) | metadata[25];
    if (count > (size-26)/12) return 1;
    for (unsigned i = 0; i < count; ++i) {
        const unsigned char *record = metadata+26+12*i;
        uint32_t offset = read32(record+4), length = read32(record+8);
        if (offset > size || length > size-offset) return 1;
        if (read32(record) == 2 && length) return 1;
    }
    return 0;
}
static int valid_path(const char *name, size_t length) {
    if (!length || length > 4096 || name[0] == '/') return 0;
    unsigned depth = 0;
    const char *start = name;
    for (size_t i = 0; i <= length; ++i) {
        unsigned char c = (unsigned char)name[i];
        if (i < length && (c < 32 || c == 127 || c == '\\')) return 0;
        if (i == length || c == '/') {
            size_t n = name+i-start;
            if (!n || n > 255 || (n == 1 && start[0] == '.') || (n == 2 && start[0] == '.' && start[1] == '.') || ++depth > 128) return 0;
            start = name+i+1;
        }
    }
    return 1;
}
int strata_archive_preview_worker(void) {
    setlocale(LC_ALL, "en_US.UTF-8");
    struct rlimit cpu = {15,15}, files = {32,32}, core = {0,0};
    if (setrlimit(RLIMIT_CPU, &cpu) || setrlimit(RLIMIT_NOFILE, &files) || setrlimit(RLIMIT_CORE, &core)) return read_error;
    // Darwin does not support a useful RLIMIT_DATA. Monitor the isolated worker's resident memory instead;
    // this is a sampled ceiling, not a per-allocation guarantee inside the system library.
    pthread_t monitor;
    if (pthread_create(&monitor, NULL, watch_memory, NULL)) return read_error;
    pthread_detach(monitor);
    char *sandbox_error = NULL;
    /* No filesystem opens, writes, network, subprocesses or device access. Already-open pipes and archive fd remain usable. */
    if (sandbox_init("(version 1)(deny default)(allow sysctl-read)(allow process-info-pidinfo)", 0, &sandbox_error)) {
        sandbox_free_error(sandbox_error); return read_error;
    }
    unsigned char request[10];
    if (!exact_read(0, request, sizeof(request)) || request[0] > 1 || request[1] > 1) return read_error;
    uint32_t path_length = read32(request+2), password_length = read32(request+6);
    if (path_length > 4096 || password_length > 1024) return limit_error;
    char selected[4097] = {0}, password[1025] = {0};
    if (!exact_read(0, selected, path_length) || !exact_read(0, password, password_length) ||
        memchr(selected, 0, path_length) || memchr(password, 0, password_length)) return read_error;
    const int extracting = request[0], folder = request[1];
    if (extracting && !valid_path(selected, path_length)) return unsafe_error;
    struct stat info;
    if (fstat(3, &info) || !S_ISREG(info.st_mode)) return read_error;
    struct source source = {.read = 0, .size = info.st_size};
    struct archive *a = archive_read_new();
    if (!a) return read_error;
    archive_read_support_filter_all(a);
    archive_read_support_format_all(a);
    archive_read_set_format_option(a, NULL, "mac-ext", "1");
    if (password_length) archive_read_add_passphrase(a, password);
    archive_read_set_seek_callback(a, seek_input);
    int result = read_error;
    if (archive_read_open2(a, &source, NULL, input, NULL, NULL) != 0) { result = failure(a); goto done; }
    if (!emit("SAP1", 4)) goto done;
    uint64_t output = 4;
    unsigned headers = 0, matched = 0;
    struct archive_entry *entry;
    int status;
    while ((status = archive_read_next_header(a, &entry)) == 0) {
        if (++headers > 50000) { result = limit_error; goto done; }
        const char *raw = archive_entry_pathname(entry);
        if (!raw) { result = unsafe_error; goto done; }
        size_t raw_length = strnlen(raw, 4098);
        if (raw_length > 4096) { result = limit_error; goto done; }
        const int relative_root = raw_length && raw[0] == '.';
        /* tar commonly prefixes ./; normalize only those whole components. */
        while (raw_length >= 2 && raw[0] == '.' && raw[1] == '/') { raw += 2; raw_length -= 2; }
        while (raw_length && raw[raw_length-1] == '/') --raw_length;
        if (!raw_length || (raw_length == 1 && raw[0] == '.')) {
            /* A relative root directory carries no member data. Files and links cannot use this exemption. */
            if (!relative_root || archive_entry_filetype(entry) != S_IFDIR ||
                archive_entry_symlink(entry) || archive_entry_hardlink(entry)) { result = unsafe_error; goto done; }
            if (archive_read_data_skip(a) < 0) { result = failure(a); goto done; }
            continue;
        }
        char path[4097]; memcpy(path, raw, raw_length); path[raw_length] = 0;
        if (!valid_path(path, raw_length)) { result = unsafe_error; goto done; }
        int chosen = !extracting || (raw_length == path_length && !memcmp(path, selected, path_length)) ||
            (folder && raw_length > path_length && !memcmp(path, selected, path_length) && path[path_length] == '/');
        if (!chosen) { if (archive_read_data_skip(a) < 0) { result = failure(a); goto done; } continue; }
        mode_t type = archive_entry_filetype(entry);
        unsigned char kind = type == S_IFDIR ? 2 : type == S_IFREG ? 1 : 3;
        if (archive_entry_symlink(entry) || archive_entry_hardlink(entry)) kind = 3;
        if (extracting && kind == 3) { result = unsafe_error; goto done; }
        if (extracting && needs_full_extraction(entry)) { result = 46; goto done; }
        int64_t size = kind == 1 ? archive_entry_size(entry) : 0;
        if (size < 0 || (extracting && (uint64_t)size > byte_limit-output)) { result = limit_error; goto done; }
        output += 21+raw_length+(extracting ? (uint64_t)size : 0);
        if (output > byte_limit) { result = limit_error; goto done; }
        if (!emit(&kind, 1) || !number(raw_length, 4) || !number((uint64_t)size, 8) ||
            !number((uint64_t)archive_entry_mtime(entry), 8) || !emit(path, raw_length)) goto done;
        ++matched;
        if (extracting && kind == 1) {
            uint64_t remaining = (uint64_t)size;
            unsigned char buffer[65536];
            while (remaining) {
                size_t count = remaining < sizeof(buffer) ? (size_t)remaining : sizeof(buffer);
                ssize_t n = archive_read_data(a, buffer, count);
                if (n <= 0) { result = failure(a); goto done; }
                if (!emit(buffer, (size_t)n)) goto done;
                remaining -= (uint64_t)n;
            }
            unsigned char extra;
            ssize_t n = archive_read_data(a, &extra, 1);
            if (n != 0) { result = n < 0 ? failure(a) : read_error; goto done; }
        } else if (archive_read_data_skip(a) < 0) { result = failure(a); goto done; }
    }
    if (status != 1) { result = failure(a); goto done; }
    if (!matched && extracting) { result = missing_error; goto done; }
    unsigned char end = 0;
    result = emit(&end, 1) ? 0 : read_error;
done:
    archive_read_free(a);
    for (volatile unsigned char *p = (volatile unsigned char *)password; p < (volatile unsigned char *)password + sizeof(password); ++p) *p = 0;
    return result;
}
