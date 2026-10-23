#ifndef EVERYTHING_H
#define EVERYTHING_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef int32_t EVERYTHING_BOOL;
#define EVERYTHING_REQUEST_FILE_NAME 0x00000001u
#define EVERYTHING_REQUEST_PATH 0x00000002u
#define EVERYTHING_REQUEST_FULL_PATH_AND_FILE_NAME 0x00000004u
#define EVERYTHING_REQUEST_EXTENSION 0x00000008u
#define EVERYTHING_REQUEST_SIZE 0x00000010u
#define EVERYTHING_REQUEST_DATE_CREATED 0x00000020u
#define EVERYTHING_REQUEST_DATE_MODIFIED 0x00000040u
#define EVERYTHING_REQUEST_DATE_ACCESSED 0x00000080u
#define EVERYTHING_REQUEST_ATTRIBUTES 0x00000100u
#define EVERYTHING_REQUEST_FILE_LIST_FILE_NAME 0x00000200u
#define EVERYTHING_REQUEST_RUN_COUNT 0x00000400u
#define EVERYTHING_REQUEST_DATE_RUN 0x00000800u
#define EVERYTHING_REQUEST_DATE_RECENTLY_CHANGED 0x00001000u
EVERYTHING_BOOL Everything_SetSearchA(const char *search);
EVERYTHING_BOOL Everything_SetSearchW(const uint16_t *search);
EVERYTHING_BOOL Everything_SetRequestFlags(uint32_t flags);
EVERYTHING_BOOL Everything_SetMax(uint32_t max);
EVERYTHING_BOOL Everything_SetOffset(uint32_t offset);
EVERYTHING_BOOL Everything_SetSort(uint32_t sort);
EVERYTHING_BOOL Everything_SetSortAscending(void);
EVERYTHING_BOOL Everything_SetSortDescending(void);
EVERYTHING_BOOL Everything_Query(EVERYTHING_BOOL wait);
EVERYTHING_BOOL Everything_IsDBLoaded(void);
void Everything_Reset(void);
uint32_t Everything_GetLastError(void);
uint32_t Everything_GetNumResults(void);
uint32_t Everything_GetNumFileResults(void);
uint32_t Everything_GetNumFolderResults(void);
uint32_t Everything_GetResultFullPathNameA(uint32_t index, char *buffer, uint32_t length);
uint32_t Everything_GetResultFullPathNameW(uint32_t index, uint16_t *buffer, uint32_t length);
uint32_t Everything_GetResultFileNameA(uint32_t index, char *buffer, uint32_t length);
uint32_t Everything_GetResultFileNameW(uint32_t index, uint16_t *buffer, uint32_t length);
uint64_t Everything_GetResultSize(uint32_t index);
int64_t Everything_GetResultDateModified(uint32_t index);
int64_t Everything_GetResultDateCreated(uint32_t index);
int64_t Everything_GetResultDateAccessed(uint32_t index);
uint32_t Everything_GetResultAttributes(uint32_t index);
#ifdef __cplusplus
}
#endif
#endif
