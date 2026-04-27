# CLAUDE.md — aws-crud-example

A serverless notes CRUD API on AWS. Five Lambda functions handle one REST operation each, DynamoDB stores the data, API Gateway (HTTP API v2) routes requests, and a static S3 site provides a browser UI. This is the AWS reference implementation; GCP and Azure ports exist as parallel projects.

---

## What This Project Does

Clients hit an API Gateway HTTP API that routes each operation to a dedicated Lambda function. DynamoDB persists the notes. A static HTML frontend served from S3 makes API calls directly to the API Gateway endpoint.

**Base URL after deploy:**
```
https://{api-id}.execute-api.us-east-1.amazonaws.com
```

| Method | Path | Lambda | Operation |
|--------|------|--------|-----------|
| POST | `/notes` | create-note | Create note |
| GET | `/notes` | list-notes | List all notes |
| GET | `/notes/{id}` | get-note | Get single note |
| PUT | `/notes/{id}` | update-note | Update note |
| DELETE | `/notes/{id}` | delete-note | Delete note |

---

## Architecture

```
Browser / curl
     │
     ▼
API Gateway (HTTP API v2) — notes-api
     │  routes by method + path
     ├── POST   /notes        → Lambda: create-note  (create.py)
     ├── GET    /notes        → Lambda: list-notes   (list.py)
     ├── GET    /notes/{id}   → Lambda: get-note     (get.py)
     ├── PUT    /notes/{id}   → Lambda: update-note  (update.py)
     └── DELETE /notes/{id}  → Lambda: delete-note  (delete.py)
                │
                ▼
          DynamoDB table: notes
          PK: owner (string)
          SK: id    (string, UUID)
```

**Why five functions instead of one:** The AWS pattern uses one Lambda per route with API Gateway handling routing. This is the idiomatic AWS approach; contrast with the GCP port which uses a single Cloud Function with internal routing (no API Gateway needed).

---

## Repository Layout

```
01-lambdas/
  code/
    create.py         Lambda: create a note
    list.py           Lambda: list all notes
    get.py            Lambda: get a note by ID
    update.py         Lambda: update a note
    delete.py         Lambda: delete a note
  main.tf             Terraform: AWS provider, data sources
  dynamodb.tf         Terraform: DynamoDB table (owner PK, id SK)
  api.tf              Terraform: API Gateway HTTP API, routes, integrations, stages
  lambda-post.tf      Terraform: IAM role + Lambda for create
  lambda-list.tf      Terraform: IAM role + Lambda for list
  lambda-get.tf       Terraform: IAM role + Lambda for get
  lambda-update.tf    Terraform: IAM role + Lambda for update
  lambda-delete.tf    Terraform: IAM role + Lambda for delete
02-webapp/
  index.html.tmpl     Web UI template — API_BASE injected at deploy time
  main.tf             Terraform: AWS provider
  s3.tf               Terraform: public S3 static site
check_env.sh          Pre-flight: verify aws/terraform/jq, test AWS credentials
apply.sh              Full deployment (both phases + validation)
destroy.sh            Teardown in reverse order
validate.sh           End-to-end CRUD smoke test via curl
```

---

## Prerequisites

- `aws`, `terraform`, `jq` in PATH
- AWS credentials configured (environment variables or `~/.aws/credentials`)
- Sufficient IAM permissions: Lambda, DynamoDB, API Gateway, S3, IAM

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

`apply.sh` runs in two phases:
1. **`check_env.sh`** → validates tools and AWS credentials
2. **`01-lambdas`** → deploys DynamoDB, all five Lambdas, API Gateway, IAM roles
3. Looks up API Gateway endpoint via `aws apigatewayv2 get-apis`, injects into `index.html.tmpl` via `envsubst`
4. **`02-webapp`** → deploys public S3 bucket, uploads generated `index.html`
5. **`validate.sh`** → creates, lists, gets, updates, and deletes 5 test notes

---

## Terraform Modules

### 01-lambdas
- `aws_dynamodb_table` `notes` — PAY_PER_REQUEST, PK=owner, SK=id
- Five `aws_lambda_function` resources (Python 3.14, 15s timeout), one per operation
- Five `aws_iam_role` resources with scoped DynamoDB policies (least-privilege per operation)
- `aws_apigatewayv2_api` `notes-api` — HTTP API with CORS configured
- Five `aws_apigatewayv2_integration` + `aws_apigatewayv2_route` pairs wiring routes to Lambdas
- `aws_apigatewayv2_stage` `$default` with auto_deploy
- Five `aws_lambda_permission` resources granting API Gateway invoke rights

### 02-webapp
- `aws_s3_bucket` with public-read static website hosting
- `aws_s3_bucket_object` uploads `index.html` (generated from template)

---

## Lambda Code

All five handlers follow the same pattern:
- Read `NOTES_TABLE_NAME` from environment
- Parse the API Gateway v2 payload format event
- Interact with DynamoDB via `boto3.resource("dynamodb")`
- Return `{"statusCode": N, "headers": {...}, "body": json.dumps(...)}`

**DynamoDB data model:**
- Table: `notes`
- PK: `owner` (always `"global"` — hardcoded, no auth)
- SK: `id` (UUID4)
- Fields: `owner`, `id`, `title`, `note`, `created_at`, `updated_at`

---

## Test Manually

```bash
BASE=$(aws apigatewayv2 get-apis \
  --query "Items[?Name=='notes-api'].ApiId" --output text | \
  xargs -I{} aws apigatewayv2 get-api --api-id {} \
  --query ApiEndpoint --output text)

# Create
curl -X POST "$BASE/notes" -H "Content-Type: application/json" \
  -d '{"title":"Hello","note":"World"}'

# List
curl "$BASE/notes"

# Get / Update / Delete (replace ID)
curl "$BASE/notes/{id}"
curl -X PUT "$BASE/notes/{id}" -H "Content-Type: application/json" \
  -d '{"title":"Updated","note":"Body"}'
curl -X DELETE "$BASE/notes/{id}"
```
