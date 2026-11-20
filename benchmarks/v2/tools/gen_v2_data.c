/*
 * Deterministic V2 benchmark dataset generator (pure C, zero Python).
 * Usage: gen_v2_data <out_dir>
 *
 * Generates:
 *   <out_dir>/dataset.json  (~11-12 MB, 30,000 nested JSON records)
 *   <out_dir>/logs.txt      (~18 MB, 200,000 structured log lines)
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static uint64_t rng_state = 0x123456789abcdef0ULL;

static uint64_t next_u64(void) {
    uint64_t x = rng_state;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    rng_state = x;
    return x;
}

static int gen_dataset_json(const char *out_dir) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/dataset.json", out_dir);
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror("fopen dataset.json");
        return 1;
    }

    static char io_buf[1 << 20];
    setvbuf(f, io_buf, _IOFBF, sizeof(io_buf));

    static const char *roles[8] = {
        "admin", "editor", "viewer", "ops", "sec", "ml", "billing", "guest"
    };
    static const char *tags[8] = {
        "prod", "staging", "edge", "canary", "batch", "realtime", "eu", "us"
    };
    static const char *regions[6] = {
        "us-east-1", "us-west-2", "eu-central-1", "ap-northeast-1", "ap-southeast-1", "sa-east-1"
    };

    rng_state = 0x123456789abcdef0ULL;
    const int N = 45000;

    fputs("{\"meta\":{\"version\":2,\"env\":\"prod\"},\"records\":[\n", f);
    for (int i = 0; i < N; i++) {
        uint64_t r1 = next_u64();
        uint64_t r2 = next_u64();
        uint64_t r3 = next_u64();

        int id = 100000 + i;
        const char *role = roles[r1 & 7];
        int active = ((r1 >> 3) % 100) < 65 ? 1 : 0;
        int latency_ms = 10 + (int)((r1 >> 11) % 490);
        int retries = (int)((r1 >> 21) % 6);
        int ntags = 2 + (int)((r2) % 3); /* 2..4 tags */
        const char *region = regions[(r2 >> 4) % 6];
        int shard = (int)((r2 >> 10) % 64);

        fprintf(f,
                "{\"user\":{\"id\":%d,\"name\":\"user_%05d_%s\",\"role\":\"%s\",\"active\":%s},"
                "\"metrics\":{\"latency_ms\":%d,\"retries\":%d,\"tags\":[",
                id, i, region, role, active ? "true" : "false", latency_ms, retries);

        int t_start = (int)((r2 >> 18) & 7);
        for (int t = 0; t < ntags; t++) {
            int tidx = (t_start + t * 3) & 7;
            if (t > 0) fputc(',', f);
            fprintf(f, "\"%s\"", tags[tidx]);
        }

        fprintf(f,
                "]},\"note\":\"req \\\"%05d\\\" \\\\ region=%s\\nshard=%02d\\ttrace=%08llx payload_ok\","
                "\"nullable\":",
                i, region, shard, (unsigned long long)(r3 & 0xffffffffULL));

        int nkind = (int)((r3 >> 32) % 3);
        if (nkind == 0) {
            fputs("null", f);
        } else if (nkind == 1) {
            int nv = (int)((r3 >> 36) % 10000) - 5000;
            fprintf(f, "%d", nv);
        } else {
            fprintf(f, "\"opt_%04llu\"", (unsigned long long)((r3 >> 36) % 9973));
        }

        if (i + 1 < N) {
            fputs("},\n", f);
        } else {
            fputs("}\n", f);
        }
    }
    fputs("]}\n", f);
    fclose(f);
    return 0;
}

static int gen_logs_txt(const char *out_dir) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/logs.txt", out_dir);
    FILE *f = fopen(path, "wb");
    if (!f) {
        perror("fopen logs.txt");
        return 1;
    }

    static char io_buf[1 << 20];
    setvbuf(f, io_buf, _IOFBF, sizeof(io_buf));

    static const char *svcs[8] = {
        "auth", "pay", "edge", "search", "cache", "db", "ml", "ingest"
    };
    static const char *regions[6] = {
        "us-east", "us-west", "eu-west", "ap-ne1", "ap-se1", "ca-cen"
    };

    rng_state = 0x9e3779b97f4a7c15ULL;
    const int LINES = 200000;

    for (int i = 0; i < LINES; i++) {
        uint64_t r1 = next_u64();
        uint64_t r2 = next_u64();

        long long ts = 1700000000LL + (long long)i * 3LL + (long long)(r1 % 3);
        int lv = (int)((r1 >> 4) % 100);
        const char *level = (lv < 75) ? "INFO" : ((lv < 90) ? "WARN" : "ERR");
        const char *svc = svcs[(r1 >> 12) & 7];
        int lat_bucket = (int)((r1 >> 16) % 100);
        int lat = (lat_bucket < 88)
                      ? (5 + (int)((r1 >> 24) % 495))
                      : (500 + (int)((r1 >> 24) % 1001));
        const char *reg = regions[(r2) % 6];
        int code = (lv >= 90) ? (500 + (int)((r2 >> 8) % 5)) : 200;
        unsigned long long req_id = (unsigned long long)((r2 >> 16) & 0xffffffULL);

        fprintf(f, "ts=%lld level=%s svc=%s lat=%d msg=req_%06llu_reg_%s_code_%d_shard_%02d\n",
                ts, level, svc, lat, req_id, reg, code, i & 31);
    }

    fclose(f);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <out_dir>\n", argv[0]);
        return 2;
    }
    mkdir(argv[1], 0755);
    if (gen_dataset_json(argv[1]) != 0) return 1;
    if (gen_logs_txt(argv[1]) != 0) return 1;
    return 0;
}
