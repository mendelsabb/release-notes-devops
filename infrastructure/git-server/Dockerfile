# Minimal smart-HTTP git server: the local stand-in for GitHub that Argo CD
# watches. Anonymous read and push - acceptable only because it is reachable
# solely from inside the kind cluster and from 127.0.0.1 on the host.
FROM alpine:3.22
RUN apk add --no-cache git git-daemon nginx fcgiwrap spawn-fcgi \
    && addgroup -S -g 10001 git && adduser -S -u 10001 -G git -h /srv/git git
COPY nginx.conf /etc/nginx/git.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
ENV HOME=/tmp
USER 10001:10001
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
