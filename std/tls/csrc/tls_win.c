#define SECURITY_WIN32
#define WIN32_LEAN_AND_MEAN

#include "tls_abi.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#ifndef SCHANNEL_USE_BLACKLISTS
#define SCHANNEL_USE_BLACKLISTS
#endif
#include <subauth.h>
#include <security.h>
#include <schannel.h>
#include <wincrypt.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifndef SP_PROT_TLS1_2_CLIENT
#define SP_PROT_TLS1_2_CLIENT 0x00000800
#endif
#ifndef SP_PROT_TLS1_3_CLIENT
#define SP_PROT_TLS1_3_CLIENT 0x00002000
#endif
#ifndef SP_PROT_SSL2_CLIENT
#define SP_PROT_SSL2_CLIENT 0x00000008
#endif
#ifndef SP_PROT_SSL3_CLIENT
#define SP_PROT_SSL3_CLIENT 0x00000020
#endif
#ifndef SP_PROT_TLS1_0_CLIENT
#define SP_PROT_TLS1_0_CLIENT 0x00000080
#endif
#ifndef SP_PROT_TLS1_1_CLIENT
#define SP_PROT_TLS1_1_CLIENT 0x00000200
#endif
#ifndef SCH_USE_STRONG_CRYPTO
#define SCH_USE_STRONG_CRYPTO 0x00400000
#endif

static INIT_ONCE g_wsa_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK init_wsa_cb(PINIT_ONCE once, PVOID param, PVOID *ctx) {
  (void)once;
  (void)param;
  (void)ctx;
  WSADATA wsa;
  WSAStartup(MAKEWORD(2, 2), &wsa);
  return TRUE;
}

static void ensure_wsa(void) {
  InitOnceExecuteOnce(&g_wsa_once, init_wsa_cb, NULL, NULL);
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
  return "Windows Schannel (TLS 1.2/1.3)";
}

typedef struct {
  SOCKET sock;
  CredHandle cred;
  CtxtHandle ctxt;
  SecPkgContext_StreamSizes sizes;
  int has_cred;
  int has_ctxt;
  int owns_sock;
  int eof;
  uint8_t *enc_buf;
  size_t enc_len;
  size_t enc_cap;
  uint8_t *dec_buf;
  size_t dec_off;
  size_t dec_len;
  size_t dec_cap;
  char protocol[32];
  char cipher[64];
  WCHAR *target_w;
} PionWinConn;

static int send_all(SOCKET sock, const uint8_t *buf, size_t len) {
  size_t sent = 0;
  while (sent < len) {
    int n = send(sock, (const char *)(buf + sent), (int)(len - sent), 0);
    if (n <= 0) {
      return -1;
    }
    sent += (size_t)n;
  }
  return 0;
}

static int ensure_enc_cap(PionWinConn *c, size_t need) {
  if (need <= c->enc_cap) {
    return 1;
  }
  size_t ncap = c->enc_cap ? c->enc_cap * 2 : 32768;
  while (ncap < need) {
    ncap *= 2;
  }
  uint8_t *p = (uint8_t *)realloc(c->enc_buf, ncap);
  if (!p) {
    return 0;
  }
  c->enc_buf = p;
  c->enc_cap = ncap;
  return 1;
}

static int append_dec(PionWinConn *c, const uint8_t *data, size_t len) {
  if (len == 0) {
    return 1;
  }
  size_t unread = c->dec_len - c->dec_off;
  if (c->dec_off > 0 && unread > 0) {
    memmove(c->dec_buf, c->dec_buf + c->dec_off, unread);
  }
  c->dec_off = 0;
  c->dec_len = unread;
  if (unread + len > c->dec_cap) {
    size_t ncap = c->dec_cap ? c->dec_cap * 2 : 32768;
    while (ncap < unread + len) {
      ncap *= 2;
    }
    uint8_t *p = (uint8_t *)realloc(c->dec_buf, ncap);
    if (!p) {
      return 0;
    }
    c->dec_buf = p;
    c->dec_cap = ncap;
  }
  memcpy(c->dec_buf + c->dec_len, data, len);
  c->dec_len += len;
  return 1;
}

