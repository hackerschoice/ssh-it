dnl Process this File with autoconf to produce a configure script.
AC_PREREQ([2.69])
AC_INIT([ssh-it],[31.337.0])
AC_CONFIG_AUX_DIR(config)
AC_CANONICAL_TARGET

dnl we use automake
AM_INIT_AUTOMAKE([foreign])
AC_CONFIG_HEADERS(config.h)
dnl AM_PROG_AR
dnl for --enable-maintainer-mode fun use:
dnl AM_MAINTAINER_MODE 
dnl AC_DISABLE_STATIC
dnl LT_INIT([disable-static])

dnl AC_CONFIG_MACRO_DIRS([m4])

dnl Checks for programs.
AC_PROG_CC # This may add COPTS=-g -O2
AC_PROG_INSTALL
AC_PROG_RANLIB
AC_CHECK_PROG([MAKE_CHECK], [make], [yes], [no])
AS_IF([test x$MAKE_CHECK = xno], [AC_MSG_ERROR([make not found])])

dnl
dnl Use these compiler flags if we have gcc.
dnl
if test $ac_cv_c_compiler_gnu = yes; then
  CCOPTS='-O2 -Wall'
  CFLAGS="$CCOPTS $CFLAGS"
fi
test "x$prefix" != "xNONE" || prefix="/usr/local"
test "x$exec_prefix" != "xNONE" || exec_prefix="${prefix}"


dnl Do "gcc -xc -E -v -" to figure out default paths
dnl Scenarios
dnl --prefix=$HOME/usr                                 => -I$HOME/usr/include /usr/include /usr/local/include
dnl --prefix=/usr       --includedir=$HOME/usr/include => -I$HOME/usr/include /usr/include /usr/local/include
dnl --prefix=/usr/local --includedir=$HOME/usr/include => -I$HOME/usr/include /usr/local/include /usr/include

dnl default: PREFIX/include unless --includedir=

dnl Try include paths (especially on OSX)
trydir_i="${includedir} /usr/local/include"
for xincdir in $trydir_i ; do
	if test ! -d "$xincdir" ; then
		continue;
	fi
	if test x"${INCLUDES}" = x; then
		INCLUDES="-I${xincdir}";
	else
		INCLUDES="$INCLUDES -I${xincdir}";
	fi
done
CPPFLAGS="-I${srcdir}/../include ${INCLUDES} $CPPFLAGS"

dnl Try library paths...
trydir_l="${libdir} /usr/local/lib"
for xlibdir in $trydir_l ; do
	if test ! -d "$xlibdir" ; then
		continue;
	fi
	if test x"${LIBDIR}" = x; then
		LIBDIR="-L${xlibdir}";
	else
		LIBDIR="$LIBDIR -L${xlibdir}";
	fi
done
LDFLAGS="${LIBDIR} $LDFLAGS"

case "$host" in
*-cygwin*)
	;;
mips-sony-bsd|mips-sony-newsos4)
        AC_DEFINE([NEED_SETPGRP], [1], [Need setpgrp to acquire controlling tty])
	;;
*-*-ultrix*)
        AC_DEFINE([NEED_SETPGRP], [1], [Need setpgrp to acquire controlling tty])
	;;
*-*-darwin*|*-*-*bsd*)
	AC_DEFINE([BSD_SCRIPT], [1], [/usr/bin/script is the bsd variant])
	if test x"$(which ar)" != x'/usr/bin/ar'; then
		ARDIRWARN=1
	fi
	;;
esac

OSARCH="$(${srcdir}/src/x.sh osarch)"

dnl Checks for header files.
AC_HEADER_SYS_WAIT
AC_CHECK_HEADERS(sys/time.h sys/endian.h unistd.h fnmatch.h string.h utmp.h utmpx.h pty.h util.h libutil.h netinet/in_systm.h sys/loadavg.h libproc.h)

dnl Checks for typedefs, structures, and compiler characteristics.
AC_C_CONST
AC_TYPE_PID_T

dnl Checks for library functions.
AC_FUNC_MEMCMP

dnl If size_t is not defined, define size_t to be unsigned. 
AC_TYPE_SIZE_T 
dnl If uid_t is not defined, define uid_t to be int and gid_t to be int.
AC_TYPE_UID_T

AC_ARG_ENABLE(static,
[  --enable-static          Compile static binary],
	[STATIC="yes"], [STATIC="no"]
)

dnl OSX does not support static binaries.
if test x"${STATIC}" = xyes; then
	case "$host" in
	*-*-darwin*)
		echo "
*** OSX does not support static binaries. Creating dynamic binaries ***
*** instead and trying our best.                                    ***
"
		;;
	*)
		CFLAGS_STATIC="-static "
		;;
	esac
fi


AC_CHECK_LIB(util, forkpty)
AC_CHECK_FUNCS(gettimeofday memcpy strchr strlcat forkpty openpty getline)

AC_ARG_ENABLE([debug],
	AS_HELP_STRING([--enable-debug], [Enable debug information.]),
	[debug=true AC_DEFINE(BUILD_DEBUG, 1, [Debug infos])]
)

AS_IF([test x$enable_debug = xyes], AC_DEFINE(D31337, 1, [Expermental feature]))

AC_SUBST(LDADD_STATIC, "${LDADD_STATIC}")
AC_SUBST(CFLAGS_STATIC, "${CFLAGS_STATIC}")
AC_SUBST(OSARCH, "${OSARCH}")
AC_CONFIG_FILES([Makefile src/Makefile])
AC_OUTPUT


echo "
${PACKAGE_NAME}-${PACKAGE_VERSION} has been configured:

 Host..............: ${host}
 OSARCH............: ${OSARCH}
 Compiler..........: ${CC}
 Compiler flags....: ${CFLAGS_STATIC}${CFLAGS}
 Preprocessor flags: ${CPPFLAGS}
 Linker flags......: ${LDFLAGS}
 Libraries.........: ${LIBS}

Configuration complete. Now type: THC_VERBOSE=1 make all install"

if test x"${ARDIRWARN}" = x1; then
	AC_MSG_WARN([Build tools seem to be a mix of GNU and Apple.])
	AC_MSG_WARN([try 'PATH=/usr/bin:\$PATH ./configure'.])
fi

