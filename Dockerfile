# Use a lightweight base image
FROM alpine:3.18

# Install dnsmasq
RUN apk add --no-cache dnsmasq

# Set an environment variable for the default IP address
ENV RANCHER_TEST_IP=192.168.100.1

# Copy the entrypoint script and dnsmasq config template
COPY entrypoint.sh /entrypoint.sh
COPY dnsmasq.conf.template /etc/dnsmasq.conf.template

# Make the script executable
RUN chmod +x /entrypoint.sh

# Expose DNS port
EXPOSE 53/udp

# Use the entrypoint script to configure dnsmasq
ENTRYPOINT ["/entrypoint.sh"]
