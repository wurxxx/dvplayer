/*
 * 最小 libmpv 加载探针（A0）。
 *
 * 只做三件事：dlopen libmpv.so、读 client API 版本、mpv_create/terminate。
 * 不建 Surface、不渲染——出画是 A4 的事。
 *
 * 不链 libmpv：Android 上推 .so 到 /data/local/tmp 用 LD_LIBRARY_PATH 跑，
 * 用 dlsym 拿符号最省事。
 */
#include <dlfcn.h>
#include <stdio.h>

typedef unsigned long (*mpv_client_api_version_fn)(void);
typedef void *(*mpv_create_fn)(void);
typedef const char *(*mpv_client_name_fn)(void *);
typedef void (*mpv_terminate_destroy_fn)(void *);

int main(void) {
    void *lib = dlopen("libmpv.so", RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        fprintf(stderr, "dlopen(libmpv.so) 失败: %s\n", dlerror());
        return 1;
    }

    mpv_client_api_version_fn api =
        (mpv_client_api_version_fn)dlsym(lib, "mpv_client_api_version");
    mpv_create_fn create = (mpv_create_fn)dlsym(lib, "mpv_create");
    mpv_client_name_fn name = (mpv_client_name_fn)dlsym(lib, "mpv_client_name");
    mpv_terminate_destroy_fn destroy =
        (mpv_terminate_destroy_fn)dlsym(lib, "mpv_terminate_destroy");

    if (!api || !create || !name || !destroy) {
        fprintf(stderr, "dlsym 失败: %s\n", dlerror());
        return 1;
    }

    unsigned long version = api();
    printf("libmpv client API: %lu.%lu\n", version >> 16, version & 0xFFFFu);

    void *ctx = create();
    if (!ctx) {
        fprintf(stderr, "mpv_create 失败\n");
        return 1;
    }
    printf("mpv_create ok: %s\n", name(ctx));
    destroy(ctx);
    return 0;
}
