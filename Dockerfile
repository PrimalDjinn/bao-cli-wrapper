FROM openbao/openbao:latest

RUN apk add --no-cache jq

WORKDIR /bao

# Copy both potential configs, but we'll use json
COPY config.json /bao/config.json
COPY entrypoint.sh /bao/entrypoint.sh
COPY env-policy.hcl /bao/env-policy.hcl

RUN chmod +x /bao/entrypoint.sh

ENTRYPOINT ["/bao/entrypoint.sh"]