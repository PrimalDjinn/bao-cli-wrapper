FROM openbao/openbao:latest

RUN apk add --no-cache jq gettext netcat-openbsd curl

WORKDIR /bao

# Copy both potential configs, but we'll use json
COPY config.json /bao/config.json
COPY entrypoint.sh /bao/entrypoint.sh
RUN mkdir -p /bao/policy
COPY policy/ /bao/policy/

RUN chmod +x /bao/entrypoint.sh

ENTRYPOINT ["/bao/entrypoint.sh"]
