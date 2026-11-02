#ifndef CHANGE_LOCATION_NATIVE_H
#define CHANGE_LOCATION_NATIVE_H
#ifdef __cplusplus
extern "C" {
#endif
// Both input and result are UTF-8 JSON. Call off the main thread. Free each result.
char *cl_request(const char *request);
void cl_free(char *response);
#ifdef __cplusplus
}
#endif
#endif
