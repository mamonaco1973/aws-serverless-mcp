# CLAUDE.md — aws-serverless-mcp

A serverless AWS Cost Explorer API designed for MCP (Model Context Protocol) tool use.
Six Lambda functions expose cost query tools behind an API Gateway HTTP API with
AWS_IAM authorization. A local MCP proxy (built separately) signs requests with
SigV4, making the remote serverless API transparent to the AI caller.

---

## What This Project Does

An AI assistant calls MCP tools that appear local but are backed by Lambda functions
running in AWS. Each tool queries the Cost Explorer API and returns a plain-text
summary suitable for direct narration — not raw CE JSON.

**Base URL after deploy:**
```
https://{api-id}.execute-api.us-east-1.amazonaws.com
```

| Tool Name | Route | Lambda | Operation |
|-----------|-------|--------|-----------|
| get_month_to_date_cost | `POST /cost/month-to-date` | cost-mtd | MTD total spend |
| get_cost_by_service | `POST /cost/by-service` | cost-by-service | Per-service breakdown |
| compare_this_month_to_last_month | `POST /cost/compare-months` | cost-compare | MoM delta |
| get_daily_cost_trend | `POST /cost/daily-trend` | cost-daily | Day-by-day spend |
| find_top_cost_drivers | `POST /cost/top-drivers` | cost-top-drivers | Ranked services |
| forecast_month_end_cost | `POST /cost/forecast` | cost-forecast | CE forecast |

---

## Architecture

```
AI assistant (MCP client)
     │  stdio / JSON-RPC
     ▼
Local MCP proxy  ← holds IAM credentials, signs with SigV4
     │  HTTPS + AWS_IAM auth
     ▼
API Gateway (HTTP API v2) — costs-api
     │  routes by method + path
     ├── POST /cost/month-to-date  → Lambda: cost-mtd
     ├── POST /cost/by-service     → Lambda: cost-by-service
     ├── POST /cost/compare-months → Lambda: cost-compare
     ├── POST /cost/daily-trend    → Lambda: cost-daily
     ├── POST /cost/top-drivers    → Lambda: cost-top-drivers
     └── POST /cost/forecast       → Lambda: cost-forecast
                │
                ▼
          AWS Cost Explorer API (global, us-east-1 endpoint)
```

**Why plain-text responses:** CE returns nested ResultsByTime arrays. Returning
pre-formatted summaries lets the AI narrate results without parsing, and keeps
the MCP tool contract simple.

**Why IAM auth:** The proxy signs every request with the caller's AWS credentials.
API Gateway enforces IAM authorization before the Lambda is invoked — no API keys
to rotate and no unauthenticated access possible.

---

## Repository Layout

```
01-lambdas/
  code/
    costs.py              All six handler functions (single file, single ZIP)
  main.tf                 Terraform: AWS provider, data sources, archive_file
  api.tf                  Terraform: HTTP API, 6 routes (AWS_IAM), integrations, stage
  lambda-mtd.tf           Terraform: IAM role + Lambda for cost-mtd
  lambda-by-service.tf    Terraform: IAM role + Lambda for cost-by-service
  lambda-compare.tf       Terraform: IAM role + Lambda for cost-compare
  lambda-daily.tf         Terraform: IAM role + Lambda for cost-daily
  lambda-top-drivers.tf   Terraform: IAM role + Lambda for cost-top-drivers
  lambda-forecast.tf      Terraform: IAM role + Lambda for cost-forecast
check_env.sh              Pre-flight: verify aws/terraform/jq, test AWS credentials
apply.sh                  Full deployment + validation
destroy.sh                Teardown
validate.sh               Smoke test via direct Lambda invocation (bypasses IAM auth)
```

---

## Prerequisites

- `aws`, `terraform`, `jq` in PATH
- AWS credentials configured with permissions:
  - Lambda, API Gateway, IAM (for deploy)
  - `ce:GetCostAndUsage`, `ce:GetCostForecast` (for the Lambda execution roles)
- Cost Explorer must be enabled in the AWS account (Console → Billing → Cost Explorer)

---

## Deployment

```bash
# Full deploy
./apply.sh

# Teardown
./destroy.sh

# Smoke test only (after deploy)
./validate.sh
```

`apply.sh` runs in one phase:
1. **`check_env.sh`** → validates tools and AWS credentials
2. **`01-lambdas`** → deploys all six Lambdas, API Gateway, IAM roles
3. **`validate.sh`** → invokes each Lambda directly and prints the plain-text output

---

## Terraform Modules

### 01-lambdas
- Six `aws_lambda_function` resources (Python 3.14, 15s timeout), one per tool
- Six `aws_iam_role` resources with scoped CE policies (least-privilege per tool):
  - `ce:GetCostAndUsage` for mtd, by-service, compare, daily, top-drivers
  - `ce:GetCostForecast` for forecast (separate action)
- `aws_apigatewayv2_api` `costs-api` — HTTP API (no CORS, IAM auth only)
- Six `aws_apigatewayv2_integration` + `aws_apigatewayv2_route` pairs
- All routes: `authorization_type = "AWS_IAM"`
- `aws_apigatewayv2_stage` `$default` with auto_deploy
- Six `aws_lambda_permission` resources granting API Gateway invoke rights

---

## Lambda Code

All six handlers live in `costs.py` and follow the same pattern:
- Compute date windows using `datetime` and `calendar.monthrange`
- Call `boto3.client("ce", region_name="us-east-1")` — CE endpoint is always us-east-1
- Return `{"statusCode": 200, "headers": {"Content-Type": "text/plain"}, "body": "..."}`
- Body is a human-readable plain-text summary, not raw CE JSON
- Handle `DataUnavailableException` from `GetCostForecast` gracefully

**CE date range convention:**
- Start is inclusive, end is exclusive
- MTD queries use end = tomorrow to capture today's partial data
- Full-month queries use end = first day of next month

---

## Test Manually

```bash
# Invoke any tool directly (no SigV4 needed for direct Lambda calls)
aws lambda invoke \
  --function-name cost-mtd \
  --payload '{}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/out.json && jq -r '.body' /tmp/out.json

# Via API Gateway (requires SigV4 signing — use awscurl or the MCP proxy)
awscurl --service execute-api --region us-east-1 \
  -X POST https://{api-id}.execute-api.us-east-1.amazonaws.com/cost/month-to-date
```