static WCHAR *utf8_to_wide(const char *s) {
  if (!s) {
    return NULL;
  }
  int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
  if (n <= 0) {
    return NULL;
  }
  WCHAR *w = (WCHAR *)malloc((size_t)n * sizeof(WCHAR));
  if (!w) {
    return NULL;
  }
  MultiByteToWideChar(CP_UTF8, 0, s, -1, w, n);
  return w;
}

static HCERTSTORE load_pem_cert_store(const char *path, char *err_buf, size_t err_cap) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    snprintf(err_buf, err_cap, "cannot open SSL_CERT_FILE `%s`", path);
    return NULL;
  }
  fseek(f, 0, SEEK_END);
  long sz = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (sz <= 0) {
    fclose(f);
    snprintf(err_buf, err_cap, "empty SSL_CERT_FILE `%s`", path);
    return NULL;
  }
  char *pem = (char *)malloc((size_t)sz + 1);
  if (!pem) {
    fclose(f);
    snprintf(err_buf, err_cap, "out of memory");
    return NULL;
  }
  size_t rd = fread(pem, 1, (size_t)sz, f);
  fclose(f);
  pem[rd] = '\0';

  HCERTSTORE store = CertOpenStore(CERT_STORE_PROV_MEMORY, 0, 0, 0, NULL);
  if (!store) {
    free(pem);
    snprintf(err_buf, err_cap, "CertOpenStore failed");
    return NULL;
  }

  int count = 0;
  const char *p = pem;
  const char *begin_marker = "-----BEGIN CERTIFICATE-----";
  const char *end_marker = "-----END CERTIFICATE-----";
  while ((p = strstr(p, begin_marker)) != NULL) {
    const char *e = strstr(p, end_marker);
    if (!e) {
      break;
    }
    e += strlen(end_marker);
    DWORD blen = (DWORD)(e - p);
    DWORD der_len = 0;
    if (CryptStringToBinaryA(p, blen, CRYPT_STRING_BASE64HEADER, NULL, &der_len, NULL, NULL)) {
      BYTE *der = (BYTE *)malloc(der_len);
      if (der) {
        if (CryptStringToBinaryA(p, blen, CRYPT_STRING_BASE64HEADER, der, &der_len, NULL, NULL)) {
          if (CertAddEncodedCertificateToStore(
                  store, X509_ASN_ENCODING | PKCS_7_ASN_ENCODING, der, der_len, CERT_STORE_ADD_ALWAYS, NULL)) {
            count++;
          }
        }
        free(der);
      }
    }
    p = e;
  }
  free(pem);
  if (count == 0) {
    CertCloseStore(store, 0);
    snprintf(err_buf, err_cap, "no certificates found in SSL_CERT_FILE `%s`", path);
    return NULL;
  }
  return store;
}

