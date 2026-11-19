#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static inline double eval_A(int i, int j) {
    int ij = i + j;
    return 1.0 / ((double)(ij * (ij + 1) / 2 + i + 1));
}

static void eval_A_times_u(int n, const double *u, double *au) {
    for (int i = 0; i < n; i++) {
        double sum = 0.0;
        for (int j = 0; j < n; j++) {
            sum += eval_A(i, j) * u[j];
        }
        au[i] = sum;
    }
}

static void eval_At_times_u(int n, const double *u, double *au) {
    for (int i = 0; i < n; i++) {
        double sum = 0.0;
        for (int j = 0; j < n; j++) {
            sum += eval_A(j, i) * u[j];
        }
        au[i] = sum;
    }
}

static void eval_AtA_times_u(int n, const double *u, double *atau, double *v) {
    eval_A_times_u(n, u, v);
    eval_At_times_u(n, v, atau);
}

int main(int argc, char **argv) {
    int n = (argc > 1) ? atoi(argv[1]) : 2000;
    double *u = (double *)malloc((size_t)n * sizeof(double));
    double *v = (double *)malloc((size_t)n * sizeof(double));
    double *tmp = (double *)malloc((size_t)n * sizeof(double));
    for (int i = 0; i < n; i++) {
        u[i] = 1.0;
        v[i] = 0.0;
    }
    for (int i = 0; i < 10; i++) {
        eval_AtA_times_u(n, u, v, tmp);
        eval_AtA_times_u(n, v, u, tmp);
    }
    double vBv = 0.0, vv = 0.0;
    for (int i = 0; i < n; i++) {
        vBv += u[i] * v[i];
        vv += v[i] * v[i];
    }
    printf("%.9f\n", sqrt(vBv / vv));
    free(u);
    free(v);
    free(tmp);
    return 0;
}
