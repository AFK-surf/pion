#define _POSIX_C_SOURCE 200809L

#include "tls_abi.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netdb.h>
#include <openssl/err.h>
#include <openssl/ssl.h>
#include <openssl/x509v3.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

typedef struct {
  SSL *ssl;
  SSL_CTX *ctx;
  int fd;
  int owns_ctx;
  int owns_fd;
} PionTlsConn;

typedef struct {
  SSL_CTX *ctx;
  int fd;
  int port;
} PionTlsListener;

static pthread_once_t g_sigpipe_once = PTHREAD_ONCE_INIT;

static void ignore_sigpipe(void) {
  signal(SIGPIPE, SIG_IGN);
}

static void set_err(char *buf, int32_t cap, const char *fmt, ...) {
  if (!buf || cap <= 0) {
    return;
  }
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, (size_t)cap, fmt, ap);
  va_end(ap);
  buf[cap - 1] = '\0';
}

static int32_t copy_cstr(const char *src, char *buf, int32_t cap) {
  if (!buf || cap <= 0) {
    return 0;
  }
  if (!src) {
    buf[0] = '\0';
    return 0;
  }
  size_t len = strlen(src);
  if (len >= (size_t)cap) {
    len = (size_t)cap - 1;
  }
  memcpy(buf, src, len);
  buf[len] = '\0';
  return (int32_t)len;
}

static void drain_openssl_errors(char *out, size_t cap) {
  if (!out || cap == 0) {
    while (ERR_get_error() != 0) {
    }
    return;
  }
  out[0] = '\0';
  size_t pos = 0;
  unsigned long e;
  while ((e = ERR_get_error()) != 0) {
    char tmp[256];
    ERR_error_string_n(e, tmp, sizeof(tmp));
    size_t n = strlen(tmp);
    if (pos > 0 && pos + 2 < cap) {
      out[pos++] = ';';
      out[pos++] = ' ';
    }
    if (pos + n >= cap) {
      n = (cap - 1) - pos;
    }
    if (n > 0) {
      memcpy(out + pos, tmp, n);
      pos += n;
    }
    out[pos] = '\0';
  }
}

static int is_ip_literal(const char *host) {
  if (!host || !host[0]) {
    return 0;
  }
  struct in_addr a4;
  if (inet_pton(AF_INET, host, &a4) == 1) {
    return 1;
  }
  struct in6_addr a6;
  if (inet_pton(AF_INET6, host, &a6) == 1) {
    return 1;
  }
  return 0;
}

const char *pion_tls_version(void) {
  return OpenSSL_version(OPENSSL_VERSION);
}

