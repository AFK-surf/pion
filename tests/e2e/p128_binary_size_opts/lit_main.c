/* P128: final link of the `ld -r` merged literal objects. */
#include <stdio.h>
#include <string.h>

const char *lit_pad(void);
const char *lit_direct(void);
const char *lit_got(void);
const char *lit_got_direct(void);
extern const char *lit_direct_ptr;

int main(void) {
    const char *got = lit_got(), *got_direct = lit_got_direct();
    printf("%s|%s|%s|%s|%s|%d\n", lit_pad(), lit_direct(), lit_direct_ptr,
           got, got_direct, got == got_direct);
    return 0;
}
