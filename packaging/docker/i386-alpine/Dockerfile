FROM i386/alpine

WORKDIR /root/
RUN apk update \
	&& apk add --no-cache bash musl-dev linux-headers gcc make automake && \
	rm -rf /var/cache/apk/* && \
	echo done
