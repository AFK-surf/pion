#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    int n;
    int y_start;
    int y_end;
    int in_set;
    int xhash;
} WorkerArg;

static void compute_stripe(WorkerArg *a) {
    int n = a->n;
    double inv_n = 2.0 / (double)n;
    int in_set = 0;
    int xhash = 0;

    for (int y = a->y_start; y < a->y_end; y++) {
        double ci = (double)y * inv_n - 1.0;
        int row_h = 0;
        int byte_acc = 0;
        int bit_num = 0;
        for (int x = 0; x < n; x++) {
            double cr = (double)x * inv_n - 1.5;
            double zr = 0.0, zi = 0.0;
            int escaped = 0;
            for (int iter = 0; iter < 50; iter++) {
                double tr = zr * zr - zi * zi + cr;
                double ti = 2.0 * zr * zi + ci;
                zr = tr;
                zi = ti;
                if (zr * zr + zi * zi > 4.0) {
                    escaped = 1;
                    break;
                }
            }
            byte_acc = (byte_acc << 1) | (escaped ? 0 : 1);
            if (!escaped) {
                in_set++;
            }
            bit_num++;
            if (bit_num == 8) {
                row_h = ((row_h * 31) + byte_acc) & 0x3fffffff;
                byte_acc = 0;
                bit_num = 0;
            }
        }
        if (bit_num > 0) {
            byte_acc <<= (8 - bit_num);
            row_h = ((row_h * 31) + byte_acc) & 0x3fffffff;
        }
        int row_mix = (row_h ^ ((y * 2654435) & 0x3fffffff)) & 0x3fffffff;
        xhash ^= row_mix;
    }

    a->in_set = in_set;
    a->xhash = xhash;
}

static void *worker_fn(void *p) {
    compute_stripe((WorkerArg *)p);
    return NULL;
}

int main(int argc, char **argv) {
    int threads = (argc > 1) ? atoi(argv[1]) : 1;
    int n = (argc > 2) ? atoi(argv[2]) : 4000;
    if (threads < 1) threads = 1;
    if (threads > 64) threads = 64;

    if (threads == 1) {
        WorkerArg a = {n, 0, n, 0, 0};
        compute_stripe(&a);
        printf("%d %d\n", a.in_set, a.xhash);
        return 0;
    }

    pthread_t tids[64];
    WorkerArg args[64];
    for (int t = 0; t < threads; t++) {
        args[t].n = n;
        args[t].y_start = (n * t) / threads;
        args[t].y_end = (n * (t + 1)) / threads;
        args[t].in_set = 0;
        args[t].xhash = 0;
        pthread_create(&tids[t], NULL, worker_fn, &args[t]);
    }

    int total_in_set = 0;
    int total_xhash = 0;
    for (int t = 0; t < threads; t++) {
        pthread_join(tids[t], NULL);
        total_in_set += args[t].in_set;
        total_xhash ^= args[t].xhash;
    }

    printf("%d %d\n", total_in_set, total_xhash);
    return 0;
}
