#!/usr/bin/env bash
sudo dnf install -y nginx || sudo yum install -y nginx
sudo systemctl enable nginx
sudo systemctl start nginx
sudo systemctl status nginx