static int verify_peer_cert(PionWinConn *c, const char *host, char *err_buf, size_t err_cap) {
  PCCERT_CONTEXT peer_cert = NULL;
  SECURITY_STATUS ss = QueryContextAttributesW(&c->ctxt, SECPKG_ATTR_REMOTE_CERT_CONTEXT, &peer_cert);
  if (ss != SEC_E_OK || !peer_cert) {
    snprintf(err_buf, err_cap, "missing remote certificate (0x%08lx)", (unsigned long)ss);
    return 0;
  }

  HCERTSTORE custom_store = NULL;
  HCERTCHAINENGINE engine = NULL;
  const char *ca_file = getenv("SSL_CERT_FILE");
  if (ca_file && ca_file[0]) {
    custom_store = load_pem_cert_store(ca_file, err_buf, err_cap);
    if (!custom_store) {
      CertFreeCertificateContext(peer_cert);
      return 0;
    }
    CERT_CHAIN_ENGINE_CONFIG cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.cbSize = sizeof(cfg);
    cfg.hExclusiveRoot = custom_store;
    if (!CertCreateCertificateChainEngine(&cfg, &engine)) {
      snprintf(err_buf, err_cap, "CertCreateCertificateChainEngine failed (%lu)", (unsigned long)GetLastError());
      CertCloseStore(custom_store, 0);
      CertFreeCertificateContext(peer_cert);
      return 0;
    }
  }

  CERT_CHAIN_PARA chain_para;
  memset(&chain_para, 0, sizeof(chain_para));
  chain_para.cbSize = sizeof(chain_para);

  PCCERT_CHAIN_CONTEXT chain_ctx = NULL;
  BOOL ok = CertGetCertificateChain(
      engine, peer_cert, NULL, peer_cert->hCertStore, &chain_para, 0, NULL, &chain_ctx);
  if (!ok || !chain_ctx) {
    snprintf(err_buf, err_cap, "CertGetCertificateChain failed (%lu)", (unsigned long)GetLastError());
    if (engine) CertFreeCertificateChainEngine(engine);
    if (custom_store) CertCloseStore(custom_store, 0);
    CertFreeCertificateContext(peer_cert);
    return 0;
  }

  WCHAR *host_w = utf8_to_wide(host);
  SSL_EXTRA_CERT_CHAIN_POLICY_PARA ssl_para;
  memset(&ssl_para, 0, sizeof(ssl_para));
  ssl_para.cbSize = sizeof(ssl_para);
  ssl_para.dwAuthType = AUTHTYPE_SERVER;
  ssl_para.pwszServerName = host_w;

  CERT_CHAIN_POLICY_PARA policy_para;
  memset(&policy_para, 0, sizeof(policy_para));
  policy_para.cbSize = sizeof(policy_para);
  policy_para.pvExtraPolicyPara = &ssl_para;

  CERT_CHAIN_POLICY_STATUS policy_status;
  memset(&policy_status, 0, sizeof(policy_status));
  policy_status.cbSize = sizeof(policy_status);

  int verified = 0;
  if (!CertVerifyCertificateChainPolicy(CERT_CHAIN_POLICY_SSL, chain_ctx, &policy_para, &policy_status)) {
    snprintf(err_buf, err_cap, "CertVerifyCertificateChainPolicy failed (%lu)", (unsigned long)GetLastError());
  } else if (policy_status.dwError != 0) {
    snprintf(err_buf, err_cap, "policy error 0x%08lx", (unsigned long)policy_status.dwError);
  } else {
    verified = 1;
  }

  free(host_w);
  CertFreeCertificateChain(chain_ctx);
  if (engine) CertFreeCertificateChainEngine(engine);
  if (custom_store) CertCloseStore(custom_store, 0);
  CertFreeCertificateContext(peer_cert);
  return verified;
}

static void free_win_conn(PionWinConn *c) {
  if (!c) {
    return;
  }
  if (c->has_ctxt) {
    DeleteSecurityContext(&c->ctxt);
    c->has_ctxt = 0;
  }
  if (c->has_cred) {
    FreeCredentialsHandle(&c->cred);
    c->has_cred = 0;
  }
  if (c->owns_sock && c->sock != INVALID_SOCKET) {
    closesocket(c->sock);
    c->sock = INVALID_SOCKET;
  }
  free(c->enc_buf);
  free(c->dec_buf);
  free(c->target_w);
  free(c);
}

