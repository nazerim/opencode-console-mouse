/* bpcheck: print kernel VT state relevant to console paste.
 * Run ON the tty you paste into:  ./bpcheck
 * Or from elsewhere:              ./bpcheck < /dev/ttyN */
#include <stdio.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/tiocl.h>

int main(void)
{
    char cmd;
    long r;

    printf("tty: %s\n", ttyname(0) ? ttyname(0) : "(not a tty)");

    /* kernel: case TIOCL_GETBRACKETEDPASTE: return get_bracketed_paste(tty);
     * -> value comes back as the ioctl() return, NOT written to the buffer */
    cmd = TIOCL_GETBRACKETEDPASTE;
    r = ioctl(0, TIOCLINUX, &cmd);
    if (r < 0) perror("TIOCL_GETBRACKETEDPASTE");
    else printf("vt ?2004 (bracketed paste) = %ld   <-- 1 means kernel WRAPS every"
                " console paste (gpm middle-click) in ESC[200~..ESC[201~\n", r);

    /* shift state IS written back to the buffer */
    cmd = TIOCL_GETSHIFTSTATE;
    if (ioctl(0, TIOCLINUX, &cmd) == 0)
        printf("shift state now            = 0x%02x\n", (unsigned char)cmd);

    return 0;
}
