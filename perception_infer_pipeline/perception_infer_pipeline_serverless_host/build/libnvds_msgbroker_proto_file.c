#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nvds_msgapi.h"

#define FILE_PROTO_NAME "libnvds_msgbroker_proto_file"
#define FILE_PROTO_VER  "1.0"

typedef struct {
    FILE *fp;
    char path[512];
} NvDsFileProtoCtx;

// ---------------------------------------------------------------------------
// Required API symbols
// ---------------------------------------------------------------------------

char *nvds_msgapi_getversion(void) {
    return FILE_PROTO_VER;
}

char *nvds_msgapi_get_protocol_name(void) {
    return FILE_PROTO_NAME;
}

// ---------------------------------------------------------------------------
// Connect (open file for writing JSON messages)
// ---------------------------------------------------------------------------
NvDsMsgApiHandle nvds_msgapi_connect(char *connection_str,
                                     nvds_msgapi_connect_cb_t connect_cb,
                                     char *config_path)
{
    (void)config_path;

    NvDsFileProtoCtx *ctx = calloc(1, sizeof(NvDsFileProtoCtx));
    if (!ctx)
        return NULL;

    const char *out_path = (connection_str && strlen(connection_str))
                               ? connection_str
                               : "/tmp/deepstream_output.json";
    strncpy(ctx->path, out_path, sizeof(ctx->path) - 1);

    ctx->fp = fopen(ctx->path, "a");
    if (!ctx->fp) {
        perror("[file-proto] fopen");
        free(ctx);
        return NULL;
    }

    if (connect_cb)
        connect_cb(ctx, NVDS_MSGAPI_EVT_SUCCESS);

    printf("[file-proto] Connected to %s\n", ctx->path);
    return (NvDsMsgApiHandle)ctx;
}

// ---------------------------------------------------------------------------
// Send message (synchronous)
// ---------------------------------------------------------------------------
NvDsMsgApiErrorType nvds_msgapi_send(NvDsMsgApiHandle h_ptr,
                                     char *topic,
                                     const uint8_t *payload,
                                     size_t nbuf)
{
    (void)topic;
    NvDsFileProtoCtx *ctx = (NvDsFileProtoCtx *)h_ptr;
    if (!ctx || !ctx->fp)
        return NVDS_MSGAPI_ERR;

    fwrite(payload, 1, nbuf, ctx->fp);
    fputc('\n', ctx->fp);
    fflush(ctx->fp);
    return NVDS_MSGAPI_OK;
}

// ---------------------------------------------------------------------------
// Send message (asynchronous)
// ---------------------------------------------------------------------------
NvDsMsgApiErrorType nvds_msgapi_send_async(NvDsMsgApiHandle h_ptr,
                                           char *topic,
                                           const uint8_t *payload,
                                           size_t nbuf,
                                           nvds_msgapi_send_cb_t send_cb,
                                           void *user_ptr)
{
    NvDsMsgApiErrorType err = nvds_msgapi_send(h_ptr, topic, payload, nbuf);
    if (send_cb)
        send_cb(user_ptr, err);
    return err;
}

// ---------------------------------------------------------------------------
// Close connection
// ---------------------------------------------------------------------------
NvDsMsgApiErrorType nvds_msgapi_close(NvDsMsgApiHandle h_ptr)
{
    NvDsFileProtoCtx *ctx = (NvDsFileProtoCtx *)h_ptr;
    if (!ctx)
        return NVDS_MSGAPI_ERR;

    if (ctx->fp)
        fclose(ctx->fp);

    printf("[file-proto] Disconnected from %s\n", ctx->path);
    free(ctx);
    return NVDS_MSGAPI_OK;
}

// ---------------------------------------------------------------------------
// Do work (required no-op for broker thread)
// ---------------------------------------------------------------------------
void nvds_msgapi_do_work(NvDsMsgApiHandle h_ptr)
{
    (void)h_ptr;
}

