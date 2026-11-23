#include "tls_abi.h"

#include <CoreFoundation/CoreFoundation.h>
#include <Network/Network.h>
#include <Security/Security.h>
#include <arpa/inet.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

extern SecIdentityRef SecIdentityCreate(
    CFAllocatorRef allocator,
    SecCertificateRef certificate,
    SecKeyRef privateKey);

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

static void cf_error_to_cstr(CFErrorRef err, char *buf, size_t cap) {
  if (!buf || cap == 0) {
    return;
  }
  buf[0] = '\0';
  if (!err) {
    return;
  }
  CFStringRef desc = CFErrorCopyDescription(err);
  if (desc) {
    if (!CFStringGetCString(desc, buf, (CFIndex)cap, kCFStringEncodingUTF8)) {
      snprintf(buf, cap, "OSStatus %ld", (long)CFErrorGetCode(err));
    }
    CFRelease(desc);
  } else {
    snprintf(buf, cap, "OSStatus %ld", (long)CFErrorGetCode(err));
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
  return "Apple Network.framework (TLS 1.2/1.3)";
}

/* ------------------------------------------------------------------------- */
/* Minimal PEM + Base64 + ASN.1 DER helpers (zero external deps, pure RAM)   */
/* ------------------------------------------------------------------------- */

static uint8_t *read_entire_file(const char *path, size_t *out_len, char *err_buf, size_t err_cap) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    snprintf(err_buf, err_cap, "%s", strerror(errno));
    return NULL;
  }
  if (fseek(f, 0, SEEK_END) != 0) {
    snprintf(err_buf, err_cap, "%s", strerror(errno));
    fclose(f);
    return NULL;
  }
  long sz = ftell(f);
  if (sz < 0) {
    snprintf(err_buf, err_cap, "%s", strerror(errno));
    fclose(f);
    return NULL;
  }
  if (fseek(f, 0, SEEK_SET) != 0) {
    snprintf(err_buf, err_cap, "%s", strerror(errno));
    fclose(f);
    return NULL;
  }
  uint8_t *buf = (uint8_t *)malloc((size_t)sz + 1);
  if (!buf) {
    snprintf(err_buf, err_cap, "out of memory");
    fclose(f);
    return NULL;
  }
  size_t rd = (sz > 0) ? fread(buf, 1, (size_t)sz, f) : 0;
  fclose(f);
  buf[rd] = '\0';
  if (out_len) {
    *out_len = rd;
  }
  return buf;
}

static int b64_val(int c) {
  if (c >= 'A' && c <= 'Z') return c - 'A';
  if (c >= 'a' && c <= 'z') return c - 'a' + 26;
  if (c >= '0' && c <= '9') return c - '0' + 52;
  if (c == '+') return 62;
  if (c == '/') return 63;
  return -1;
}

static uint8_t *b64_decode(const char *src, size_t src_len, size_t *out_len) {
  uint8_t *out = (uint8_t *)malloc((src_len * 3) / 4 + 4);
  if (!out) {
    return NULL;
  }
  size_t n = 0;
  uint32_t acc = 0;
  int bits = 0;
  for (size_t i = 0; i < src_len; i++) {
    unsigned char ch = (unsigned char)src[i];
    if (ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n') {
      continue;
    }
    if (ch == '=') {
      break;
    }
    int v = b64_val((int)ch);
    if (v < 0) {
      free(out);
      return NULL;
    }
    acc = (acc << 6) | (uint32_t)v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[n++] = (uint8_t)((acc >> bits) & 0xFF);
    }
  }
  *out_len = n;
  return out;
}

static int pem_find_next(
    const char *text,
    size_t text_len,
    size_t *cursor,
    char *label_out,
    size_t label_cap,
    uint8_t **der_out,
    size_t *der_len_out) {
  const char *p = text + *cursor;
  const char *end = text + text_len;
  const char *hdr_prefix = "-----BEGIN ";
  size_t hdr_prefix_len = strlen(hdr_prefix);

  while (p < end) {
    const char *b = strstr(p, hdr_prefix);
    if (!b || b >= end) {
      return 0;
    }
    const char *label_start = b + hdr_prefix_len;
    const char *hdr_end = strstr(label_start, "-----");
    if (!hdr_end || hdr_end >= end) {
      return 0;
    }
    size_t label_len = (size_t)(hdr_end - label_start);
    if (label_len == 0 || label_len >= label_cap) {
      p = hdr_end + 5;
      continue;
    }
    memcpy(label_out, label_start, label_len);
    label_out[label_len] = '\0';

    char footer[128];
    snprintf(footer, sizeof(footer), "-----END %s-----", label_out);
    const char *body_start = hdr_end + 5;
    const char *ftr = strstr(body_start, footer);
    if (!ftr || ftr >= end) {
      return 0;
    }
    size_t der_len = 0;
    uint8_t *der = b64_decode(body_start, (size_t)(ftr - body_start), &der_len);
    *cursor = (size_t)((ftr + strlen(footer)) - text);
    if (!der || der_len == 0) {
      free(der);
      return -1;
    }
    *der_out = der;
    *der_len_out = der_len;
    return 1;
  }
  return 0;
}

static CFMutableArrayRef load_pem_certificates(
    const char *path,
    char *err_buf,
    size_t err_cap) {
  size_t file_len = 0;
  char f_err[256] = {0};
  uint8_t *raw = read_entire_file(path, &file_len, f_err, sizeof(f_err));
  if (!raw) {
    snprintf(err_buf, err_cap, "%s", f_err);
    return NULL;
  }
  CFMutableArrayRef arr = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
  size_t cursor = 0;
  char label[64];
  uint8_t *der = NULL;
  size_t der_len = 0;
  while (1) {
    int r = pem_find_next((const char *)raw, file_len, &cursor, label, sizeof(label), &der, &der_len);
    if (r == 0) {
      break;
    }
    if (r < 0) {
      free(raw);
      CFRelease(arr);
      snprintf(err_buf, err_cap, "invalid base64 in PEM certificate");
      return NULL;
    }
    if (strcmp(label, "CERTIFICATE") == 0 || strcmp(label, "X509 CERTIFICATE") == 0) {
      CFDataRef data = CFDataCreate(NULL, der, (CFIndex)der_len);
      SecCertificateRef cert = data ? SecCertificateCreateWithData(NULL, data) : NULL;
      if (data) {
        CFRelease(data);
      }
      if (!cert) {
        free(der);
        free(raw);
        CFRelease(arr);
        snprintf(err_buf, err_cap, "SecCertificateCreateWithData rejected DER certificate");
        return NULL;
      }
      CFArrayAppendValue(arr, cert);
      CFRelease(cert);
    }
    free(der);
  }
  free(raw);
  if (CFArrayGetCount(arr) == 0) {
    CFRelease(arr);
    snprintf(err_buf, err_cap, "no PEM CERTIFICATE block found");
    return NULL;
  }
  return arr;
}