static int win_handshake_loop(
    PionWinConn *c,
    SECURITY_STATUS init_ss,
    const char *host,
    int32_t port,
    char *err_buf,
    int32_t err_cap) {
  ULONG req_flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                    ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_MANUAL_CRED_VALIDATION;
  ULONG out_flags = 0;
  SECURITY_STATUS ss = init_ss;

  while (ss == SEC_I_CONTINUE_NEEDED || ss == SEC_E_INCOMPLETE_MESSAGE || ss == SEC_I_INCOMPLETE_CREDENTIALS) {
    if (c->enc_len == 0 || ss == SEC_E_INCOMPLETE_MESSAGE) {
      if (!ensure_enc_cap(c, c->enc_len + 16384)) {
        set_err(err_buf, err_cap, "out of memory");
        return 0;
      }
      int n = recv(c->sock, (char *)(c->enc_buf + c->enc_len), (int)(c->enc_cap - c->enc_len), 0);
      if (n <= 0) {
        set_err(err_buf, err_cap, "TLS handshake with %s failed: peer closed", host ? host : "");
        return 0;
      }
      c->enc_len += (size_t)n;
    }

    SecBuffer in_bufs[2];
    in_bufs[0].pvBuffer = c->enc_buf;
    in_bufs[0].cbBuffer = (unsigned long)c->enc_len;
    in_bufs[0].BufferType = SECBUFFER_TOKEN;
    in_bufs[1].pvBuffer = NULL;
    in_bufs[1].cbBuffer = 0;
    in_bufs[1].BufferType = SECBUFFER_EMPTY;
    SecBufferDesc in_desc;
    in_desc.cBuffers = 2;
    in_desc.pBuffers = in_bufs;
    in_desc.ulVersion = SECBUFFER_VERSION;

    SecBuffer out_bufs[1];
    out_bufs[0].pvBuffer = NULL;
    out_bufs[0].BufferType = SECBUFFER_TOKEN;
    out_bufs[0].cbBuffer = 0;
    SecBufferDesc out_desc;
    out_desc.cBuffers = 1;
    out_desc.pBuffers = out_bufs;
    out_desc.ulVersion = SECBUFFER_VERSION;

    ss = InitializeSecurityContextW(
        &c->cred, &c->ctxt, c->target_w, req_flags, 0, 0, &in_desc, 0, NULL, &out_desc, &out_flags, NULL);

    if (ss == SEC_E_INCOMPLETE_MESSAGE) {
      continue;
    }

    if (out_bufs[0].pvBuffer) {
      int sr = 0;
      if (out_bufs[0].cbBuffer > 0) {
        sr = send_all(c->sock, (const uint8_t *)out_bufs[0].pvBuffer, out_bufs[0].cbBuffer);
      }
      FreeContextBuffer(out_bufs[0].pvBuffer);
      if (sr != 0) {
        set_err(err_buf, err_cap, "TLS handshake with %s failed: send error", host ? host : "");
        return 0;
      }
    }

    if (in_bufs[1].BufferType == SECBUFFER_EXTRA && in_bufs[1].cbBuffer > 0) {
      size_t extra = (size_t)in_bufs[1].cbBuffer;
      memmove(c->enc_buf, c->enc_buf + (c->enc_len - extra), extra);
      c->enc_len = extra;
    } else if (ss == SEC_E_OK || ss == SEC_I_CONTINUE_NEEDED) {
      c->enc_len = 0;
    }

    if (ss != SEC_E_OK && ss != SEC_I_CONTINUE_NEEDED && ss != SEC_I_INCOMPLETE_CREDENTIALS) {
      if (port >= 0) {
        set_err(err_buf, err_cap, "TLS handshake with %s:%d failed (0x%08lx)", host ? host : "", (int)port, (unsigned long)ss);
      } else {
        set_err(err_buf, err_cap, "TLS handshake with %s failed (0x%08lx)", host ? host : "", (unsigned long)ss);
      }
      return 0;
    }
  }
  return 1;
}