static void *openssl_client_handshake(
    int fd,
    const char *host,
    int32_t port,
    int32_t verify_cert,
    char *err_buf,
    int32_t err_cap) {
  pthread_once(&g_sigpipe_once, ignore_sigpipe);
  drain_openssl_errors(NULL, 0);

  SSL_CTX *ctx = SSL_CTX_new(TLS_client_method());
  if (!ctx) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(err_buf, err_cap, "SSL_CTX_new failed: %s", errs);
    return NULL;
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);
  if (verify_cert) {
    if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
      char errs[256];
      drain_openssl_errors(errs, sizeof(errs));
      set_err(err_buf, err_cap, "loading the default CA store failed: %s", errs);
      SSL_CTX_free(ctx);
      return NULL;
    }
    SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, NULL);
  } else {
    SSL_CTX_set_verify(ctx, SSL_VERIFY_NONE, NULL);
  }

  SSL *ssl = SSL_new(ctx);
  if (!ssl) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(err_buf, err_cap, "SSL_new failed: %s", errs);
    SSL_CTX_free(ctx);
    return NULL;
  }

  int ip = is_ip_literal(host);
  int ok = (SSL_set_fd(ssl, fd) == 1);
  if (ok && !ip && host && host[0]) {
    ok = (SSL_set_tlsext_host_name(ssl, host) == 1);
  }
  if (ok && verify_cert && host && host[0]) {
    if (ip) {
      ok = (X509_VERIFY_PARAM_set1_ip_asc(SSL_get0_param(ssl), host) == 1);
    } else {
      ok = (SSL_set1_host(ssl, host) == 1);
    }
  }
  if (!ok) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(err_buf, err_cap, "TLS session setup for %s failed: %s", host ? host : "", errs);
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    return NULL;
  }

  int rc = SSL_connect(ssl);
  if (rc != 1) {
    int ssl_err = SSL_get_error(ssl, rc);
    long vr = SSL_get_verify_result(ssl);
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    if (port >= 0) {
      if (verify_cert && vr != X509_V_OK) {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s:%d failed (rc=%d, ssl_error=%d)%s%s (certificate verify error %ld: %s)",
            host ? host : "",
            (int)port,
            rc,
            ssl_err,
            errs[0] ? ": " : "",
            errs,
            vr,
            X509_verify_cert_error_string(vr));
      } else {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s:%d failed (rc=%d, ssl_error=%d)%s%s",
            host ? host : "",
            (int)port,
            rc,
            ssl_err,
            errs[0] ? ": " : "",
            errs);
      }
    } else {
      if (verify_cert && vr != X509_V_OK) {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s failed (rc=%d, ssl_error=%d)%s%s (certificate verify error %ld: %s)",
            host ? host : "",
            rc,
            ssl_err,
            errs[0] ? ": " : "",
            errs,
            vr,
            X509_verify_cert_error_string(vr));
      } else {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s failed (rc=%d, ssl_error=%d)%s%s",
            host ? host : "",
            rc,
            ssl_err,
            errs[0] ? ": " : "",
            errs);
      }
    }
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    return NULL;
  }

  PionTlsConn *c = (PionTlsConn *)calloc(1, sizeof(PionTlsConn));
  if (!c) {
    SSL_free(ssl);
    SSL_CTX_free(ctx);
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  c->ssl = ssl;
  c->ctx = ctx;
  c->fd = fd;
  c->owns_ctx = 1;
  c->owns_fd = 1;
  return c;
}

void *pion_tls_connect(
    const char *host,
    int32_t port,
    int32_t verify_cert,
    int32_t *out_fd,
    char *err_buf,
    int32_t err_cap) {
  pthread_once(&g_sigpipe_once, ignore_sigpipe);
  if (out_fd) {
    *out_fd = -1;
  }
  if (!host || !host[0] || port < 1 || port > 65535) {
    set_err(err_buf, err_cap, "connect to %s:%d failed: invalid host or port", host ? host : "", (int)port);
    return NULL;
  }

  char port_str[16];
  snprintf(port_str, sizeof(port_str), "%d", (int)port);

  struct addrinfo hints;
  memset(&hints, 0, sizeof(hints));
  hints.ai_family = AF_UNSPEC;
  hints.ai_socktype = SOCK_STREAM;

  struct addrinfo *res = NULL;
  int gai = getaddrinfo(host, port_str, &hints, &res);
  if (gai != 0 || !res) {
    set_err(err_buf, err_cap, "connect to %s:%d failed: %s", host, (int)port, gai_strerror(gai));
    return NULL;
  }

  int fd = -1;
  int last_errno = 0;
  for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
    int s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (s < 0) {
      last_errno = errno;
      continue;
    }
    if (connect(s, ai->ai_addr, ai->ai_addrlen) == 0) {
      fd = s;
      break;
    }
    last_errno = errno;
    close(s);
  }
  freeaddrinfo(res);

  if (fd < 0) {
    set_err(err_buf, err_cap, "connect to %s:%d failed: %s", host, (int)port, strerror(last_errno));
    return NULL;
  }

  void *h = openssl_client_handshake(fd, host, port, verify_cert, err_buf, err_cap);
  if (!h) {
    close(fd);
    return NULL;
  }
  if (out_fd) {
    *out_fd = fd;
  }
  return h;
}

void *pion_tls_wrap_fd(
    int32_t fd,
    const char *host,
    int32_t verify_cert,
    char *err_buf,
    int32_t err_cap) {
  if (fd < 0) {
    set_err(err_buf, err_cap, "TLS handshake with %s failed: invalid fd %d", host ? host : "", (int)fd);
    return NULL;
  }
  return openssl_client_handshake((int)fd, host ? host : "", -1, verify_cert, err_buf, err_cap);
}

int32_t pion_tls_protocol(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionTlsConn *c = (PionTlsConn *)h;
  return copy_cstr(SSL_get_version(c->ssl), buf, cap);
}