static int der_read_tlv(
    const uint8_t *buf,
    size_t len,
    size_t *off,
    uint8_t *tag_out,
    const uint8_t **val_out,
    size_t *val_len_out) {
  if (*off >= len) {
    return 0;
  }
  uint8_t tag = buf[(*off)++];
  if (*off >= len) {
    return 0;
  }
  uint8_t l0 = buf[(*off)++];
  size_t vlen = 0;
  if ((l0 & 0x80) == 0) {
    vlen = l0;
  } else {
    int nbytes = l0 & 0x7F;
    if (nbytes == 0 || nbytes > 4 || *off + (size_t)nbytes > len) {
      return 0;
    }
    for (int i = 0; i < nbytes; i++) {
      vlen = (vlen << 8) | buf[(*off)++];
    }
  }
  if (*off + vlen > len) {
    return 0;
  }
  *tag_out = tag;
  *val_out = buf + *off;
  *val_len_out = vlen;
  *off += vlen;
  return 1;
}

/* Convert SEC1 ECPrivateKey DER to Apple SecKeyCreateWithData X9.63 (04||X||Y||d). */
static uint8_t *sec1_ec_to_x963(const uint8_t *der, size_t der_len, size_t *out_len) {
  size_t off = 0;
  uint8_t tag = 0;
  const uint8_t *seq = NULL;
  size_t seq_len = 0;
  if (!der_read_tlv(der, der_len, &off, &tag, &seq, &seq_len) || tag != 0x30) {
    return NULL;
  }
  size_t soff = 0;
  const uint8_t *v = NULL;
  size_t vlen = 0;
  /* version INTEGER */
  if (!der_read_tlv(seq, seq_len, &soff, &tag, &v, &vlen) || tag != 0x02) {
    return NULL;
  }
  /* privateKey OCTET STRING */
  const uint8_t *priv = NULL;
  size_t priv_len = 0;
  if (!der_read_tlv(seq, seq_len, &soff, &tag, &priv, &priv_len) || tag != 0x04) {
    return NULL;
  }
  /* Look for [1] EXPLICIT BIT STRING publicKey */
  const uint8_t *pub = NULL;
  size_t pub_len = 0;
  while (soff < seq_len) {
    if (!der_read_tlv(seq, seq_len, &soff, &tag, &v, &vlen)) {
      break;
    }
    if (tag == 0xA1) {
      size_t boff = 0;
      uint8_t btag = 0;
      const uint8_t *bval = NULL;
      size_t blen = 0;
      if (der_read_tlv(v, vlen, &boff, &btag, &bval, &blen) && btag == 0x03 && blen > 2 && bval[0] == 0x00) {
        pub = bval + 1;
        pub_len = blen - 1;
      }
    }
  }
  if (!pub || pub_len < 3 || pub[0] != 0x04 || ((pub_len - 1) % 2) != 0) {
    return NULL;
  }
  size_t coord_len = (pub_len - 1) / 2;
  /* Strip optional leading zero on d if longer than coord_len */
  while (priv_len > coord_len && priv[0] == 0x00) {
    priv++;
    priv_len--;
  }
  if (priv_len > coord_len) {
    return NULL;
  }
  uint8_t *x963 = (uint8_t *)calloc(1, pub_len + coord_len);
  if (!x963) {
    return NULL;
  }
  memcpy(x963, pub, pub_len);
  memcpy(x963 + pub_len + (coord_len - priv_len), priv, priv_len);
  *out_len = pub_len + coord_len;
  return x963;
}