static void *win_client_handshake(
    SOCKET sock,
    const char *host,
    int32_t port,
    int32_t verify_cert,
    int owns_sock_on_success,
    char *err_buf,
    int32_t err_cap) {
  ensure_wsa();
  PionWinConn *c = (PionWinConn *)calloc(1, sizeof(PionWinConn));
  if (!c) {
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  c->sock = sock;
  c->owns_sock = 0;

  SECURITY_STATUS ss;
#ifdef SCH_CREDENTIALS_VERSION
  TLS_PARAMETERS tls_params;
  memset(&tls_params, 0, sizeof(tls_params));
  tls_params.grbitDisabledProtocols =
      SP_PROT_SSL2_CLIENT | SP_PROT_SSL3_CLIENT | SP_PROT_TLS1_0_CLIENT | SP_PROT_TLS1_1_CLIENT;
  SCH_CREDENTIALS cred_cfg;
  memset(&cred_cfg, 0, sizeof(cred_cfg));
  cred_cfg.dwVersion = SCH_CREDENTIALS_VERSION;
  cred_cfg.dwFlags = SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS | SCH_USE_STRONG_CRYPTO;
  cred_cfg.cTlsParameters = 1;
  cred_cfg.pTlsParameters = &tls_params;
  ss = AcquireCredentialsHandleW(
      NULL, (LPWSTR)UNISP_NAME_W, SECPKG_CRED_OUTBOUND, NULL, &cred_cfg, NULL, NULL, &c->cred, NULL);
#else
  SCHANNEL_CRED cred_cfg;
  memset(&cred_cfg, 0, sizeof(cred_cfg));
  cred_cfg.dwVersion = SCHANNEL_CRED_VERSION;
  cred_cfg.grbitEnabledProtocols = 0;
  cred_cfg.dwFlags = SCH_CRED_MANUAL_CRED_VALIDATION | SCH_CRED_NO_DEFAULT_CREDS | SCH_USE_STRONG_CRYPTO;
  ss = AcquireCredentialsHandleW(
      NULL, (LPWSTR)UNISP_NAME_W, SECPKG_CRED_OUTBOUND, NULL, &cred_cfg, NULL, NULL, &c->cred, NULL);
#endif
  if (ss != SEC_E_OK) {
    set_err(err_buf, err_cap, "AcquireCredentialsHandleW failed (0x%08lx)", (unsigned long)ss);
    free_win_conn(c);
    return NULL;
  }
  c->has_cred = 1;

  c->target_w = (!is_ip_literal(host) && host && host[0]) ? utf8_to_wide(host) : NULL;
  ULONG req_flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT | ISC_REQ_CONFIDENTIALITY |
                    ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM | ISC_REQ_MANUAL_CRED_VALIDATION;
  ULONG out_flags = 0;

  SecBuffer out_bufs[1];
  out_bufs[0].pvBuffer = NULL;
  out_bufs[0].BufferType = SECBUFFER_TOKEN;
  out_bufs[0].cbBuffer = 0;
  SecBufferDesc out_desc;
  out_desc.cBuffers = 1;
  out_desc.pBuffers = out_bufs;
  out_desc.ulVersion = SECBUFFER_VERSION;

  ss = InitializeSecurityContextW(
      &c->cred, NULL, c->target_w, req_flags, 0, 0, NULL, 0, &c->ctxt, &out_desc, &out_flags, NULL);
  if (ss != SEC_I_CONTINUE_NEEDED && ss != SEC_E_OK) {
    set_err(err_buf, err_cap, "TLS handshake with %s failed (0x%08lx)", host ? host : "", (unsigned long)ss);
    free_win_conn(c);
    return NULL;
  }
  c->has_ctxt = 1;

  if (out_bufs[0].pvBuffer) {
    int sr = 0;
    if (out_bufs[0].cbBuffer > 0) {
      sr = send_all(c->sock, (const uint8_t *)out_bufs[0].pvBuffer, out_bufs[0].cbBuffer);
    }
    FreeContextBuffer(out_bufs[0].pvBuffer);
    if (sr != 0) {
      set_err(err_buf, err_cap, "TLS handshake with %s failed: send error", host ? host : "");
      free_win_conn(c);
      return NULL;
    }
  }

  if (!win_handshake_loop(c, ss, host, port, err_buf, err_cap)) {
    free_win_conn(c);
    return NULL;
  }

  SecPkgContext_ConnectionInfo ci;
  memset(&ci, 0, sizeof(ci));
  if (QueryContextAttributesW(&c->ctxt, SECPKG_ATTR_CONNECTION_INFO, &ci) == SEC_E_OK) {
    if (ci.dwProtocol & SP_PROT_TLS1_3_CLIENT) {
      copy_cstr("TLSv1.3", c->protocol, (int32_t)sizeof(c->protocol));
    } else if (ci.dwProtocol & SP_PROT_TLS1_2_CLIENT) {
      copy_cstr("TLSv1.2", c->protocol, (int32_t)sizeof(c->protocol));
    } else {
      set_err(err_buf, err_cap, "TLS handshake with %s failed: negotiated protocol below TLS 1.2 (0x%lx)", host ? host : "", (unsigned long)ci.dwProtocol);
      free_win_conn(c);
      return NULL;
    }
    snprintf(c->cipher, sizeof(c->cipher), "SCHANNEL_0x%x_%lu", (unsigned int)ci.aiCipher, (unsigned long)ci.dwCipherStrength);
  } else {
    copy_cstr("TLSv1.2", c->protocol, (int32_t)sizeof(c->protocol));
    copy_cstr("SCHANNEL", c->cipher, (int32_t)sizeof(c->cipher));
  }

  if (verify_cert) {
    char verr[256] = {0};
    if (!verify_peer_cert(c, host ? host : "", verr, sizeof(verr))) {
      if (port >= 0) {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s:%d failed (certificate verify error: %s)",
            host ? host : "",
            (int)port,
            verr);
      } else {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s failed (certificate verify error: %s)",
            host ? host : "",
            verr);
      }
      free_win_conn(c);
      return NULL;
    }
  }

  ss = QueryContextAttributesW(&c->ctxt, SECPKG_ATTR_STREAM_SIZES, &c->sizes);
  if (ss != SEC_E_OK) {
    set_err(err_buf, err_cap, "QueryContextAttributes(STREAM_SIZES) failed (0x%08lx)", (unsigned long)ss);
    free_win_conn(c);
    return NULL;
  }

  c->owns_sock = owns_sock_on_success;
  return c;
}