int32_t pion_tls_cipher(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionTlsConn *c = (PionTlsConn *)h;
  const SSL_CIPHER *cipher = SSL_get_current_cipher(c->ssl);
  if (!cipher) {
    return copy_cstr("", buf, cap);
  }
  return copy_cstr(SSL_CIPHER_get_name(cipher), buf, cap);
}

int32_t pion_tls_peer_sni(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionTlsConn *c = (PionTlsConn *)h;
  const char *sni = SSL_get_servername(c->ssl, TLSEXT_NAMETYPE_host_name);
  return copy_cstr(sni ? sni : "", buf, cap);
}

int32_t pion_tls_write(
    void *h,
    const uint8_t *data,
    int32_t len,
    char *err_buf,
    int32_t err_cap) {
  if (!h) {
    set_err(err_buf, err_cap, "TLS write on closed connection");
    return -1;
  }
  if (len <= 0) {
    return 0;
  }
  pthread_once(&g_sigpipe_once, ignore_sigpipe);
  PionTlsConn *c = (PionTlsConn *)h;
  int32_t total = 0;
  while (total < len) {
    int rc = SSL_write(c->ssl, data + total, (int)(len - total));
    if (rc > 0) {
      total += rc;
      continue;
    }
    int ssl_err = SSL_get_error(c->ssl, rc);
    if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
      continue;
    }
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(
        err_buf,
        err_cap,
        "SSL_write failed (rc=%d, ssl_error=%d)%s%s",
        rc,
        ssl_err,
        errs[0] ? ": " : "",
        errs);
    return -1;
  }
  return total;
}

int32_t pion_tls_read(void *h, uint8_t *buf, int32_t max_bytes) {
  if (!h || !buf || max_bytes <= 0) {
    return 0;
  }
  PionTlsConn *c = (PionTlsConn *)h;
  for (;;) {
    int n = SSL_read(c->ssl, buf, (int)max_bytes);
    if (n > 0) {
      return (int32_t)n;
    }
    int ssl_err = SSL_get_error(c->ssl, n);
    if (ssl_err == SSL_ERROR_WANT_READ || ssl_err == SSL_ERROR_WANT_WRITE) {
      continue;
    }
    drain_openssl_errors(NULL, 0);
    if (ssl_err == SSL_ERROR_ZERO_RETURN || n == 0) {
      return 0;
    }
    return -1;
  }
}

void pion_tls_close(void *h) {
  if (!h) {
    return;
  }
  PionTlsConn *c = (PionTlsConn *)h;
  if (c->ssl) {
    SSL_shutdown(c->ssl);
    SSL_free(c->ssl);
  }
  if (c->owns_ctx && c->ctx) {
    SSL_CTX_free(c->ctx);
  }
  drain_openssl_errors(NULL, 0);
  if (c->owns_fd && c->fd >= 0) {
    close(c->fd);
  }
  free(c);
}

