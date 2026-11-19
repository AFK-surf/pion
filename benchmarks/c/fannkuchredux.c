#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    int n = (argc > 1) ? atoi(argv[1]) : 10;
    int *perm = (int *)malloc((size_t)n * sizeof(int));
    int *perm1 = (int *)malloc((size_t)n * sizeof(int));
    int *count = (int *)malloc((size_t)n * sizeof(int));

    for (int i = 0; i < n; i++) {
        perm1[i] = i;
    }

    int max_flips = 0;
    int checksum = 0;
    int perm_count = 0;
    int r = n;

    for (;;) {
        while (r != 1) {
            count[r - 1] = r;
            r--;
        }

        for (int i = 0; i < n; i++) {
            perm[i] = perm1[i];
        }

        int flips = 0;
        int k = perm[0];
        while (k != 0) {
            int k2 = (k + 1) >> 1;
            for (int i = 0; i < k2; i++) {
                int tmp = perm[i];
                perm[i] = perm[k - i];
                perm[k - i] = tmp;
            }
            flips++;
            k = perm[0];
        }

        if (flips > max_flips) {
            max_flips = flips;
        }
        if ((perm_count & 1) == 0) {
            checksum += flips;
        } else {
            checksum -= flips;
        }
        perm_count++;

        for (;;) {
            if (r == n) {
                printf("%d %d\n", checksum, max_flips);
                free(perm);
                free(perm1);
                free(count);
                return 0;
            }
            int perm0 = perm1[0];
            for (int i = 0; i < r; i++) {
                perm1[i] = perm1[i + 1];
            }
            perm1[r] = perm0;
            count[r]--;
            if (count[r] > 0) {
                break;
            }
            r++;
        }
    }
}
