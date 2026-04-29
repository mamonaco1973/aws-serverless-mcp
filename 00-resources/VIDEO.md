#AWS #MCP #ModelContextProtocol #AWSLambda #APIGateway #Terraform #Python #ClaudeDesktop #Serverless #IAM

*Build a Serverless MCP Backend on AWS (Lambda + API Gateway + SigV4)*

What if your AI assistant could query your AWS costs just by asking? In this project we build a fully serverless MCP backend using API Gateway, Lambda, and AWS IAM — then connect it to Claude Desktop and OpenAI Codex using a lightweight stdio proxy.

The proxy makes the remote AWS backend look like a local MCP server. The AI never knows the difference — but every request is signed with SigV4 and authorized by IAM before a single Lambda function runs.

Six cost tools are exposed as MCP tools: month-to-date spend, cost by service, month-over-month comparison, daily trend, top drivers, and a month-end forecast. A seventh endpoint acts as a self-configuring tool registry — the proxy discovers routes at startup, so adding a new tool requires no proxy changes.

This pattern works with Claude Desktop, OpenAI Codex, Cursor, and any other MCP client that supports stdio transport.

WHAT YOU'LL LEARN
• The serverless MCP backend pattern — remote tools that look local to any AI client
• Writing a stdio MCP proxy in Bash (and PowerShell) that signs requests with AWS SigV4
• Securing API Gateway routes with AWS_IAM authorization (no API keys to rotate)
• Applying least-privilege IAM — one scoped role per Lambda, one proxy user with invoke-only rights
• Implementing self-configuring tool discovery via a /tools registry endpoint
• Storing and retrieving proxy credentials from Secrets Manager

INFRASTRUCTURE DEPLOYED
• API Gateway HTTP API v2 (costs-api) — 7 routes, all AWS_IAM authorized
• 7 Lambda functions (Python 3.14) — 6 cost query tools + 1 tool registry
• 7 IAM roles with scoped Cost Explorer permissions per function
• IAM user (cost-mcp-proxy) scoped to execute-api:Invoke on this API only
• Secrets Manager secret storing proxy credentials (key ID, secret, endpoint, region)
• MCP proxy (proxy.sh / proxy.ps1) — stdio bridge with SigV4 signing

GitHub
https://github.com/mamonaco1973/aws-serverless-mcp

README
https://github.com/mamonaco1973/aws-serverless-mcp/blob/main/README.md

TIMESTAMPS
00:00 Introduction
00:17 Architecture
00:55 Build the Code
01:45 Build Results
03:00 Demo