void *pion_tls_listen(
    const char *host,
    int32_t port,
    const char *cert_pem,
    const char *key_pem,
    int32_t *out_fd,
    int32_t *out_port,
    char *err_buf,
    int32_t err_cap) {
  pthread_once(&g_sigpipe_once, ignore_sigpipe);
  if (out_fd) {
    *out_fd = -1;
  }
  if (out_port) {
    *out_port = 0;
  }
  drain_openssl_errors(NULL, 0);

  SSL_CTX *ctx = SSL_CTX_new(TLS_server_method());
  if (!ctx) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(err_buf, err_cap, "SSL_CTX_new failed: %s", errs);
    return NULL;
  }
  SSL_CTX_set_min_proto_version(ctx, TLS1_2_VERSION);

  if (SSL_CTX_use_certificate_chain_file(ctx, cert_pem) != 1) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(err_buf, err_cap, "loading certificate chain `%s` failed: %s", cert_pem, errs);
    SSL_CTX_free(ctx);
    return NULL;
  }
  if (SSL_CTX_use_PrivateKey_file(ctx, key_pem, SSL_FILETYPE_PEM) != 1) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(err_buf, err_cap, "loading private key `%s` failed: %s", key_pem, errs);
    SSL_CTX_free(ctx);
    return NULL;
  }
  if (SSL_CTX_check_private_key(ctx) != 1) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    set_err(
        err_buf,
        err_cap,
        "private key `%s` does not match certificate `%s`: %s",
        key_pem,
        cert_pem,
        errs);
    SSL_CTX_free(ctx);
    return NULL;
  }

  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0) {
    set_err(err_buf, err_cap, "listen on %s:%d failed: %s", host ? host : "", (int)port, strerror(errno));
    SSL_CTX_free(ctx);
    return NULL;
  }
  int yes = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_port = htons((uint16_t)port);
  if (!host || !host[0]) {
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
  } else if (strcmp(host, "localhost") == 0) {
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  } else if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
    close(fd);
    SSL_CTX_free(ctx);
    set_err(err_buf, err_cap, "listen on %s:%d failed: invalid bind address", host, (int)port);
    return NULL;
  }

  if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 128) != 0) {
    int e = errno;
    close(fd);
    SSL_CTX_free(ctx);
    set_err(err_buf, err_cap, "listen on %s:%d failed: %s", host ? host : "", (int)port, strerror(e));
    return NULL;
  }

  struct sockaddr_in bound;
  socklen_t blen = sizeof(bound);
  int bound_port = (int)port;
  if (getsockname(fd, (struct sockaddr *)&bound, &blen) == 0) {
    bound_port = (int)ntohs(bound.sin_port);
  }

  PionTlsListener *l = (PionTlsListener *)calloc(1, sizeof(PionTlsListener));
  if (!l) {
    close(fd);
    SSL_CTX_free(ctx);
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  l->ctx = ctx;
  l->fd = fd;
  l->port = bound_port;
  if (out_fd) {
    *out_fd = fd;
  }
  if (out_port) {
    *out_port = bound_port;
  }
  return l;
}

void *pion_tls_accept(
    void *lh,
    int32_t *out_fd,
    char *sni_buf,
    int32_t sni_cap,
    char *err_buf,
    int32_t err_cap) {
  if (out_fd) {
    *out_fd = -1;
  }
  if (sni_buf && sni_cap > 0) {
    sni_buf[0] = '\0';
  }
  if (!lh) {
    set_err(err_buf, err_cap, "accept on closed listener");
    return NULL;
  }
  PionTlsListener *l = (PionTlsListener *)lh;
  int cfd = accept(l->fd, NULL, NULL);
  if (cfd < 0) {
    set_err(err_buf, err_cap, "accept on listener fd %d failed: %s", l->fd, strerror(errno));
    return NULL;
  }

  drain_openssl_errors(NULL, 0);
  SSL *ssl = SSL_new(l->ctx);
  if (!ssl) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    close(cfd);
    set_err(err_buf, err_cap, "SSL_new failed: %s", errs);
    return NULL;
  }
  if (SSL_set_fd(ssl, cfd) != 1) {
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    SSL_free(ssl);
    close(cfd);
    set_err(err_buf, err_cap, "SSL_set_fd failed: %s", errs);
    return NULL;
  }
  int rc = SSL_accept(ssl);
  if (rc != 1) {
    int ssl_err = SSL_get_error(ssl, rc);
    char errs[256];
    drain_openssl_errors(errs, sizeof(errs));
    SSL_free(ssl);
    close(cfd);
    set_err(
        err_buf,
        err_cap,
        "TLS server handshake failed (rc=%d, ssl_error=%d)%s%s",
        rc,
        ssl_err,
        errs[0] ? ": " : "",
        errs);
    return NULL;
  }

  const char *sni = SSL_get_servername(ssl, TLSEXT_NAMETYPE_host_name);
  copy_cstr(sni ? sni : "", sni_buf, sni_cap);

  PionTlsConn *c = (PionTlsConn *)calloc(1, sizeof(PionTlsConn));
  if (!c) {
    SSL_free(ssl);
    close(cfd);
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  c->ssl = ssl;
  c->ctx = l->ctx;
  c->fd = cfd;
  c->owns_ctx = 0;
  c->owns_fd = 1;
  if (out_fd) {
    *out_fd = cfd;
  }
  return c;
}

void pion_tls_listener_close(void *lh) {
  if (!lh) {
    return;
  }
  PionTlsListener *l = (PionTlsListener *)lh;
  if (l->ctx) {
    SSL_CTX_free(l->ctx);
  }
  drain_openssl_errors(NULL, 0);
  if (l->fd >= 0) {
    close(l->fd);
  }
  free(l);
}
