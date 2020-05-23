FROM alpine:3.11

# Install jq, iptables, and kubectl
RUN apk add jq iptables
RUN wget -q -O /usr/bin/kubectl "https://storage.googleapis.com/kubernetes-release/release/$(wget -q -O - https://storage.googleapis.com/kubernetes-release/release/stable.txt)/bin/linux/amd64/kubectl" && chmod +x /usr/bin/kubectl

COPY run.sh /root/run.sh

CMD ["/root/run.sh"]
