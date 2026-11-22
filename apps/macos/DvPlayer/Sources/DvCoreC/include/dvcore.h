// 共享核心（core/media，Rust）的 C ABI。
//
// 所有业务逻辑都在 Rust 里，界面只认 JSON：每个函数返回一段
// `{"ok":true,"data":...}` / `{"ok":false,"error":"..."}`，
// 用完必须 dv_string_free。
#ifndef DVCORE_H
#define DVCORE_H

#include <stdint.h>

typedef void *DVHub;

DVHub dv_hub_new(void);
void dv_hub_free(DVHub handle);

char *dv_hub_add(DVHub handle, const char *config);
/// 并行添加并登录多个源，configs 是 SourceConfig 的 JSON 数组。
char *dv_hub_add_many(DVHub handle, const char *configs);
char *dv_hub_sources(const DVHub handle);
char *dv_hub_libraries(const DVHub handle);

char *dv_hub_items(const DVHub handle, const char *library_id,
                   int32_t page, int32_t page_size, const char *query);
char *dv_hub_children(const DVHub handle, const char *parent_id,
                      int32_t page, int32_t page_size, const char *query);
char *dv_hub_genres(const DVHub handle, const char *scope_id);
char *dv_hub_search(const DVHub handle, const char *query);

char *dv_hub_detail(const DVHub handle, const char *item_id);
char *dv_hub_item_sources(const DVHub handle, const char *item_id);
char *dv_hub_people(const DVHub handle, const char *item_id);
char *dv_hub_person_works(const DVHub handle, const char *person_id);
char *dv_hub_media_info(const DVHub handle, const char *item_id);
char *dv_hub_play_source(const DVHub handle, const char *item_id);

char *dv_hub_records(const DVHub handle);
char *dv_hub_report_progress(const DVHub handle, const char *item_id,
                             int64_t position, int64_t duration);
char *dv_hub_report_stopped(const DVHub handle, const char *item_id,
                            int64_t position, int64_t duration);

/* Dolby Vision P7 的 FEL / MEL 判定：只读码流前缀，找不到 RPU 返回 ok=false。 */
char *dv_probe_dovi(const char *url, const char *headers_json, const char *proxy);
char *dv_hub_set_favorite(const DVHub handle, const char *item_id, int32_t favorite);
char *dv_hub_set_watched(const DVHub handle, const char *item_id, int32_t watched);
char *dv_hub_remove_record(const DVHub handle, const char *item_id);
char *dv_hub_favorites(const DVHub handle, int32_t page, int32_t page_size);

char *dv_hub_image_source(const DVHub handle, const char *path);
char *dv_version(void);

void dv_string_free(char *text);

#endif
