#!/bin/sh
# Runs after certbot renews the certificate: make the services load the new one.
systemctl reload postfix dovecot nginx
