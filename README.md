# DevOps Projects

DevOps portfolio for cloud engineering roles. This repository is where I publish the delivery systems that show how I build, test, release, and operate infrastructure on AWS and Azure.

## What this work shows

- CI/CD pipelines with security gates (secret scanning, IaC and container scanning, code quality) before anything is deployed
- Promotion from QA to production of the exact image that was tested, with the deployed version recorded in Git
- Cloud authentication with OpenID Connect, so pipelines do not store long-lived access keys
- Separate QA and production environments, each with its own least-privilege deploy role
- Observability with metrics, logs and dashboards for every environment

Each project lives in its own folder so it can be reviewed on its own.

## Projects

| Project | What it covers | Stack |
|---------|----------------|-------|
| [3-Tier User Platform on AWS EKS](3-Tier-User-Platform-Project) | React, Node.js and MySQL app on Amazon EKS with a 15-job DevSecOps pipeline, QA to prod image promotion, External Secrets and Prometheus, Loki and Grafana monitoring | AWS EKS, Kubernetes, Docker, GitHub Actions, SonarQube, Trivy, Checkov, Gitleaks |
