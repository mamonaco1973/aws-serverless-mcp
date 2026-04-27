# ================================================================================
# File: apply.sh
#
# Purpose:
#   Orchestrates end-to-end deployment of the Notes application stack.
#   This includes environment validation, Lambda/API infrastructure,
#   and a static web client wired to the deployed API Gateway endpoint.
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
#   - Lambda functions
#   - API Gateway (HTTP API)
# using Terraform configuration in the 01-lambdas directory.
echo "NOTE: Building Lambdas and API gateway..."

cd 01-lambdas || {
  echo "ERROR: 01-lambdas directory missing."
  exit 1
}

terraform init
terraform apply -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Build static web application
# ------------------------------------------------------------------------------

# Retrieves the API Gateway endpoint and injects it into the
# static HTML client using environment variable substitution.

# Lookup API Gateway ID by name.
API_ID=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='notes-api'].ApiId" \
  --output text)

# Fail if the API does not exist.
if [[ -z "${API_ID}" || "${API_ID}" == "None" ]]; then
  echo "ERROR: No API found with name 'notes-api'"
  exit 1
fi

# Retrieve the API Gateway endpoint URL.
URL=$(aws apigatewayv2 get-api \
  --api-id "${API_ID}" \
  --query "ApiEndpoint" \
  --output text)

# Export API base URL for template substitution.
export API_BASE="${URL}"
echo "NOTE: API Gateway URL - ${API_BASE}"

echo "NOTE: Building Simple Web Application..."

cd 02-webapp || {
  echo "ERROR: 02-webapp directory missing."
  exit 1
}

# Substitute API endpoint into HTML template.
envsubst '${API_BASE}' < index.html.tmpl > index.html || {
  echo "ERROR: Failed to generate index.html file. Exiting."
  exit 1
}

terraform init
terraform apply -auto-approve

cd .. || exit

# ------------------------------------------------------------------------------
# Post-deployment validation (optional)
# ------------------------------------------------------------------------------

# Executes runtime validation checks once implemented.
echo "NOTE: Running build validation..."
./validate.sh

# ================================================================================
# End of script
# ================================================================================
