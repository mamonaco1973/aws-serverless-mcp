#!/bin/bash
# ================================================================================
# File: destroy.sh
#
# Purpose:
#   Tears down the Notes application stack deployed by apply.sh.
#   Destroys the static web client first, then backend Lambdas/API.
# ================================================================================

# ------------------------------------------------------------------------------
# Global configuration
# ------------------------------------------------------------------------------

# Default AWS region used by AWS CLI and Terraform providers.
export AWS_DEFAULT_REGION="us-east-1"

# Enable strict shell execution:
#   -e  Exit immediately on command failure
#   -u  Treat unset variables as errors
#   -o pipefail  Propagate failures across piped commands
set -euo pipefail

# ------------------------------------------------------------------------------
# Destroy static web application
# ------------------------------------------------------------------------------

# Removes the S3-hosted static web app and associated resources
# provisioned by Terraform in the 02-webapp directory.
echo "NOTE: Destroying Web Application..."

cd 02-webapp || {
  echo "ERROR: Directory 02-webapp not found."
  exit 1
}

terraform init
terraform destroy -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Destroy Lambda functions and API Gateway
# ------------------------------------------------------------------------------

# Removes backend infrastructure including:
#   - Lambda compute functions
#   - API Gateway (HTTP API) and routes/integrations
# provisioned by Terraform in the 01-lambdas directory.
echo "NOTE: Destroying Lambdas and API Gateway..."

cd 01-lambdas || {
  echo "ERROR: Directory 01-lambdas not found."
  exit 1
}

terraform init
terraform destroy -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Completion
# ------------------------------------------------------------------------------

# Indicates that all Terraform stacks completed teardown successfully.
echo "NOTE: Infrastructure teardown complete."

# ================================================================================
# End of script
# ================================================================================
