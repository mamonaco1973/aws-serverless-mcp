# Serverless MCP on AWS: Cost Explorer Tools

A **serverless MCP (Model Context Protocol) backend** that lets an AI
assistant ask about your AWS costs in plain English. Seven **Lambda**
functions, six cost tools plus a tool registry, sit behind an **API Gateway
HTTP API** that requires **AWS IAM** on every route. A small local proxy
speaks MCP over stdio to the AI client and signs each request with SigV4,
so the remote API looks like a local tool server.

| Piece | Where | Role |
|---|---|---|
| **proxy.sh** / **proxy.ps1** | your machine | stdio MCP server (JSON-RPC 2.0); loads its tool list from `GET /tools`; signs requests with SigV4 |
| **costs-api** | API Gateway, us-east-1 | HTTP API, `$default` stage, seven routes, all `AWS_IAM`; no CORS |
| **cost-tools** | Lambda | returns `TOOL_REGISTRY` from `costs.py`: names, descriptions, input schemas and routes |
| **6 cost functions** | Lambda | Python 3.14, 15 s timeout, all from `costs.py`; each role allows only the Cost Explorer action it needs |
| **cost-mcp-proxy** | IAM user + Secrets Manager | an access key limited to `execute-api:Invoke` on this API; the secret holds the key, endpoint and region |

## Architecture

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="architecture-dark.svg">
  <img alt="Claude Desktop runs proxy.sh or proxy.ps1 as a local MCP server over stdio. The proxy signs every request with SigV4 using the cost-mcp-proxy IAM user's keys, which apply.sh reads from Secrets Manager into the Claude config, and calls costs-api, an API Gateway HTTP API that requires AWS_IAM on every route. At startup it calls GET /tools, served by the cost-tools Lambda, to learn the tool list; tool calls go to POST /cost/* routes, each a Python 3.14 Lambda with a role scoped to the Cost Explorer action it needs." src="architecture-light.svg">
</picture>

Regenerate with `python3 make_diagram.py`.

- **`01-lambdas/`**: `api.tf` (API, routes, integrations, stage), one
  `lambda-*.tf` per function with its role, `iam-proxy-user.tf` (the proxy
  user, key and secret), and the shared code in `code/costs.py`.
- **`02-proxy/`**: the Bash and PowerShell proxies, and Claude Desktop
  config templates for each.

## MCP tools

| Tool | Route | Lambda | Returns |
|---|---|---|---|
| `get_month_to_date_cost` | `POST /cost/month-to-date` | `cost-mtd` | total spend from the 1st through today |
| `get_cost_by_service` | `POST /cost/by-service` | `cost-by-service` | month-to-date spend per service, highest first |
| `compare_this_month_to_last_month` | `POST /cost/compare-months` | `cost-compare` | this month so far vs. last month's total |
| `get_daily_cost_trend` | `POST /cost/daily-trend` | `cost-daily` | spend per day this month, with running totals |
| `find_top_cost_drivers` | `POST /cost/top-drivers` | `cost-top-drivers` | the top 10 services with their share |
| `forecast_month_end_cost` | `POST /cost/forecast` | `cost-forecast` | projected remaining spend, with an 80% range |

Every tool returns a plain-text summary rather than Cost Explorer's nested
JSON, so the AI can read it out directly:

```
Top AWS cost drivers (2026-04-01 through 2026-04-27):
   1. Amazon EC2: $87.14 (61.2% of total)
   2. Amazon RDS: $31.20 (21.9% of total)
   3. AWS Lambda: $12.50 (8.8% of total)
   ...
  Total across all services: $142.38
```

### How the proxy configures itself

At startup the proxy calls `GET /tools` (signed) and gets `TOOL_REGISTRY`:

```json
[
  {
    "name": "get_month_to_date_cost",
    "description": "Returns total AWS spend from the first of this month through today.",
    "inputSchema": { "type": "object", "properties": {} },
    "route": "/cost/month-to-date"
  }
]
```

It keeps `route` for itself and hands the AI the standard MCP fields. To add
a tool, add it to `costs.py` and redeploy; the proxy picks it up on its next
start. Because the proxy has no tool-specific code, it can front any backend
that serves `GET /tools` in this format.

## Prerequisites

* [An AWS Account](https://aws.amazon.com/console/) with **Cost Explorer
  enabled** (Billing console > Cost Explorer)
* [Install AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html)
* [Install Terraform](https://developer.hashicorp.com/terraform/install)
* [Install jq](https://jqlang.github.io/jq/download/) and `envsubst`
  (for `apply.sh`)
* `bash` 4+, `curl` and `openssl` (for `proxy.sh`), or PowerShell (for
  `proxy.ps1`)
* An MCP client: Claude Desktop, or any host that supports stdio servers

If this is your first time following along, we recommend starting with this
video: [AWS + Terraform: Easy Setup](https://www.youtube.com/watch?v=9clW3VQLyxA).

## Deploy

```bash
git clone https://github.com/mamonaco1973/aws-serverless-mcp.git
cd aws-serverless-mcp
./apply.sh
```

Everything deploys to `us-east-1`. After Terraform, `apply.sh` reads the
`cost-mcp-proxy` secret and writes `02-proxy/claude_desktop_config_sh.json`
and `claude_desktop_config_ps1.json` (both gitignored) with the real key and
endpoint. It ends by running `validate.sh`, which invokes each Lambda
directly with `aws lambda invoke` and prints its output, then checks the
tool registry.

## Try it

1. Copy the `mcpServers` block from `02-proxy/claude_desktop_config_sh.json`
   (Bash) or `claude_desktop_config_ps1.json` (PowerShell) into your Claude
   Desktop `claude_desktop_config.json`, and fix the proxy script path for
   your machine.
2. Restart Claude Desktop and ask, for example, "What are my top AWS cost
   drivers this month?" or "Forecast my month-end AWS bill."
3. To call a function without the proxy:

   ```bash
   aws lambda invoke --function-name cost-mtd --payload '{}' \
     --cli-binary-format raw-in-base64-out /tmp/out.json && jq -r .body /tmp/out.json
   ```

## Teardown

```bash
./destroy.sh
```

## Notes

- The proxy user's secret key is in Secrets Manager and in the generated
  config files on your machine; keep those files private.
- `webapp.png` in this repository shows a different project (a notes demo)
  and isn't used here.
