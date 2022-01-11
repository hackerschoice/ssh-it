FROM muslcc/i686:mips-linux-muslsf

WORKDIR /root/
RUN apk update \
	&& apk add --no-cache bash perl make && \
	rm -rf /var/cache/apk/* && \
	echo done
