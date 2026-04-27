#!/bin/bash
# ================================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the Cost Explorer MCP API stack.
#   This includes environment validation and Lambda/API Gateway infrastructure.
# ================================================================================

# ------------------------------------------------------------------------------
# Global configuration
# ------------------------------------------------------------------------------

# Default AWS region for all CLI and Terraform operations.
export AWS_DEFAULT_REGION="us-east-1"

# Enable strict shell behavior:
#   -e  Exit immediately on error
#   -u  Treat unset variables as errors
#   -o pipefail  Fail pipelines if any command fails
set -euo pipefail

# ------------------------------------------------------------------------------
# Environment pre-check
# ------------------------------------------------------------------------------

# Validate that required tools, credentials, and environment variables
# are present before proceeding with any infrastructure deployment.
echo "NOTE: Running environment validation..."
./check_env.sh

# ------------------------------------------------------------------------------
# Build Lambda functions and API Gateway
# ------------------------------------------------------------------------------

# Deploys backend infrastructure including:
#   - Six Lambda functions (one per MCP cost tool)
#   - API Gateway (HTTP API with IAM authorization)
#   - IAM roles scoped to Cost Explorer read permissions
# using Terraform configuration in the 01-lambdas directory.
echo "NOTE: Building Lambdas and API Gateway..."

cd 01-lambdas || {
  echo "ERROR: 01-lambdas directory missing."
  exit 1
}

terraform init
terraform apply -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Post-deployment validation
# ------------------------------------------------------------------------------

# Invokes each Lambda function directly to verify Cost Explorer connectivity
# and confirm plain-text summaries are returned correctly.
echo "NOTE: Running build validation..."
./validate.sh

# ================================================================================
# End of script
# ================================================================================