static SecKeyRef create_seckey_from_bytes(
    const uint8_t *bytes,
    size_t len,
    CFStringRef key_type,
    char *err_buf,
    size_t err_cap) {
  CFDataRef data = CFDataCreate(NULL, bytes, (CFIndex)len);
  if (!data) {
    snprintf(err_buf, err_cap, "out of memory");
    return NULL;
  }
  const void *keys[2] = { kSecAttrKeyType, kSecAttrKeyClass };
  const void *vals[2] = { key_type, kSecAttrKeyClassPrivate };
  CFDictionaryRef attrs = CFDictionaryCreate(
      NULL, keys, vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFErrorRef cf_err = NULL;
  SecKeyRef key = SecKeyCreateWithData(data, attrs, &cf_err);
  CFRelease(attrs);
  CFRelease(data);
  if (!key) {
    cf_error_to_cstr(cf_err, err_buf, err_cap);
    if (cf_err) {
      CFRelease(cf_err);
    }
  }
  return key;
}

static SecKeyRef load_pem_private_key(const char *path, char *err_buf, size_t err_cap) {
  size_t file_len = 0;
  char f_err[256] = {0};
  uint8_t *raw = read_entire_file(path, &file_len, f_err, sizeof(f_err));
  if (!raw) {
    snprintf(err_buf, err_cap, "%s", f_err);
    return NULL;
  }
  size_t cursor = 0;
  char label[64];
  uint8_t *der = NULL;
  size_t der_len = 0;
  SecKeyRef key = NULL;
  int found_key_block = 0;

  while (1) {
    int r = pem_find_next((const char *)raw, file_len, &cursor, label, sizeof(label), &der, &der_len);
    if (r == 0) {
      break;
    }
    if (r < 0) {
      free(raw);
      snprintf(err_buf, err_cap, "invalid base64 in PEM private key");
      return NULL;
    }
    if (strcmp(label, "RSA PRIVATE KEY") == 0) {
      found_key_block = 1;
      key = create_seckey_from_bytes(der, der_len, kSecAttrKeyTypeRSA, err_buf, err_cap);
      free(der);
      break;
    }
    if (strcmp(label, "EC PRIVATE KEY") == 0) {
      found_key_block = 1;
      size_t xlen = 0;
      uint8_t *x963 = sec1_ec_to_x963(der, der_len, &xlen);
      free(der);
      if (!x963) {
        snprintf(err_buf, err_cap, "failed to decode SEC1 EC private key");
        break;
      }
      key = create_seckey_from_bytes(x963, xlen, kSecAttrKeyTypeECSECPrimeRandom, err_buf, err_cap);
      free(x963);
      break;
    }
    if (strcmp(label, "PRIVATE KEY") == 0) {
      found_key_block = 1;
      /* PKCS#8 PrivateKeyInfo ::= SEQUENCE { version INTEGER, alg SEQUENCE { OID, ... }, key OCTET STRING } */
      size_t off = 0;
      uint8_t tag = 0;
      const uint8_t *seq = NULL, *v = NULL, *alg = NULL, *inner = NULL;
      size_t seq_len = 0, vlen = 0, alg_len = 0, inner_len = 0;
      if (der_read_tlv(der, der_len, &off, &tag, &seq, &seq_len) && tag == 0x30) {
        size_t soff = 0;
        if (der_read_tlv(seq, seq_len, &soff, &tag, &v, &vlen) && tag == 0x02 &&
            der_read_tlv(seq, seq_len, &soff, &tag, &alg, &alg_len) && tag == 0x30 &&
            der_read_tlv(seq, seq_len, &soff, &tag, &inner, &inner_len) && tag == 0x04) {
          size_t aoff = 0;
          uint8_t otag = 0;
          const uint8_t *oid = NULL;
          size_t oid_len = 0;
          /* OID 1.2.840.113549.1.1.1 (rsaEncryption) */
          static const uint8_t kPionOidRsa[9] = { 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01 };
          /* OID 1.2.840.10045.2.1 (id-ecPublicKey) */
          static const uint8_t kPionOidEc[7] = { 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01 };
          if (der_read_tlv(alg, alg_len, &aoff, &otag, &oid, &oid_len) && otag == 0x06) {
            if (oid_len == sizeof(kPionOidRsa) && memcmp(oid, kPionOidRsa, sizeof(kPionOidRsa)) == 0) {
              key = create_seckey_from_bytes(inner, inner_len, kSecAttrKeyTypeRSA, err_buf, err_cap);
            } else if (oid_len == sizeof(kPionOidEc) && memcmp(oid, kPionOidEc, sizeof(kPionOidEc)) == 0) {
              size_t xlen = 0;
              uint8_t *x963 = sec1_ec_to_x963(inner, inner_len, &xlen);
              if (x963) {
                key = create_seckey_from_bytes(x963, xlen, kSecAttrKeyTypeECSECPrimeRandom, err_buf, err_cap);
                free(x963);
              } else {
                snprintf(err_buf, err_cap, "failed to decode PKCS#8 EC private key");
              }
            } else {
              snprintf(err_buf, err_cap, "unsupported PKCS#8 key algorithm");
            }
          } else {
            snprintf(err_buf, err_cap, "invalid PKCS#8 AlgorithmIdentifier");
          }
        } else {
          snprintf(err_buf, err_cap, "invalid PKCS#8 PrivateKeyInfo structure");
        }
      } else {
        snprintf(err_buf, err_cap, "invalid PKCS#8 DER");
      }
      free(der);
      break;
    }
    free(der);
  }
  free(raw);
  if (!found_key_block) {
    snprintf(err_buf, err_cap, "no PEM PRIVATE KEY block found");
  }
  return key;
}

static int cert_matches_private_key(SecCertificateRef cert, SecKeyRef priv_key) {
  SecKeyRef cert_pub = SecCertificateCopyKey(cert);
  SecKeyRef priv_pub = SecKeyCopyPublicKey(priv_key);
  if (!cert_pub || !priv_pub) {
    if (cert_pub) CFRelease(cert_pub);
    if (priv_pub) CFRelease(priv_pub);
    return 0;
  }
  CFDataRef d1 = SecKeyCopyExternalRepresentation(cert_pub, NULL);
  CFDataRef d2 = SecKeyCopyExternalRepresentation(priv_pub, NULL);
  int same = (d1 && d2 && CFEqual(d1, d2)) ? 1 : 0;
  if (d1) CFRelease(d1);
  if (d2) CFRelease(d2);
  CFRelease(cert_pub);
  CFRelease(priv_pub);
  return same;
}

/* ------------------------------------------------------------------------- */
/* Cipher suite & protocol metadata helpers                                  */
/* ------------------------------------------------------------------------- */

static const char *ciphersuite_name(tls_ciphersuite_t cs, char *fallback, size_t cap) {
  switch ((uint16_t)cs) {
    case 0x1301: return "TLS_AES_128_GCM_SHA256";
    case 0x1302: return "TLS_AES_256_GCM_SHA384";
    case 0x1303: return "TLS_CHACHA20_POLY1305_SHA256";
    case 0xC02F: return "ECDHE-RSA-AES128-GCM-SHA256";
    case 0xC030: return "ECDHE-RSA-AES256-GCM-SHA384";
    case 0xC02B: return "ECDHE-ECDSA-AES128-GCM-SHA256";
    case 0xC02C: return "ECDHE-ECDSA-AES256-GCM-SHA384";
    case 0xCCA8: return "ECDHE-RSA-CHACHA20-POLY1305";
    case 0xCCA9: return "ECDHE-ECDSA-CHACHA20-POLY1305";
    case 0x009C: return "AES128-GCM-SHA256";
    case 0x009D: return "AES256-GCM-SHA384";
    default:
      snprintf(fallback, cap, "TLS_CIPHER_0x%04x", (unsigned int)(uint16_t)cs);
      return fallback;
  }
}

/* ------------------------------------------------------------------------- */
/* Connection & local TCP relay (for pion_tls_wrap_fd)                       */
/* ------------------------------------------------------------------------- */

typedef struct {
  int listen_fd;
  int user_fd;
  int wake_r;
  int wake_w;
  volatile int stop;
  pthread_t thread;
  int started;
} FdRelay;

typedef struct {
  nw_connection_t conn;
  dispatch_queue_t queue;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int hs_done;
  int hs_ok;
  int cancelled;
  int eof;
  int verify_failed;
  char verify_err[256];
  char hs_err[256];
  char protocol[32];
  char cipher[64];
  char peer_sni[256];
  int has_relay;
  int owns_user_fd;
  FdRelay *relay;
  char *host_copy;
  char *ca_copy;
} PionMacConn;

static void *relay_thread_main(void *arg) {
  FdRelay *r = (FdRelay *)arg;
  struct pollfd lpfd[2];
  lpfd[0].fd = r->listen_fd;
  lpfd[0].events = POLLIN;
  lpfd[1].fd = r->wake_r;
  lpfd[1].events = POLLIN;

  int local_fd = -1;
  while (!r->stop && local_fd < 0) {
    int pr = poll(lpfd, 2, -1);
    if (pr < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (lpfd[1].revents & POLLIN) {
      break;
    }
    if (lpfd[0].revents & POLLIN) {
      local_fd = accept(r->listen_fd, NULL, NULL);
      break;
    }
  }
  close(r->listen_fd);
  r->listen_fd = -1;
  if (local_fd < 0) {
    return NULL;
  }

  uint8_t buf[16384];
  struct pollfd pfds[3];
  while (!r->stop) {
    pfds[0].fd = local_fd;
    pfds[0].events = POLLIN;
    pfds[0].revents = 0;
    pfds[1].fd = r->user_fd;
    pfds[1].events = POLLIN;
    pfds[1].revents = 0;
    pfds[2].fd = r->wake_r;
    pfds[2].events = POLLIN;
    pfds[2].revents = 0;

    int pr = poll(pfds, 3, -1);
    if (pr < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (pfds[2].revents & (POLLIN | POLLHUP | POLLERR)) {
      break;
    }
    if (pfds[0].revents & (POLLIN | POLLHUP | POLLERR)) {
      ssize_t n = recv(local_fd, buf, sizeof(buf), 0);
      if (n <= 0) {
        shutdown(r->user_fd, SHUT_WR);
        break;
      }
      ssize_t off = 0;
      while (off < n) {
        ssize_t w = send(r->user_fd, buf + off, (size_t)(n - off), 0);
        if (w <= 0) {
          r->stop = 1;
          break;
        }
        off += w;
      }
    }
    if (!r->stop && (pfds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
      ssize_t n = recv(r->user_fd, buf, sizeof(buf), 0);
      if (n <= 0) {
        shutdown(local_fd, SHUT_WR);
        break;
      }
      ssize_t off = 0;
      while (off < n) {
        ssize_t w = send(local_fd, buf + off, (size_t)(n - off), 0);
        if (w <= 0) {
          r->stop = 1;
          break;
        }
        off += w;
      }
    }
  }
  close(local_fd);
  return NULL;
}

static void stop_relay(PionMacConn *c) {
  if (!c->has_relay || !c->relay) {
    return;
  }
  FdRelay *r = c->relay;
  r->stop = 1;
  if (r->wake_w >= 0) {
    uint8_t b = 1;
    ssize_t unused = write(r->wake_w, &b, 1);
    (void)unused;
  }
  if (r->started) {
    pthread_join(r->thread, NULL);
    r->started = 0;
  }
  if (r->listen_fd >= 0) {
    close(r->listen_fd);
    r->listen_fd = -1;
  }
  if (r->wake_r >= 0) {
    close(r->wake_r);
    r->wake_r = -1;
  }
  if (r->wake_w >= 0) {
    close(r->wake_w);
    r->wake_w = -1;
  }
  if (c->owns_user_fd && r->user_fd >= 0) {
    close(r->user_fd);
    r->user_fd = -1;
  }
  free(r);
  c->relay = NULL;
  c->has_relay = 0;
}

static void populate_tls_metadata(PionMacConn *c) {
  nw_protocol_definition_t tls_def = nw_protocol_copy_tls_definition();
  if (!tls_def) {
    return;
  }
  nw_protocol_metadata_t meta = nw_connection_copy_protocol_metadata(c->conn, tls_def);
  nw_release(tls_def);
  if (!meta) {
    return;
  }
  sec_protocol_metadata_t sec_meta = nw_tls_copy_sec_protocol_metadata(meta);
  nw_release(meta);
  if (!sec_meta) {
    return;
  }
  tls_protocol_version_t ver = sec_protocol_metadata_get_negotiated_tls_protocol_version(sec_meta);
  if (ver == tls_protocol_version_TLSv13) {
    copy_cstr("TLSv1.3", c->protocol, (int32_t)sizeof(c->protocol));
  } else if (ver == tls_protocol_version_TLSv12) {
    copy_cstr("TLSv1.2", c->protocol, (int32_t)sizeof(c->protocol));
  } else {
    snprintf(c->protocol, sizeof(c->protocol), "TLS(0x%04x)", (unsigned int)ver);
  }
  tls_ciphersuite_t cs = sec_protocol_metadata_get_negotiated_tls_ciphersuite(sec_meta);
  char fb[64];
  copy_cstr(ciphersuite_name(cs, fb, sizeof(fb)), c->cipher, (int32_t)sizeof(c->cipher));
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  const char *sni = sec_protocol_metadata_get_server_name(sec_meta);
#pragma clang diagnostic pop
  copy_cstr(sni ? sni : "", c->peer_sni, (int32_t)sizeof(c->peer_sni));
  sec_release(sec_meta);
}

static void destroy_conn(PionMacConn *c) {
  if (!c) {
    return;
  }
  if (c->conn) {
    nw_connection_cancel(c->conn);
    pthread_mutex_lock(&c->mu);
    while (!c->cancelled) {
      pthread_cond_wait(&c->cv, &c->mu);
    }
    pthread_mutex_unlock(&c->mu);
    nw_release(c->conn);
    c->conn = NULL;
  }
  if (c->queue) {
    dispatch_release(c->queue);
    c->queue = NULL;
  }
  stop_relay(c);
  free(c->host_copy);
  c->host_copy = NULL;
  free(c->ca_copy);
  c->ca_copy = NULL;
  pthread_cond_destroy(&c->cv);
  pthread_mutex_destroy(&c->mu);
  free(c);
}

static void attach_state_handler(PionMacConn *c) {
  nw_connection_set_queue(c->conn, c->queue);
  nw_connection_set_state_changed_handler(c->conn, ^(nw_connection_state_t state, nw_error_t error) {
    pthread_mutex_lock(&c->mu);
    if (state == nw_connection_state_ready) {
      if (!c->hs_done) {
        c->hs_done = 1;
        c->hs_ok = 1;
        pthread_cond_broadcast(&c->cv);
      }
    } else if (state == nw_connection_state_waiting) {
      if (!c->hs_done) {
        c->hs_done = 1;
        c->hs_ok = 0;
        if (error) {
          snprintf(
              c->hs_err,
              sizeof(c->hs_err),
              "domain=%d code=%d",
              (int)nw_error_get_error_domain(error),
              (int)nw_error_get_error_code(error));
        } else {
          copy_cstr("connection waiting/refused", c->hs_err, (int32_t)sizeof(c->hs_err));
        }
        pthread_cond_broadcast(&c->cv);
      }
      nw_connection_cancel(c->conn);
    } else if (state == nw_connection_state_failed) {
      if (!c->hs_done) {
        c->hs_done = 1;
        c->hs_ok = 0;
        if (error) {
          snprintf(
              c->hs_err,
              sizeof(c->hs_err),
              "domain=%d code=%d",
              (int)nw_error_get_error_domain(error),
              (int)nw_error_get_error_code(error));
        } else {
          copy_cstr("connection failed", c->hs_err, (int32_t)sizeof(c->hs_err));
        }
        pthread_cond_broadcast(&c->cv);
      }
      nw_connection_cancel(c->conn);
    } else if (state == nw_connection_state_cancelled) {
      if (!c->hs_done) {
        c->hs_done = 1;
        c->hs_ok = 0;
        if (!c->hs_err[0]) {
          copy_cstr("connection cancelled", c->hs_err, (int32_t)sizeof(c->hs_err));
        }
      }
      c->cancelled = 1;
      pthread_cond_broadcast(&c->cv);
    }
    pthread_mutex_unlock(&c->mu);
  });
}

static PionMacConn *macos_client_connect_endpoint(
    const char *dial_host,
    int32_t dial_port,
    const char *tls_host,
    int32_t display_port,
    int32_t verify_cert,
    char *err_buf,
    int32_t err_cap) {
  pthread_once(&g_sigpipe_once, ignore_sigpipe);
  PionMacConn *c = (PionMacConn *)calloc(1, sizeof(PionMacConn));
  if (!c) {
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  pthread_mutex_init(&c->mu, NULL);
  pthread_cond_init(&c->cv, NULL);
  c->queue = dispatch_queue_create("pion.tls.client", DISPATCH_QUEUE_SERIAL);

  c->host_copy = strdup(tls_host ? tls_host : "");
  int is_ip = is_ip_literal(c->host_copy);
  const char *ca_env = getenv("SSL_CERT_FILE");
  c->ca_copy = (ca_env && ca_env[0]) ? strdup(ca_env) : NULL;

  nw_parameters_configure_protocol_block_t configure_tls = ^(nw_protocol_options_t tls_options) {
    sec_protocol_options_t sec_opts = nw_tls_copy_sec_protocol_options(tls_options);
    sec_protocol_options_set_min_tls_protocol_version(sec_opts, tls_protocol_version_TLSv12);
    sec_protocol_options_set_max_tls_protocol_version(sec_opts, tls_protocol_version_TLSv13);
    if (!is_ip && c->host_copy && c->host_copy[0]) {
      sec_protocol_options_set_tls_server_name(sec_opts, c->host_copy);
    }
    sec_protocol_options_set_verify_block(
        sec_opts,
        ^(sec_protocol_metadata_t metadata, sec_trust_t sec_trust, sec_protocol_verify_complete_t complete) {
          (void)metadata;
          if (!verify_cert) {
            complete(true);
            return;
          }
          SecTrustRef trust = sec_trust_copy_ref(sec_trust);
          if (!trust) {
            pthread_mutex_lock(&c->mu);
            c->verify_failed = 1;
            copy_cstr("missing SecTrust", c->verify_err, (int32_t)sizeof(c->verify_err));
            pthread_mutex_unlock(&c->mu);
            complete(false);
            return;
          }
          CFStringRef host_cf = CFStringCreateWithCString(NULL, c->host_copy ? c->host_copy : "", kCFStringEncodingUTF8);
          SecPolicyRef policy = SecPolicyCreateSSL(true, host_cf);
          if (policy) {
            SecTrustSetPolicies(trust, policy);
          }
          bool anchors_ok = true;
          if (c->ca_copy) {
            char ca_err[256] = {0};
            CFMutableArrayRef anchors = load_pem_certificates(c->ca_copy, ca_err, sizeof(ca_err));
            if (!anchors) {
              anchors_ok = false;
              pthread_mutex_lock(&c->mu);
              c->verify_failed = 1;
              snprintf(c->verify_err, sizeof(c->verify_err), "SSL_CERT_FILE load failed: %s", ca_err);
              pthread_mutex_unlock(&c->mu);
            } else {
              SecTrustSetAnchorCertificates(trust, anchors);
              SecTrustSetAnchorCertificatesOnly(trust, true);
              CFRelease(anchors);
            }
          }
          bool ok = false;
          if (anchors_ok) {
            CFErrorRef cf_err = NULL;
            ok = SecTrustEvaluateWithError(trust, &cf_err);
            if (!ok) {
              pthread_mutex_lock(&c->mu);
              c->verify_failed = 1;
              cf_error_to_cstr(cf_err, c->verify_err, sizeof(c->verify_err));
              if (!c->verify_err[0]) {
                copy_cstr("trust evaluation failed", c->verify_err, (int32_t)sizeof(c->verify_err));
              }
              pthread_mutex_unlock(&c->mu);
            }
            if (cf_err) {
              CFRelease(cf_err);
            }
          }
          if (policy) CFRelease(policy);
          if (host_cf) CFRelease(host_cf);
          CFRelease(trust);
          complete(ok);
        },
        c->queue);
    sec_release(sec_opts);
  };

  nw_parameters_t params = nw_parameters_create_secure_tcp(
      configure_tls, NW_PARAMETERS_DEFAULT_CONFIGURATION);

  char port_str[16];
  snprintf(port_str, sizeof(port_str), "%d", (int)dial_port);
  nw_endpoint_t ep = nw_endpoint_create_host(dial_host, port_str);
  c->conn = nw_connection_create(ep, params);
  nw_release(ep);
  nw_release(params);

  attach_state_handler(c);
  nw_connection_start(c->conn);

  pthread_mutex_lock(&c->mu);
  while (!c->hs_done) {
    pthread_cond_wait(&c->cv, &c->mu);
  }
  int ok = c->hs_ok;
  int vfail = c->verify_failed;
  char verr[256];
  char herr[256];
  copy_cstr(c->verify_err, verr, (int32_t)sizeof(verr));
  copy_cstr(c->hs_err, herr, (int32_t)sizeof(herr));
  pthread_mutex_unlock(&c->mu);

  if (!ok) {
    if (display_port >= 0) {
      if (vfail) {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s:%d failed (certificate verify error: %s)",
            tls_host ? tls_host : "",
            (int)display_port,
            verr);
      } else {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s:%d failed: %s",
            tls_host ? tls_host : "",
            (int)display_port,
            herr[0] ? herr : "handshake error");
      }
    } else {
      if (vfail) {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s failed (certificate verify error: %s)",
            tls_host ? tls_host : "",
            verr);
      } else {
        set_err(
            err_buf,
            err_cap,
            "TLS handshake with %s failed: %s",
            tls_host ? tls_host : "",
            herr[0] ? herr : "handshake error");
      }
    }
    destroy_conn(c);
    return NULL;
  }

  populate_tls_metadata(c);
  return c;
}

void *pion_tls_connect(
    const char *host,
    int32_t port,
    int32_t verify_cert,
    int32_t *out_fd,
    char *err_buf,
    int32_t err_cap) {
  if (out_fd) {
    *out_fd = -1;
  }
  if (!host || !host[0] || port < 1 || port > 65535) {
    set_err(err_buf, err_cap, "connect to %s:%d failed: invalid host or port", host ? host : "", (int)port);
    return NULL;
  }
  return macos_client_connect_endpoint(host, port, host, port, verify_cert, err_buf, err_cap);
}

void *pion_tls_wrap_fd(
    int32_t fd,
    const char *host,
    int32_t verify_cert,
    char *err_buf,
    int32_t err_cap) {
  pthread_once(&g_sigpipe_once, ignore_sigpipe);
  if (fd < 0) {
    set_err(err_buf, err_cap, "TLS handshake with %s failed: invalid fd %d", host ? host : "", (int)fd);
    return NULL;
  }
  int lfd = socket(AF_INET, SOCK_STREAM, 0);
  if (lfd < 0) {
    set_err(err_buf, err_cap, "TLS handshake with %s failed: socket: %s", host ? host : "", strerror(errno));
    return NULL;
  }
  struct sockaddr_in addr;
  memset(&addr, 0, sizeof(addr));
  addr.sin_family = AF_INET;
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  addr.sin_port = 0;
  if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(lfd, 1) != 0) {
    int e = errno;
    close(lfd);
    set_err(err_buf, err_cap, "TLS handshake with %s failed: local relay bind: %s", host ? host : "", strerror(e));
    return NULL;
  }
  socklen_t alen = sizeof(addr);
  if (getsockname(lfd, (struct sockaddr *)&addr, &alen) != 0) {
    int e = errno;
    close(lfd);
    set_err(err_buf, err_cap, "TLS handshake with %s failed: getsockname: %s", host ? host : "", strerror(e));
    return NULL;
  }
  int32_t local_port = (int32_t)ntohs(addr.sin_port);

  int wpipe[2];
  if (pipe(wpipe) != 0) {
    int e = errno;
    close(lfd);
    set_err(err_buf, err_cap, "TLS handshake with %s failed: pipe: %s", host ? host : "", strerror(e));
    return NULL;
  }

  FdRelay *relay = (FdRelay *)calloc(1, sizeof(FdRelay));
  if (!relay) {
    close(lfd);
    close(wpipe[0]);
    close(wpipe[1]);
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  relay->listen_fd = lfd;
  relay->user_fd = (int)fd;
  relay->wake_r = wpipe[0];
  relay->wake_w = wpipe[1];
  relay->stop = 0;

  if (pthread_create(&relay->thread, NULL, relay_thread_main, relay) != 0) {
    int e = errno;
    close(lfd);
    close(wpipe[0]);
    close(wpipe[1]);
    free(relay);
    set_err(err_buf, err_cap, "TLS handshake with %s failed: pthread_create: %s", host ? host : "", strerror(e));
    return NULL;
  }
  relay->started = 1;

  PionMacConn *c = macos_client_connect_endpoint(
      "127.0.0.1", local_port, host ? host : "", -1, verify_cert, err_buf, err_cap);
  if (!c) {
    /* Handshake failed: tear down local relay, do NOT close user_fd! */
    relay->stop = 1;
    uint8_t b = 1;
    ssize_t unused = write(relay->wake_w, &b, 1);
    (void)unused;
    pthread_join(relay->thread, NULL);
    if (relay->listen_fd >= 0) close(relay->listen_fd);
    close(relay->wake_r);
    close(relay->wake_w);
    free(relay);
    return NULL;
  }

  c->has_relay = 1;
  c->owns_user_fd = 1;
  c->relay = relay;
  return c;
}

int32_t pion_tls_protocol(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionMacConn *c = (PionMacConn *)h;
  return copy_cstr(c->protocol, buf, cap);
}

int32_t pion_tls_cipher(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionMacConn *c = (PionMacConn *)h;
  return copy_cstr(c->cipher, buf, cap);
}

int32_t pion_tls_peer_sni(void *h, char *buf, int32_t cap) {
  if (!h) {
    return copy_cstr("", buf, cap);
  }
  PionMacConn *c = (PionMacConn *)h;
  return copy_cstr(c->peer_sni, buf, cap);
}

typedef struct {
  int ok;
  char err[256];
  dispatch_semaphore_t sem;
} SendWait;

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
  PionMacConn *c = (PionMacConn *)h;
  dispatch_data_t ddata = dispatch_data_create(data, (size_t)len, c->queue, DISPATCH_DATA_DESTRUCTOR_DEFAULT);
  SendWait sw;
  memset(&sw, 0, sizeof(sw));
  sw.sem = dispatch_semaphore_create(0);
  SendWait *swp = &sw;

  nw_connection_send(
      c->conn,
      ddata,
      NW_CONNECTION_DEFAULT_MESSAGE_CONTEXT,
      true,
      ^(nw_error_t error) {
        if (error) {
          swp->ok = 0;
          snprintf(
              swp->err,
              sizeof(swp->err),
              "nw_connection_send failed (domain=%d, code=%d)",
              (int)nw_error_get_error_domain(error),
              (int)nw_error_get_error_code(error));
        } else {
          swp->ok = 1;
        }
        dispatch_semaphore_signal(swp->sem);
      });

  dispatch_semaphore_wait(sw.sem, DISPATCH_TIME_FOREVER);
  dispatch_release(ddata);
  dispatch_release(sw.sem);

  if (!sw.ok) {
    set_err(err_buf, err_cap, "%s", sw.err[0] ? sw.err : "TLS write failed");
    return -1;
  }
  return len;
}

typedef struct {
  uint8_t *dst;
  size_t cap;
  size_t copied;
  int is_eof;
  int has_err;
  dispatch_semaphore_t sem;
} RecvWait;

int32_t pion_tls_read(void *h, uint8_t *buf, int32_t max_bytes) {
  if (!h || !buf || max_bytes <= 0) {
    return 0;
  }
  PionMacConn *c = (PionMacConn *)h;
  if (c->eof) {
    return 0;
  }
  RecvWait rw;
  memset(&rw, 0, sizeof(rw));
  rw.dst = buf;
  rw.cap = (size_t)max_bytes;
  rw.sem = dispatch_semaphore_create(0);
  RecvWait *rwp = &rw;

  nw_connection_receive(
      c->conn,
      1,
      (uint32_t)max_bytes,
      ^(dispatch_data_t content, nw_content_context_t context, bool is_complete, nw_error_t error) {
        (void)context;
        if (content) {
          dispatch_data_apply(content, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t size) {
            (void)region;
            (void)offset;
            size_t avail = rwp->cap - rwp->copied;
            size_t take = (size < avail) ? size : avail;
            if (take > 0) {
              memcpy(rwp->dst + rwp->copied, buffer, take);
              rwp->copied += take;
            }
            return rwp->copied < rwp->cap;
          });
        }
        if (is_complete) {
          rwp->is_eof = 1;
        }
        if (error) {
          rwp->has_err = 1;
        }
        dispatch_semaphore_signal(rwp->sem);
      });

  dispatch_semaphore_wait(rw.sem, DISPATCH_TIME_FOREVER);
  dispatch_release(rw.sem);

  if (rw.copied > 0) {
    if (rw.is_eof) {
      c->eof = 1;
    }
    return (int32_t)rw.copied;
  }
  c->eof = 1;
  return rw.has_err ? -1 : 0;
}

