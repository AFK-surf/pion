#ifndef PION_TLS_ABI_H
#define PION_TLS_ABI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

const char *pion_tls_version(void);

void *pion_tls_connect(
    const char *host,
    int32_t port,
    int32_t verify_cert,
    int32_t *out_fd,
    char *err_buf,
    int32_t err_cap);

void *pion_tls_wrap_fd(
    int32_t fd,
    const char *host,
    int32_t verify_cert,
    char *err_buf,
    int32_t err_cap);

int32_t pion_tls_protocol(void *h, char *buf, int32_t cap);
int32_t pion_tls_cipher(void *h, char *buf, int32_t cap);
int32_t pion_tls_peer_sni(void *h, char *buf, int32_t cap);

int32_t pion_tls_write(
    void *h,
    const uint8_t *data,
    int32_t len,
    char *err_buf,
    int32_t err_cap);

int32_t pion_tls_read(void *h, uint8_t *buf, int32_t max_bytes);
void pion_tls_close(void *h);

void *pion_tls_listen(
    const char *host,
    int32_t port,
    const char *cert_pem,
    const char *key_pem,
    int32_t *out_fd,
    int32_t *out_port,
    char *err_buf,
    int32_t err_cap);

void *pion_tls_accept(
    void *lh,
    int32_t *out_fd,
    char *sni_buf,
    int32_t sni_cap,
    char *err_buf,
    int32_t err_cap);

void pion_tls_listener_close(void *lh);

#ifdef __cplusplus
}
#endif

#endif