void *pion_tls_connect(
    const char *host,
    int32_t port,
    int32_t verify_cert,
    int32_t *out_fd,
    char *err_buf,
    int32_t err_cap) {
  ensure_wsa();
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
    set_err(err_buf, err_cap, "connect to %s:%d failed: getaddrinfo %d", host, (int)port, gai);
    return NULL;
  }

  SOCKET sock = INVALID_SOCKET;
  for (struct addrinfo *ai = res; ai != NULL; ai = ai->ai_next) {
    SOCKET s = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (s == INVALID_SOCKET) {
      continue;
    }
    if (connect(s, ai->ai_addr, (int)ai->ai_addrlen) == 0) {
      sock = s;
      break;
    }
    closesocket(s);
  }
  freeaddrinfo(res);

  if (sock == INVALID_SOCKET) {
    set_err(err_buf, err_cap, "connect to %s:%d failed: WSA error %d", host, (int)port, WSAGetLastError());
    return NULL;
  }

  void *h = win_client_handshake(sock, host, port, verify_cert, 1, err_buf, err_cap);
  if (!h) {
    closesocket(sock);
    return NULL;
  }
  if (out_fd) {
    *out_fd = (int32_t)sock;
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
  return win_client_handshake((SOCKET)(uintptr_t)(uint32_t)fd, host ? host : "", -1, verify_cert, 1, err_buf, err_cap);
}

int32_t pion_tls_protocol(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionWinConn *c = (PionWinConn *)h;
  return copy_cstr(c->protocol, buf, cap);
}

int32_t pion_tls_cipher(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionWinConn *c = (PionWinConn *)h;
  return copy_cstr(c->cipher, buf, cap);
}

int32_t pion_tls_peer_sni(void *h, char *buf, int32_t cap) {
  (void)h;
  return copy_cstr("", buf, cap);
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
  PionWinConn *c = (PionWinConn *)h;
  size_t max_msg = c->sizes.cbMaximumMessage ? (size_t)c->sizes.cbMaximumMessage : 16384;
  size_t msg_cap = (size_t)c->sizes.cbHeader + max_msg + (size_t)c->sizes.cbTrailer;
  uint8_t *msg = (uint8_t *)malloc(msg_cap);
  if (!msg) {
    set_err(err_buf, err_cap, "out of memory");
    return -1;
  }

  int32_t off = 0;
  while (off < len) {
    size_t chunk = (size_t)(len - off);
    if (chunk > max_msg) {
      chunk = max_msg;
    }
    memcpy(msg + c->sizes.cbHeader, data + off, chunk);

    SecBuffer bufs[4];
    bufs[0].pvBuffer = msg;
    bufs[0].cbBuffer = c->sizes.cbHeader;
    bufs[0].BufferType = SECBUFFER_STREAM_HEADER;
    bufs[1].pvBuffer = msg + c->sizes.cbHeader;
    bufs[1].cbBuffer = (unsigned long)chunk;
    bufs[1].BufferType = SECBUFFER_DATA;
    bufs[2].pvBuffer = msg + c->sizes.cbHeader + chunk;
    bufs[2].cbBuffer = c->sizes.cbTrailer;
    bufs[2].BufferType = SECBUFFER_STREAM_TRAILER;
    bufs[3].pvBuffer = NULL;
    bufs[3].cbBuffer = 0;
    bufs[3].BufferType = SECBUFFER_EMPTY;

    SecBufferDesc desc;
    desc.ulVersion = SECBUFFER_VERSION;
    desc.cBuffers = 4;
    desc.pBuffers = bufs;

    SECURITY_STATUS ss = EncryptMessage(&c->ctxt, 0, &desc, 0);
    if (ss != SEC_E_OK) {
      free(msg);
      set_err(err_buf, err_cap, "EncryptMessage failed (0x%08lx)", (unsigned long)ss);
      return -1;
    }
    size_t total_out = (size_t)bufs[0].cbBuffer + (size_t)bufs[1].cbBuffer + (size_t)bufs[2].cbBuffer;
    if (send_all(c->sock, msg, total_out) != 0) {
      free(msg);
      set_err(err_buf, err_cap, "TLS write send failed (WSA %d)", WSAGetLastError());
      return -1;
    }
    off += (int32_t)chunk;
  }
  free(msg);
  return off;
}