void pion_tls_close(void *h) {
  destroy_conn((PionMacConn *)h);
}

/* ------------------------------------------------------------------------- */
/* Server side: nw_listener + in-memory SecIdentityCreate                    */
/* ------------------------------------------------------------------------- */

typedef struct PendingConnNode {
  nw_connection_t conn;
  struct PendingConnNode *next;
} PendingConnNode;

typedef struct {
  nw_listener_t listener;
  dispatch_queue_t queue;
  pthread_mutex_t mu;
  pthread_cond_t cv;
  int ready;
  int failed;
  int cancelled;
  int closed;
  char err[256];
  PendingConnNode *head;
  PendingConnNode *tail;
} PionMacListener;

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

  char detail[256] = {0};
  CFMutableArrayRef certs = load_pem_certificates(cert_pem, detail, sizeof(detail));
  if (!certs) {
    set_err(err_buf, err_cap, "loading certificate chain `%s` failed: %s", cert_pem, detail);
    return NULL;
  }

  detail[0] = '\0';
  SecKeyRef priv_key = load_pem_private_key(key_pem, detail, sizeof(detail));
  if (!priv_key) {
    CFRelease(certs);
    set_err(err_buf, err_cap, "loading private key `%s` failed: %s", key_pem, detail);
    return NULL;
  }

  SecCertificateRef leaf = (SecCertificateRef)CFArrayGetValueAtIndex(certs, 0);
  if (!cert_matches_private_key(leaf, priv_key)) {
    CFRelease(priv_key);
    CFRelease(certs);
    set_err(err_buf, err_cap, "private key `%s` does not match certificate `%s`", key_pem, cert_pem);
    return NULL;
  }

  SecIdentityRef identity = SecIdentityCreate(NULL, leaf, priv_key);
  CFRelease(priv_key);
  if (!identity) {
    CFRelease(certs);
    set_err(err_buf, err_cap, "private key `%s` does not match certificate `%s`", key_pem, cert_pem);
    return NULL;
  }

  sec_identity_t sec_id = NULL;
  CFIndex ncerts = CFArrayGetCount(certs);
  if (ncerts > 1) {
    CFMutableArrayRef extras = CFArrayCreateMutable(NULL, ncerts - 1, &kCFTypeArrayCallBacks);
    for (CFIndex i = 1; i < ncerts; i++) {
      CFArrayAppendValue(extras, CFArrayGetValueAtIndex(certs, i));
    }
    sec_id = sec_identity_create_with_certificates(identity, extras);
    CFRelease(extras);
  } else {
    sec_id = sec_identity_create(identity);
  }
  CFRelease(identity);
  CFRelease(certs);
  if (!sec_id) {
    set_err(err_buf, err_cap, "sec_identity_create failed");
    return NULL;
  }

  nw_parameters_configure_protocol_block_t configure_tls = ^(nw_protocol_options_t tls_options) {
    sec_protocol_options_t sec_opts = nw_tls_copy_sec_protocol_options(tls_options);
    sec_protocol_options_set_local_identity(sec_opts, sec_id);
    sec_protocol_options_set_min_tls_protocol_version(sec_opts, tls_protocol_version_TLSv12);
    sec_protocol_options_set_max_tls_protocol_version(sec_opts, tls_protocol_version_TLSv13);
    sec_release(sec_opts);
  };

  nw_parameters_t params = nw_parameters_create_secure_tcp(
      configure_tls, NW_PARAMETERS_DEFAULT_CONFIGURATION);
  sec_release(sec_id);

  nw_parameters_set_reuse_local_address(params, true);
  char port_str[16];
  snprintf(port_str, sizeof(port_str), "%d", (int)port);
  const char *bind_host = (host && host[0]) ? host : "0.0.0.0";
  nw_endpoint_t ep = nw_endpoint_create_host(bind_host, port_str);
  nw_parameters_set_local_endpoint(params, ep);
  nw_release(ep);

  nw_listener_t listener = nw_listener_create(params);
  nw_release(params);
  if (!listener) {
    set_err(err_buf, err_cap, "listen on %s:%d failed: nw_listener_create failed", bind_host, (int)port);
    return NULL;
  }

  PionMacListener *l = (PionMacListener *)calloc(1, sizeof(PionMacListener));
  if (!l) {
    nw_release(listener);
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  pthread_mutex_init(&l->mu, NULL);
  pthread_cond_init(&l->cv, NULL);
  l->listener = listener;
  l->queue = dispatch_queue_create("pion.tls.listener", DISPATCH_QUEUE_SERIAL);

  nw_listener_set_queue(l->listener, l->queue);
  nw_listener_set_state_changed_handler(l->listener, ^(nw_listener_state_t state, nw_error_t error) {
    pthread_mutex_lock(&l->mu);
    if (state == nw_listener_state_ready) {
      l->ready = 1;
      pthread_cond_broadcast(&l->cv);
    } else if (state == nw_listener_state_failed) {
      l->failed = 1;
      if (error) {
        snprintf(
            l->err,
            sizeof(l->err),
            "domain=%d code=%d",
            (int)nw_error_get_error_domain(error),
            (int)nw_error_get_error_code(error));
      } else {
        copy_cstr("listener failed", l->err, (int32_t)sizeof(l->err));
      }
      pthread_cond_broadcast(&l->cv);
      nw_listener_cancel(l->listener);
    } else if (state == nw_listener_state_cancelled) {
      l->cancelled = 1;
      pthread_cond_broadcast(&l->cv);
    }
    pthread_mutex_unlock(&l->mu);
  });

  nw_listener_set_new_connection_handler(l->listener, ^(nw_connection_t new_conn) {
    pthread_mutex_lock(&l->mu);
    if (l->closed || l->cancelled || l->failed) {
      pthread_mutex_unlock(&l->mu);
      nw_connection_cancel(new_conn);
      return;
    }
    PendingConnNode *node = (PendingConnNode *)calloc(1, sizeof(PendingConnNode));
    if (!node) {
      pthread_mutex_unlock(&l->mu);
      nw_connection_cancel(new_conn);
      return;
    }
    nw_retain(new_conn);
    node->conn = new_conn;
    if (l->tail) {
      l->tail->next = node;
      l->tail = node;
    } else {
      l->head = l->tail = node;
    }
    pthread_cond_signal(&l->cv);
    pthread_mutex_unlock(&l->mu);
  });

  nw_listener_start(l->listener);

  pthread_mutex_lock(&l->mu);
  while (!l->ready && !l->failed && !l->cancelled) {
    pthread_cond_wait(&l->cv, &l->mu);
  }
  int ok = l->ready && !l->failed && !l->cancelled;
  char lerr[256];
  copy_cstr(l->err, lerr, (int32_t)sizeof(lerr));
  pthread_mutex_unlock(&l->mu);

  if (!ok) {
    set_err(err_buf, err_cap, "listen on %s:%d failed: %s", bind_host, (int)port, lerr[0] ? lerr : "listener error");
    pion_tls_listener_close(l);
    return NULL;
  }

  uint16_t bound = nw_listener_get_port(l->listener);
  if (out_port) {
    *out_port = (int32_t)bound;
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
  PionMacListener *l = (PionMacListener *)lh;

  pthread_mutex_lock(&l->mu);
  while (!l->head && !l->closed && !l->failed && !l->cancelled) {
    pthread_cond_wait(&l->cv, &l->mu);
  }
  if (!l->head) {
    pthread_mutex_unlock(&l->mu);
    set_err(err_buf, err_cap, "accept on listener failed: listener closed");
    return NULL;
  }
  PendingConnNode *node = l->head;
  l->head = node->next;
  if (!l->head) {
    l->tail = NULL;
  }
  pthread_mutex_unlock(&l->mu);

  nw_connection_t raw_conn = node->conn;
  free(node);

  PionMacConn *c = (PionMacConn *)calloc(1, sizeof(PionMacConn));
  if (!c) {
    nw_connection_cancel(raw_conn);
    nw_release(raw_conn);
    set_err(err_buf, err_cap, "out of memory");
    return NULL;
  }
  pthread_mutex_init(&c->mu, NULL);
  pthread_cond_init(&c->cv, NULL);
  c->conn = raw_conn;
  c->queue = dispatch_queue_create("pion.tls.server_conn", DISPATCH_QUEUE_SERIAL);

  attach_state_handler(c);
  nw_connection_start(c->conn);

  pthread_mutex_lock(&c->mu);
  while (!c->hs_done) {
    pthread_cond_wait(&c->cv, &c->mu);
  }
  int ok = c->hs_ok;
  char herr[256];
  copy_cstr(c->hs_err, herr, (int32_t)sizeof(herr));
  pthread_mutex_unlock(&c->mu);

  if (!ok) {
    set_err(err_buf, err_cap, "TLS server handshake failed: %s", herr[0] ? herr : "peer closed");
    destroy_conn(c);
    return NULL;
  }

  populate_tls_metadata(c);
  copy_cstr(c->peer_sni, sni_buf, sni_cap);
  return c;
}

void pion_tls_listener_close(void *lh) {
  if (!lh) {
    return;
  }
  PionMacListener *l = (PionMacListener *)lh;
  pthread_mutex_lock(&l->mu);
  l->closed = 1;
  pthread_cond_broadcast(&l->cv);
  pthread_mutex_unlock(&l->mu);

  if (l->listener) {
    nw_listener_cancel(l->listener);
    pthread_mutex_lock(&l->mu);
    while (!l->cancelled) {
      pthread_cond_wait(&l->cv, &l->mu);
    }
    pthread_mutex_unlock(&l->mu);
    nw_release(l->listener);
    l->listener = NULL;
  }
  while (l->head) {
    PendingConnNode *n = l->head;
    l->head = n->next;
    nw_connection_cancel(n->conn);
    nw_release(n->conn);
    free(n);
  }
  l->tail = NULL;
  if (l->queue) {
    dispatch_release(l->queue);
    l->queue = NULL;
  }
  pthread_cond_destroy(&l->cv);
  pthread_mutex_destroy(&l->mu);
  free(l);
}
