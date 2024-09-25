#!/bin/sh

# Replace the placeholder in the dnsmasq config template with the IP address from the environment variable
sed "s/{{RANCHER_TEST_IP}}/${RANCHER_TEST_IP}/g" /etc/dnsmasq.conf.template > /etc/dnsmasq.conf

# Run dnsmasq in the foreground
exec dnsmasq -k