int32_t pion_tls_read(void *h, uint8_t *buf, int32_t max_bytes) {
  if (!h || !buf || max_bytes <= 0) {
    return 0;
  }
  PionWinConn *c = (PionWinConn *)h;
  for (;;) {
    size_t avail = c->dec_len - c->dec_off;
    if (avail > 0) {
      size_t take = (avail < (size_t)max_bytes) ? avail : (size_t)max_bytes;
      memcpy(buf, c->dec_buf + c->dec_off, take);
      c->dec_off += take;
      if (c->dec_off == c->dec_len) {
        c->dec_off = c->dec_len = 0;
      }
      return (int32_t)take;
    }
    if (c->eof) {
      return 0;
    }

    if (c->enc_len > 0) {
      SecBuffer bufs[4];
      bufs[0].pvBuffer = c->enc_buf;
      bufs[0].cbBuffer = (unsigned long)c->enc_len;
      bufs[0].BufferType = SECBUFFER_DATA;
      bufs[1].pvBuffer = NULL; bufs[1].cbBuffer = 0; bufs[1].BufferType = SECBUFFER_EMPTY;
      bufs[2].pvBuffer = NULL; bufs[2].cbBuffer = 0; bufs[2].BufferType = SECBUFFER_EMPTY;
      bufs[3].pvBuffer = NULL; bufs[3].cbBuffer = 0; bufs[3].BufferType = SECBUFFER_EMPTY;
      SecBufferDesc desc;
      desc.ulVersion = SECBUFFER_VERSION;
      desc.cBuffers = 4;
      desc.pBuffers = bufs;

      SECURITY_STATUS ss = DecryptMessage(&c->ctxt, &desc, 0, NULL);
      if (ss == SEC_E_OK || ss == SEC_I_CONTEXT_EXPIRED) {
        SecBuffer *data_b = NULL;
        SecBuffer *extra_b = NULL;
        for (int i = 0; i < 4; i++) {
          if (bufs[i].BufferType == SECBUFFER_DATA) data_b = &bufs[i];
          if (bufs[i].BufferType == SECBUFFER_EXTRA) extra_b = &bufs[i];
        }
        if (data_b && data_b->cbBuffer > 0) {
          if (!append_dec(c, (const uint8_t *)data_b->pvBuffer, (size_t)data_b->cbBuffer)) {
            return -1;
          }
        }
        if (extra_b && extra_b->cbBuffer > 0) {
          memmove(c->enc_buf, extra_b->pvBuffer, (size_t)extra_b->cbBuffer);
          c->enc_len = (size_t)extra_b->cbBuffer;
        } else {
          c->enc_len = 0;
        }
        if (ss == SEC_I_CONTEXT_EXPIRED) {
          c->eof = 1;
        }
        continue;
      }
      if (ss == SEC_I_RENEGOTIATE) {
        SecBuffer *extra_b = NULL;
        for (int i = 0; i < 4; i++) {
          if (bufs[i].BufferType == SECBUFFER_EXTRA) {
            extra_b = &bufs[i];
            break;
          }
        }
        if (extra_b && extra_b->cbBuffer > 0) {
          memmove(c->enc_buf, extra_b->pvBuffer, (size_t)extra_b->cbBuffer);
          c->enc_len = (size_t)extra_b->cbBuffer;
        } else {
          c->enc_len = 0;
        }
        if (!win_handshake_loop(c, SEC_I_CONTINUE_NEEDED, "", -1, NULL, 0)) {
          c->eof = 1;
          return -1;
        }
        QueryContextAttributesW(&c->ctxt, SECPKG_ATTR_STREAM_SIZES, &c->sizes);
        continue;
      }
      if (ss != SEC_E_INCOMPLETE_MESSAGE) {
        c->eof = 1;
        return -1;
      }
    }

    if (!ensure_enc_cap(c, c->enc_len + 16384)) {
      return -1;
    }
    int n = recv(c->sock, (char *)(c->enc_buf + c->enc_len), (int)(c->enc_cap - c->enc_len), 0);
    if (n <= 0) {
      c->eof = 1;
      return 0;
    }
    c->enc_len += (size_t)n;
  }
}

