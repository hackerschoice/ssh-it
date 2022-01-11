

typedef void (*cb_lnbuf_t)(void *lnbuf, void *arg);

typedef struct
{
	int id;
	char *data;
	char *line;
	char *wd;
	char *end;
	size_t sz_max;
	cb_lnbuf_t func;
	void *arg;
} LNBUF;

void LNBUF_init(LNBUF *l, size_t sz_max, int id, cb_lnbuf_t func, void *arg);
void LNBUF_add(LNBUF *l, void *in, size_t sz);
void LNBUF_free(LNBUF *l);
char *LNBUF_str(LNBUF *l);
char *LNBUF_line(LNBUF *l);
#define LNBUF_IS_INIT(_lnb)   (_lnb)->data?1:0

int fd_cmd(const char *cmd, pid_t *pidptr, bool is_setsid);
void mkdirp(const char *path);
char *find_bin_in_path(char *bin, int pos);
void cmd_failed_exit(const char *cmd);

void stty_set_pwd(int fd);
void stty_set_raw(int fd);
void stty_set_passthrough(int fd, struct termios *tios_orig);

uint64_t THC_usec(void);


const char *THC_logtime(void);
