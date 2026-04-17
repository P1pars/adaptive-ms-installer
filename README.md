# Adaptive MS Installer

## Installation

This installer deploys Adaptive MS with Docker and PostgreSQL.

## What it does

- Performs a fresh install if no previous configuration exists
- Detects an existing installation after server or VM restart
- Lets you:
  - reuse the old configuration and start the system
  - or delete everything and perform a fresh install

## Requirements

- Ubuntu or another Linux server
- Docker installed and running
- Docker Compose available
- Access to the private Docker image:
  `hubadaptive/adaptive-ms:latest`

1. Login to Docker Hub:
sudo docker login -u hubadaptive

2. Download installer:
curl -fsSL https://raw.githubusercontent.com/P1pars/adaptive-ms-installer/main/adaptive-installer.sh -o adaptive-installer.sh

3. Make executable:
chmod +x adaptive-installer.sh

4. Run:
sudo ./adaptive-installer.sh