void pion_tls_close(void *h) {
  if (!h) {
    return;
  }
  PionWinConn *c = (PionWinConn *)h;
  if (c->has_ctxt && c->sock != INVALID_SOCKET) {
    DWORD shutdown_type = SCHANNEL_SHUTDOWN;
    SecBuffer sb;
    sb.pvBuffer = &shutdown_type;
    sb.cbBuffer = sizeof(shutdown_type);
    sb.BufferType = SECBUFFER_TOKEN;
    SecBufferDesc sbd;
    sbd.ulVersion = SECBUFFER_VERSION;
    sbd.cBuffers = 1;
    sbd.pBuffers = &sb;
    if (ApplyControlToken(&c->ctxt, &sbd) == SEC_E_OK) {
      SecBuffer out_b;
      out_b.pvBuffer = NULL;
      out_b.cbBuffer = 0;
      out_b.BufferType = SECBUFFER_TOKEN;
      SecBufferDesc out_d;
      out_d.ulVersion = SECBUFFER_VERSION;
      out_d.cBuffers = 1;
      out_d.pBuffers = &out_b;
      ULONG out_flags = 0;
      ULONG req_flags = ISC_REQ_SEQUENCE_DETECT | ISC_REQ_REPLAY_DETECT |
                        ISC_REQ_CONFIDENTIALITY | ISC_REQ_ALLOCATE_MEMORY | ISC_REQ_STREAM;
      SECURITY_STATUS sh_ss = InitializeSecurityContextW(
          &c->cred, &c->ctxt, NULL, req_flags, 0, 0, NULL, 0, &c->ctxt, &out_d, &out_flags, NULL);
      if ((sh_ss == SEC_E_OK || sh_ss == SEC_I_CONTEXT_EXPIRED) && out_b.pvBuffer && out_b.cbBuffer > 0) {
        send_all(c->sock, (const uint8_t *)out_b.pvBuffer, (size_t)out_b.cbBuffer);
      }
      if (out_b.pvBuffer) {
        FreeContextBuffer(out_b.pvBuffer);
      }
    }
  }
  free_win_conn(c);
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
  (void)host;
  (void)port;
  (void)cert_pem;
  (void)key_pem;
  if (out_fd) *out_fd = -1;
  if (out_port) *out_port = 0;
  set_err(err_buf, err_cap, "TLS server (tls_listen) is not supported on Windows Schannel yet");
  return NULL;
}

void *pion_tls_accept(
    void *lh,
    int32_t *out_fd,
    char *sni_buf,
    int32_t sni_cap,
    char *err_buf,
    int32_t err_cap) {
  (void)lh;
  if (out_fd) *out_fd = -1;
  if (sni_buf && sni_cap > 0) sni_buf[0] = '\0';
  set_err(err_buf, err_cap, "accept: TLS server is not supported on Windows Schannel yet");
  return NULL;
}

void pion_tls_listener_close(void *lh) {
  (void)lh;
}
