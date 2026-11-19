#include <stdio.h>
#include <stdlib.h>

typedef struct Node {
    struct Node *left;
    struct Node *right;
} Node;

static Node *make_tree(int depth) {
    Node *n = (Node *)malloc(sizeof(Node));
    if (depth > 0) {
        n->left = make_tree(depth - 1);
        n->right = make_tree(depth - 1);
    } else {
        n->left = NULL;
        n->right = NULL;
    }
    return n;
}

static int check_tree(const Node *n) {
    if (n->left == NULL) {
        return 1;
    }
    return 1 + check_tree(n->left) + check_tree(n->right);
}

static void free_tree(Node *n) {
    if (n->left != NULL) {
        free_tree(n->left);
        free_tree(n->right);
    }
    free(n);
}

int main(int argc, char **argv) {
    int max_depth = (argc > 1) ? atoi(argv[1]) : 16;
    int min_depth = 4;
    if (min_depth + 2 > max_depth) {
        max_depth = min_depth + 2;
    }

    int stretch_depth = max_depth + 1;
    Node *stretch = make_tree(stretch_depth);
    int stretch_check = check_tree(stretch);
    free_tree(stretch);

    Node *long_lived = make_tree(max_depth);

    long long total_check = 0;
    for (int depth = min_depth; depth <= max_depth; depth += 2) {
        int iterations = 1 << (max_depth - depth + min_depth);
        int check = 0;
        for (int i = 0; i < iterations; i++) {
            Node *t = make_tree(depth);
            check += check_tree(t);
            free_tree(t);
        }
        total_check += check;
    }

    int long_check = check_tree(long_lived);
    free_tree(long_lived);

    printf("stretch=%d long=%d total=%lld\n", stretch_check, long_check, total_check);
    return 0;
}
