# Deploy Your Application to Azure using GitHub

Included in this repo is some simple HTML to generate a website. The workflows use Bicep, but there are Terraform files included if you would like to switch it up.

There is a starter workflow setup to deploy to different environments and include the following:
- A multi environment workflow for complete CI/CD
- Gating between environments to ensure manual code checks
- Microsoft Defender scanning of your Azure ACR vulnerabilities
