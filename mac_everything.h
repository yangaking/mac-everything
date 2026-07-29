#ifndef mac_everything_h
#define mac_everything_h

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct {
    char** paths;
    size_t count;
} CSearchResult;

void init_engine(const char* root_path);
CSearchResult* search(const char* query, size_t limit, bool enable_path_search, uint8_t sort_col, bool sort_asc);
void free_search_results(CSearchResult* res);

#endif /* mac_everything_h */
