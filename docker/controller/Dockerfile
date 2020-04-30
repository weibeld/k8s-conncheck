FROM alpine:3.11

# Install jq
RUN apk add jq

# Install yq
RUN wget -q -O /usr/bin/yq "$(wget -q -O - https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r '.assets[] | select(.name == "yq_linux_amd64") | .browser_download_url')" && chmod +x /usr/bin/yq

# Install kubectl
RUN wget -q -O /usr/bin/kubectl "https://storage.googleapis.com/kubernetes-release/release/$(wget -q -O - https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x /usr/bin/kubectl

COPY run.sh .

